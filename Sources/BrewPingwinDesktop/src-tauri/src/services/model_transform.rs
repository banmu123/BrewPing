//! 协议转换：Anthropic Messages ↔ OpenAI Chat Completions。
//!
//! 迁移自 cc-switch `proxy/providers/transform.rs`（非流式）与
//! `proxy/providers/streaming.rs`（SSE 流式状态机），保留核心行为、裁剪
//! Copilot/Codex 专有逻辑。两个方向的约定：
//!
//! - **入站 Anthropic（Claude Code POST /v1/messages）→ 上游 openai_chat**：
//!   请求体转换 + 非流式响应转回 + SSE 流转回；
//! - 其余组合（anthropic 客户端→anthropic 上游、openai 客户端→openai 上游）
//!   仍是逐字节透传，不经过本模块。
//!
//! 关键语义（与 cc-switch 逐条对齐）：
//! - system 顶层数组**合并为一条 system 消息**（跨轮字节稳定，利于前缀缓存），
//!   并剥掉 Claude Code 注入的首行 billing header；
//! - `tool_result` 块 → 独立 `role:"tool"` 消息；`tool_use` → `tool_calls`；
//! - `thinking` 默认**丢弃**（OpenAI 通用后端不认识），仅在 preserve 模式
//!   （DeepSeek/MiMo 等推理厂商）映射为 `reasoning_content`；
//! - o-series 模型 `max_tokens` → `max_completion_tokens`；
//!   `thinking.budget_tokens` → `reasoning_effort`（仅 GPT-5+/o-series/grok-4.5）；
//! - 流式请求强制注入 `stream_options.include_usage`，否则拿不到 usage；
//! - 响应 usage：OpenAI `prompt_tokens` 含缓存命中，Anthropic 不含 →
//!   `input = prompt - cache_read - cache_creation`（三桶互斥恒等）；
//! - SSE：`message_start`/`content_block_*`/`message_delta`/`message_stop` 全套
//!   Anthropic 事件；finish_reason 只处理第一个（其余仅更新 usage），缓存的
//!   `message_delta` 延迟到 `[DONE]` 才发，保证 usage 完整且唯一；
//! - tool_calls 按 OpenAI 的 `index` 路由到各自的 Anthropic block，id/name 齐
//!   了才 start（部分上游先吐 arguments 再吐 id/name，需缓存 pending args）。
//!
//! 模块不依赖 tauri 类型（services 层同款约束）。

use serde_json::{json, Map, Value};
use std::collections::HashMap;

/// Claude Code 在 system prompt 首行注入的计费标记（转发前剥除）。
const BILLING_HEADER_PREFIX: &str = "x-anthropic-billing-header:";

/// thinking 历史占位（preserve 模式下 assistant 工具调用消息缺 thinking 时注入）。
const THINKING_PLACEHOLDER: &str = "[thinking]";

// ─────────────────────────────── 请求转换 ───────────────────────────────

/// Anthropic Messages 请求体 → OpenAI Chat Completions 请求体。
///
/// `preserve_reasoning_content`：仅 DeepSeek/MiMo 等明确需要 `reasoning_content`
/// 兼容字段的厂商开启（按 base_url/model 名含推理厂商关键词判定，见
/// [`is_reasoning_vendor`]）。通用后端不发送该非标准字段。
pub fn anthropic_to_openai(body: Value, preserve_reasoning_content: bool) -> Result<Value, String> {
    let obj = body
        .as_object()
        .ok_or_else(|| "anthropic request body must be a JSON object".to_string())?;
    let model = obj.get("model").and_then(Value::as_str).unwrap_or("");

    let mut result = Map::new();
    if !model.is_empty() {
        result.insert("model".into(), json!(model));
    }

    let mut messages: Vec<Value> = Vec::new();

    // system：字符串或块数组 → 合并为一条 system 消息
    match obj.get("system") {
        Some(Value::String(text)) => {
            let text = strip_billing_header(text);
            if !text.is_empty() {
                messages.push(json!({ "role": "system", "content": text }));
            }
        }
        Some(Value::Array(parts)) => {
            let mut texts = Vec::new();
            for part in parts {
                if let Some(text) = part.get("text").and_then(Value::as_str) {
                    let text = strip_billing_header(text);
                    if !text.is_empty() {
                        texts.push(text.to_string());
                    }
                }
            }
            if !texts.is_empty() {
                messages.push(json!({ "role": "system", "content": texts.join("\n") }));
            }
        }
        _ => {}
    }

    if let Some(msgs) = obj.get("messages").and_then(Value::as_array) {
        for msg in msgs {
            let role = msg.get("role").and_then(Value::as_str).unwrap_or("user");
            messages.extend(convert_message(role, msg.get("content"), preserve_reasoning_content));
        }
    }
    result.insert("messages".into(), Value::Array(messages));

    // 参数映射；o-series 需要 max_completion_tokens
    if let Some(v) = obj.get("max_tokens") {
        let key = if is_openai_o_series(model) {
            "max_completion_tokens"
        } else {
            "max_tokens"
        };
        result.insert(key.into(), v.clone());
    }
    for (from, to) in [("temperature", "temperature"), ("top_p", "top_p")] {
        if let Some(v) = obj.get(from) {
            result.insert(to.into(), v.clone());
        }
    }
    if let Some(v) = obj.get("stop_sequences") {
        result.insert("stop".into(), v.clone());
    }
    if let Some(v) = obj.get("stream") {
        result.insert("stream".into(), v.clone());
    }

    // thinking → reasoning_effort（仅支持的模型族；与 cc-switch resolve_reasoning_effort 一致）
    if supports_reasoning_effort(model) {
        if let Some(effort) = resolve_reasoning_effort(obj) {
            result.insert("reasoning_effort".into(), json!(effort));
        }
    }

    // tools：Anthropic {name,description,input_schema} → OpenAI function 格式
    if let Some(tools) = obj.get("tools").and_then(Value::as_array) {
        let openai_tools: Vec<Value> = tools
            .iter()
            .filter(|t| t.get("type").and_then(Value::as_str) != Some("BatchTool"))
            .map(|t| {
                json!({
                    "type": "function",
                    "function": {
                        "name": t.get("name").and_then(Value::as_str).unwrap_or(""),
                        "description": t.get("description"),
                        "parameters": clean_schema(t.get("input_schema").cloned().unwrap_or(json!({}))),
                    }
                })
            })
            .collect();
        if !openai_tools.is_empty() {
            result.insert("tools".into(), Value::Array(openai_tools));
        }
    }
    if let Some(v) = obj.get("tool_choice") {
        result.insert("tool_choice".into(), map_tool_choice(v));
    }

    // 流式必须声明 include_usage，否则末尾拿不到 usage chunk
    inject_stream_include_usage(&mut result);

    Ok(Value::Object(result))
}

/// 单条 Anthropic 消息 → 一到多条 OpenAI 消息。
fn convert_message(role: &str, content: Option<&Value>, preserve_reasoning: bool) -> Vec<Value> {
    let Some(content) = content else {
        return vec![json!({ "role": role, "content": null })];
    };
    // 纯字符串直接透传
    if let Some(text) = content.as_str() {
        return vec![json!({ "role": role, "content": text })];
    }
    let Some(blocks) = content.as_array() else {
        return vec![json!({ "role": role, "content": content })];
    };

    let mut out: Vec<Value> = Vec::new();
    let mut parts: Vec<Value> = Vec::new();
    let mut tool_calls: Vec<Value> = Vec::new();
    let mut reasoning: Vec<String> = Vec::new();

    for block in blocks {
        match block.get("type").and_then(Value::as_str).unwrap_or("") {
            "text" => {
                if let Some(text) = block.get("text").and_then(Value::as_str) {
                    parts.push(json!({ "type": "text", "text": text }));
                }
            }
            "image" => {
                // base64 图像 → OpenAI image_url data URI（非 base64 源丢弃）
                if let Some(src) = block.get("source") {
                    let media = src.get("media_type").and_then(Value::as_str).unwrap_or("");
                    let data = src.get("data").and_then(Value::as_str).unwrap_or("");
                    if src.get("type").and_then(Value::as_str) == Some("base64")
                        && media.starts_with("image/")
                        && !data.is_empty()
                    {
                        parts.push(json!({
                            "type": "image_url",
                            "image_url": { "url": format!("data:{media};base64,{data}") }
                        }));
                    }
                }
            }
            "tool_use" => {
                let input = block.get("input").cloned().unwrap_or(json!({}));
                tool_calls.push(json!({
                    "id": block.get("id").and_then(Value::as_str).unwrap_or(""),
                    "type": "function",
                    "function": {
                        "name": block.get("name").and_then(Value::as_str).unwrap_or(""),
                        "arguments": input.to_string(),
                    }
                }));
            }
            "tool_result" => {
                let tool_use_id = block.get("tool_use_id").and_then(Value::as_str).unwrap_or("");
                // Chat 的 tool 消息不能带图；非文本内容降级为 JSON 字符串
                let content_str = match block.get("content") {
                    Some(Value::String(s)) => s.clone(),
                    Some(v) => v.to_string(),
                    None => String::new(),
                };
                out.push(json!({
                    "role": "tool",
                    "tool_call_id": tool_use_id,
                    "content": content_str,
                }));
            }
            "thinking" => {
                if preserve_reasoning {
                    if let Some(t) = block.get("thinking").and_then(Value::as_str) {
                        if !t.is_empty() {
                            reasoning.push(t.to_string());
                        }
                    }
                }
            }
            "redacted_thinking" if preserve_reasoning => {
                reasoning.push("[redacted thinking]".to_string());
            }
            _ => {}
        }
    }

    if !parts.is_empty() || !tool_calls.is_empty() {
        let mut msg = Map::new();
        msg.insert("role".into(), json!(role));
        msg.insert(
            "content".into(),
            if parts.is_empty() {
                Value::Null
            } else if parts.len() == 1 && parts[0].get("type").and_then(Value::as_str) == Some("text")
            {
                // 单 text 块简化为纯字符串（对齐 cc-switch，利于上游兼容）
                parts[0].get("text").cloned().unwrap_or(Value::Null)
            } else {
                Value::Array(parts)
            },
        );
        if !tool_calls.is_empty() {
            msg.insert("tool_calls".into(), Value::Array(tool_calls.clone()));
        }
        // DeepSeek/MiMo 要求 assistant 工具调用消息带非空 reasoning_content
        if preserve_reasoning && role == "assistant" && !tool_calls.is_empty() {
            let r = if reasoning.is_empty() {
                THINKING_PLACEHOLDER.to_string()
            } else {
                reasoning.join("\n")
            };
            msg.insert("reasoning_content".into(), json!(r));
        }
        out.push(Value::Object(msg));
    }
    out
}

/// `tool_choice`：`"any"` → `"required"`；`{type:"tool",name}` → function 选择器。
fn map_tool_choice(v: &Value) -> Value {
    match v {
        Value::String(s) if s == "any" => json!("required"),
        Value::Object(obj) => match obj.get("type").and_then(Value::as_str) {
            Some("any") => json!("required"),
            Some("tool") => json!({
                "type": "function",
                "function": { "name": obj.get("name").and_then(Value::as_str).unwrap_or("") }
            }),
            _ => v.clone(),
        },
        _ => v.clone(),
    }
}

/// 工具参数 schema 清理：根补 `type:"object"`、去 `format:"uri"`（OpenAI 拒绝）、递归。
fn clean_schema(schema: Value) -> Value {
    clean_schema_inner(schema, true)
}

fn clean_schema_inner(mut schema: Value, is_root: bool) -> Value {
    if let Some(obj) = schema.as_object_mut() {
        let missing_type = is_root && !obj.contains_key("type");
        if missing_type {
            obj.insert("type".into(), json!("object"));
            if !obj.contains_key("properties") {
                obj.insert("properties".into(), json!({}));
            }
        }
        if obj.get("format").and_then(Value::as_str) == Some("uri") {
            obj.remove("format");
        }
        if let Some(props) = obj.get_mut("properties").and_then(Value::as_object_mut) {
            for (_, v) in props.iter_mut() {
                *v = clean_schema_inner(v.clone(), false);
            }
        }
        if let Some(items) = obj.get_mut("items") {
            *items = clean_schema_inner(items.clone(), false);
        }
    }
    schema
}

fn inject_stream_include_usage(result: &mut Map<String, Value>) {
    let is_stream = result.get("stream").and_then(Value::as_bool).unwrap_or(false);
    if !is_stream {
        return;
    }
    match result.get_mut("stream_options") {
        Some(Value::Object(opts)) => {
            opts.insert("include_usage".into(), json!(true));
        }
        _ => {
            result.insert("stream_options".into(), json!({ "include_usage": true }));
        }
    }
}

fn strip_billing_header(text: &str) -> &str {
    if !text.starts_with(BILLING_HEADER_PREFIX) {
        return text;
    }
    match text.find('\n') {
        Some(pos) => text[pos + 1..].trim_start_matches(['\r', '\n']),
        None => "",
    }
}

/// o-series 判定（o1/o3/o4-mini…）：需要 max_completion_tokens。
pub fn is_openai_o_series(model: &str) -> bool {
    let b = model.as_bytes();
    model.len() > 1 && b[0] == b'o' && b.get(1).is_some_and(|c| c.is_ascii_digit())
}

/// 支持 reasoning_effort 的模型族：o-series / gpt-5+ / grok-4.5。
fn supports_reasoning_effort(model: &str) -> bool {
    let m = model.to_lowercase();
    is_openai_o_series(&m)
        || m.strip_prefix("gpt-")
            .and_then(|rest| rest.chars().next())
            .is_some_and(|c| c.is_ascii_digit() && c >= '5')
        || m == "grok-4.5"
        || m.starts_with("grok-4.5-")
}

/// thinking → reasoning_effort（对齐 cc-switch resolve_reasoning_effort）：
/// output_config.effort 优先（max→xhigh）；否则按 budget_tokens 分档。
fn resolve_reasoning_effort(obj: &Map<String, Value>) -> Option<&'static str> {
    if let Some(effort) = obj
        .get("output_config")
        .and_then(|v| v.get("effort"))
        .and_then(Value::as_str)
    {
        return match effort {
            "low" => Some("low"),
            "medium" => Some("medium"),
            "high" => Some("high"),
            "max" => Some("xhigh"),
            _ => None,
        };
    }
    let thinking = obj.get("thinking")?;
    match thinking.get("type").and_then(Value::as_str) {
        Some("adaptive") => Some("xhigh"),
        Some("enabled") => match thinking.get("budget_tokens").and_then(Value::as_u64) {
            Some(b) if b < 4_000 => Some("low"),
            Some(b) if b < 16_000 => Some("medium"),
            Some(_) => Some("high"),
            None => Some("high"),
        },
        _ => None,
    }
}

/// 推理厂商判定（preserve reasoning_content 开关；对齐 cc-switch 的
/// REASONING_VENDOR_HINTS：DeepSeek / MiMo / Kimi 等思考型厂商关键词）。
pub fn is_reasoning_vendor(value: &str) -> bool {
    let v = value.to_lowercase();
    ["deepseek", "mimo", "kimi", "moonshot", "glm-4", "zhipu", "qwen3"]
        .iter()
        .any(|hint| v.contains(hint))
}

// ─────────────────────────────── 非流式响应 ───────────────────────────────

/// OpenAI Chat Completions 响应 → Anthropic Messages 响应。
pub fn openai_to_anthropic(body: Value) -> Result<Value, String> {
    let choice = body
        .pointer("/choices/0")
        .ok_or_else(|| "openai response has no choices".to_string())?;
    let message = choice
        .get("message")
        .ok_or_else(|| "openai choice has no message".to_string())?;

    let mut content: Vec<Value> = Vec::new();
    let mut has_tool_use = false;

    // DeepSeek/MiMo 思考内容 → thinking 块
    if let Some(r) = message.get("reasoning_content").and_then(Value::as_str) {
        if !r.is_empty() {
            content.push(json!({ "type": "thinking", "thinking": r }));
        }
    }

    match message.get("content") {
        Some(Value::String(text)) if !text.is_empty() => {
            content.push(json!({ "type": "text", "text": text }));
        }
        Some(Value::Array(parts)) => {
            for part in parts {
                let ptype = part.get("type").and_then(Value::as_str).unwrap_or("");
                if matches!(ptype, "text" | "output_text" | "refusal") {
                    if let Some(text) = part.get(ptype).and_then(Value::as_str) {
                        if !text.is_empty() {
                            content.push(json!({ "type": "text", "text": text }));
                        }
                    }
                }
            }
        }
        _ => {}
    }
    if let Some(refusal) = message.get("refusal").and_then(Value::as_str) {
        if !refusal.is_empty() {
            content.push(json!({ "type": "text", "text": refusal }));
        }
    }

    if let Some(tool_calls) = message.get("tool_calls").and_then(Value::as_array) {
        for tc in tool_calls {
            let func = tc.get("function").cloned().unwrap_or(json!({}));
            let name = func.get("name").and_then(Value::as_str).unwrap_or("");
            let args = func.get("arguments").and_then(Value::as_str).unwrap_or("{}");
            let input: Value = serde_json::from_str(args).unwrap_or(json!({}));
            content.push(json!({
                "type": "tool_use",
                "id": tc.get("id").and_then(Value::as_str).unwrap_or(""),
                "name": name,
                "input": input,
            }));
        }
        has_tool_use = true;
    }
    // 旧 function_call 格式兼容
    if !has_tool_use {
        if let Some(fc) = message.get("function_call") {
            let name = fc.get("name").and_then(Value::as_str).unwrap_or("");
            let input = match fc.get("arguments") {
                Some(Value::String(s)) => serde_json::from_str(s).unwrap_or(json!({})),
                Some(v) => v.clone(),
                None => json!({}),
            };
            if !name.is_empty() {
                content.push(json!({
                    "type": "tool_use",
                    "id": fc.get("id").and_then(Value::as_str).unwrap_or(""),
                    "name": name,
                    "input": input,
                }));
                has_tool_use = true;
            }
        }
    }

    let stop_reason = choice
        .get("finish_reason")
        .and_then(Value::as_str)
        .map(map_finish_reason)
        .or(if has_tool_use { Some("tool_use") } else { None });

    let usage = body.get("usage").cloned().unwrap_or(json!({}));
    let (usage_json, _) = build_usage(&usage);

    Ok(json!({
        "id": body.get("id").and_then(Value::as_str).unwrap_or(""),
        "type": "message",
        "role": "assistant",
        "content": content,
        "model": body.get("model").and_then(Value::as_str).unwrap_or(""),
        "stop_reason": stop_reason,
        "stop_sequence": null,
        "usage": usage_json,
    }))
}

/// finish_reason → stop_reason（未知值回落 end_turn）。
fn map_finish_reason(r: &str) -> &'static str {
    match r {
        "tool_calls" | "function_call" => "tool_use",
        "length" => "max_tokens",
        "stop" | "content_filter" => "end_turn",
        _ => "end_turn",
    }
}

/// usage 三桶换算：`input = prompt - cache_read - cache_creation`（Anthropic 口径）。
/// 返回 (usage_json, 原始 prompt_tokens)。
fn build_usage(usage: &Value) -> (Value, u64) {
    let cached = usage
        .get("cache_read_input_tokens")
        .and_then(Value::as_u64)
        .or_else(|| {
            usage
                .pointer("/prompt_tokens_details/cached_tokens")
                .and_then(Value::as_u64)
        })
        .unwrap_or(0);
    let cache_creation = usage
        .get("cache_creation_input_tokens")
        .and_then(Value::as_u64)
        .or_else(|| {
            usage
                .pointer("/prompt_tokens_details/cache_write_tokens")
                .and_then(Value::as_u64)
        })
        .unwrap_or(0);
    let prompt = usage.get("prompt_tokens").and_then(Value::as_u64).unwrap_or(0);
    let completion = usage
        .get("completion_tokens")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let mut usage_json = json!({
        "input_tokens": prompt.saturating_sub(cached).saturating_sub(cache_creation),
        "output_tokens": completion,
    });
    if cached > 0 {
        usage_json["cache_read_input_tokens"] = json!(cached);
    }
    if cache_creation > 0 {
        usage_json["cache_creation_input_tokens"] = json!(cache_creation);
    }
    (usage_json, prompt)
}

// ─────────────────────────────── SSE 流式转换 ───────────────────────────────

/// OpenAI Chat SSE → Anthropic SSE。
///
/// 逐条输出 Anthropic 事件字节（`event: <t>\ndata: <json>\n\n`）。状态机语义
/// 与 cc-switch `create_anthropic_sse_stream` 一致：
/// - 首个带 choices 的 chunk 发 `message_start`；
/// - text / thinking（reasoning）按块类型自动开闭 `content_block_*`；
/// - tool_calls 按 OpenAI `index` 路由，id+name 齐全才 start，先到的
///   arguments 缓存为 pending（部分上游顺序颠倒）；
/// - finish_reason 只认第一个（多余的仅更新 usage），`message_delta` 缓存到
///   `[DONE]` 或流结束时统一发，保证 usage 完整且只出现一次；
/// - 上游错误（Some(Err)）→ Anthropic `error` 事件，且不再发终止事件。
pub fn create_anthropic_sse_stream<E, S>(upstream: S) -> impl futures::Stream<Item = Result<Vec<u8>, std::io::Error>>
where
    E: std::error::Error + Send + 'static,
    S: futures::Stream<Item = Result<bytes::Bytes, E>> + Unpin,
{
    futures::stream::unfold(SseState::new(upstream), |mut st| async move {
        loop {
            // 先弹出已解析好的事件
            if !st.pending.is_empty() {
                return Some((Ok(st.pending.remove(0)), st));
            }
            if st.finished {
                return None;
            }
            match st.upstream.next().await {
                Some(Ok(bytes)) => st.feed(&bytes),
                Some(Err(e)) => st.fail(format!("upstream stream error: {e}")),
                None => st.finish(),
            }
        }
    })
}

use futures::StreamExt;

struct ToolBlockState {
    anthropic_index: u32,
    id: String,
    name: String,
    started: bool,
    pending_args: String,
}

struct SseState<S> {
    upstream: S,
    buffer: String,
    utf8_remainder: Vec<u8>,
    pending: Vec<Vec<u8>>,
    finished: bool,
    errored: bool,
    message_id: Option<String>,
    model: Option<String>,
    next_index: u32,
    sent_start: bool,
    open_block: Option<(u32, &'static str)>, // (index, "text"|"thinking")
    tools: HashMap<usize, ToolBlockState>,
    open_tools: Vec<u32>,
    delta_sent: bool,
    pending_delta: Option<(Option<String>, Option<Value>)>,
    latest_usage: Option<Value>,
}

impl<S> SseState<S> {
    fn new(upstream: S) -> Self {
        Self {
            upstream,
            buffer: String::new(),
            utf8_remainder: Vec::new(),
            pending: Vec::new(),
            finished: false,
            errored: false,
            message_id: None,
            model: None,
            next_index: 0,
            sent_start: false,
            open_block: None,
            tools: HashMap::new(),
            open_tools: Vec::new(),
            delta_sent: false,
            pending_delta: None,
            latest_usage: None,
        }
    }

    fn emit(&mut self, event: &str, data: &Value) {
        let payload = format!(
            "event: {event}\ndata: {}\n\n",
            serde_json::to_string(data).unwrap_or_default()
        );
        self.pending.push(payload.into_bytes());
    }

    /// 不完整 UTF-8 跨 chunk 安全拼接（对齐 cc-switch append_utf8_safe）。
    fn feed(&mut self, bytes: &[u8]) {
        let mut chunk = std::mem::take(&mut self.utf8_remainder);
        chunk.extend_from_slice(bytes);
        match std::str::from_utf8(&chunk) {
            Ok(text) => self.buffer.push_str(text),
            Err(e) => {
                let valid = e.valid_up_to();
                self.buffer.push_str(&String::from_utf8_lossy(&chunk[..valid]));
                self.utf8_remainder = chunk[valid..].to_vec();
            }
        }
        while let Some(block) = take_sse_block(&mut self.buffer) {
            self.parse_block(&block);
        }
    }

    fn parse_block(&mut self, block: &str) {
        for line in block.lines() {
            let Some(data) = line.strip_prefix("data:") else {
                continue;
            };
            let data = data.strip_prefix(' ').unwrap_or(data);
            if data.trim() == "[DONE]" {
                if let Some((stop, usage)) = self.pending_delta.take() {
                    self.emit_message_delta(stop, usage);
                }
                self.emit("message_stop", &json!({ "type": "message_stop" }));
                continue;
            }
            let Ok(chunk) = serde_json::from_str::<Value>(data) else {
                continue;
            };
            self.parse_chunk(chunk);
        }
    }

    fn parse_chunk(&mut self, chunk: Value) {
        if self.message_id.is_none() {
            self.message_id = chunk.get("id").and_then(Value::as_str).map(String::from);
        }
        if self.model.is_none() {
            self.model = chunk.get("model").and_then(Value::as_str).map(String::from);
        }

        // usage chunk（含 include_usage 末尾的纯 usage chunk）
        let chunk_usage = chunk.get("usage").filter(|u| u.is_object()).cloned();
        if let Some(u) = &chunk_usage {
            let (uj, _) = build_usage(u);
            self.latest_usage = Some(uj.clone());
            if let Some((_, pu)) = self.pending_delta.as_mut() {
                *pu = Some(uj);
            }
        }

        let Some(choice) = chunk.pointer("/choices/0") else {
            return;
        };

        if !self.sent_start {
            self.sent_start = true;
            let mut start_usage = json!({ "input_tokens": 0, "output_tokens": 0 });
            if let Some(u) = &chunk_usage {
                let (uj, _) = build_usage(u);
                if let Some(obj) = uj.as_object() {
                    for (k, v) in obj {
                        if k != "output_tokens" {
                            start_usage[k.as_str()] = v.clone();
                        }
                    }
                }
            }
            self.emit(
                "message_start",
                &json!({
                    "type": "message_start",
                    "message": {
                        "id": self.message_id.clone().unwrap_or_default(),
                        "type": "message",
                        "role": "assistant",
                        "model": self.model.clone().unwrap_or_default(),
                        "usage": start_usage,
                    }
                }),
            );
        }

        // reasoning（thinking）块：OpenRouter 风格 `reasoning` 与 DeepSeek 风格
        // `reasoning_content` 都认（对齐 cc-switch 的 chunk 结构体别名）
        if let Some(r) = choice
            .pointer("/delta/reasoning")
            .or_else(|| choice.pointer("/delta/reasoning_content"))
            .and_then(Value::as_str)
        {
            if !r.is_empty() {
                self.ensure_open_block("thinking");
                let (idx, _) = self.open_block.expect("block open");
                self.emit(
                    "content_block_delta",
                    &json!({
                        "type": "content_block_delta",
                        "index": idx,
                        "delta": { "type": "thinking_delta", "thinking": r },
                    }),
                );
            }
        }

        // 文本块
        if let Some(c) = choice.pointer("/delta/content").and_then(Value::as_str) {
            if !c.is_empty() {
                self.ensure_open_block("text");
                let (idx, _) = self.open_block.expect("block open");
                self.emit(
                    "content_block_delta",
                    &json!({
                        "type": "content_block_delta",
                        "index": idx,
                        "delta": { "type": "text_delta", "text": c },
                    }),
                );
            }
        }

        // 工具调用（按 OpenAI index 路由；id/name 齐全才 start）
        if let Some(tcs) = choice.pointer("/delta/tool_calls").and_then(Value::as_array) {
            if !tcs.is_empty() {
                self.close_open_block();
                for tc in tcs {
                    self.handle_tool_call(tc);
                }
            }
        }

        // finish_reason：只认第一个；message_delta 缓存到 [DONE] 再发
        if let Some(finish) = choice.get("finish_reason").filter(|v| !v.is_null()) {
            let stop = finish.as_str().map(map_finish_reason);
            let usage = chunk_usage.as_ref().map(|u| build_usage(u).0).or_else(|| self.latest_usage.clone());
            if self.delta_sent {
                if let Some((_, ref mut pu)) = self.pending_delta {
                    if usage.is_some() {
                        *pu = usage;
                    }
                }
                return;
            }
            self.delta_sent = true;
            self.close_open_block();
            self.late_tool_starts();
            self.close_all_tools();
            self.pending_delta = Some((stop.map(String::from), usage));
        }
    }

    fn ensure_open_block(&mut self, kind: &'static str) {
        if self.open_block.as_ref().map(|(_, k)| *k) == Some(kind) {
            return;
        }
        self.close_open_block();
        let idx = self.next_index;
        self.next_index += 1;
        let block = if kind == "text" {
            json!({ "type": "text", "text": "" })
        } else {
            json!({ "type": "thinking", "thinking": "" })
        };
        self.emit(
            "content_block_start",
            &json!({ "type": "content_block_start", "index": idx, "content_block": block }),
        );
        self.open_block = Some((idx, kind));
    }

    fn close_open_block(&mut self) {
        if let Some((idx, _)) = self.open_block.take() {
            self.emit(
                "content_block_stop",
                &json!({ "type": "content_block_stop", "index": idx }),
            );
        }
    }

    fn handle_tool_call(&mut self, tc: &Value) {
        let openai_idx = tc.get("index").and_then(Value::as_u64).unwrap_or(0) as usize;
        self.tools.entry(openai_idx).or_insert_with(|| {
            let anthropic_index = self.next_index;
            self.next_index += 1;
            ToolBlockState {
                anthropic_index,
                id: String::new(),
                name: String::new(),
                started: false,
                pending_args: String::new(),
            }
        });

        // 单次借用内完成状态更新，产出三类待发内容：
        // start（id/name 齐全的第一帧）、pending 冲积（start 前缓存的 args）、
        // 立即增量（started 后当帧 args；未 start 时并入 pending）。
        let (anthropic_index, should_start, pending_flush, immediate_delta) = {
            let st = self.tools.get_mut(&openai_idx).expect("just inserted");
            if let Some(id) = tc.get("id").and_then(Value::as_str) {
                if !id.is_empty() {
                    st.id = id.to_string();
                }
            }
            if let Some(name) = tc.pointer("/function/name").and_then(Value::as_str) {
                if !name.is_empty() {
                    st.name = name.to_string();
                }
            }
            let should_start = !st.started && !st.id.is_empty() && !st.name.is_empty();
            if should_start {
                st.started = true;
            }
            let pending_flush = if should_start && !st.pending_args.is_empty() {
                Some(std::mem::take(&mut st.pending_args))
            } else {
                None
            };
            let immediate_delta =
                match tc.pointer("/function/arguments").and_then(Value::as_str) {
                    Some(args) if st.started => Some(args.to_string()),
                    Some(args) => {
                        st.pending_args.push_str(args);
                        None
                    }
                    None => None,
                };
            (st.anthropic_index, should_start, pending_flush, immediate_delta)
        };

        if should_start {
            let (id, name) = {
                let st = self.tools.get(&openai_idx).expect("exists");
                (st.id.clone(), st.name.clone())
            };
            self.emit(
                "content_block_start",
                &json!({
                    "type": "content_block_start",
                    "index": anthropic_index,
                    "content_block": { "type": "tool_use", "id": id, "name": name },
                }),
            );
            self.open_tools.push(anthropic_index);
        }
        if let Some(args) = pending_flush {
            self.emit_json_delta(anthropic_index, &args);
        }
        if let Some(args) = immediate_delta {
            self.emit_json_delta(anthropic_index, &args);
        }
    }

    fn emit_json_delta(&mut self, index: u32, partial_json: &str) {
        self.emit(
            "content_block_delta",
            &json!({
                "type": "content_block_delta",
                "index": index,
                "delta": { "type": "input_json_delta", "partial_json": partial_json },
            }),
        );
    }

    /// finish 时仍未 start 的工具块（id/name 迟到）：用回退值补 start + 冲积 args。
    fn late_tool_starts(&mut self) {
        let mut entries: Vec<(usize, ToolBlockState)> = self
            .tools
            .iter()
            .map(|(k, v)| (*k, v.clone_inner()))
            .filter(|(_, st)| !st.started)
            .filter(|(_, st)| !st.pending_args.is_empty() || !st.id.is_empty() || !st.name.is_empty())
            .collect();
        entries.sort_by_key(|(k, _)| *k);
        for (openai_idx, mut st) in entries {
            let id = if st.id.is_empty() {
                format!("tool_call_{openai_idx}")
            } else {
                std::mem::take(&mut st.id)
            };
            let name = if st.name.is_empty() {
                "unknown_tool".to_string()
            } else {
                std::mem::take(&mut st.name)
            };
            let pending = std::mem::take(&mut st.pending_args);
            self.emit(
                "content_block_start",
                &json!({
                    "type": "content_block_start",
                    "index": st.anthropic_index,
                    "content_block": { "type": "tool_use", "id": id, "name": name },
                }),
            );
            self.open_tools.push(st.anthropic_index);
            if !pending.is_empty() {
                self.emit_json_delta(st.anthropic_index, &pending);
            }
            if let Some(slot) = self.tools.get_mut(&openai_idx) {
                slot.started = true;
            }
        }
    }

    fn close_all_tools(&mut self) {
        let mut indices = std::mem::take(&mut self.open_tools);
        indices.sort_unstable();
        indices.dedup();
        for idx in indices {
            self.emit(
                "content_block_stop",
                &json!({ "type": "content_block_stop", "index": idx }),
            );
        }
    }

    fn emit_message_delta(&mut self, stop: Option<String>, usage: Option<Value>) {
        let usage = usage.unwrap_or_else(|| json!({ "input_tokens": 0, "output_tokens": 0 }));
        self.emit(
            "message_delta",
            &json!({
                "type": "message_delta",
                "delta": { "stop_reason": stop, "stop_sequence": null },
                "usage": usage,
            }),
        );
    }

    /// 上游错误：发 Anthropic error 事件，且不再补发终止事件（对齐 cc-switch）。
    fn fail(&mut self, message: String) {
        self.errored = true;
        self.finished = true;
        self.emit(
            "error",
            &json!({
                "type": "error",
                "error": { "type": "stream_error", "message": message },
            }),
        );
    }

    /// 流自然结束：flush 缓存的 message_delta（含完整 usage）。
    fn finish(&mut self) {
        self.finished = true;
        if self.errored {
            return;
        }
        if let Some((stop, usage)) = self.pending_delta.take() {
            self.emit_message_delta(stop, usage);
        }
        if self.sent_start && !self.delta_sent {
            // 有 message_start 但始终没有 finish_reason：仍需终止事件
            let usage = self.latest_usage.take();
            self.emit_message_delta(None, usage);
        }
        if self.sent_start {
            self.emit("message_stop", &json!({ "type": "message_stop" }));
        }
    }
}

impl ToolBlockState {
    fn clone_inner(&self) -> ToolBlockState {
        ToolBlockState {
            anthropic_index: self.anthropic_index,
            id: self.id.clone(),
            name: self.name.clone(),
            started: self.started,
            pending_args: self.pending_args.clone(),
        }
    }
}

/// 从缓冲取出一个完整 SSE 块（以空行分隔；返回后从缓冲移除）。
fn take_sse_block(buffer: &mut String) -> Option<String> {
    let sep = buffer.find("\n\n").map(|p| (p, 2)).or_else(|| buffer.find("\r\n\r\n").map(|p| (p, 4)))?;
    let block: String = buffer[..sep.0].to_string();
    buffer.drain(..sep.0 + sep.1);
    Some(block)
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;
    use futures::stream;

    // TC-MT-01  请求转换：system 合并 + 参数映射 + tools/tool_choice
    #[test]
    fn anthropic_request_becomes_openai() {
        let body = json!({
            "model": "deepseek-chat",
            "system": [
                { "type": "text", "text": "You are helpful." },
                { "type": "text", "text": "Be brief." }
            ],
            "messages": [
                { "role": "user", "content": "hi" },
                { "role": "assistant", "content": [
                    { "type": "tool_use", "id": "t1", "name": "get_weather", "input": { "city": "SF" } }
                ]},
                { "role": "user", "content": [
                    { "type": "tool_result", "tool_use_id": "t1", "content": "sunny" },
                    { "type": "text", "text": "thanks" }
                ]}
            ],
            "max_tokens": 1024,
            "temperature": 0.7,
            "stop_sequences": ["END"],
            "stream": true,
            "tools": [
                { "name": "get_weather", "description": "Get weather", "input_schema": { "type": "object", "properties": { "city": { "type": "string", "format": "uri" } } } }
            ],
            "tool_choice": { "type": "any" }
        });
        let out = anthropic_to_openai(body, false).unwrap();
        assert_eq!(out["model"], "deepseek-chat");
        let msgs = out["messages"].as_array().unwrap();
        assert_eq!(msgs[0]["role"], "system");
        assert_eq!(msgs[0]["content"], "You are helpful.\nBe brief.");
        assert_eq!(msgs[1]["content"], "hi");
        // tool_use → assistant + tool_calls
        assert_eq!(msgs[2]["tool_calls"][0]["id"], "t1");
        assert_eq!(msgs[2]["tool_calls"][0]["function"]["name"], "get_weather");
        // tool_result → role:"tool"
        assert_eq!(msgs[3]["role"], "tool");
        assert_eq!(msgs[3]["tool_call_id"], "t1");
        assert_eq!(msgs[3]["content"], "sunny");
        assert_eq!(out["max_tokens"], 1024);
        assert_eq!(out["stop"], json!(["END"]));
        assert_eq!(out["tool_choice"], "required");
        assert_eq!(out["tools"][0]["type"], "function");
        assert!(out["tools"][0]["function"]["parameters"]["properties"]["city"].get("format").is_none(), "format:uri 必须剥除");
        // 流式注入 include_usage
        assert_eq!(out["stream_options"]["include_usage"], true);
    }

    // TC-MT-02  o-series：max_completion_tokens + reasoning_effort 映射
    #[test]
    fn o_series_and_reasoning_effort() {
        let body = json!({
            "model": "o3",
            "messages": [{ "role": "user", "content": "hi" }],
            "max_tokens": 2048,
            "thinking": { "type": "enabled", "budget_tokens": 8000 }
        });
        let out = anthropic_to_openai(body, false).unwrap();
        assert_eq!(out["max_completion_tokens"], 2048);
        assert!(out.get("max_tokens").is_none());
        assert_eq!(out["reasoning_effort"], "medium");

        // 非 o 系列不换字段名；gpt-5 支持 effort
        let out = anthropic_to_openai(
            json!({ "model": "gpt-5.1", "messages": [], "max_tokens": 9, "thinking": { "type": "enabled", "budget_tokens": 20000 } }),
            false,
        )
        .unwrap();
        assert_eq!(out["max_tokens"], 9);
        assert_eq!(out["reasoning_effort"], "high");
        // thinking disabled / 普通模型：无 effort
        let out = anthropic_to_openai(json!({ "model": "deepseek-chat", "messages": [], "thinking": { "type": "disabled" } }), false).unwrap();
        assert!(out.get("reasoning_effort").is_none());
    }

    // TC-MT-03  billing header 剥除 + thinking 丢弃 / preserve 注入
    #[test]
    fn system_billing_and_thinking() {
        let body = json!({
            "model": "m",
            "system": "x-anthropic-billing-header: t=1\nreal prompt",
            "messages": [{ "role": "user", "content": "hi" }]
        });
        let out = anthropic_to_openai(body, false).unwrap();
        assert_eq!(out["messages"][0]["content"], "real prompt");

        // preserve 模式：assistant 工具调用缺 thinking → 注入占位
        let body = json!({
            "model": "deepseek-reasoner",
            "messages": [
                { "role": "user", "content": "q" },
                { "role": "assistant", "content": [{ "type": "tool_use", "id": "t", "name": "f", "input": {} }] }
            ]
        });
        let out = anthropic_to_openai(body, true).unwrap();
        assert_eq!(out["messages"][1]["reasoning_content"], THINKING_PLACEHOLDER);
    }

    // TC-MT-04  非流式响应：content/tool_calls/usage 三桶/finish_reason
    #[test]
    fn openai_response_becomes_anthropic() {
        let resp = json!({
            "id": "resp1", "model": "deepseek-chat",
            "choices": [{
                "message": {
                    "role": "assistant",
                    "reasoning_content": "let me think",
                    "content": "hello",
                    "tool_calls": [{ "id": "c1", "type": "function", "function": { "name": "f", "arguments": "{\"a\":1}" } }]
                },
                "finish_reason": "tool_calls"
            }],
            "usage": { "prompt_tokens": 100, "completion_tokens": 20,
                       "prompt_tokens_details": { "cached_tokens": 30 } }
        });
        let out = openai_to_anthropic(resp).unwrap();
        assert_eq!(out["type"], "message");
        assert_eq!(out["stop_reason"], "tool_use");
        let content = out["content"].as_array().unwrap();
        assert_eq!(content[0]["type"], "thinking");
        assert_eq!(content[1]["type"], "text");
        assert_eq!(content[2]["type"], "tool_use");
        assert_eq!(content[2]["input"], json!({ "a": 1 }));
        // input = 100 - 30(cache_read) - 0
        assert_eq!(out["usage"]["input_tokens"], 70);
        assert_eq!(out["usage"]["cache_read_input_tokens"], 30);
        assert_eq!(out["usage"]["output_tokens"], 20);

        // finish_reason 映射
        let out = openai_to_anthropic(json!({
            "choices": [{ "message": { "role": "assistant", "content": "x" }, "finish_reason": "length" }],
            "usage": {}
        }))
        .unwrap();
        assert_eq!(out["stop_reason"], "max_tokens");
    }

    // TC-MT-05  SSE：文本流 → message_start/delta/stop + usage 延迟到 DONE
    #[tokio::test]
    async fn sse_text_stream() {
        type Chunk = Result<Bytes, std::io::Error>;
        let chunks: Vec<Chunk> = vec![
            Ok(Bytes::from(
                "data: {\"id\":\"m1\",\"model\":\"kimi\",\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"he\"}}]}\n\n",
            )),
            Ok(Bytes::from(
                "data: {\"choices\":[{\"delta\":{\"content\":\"llo\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5}}\n\n",
            )),
            Ok(Bytes::from("data: [DONE]\n\n")),
        ];
        let upstream = stream::iter(chunks);
        let events = collect_events(upstream).await;
        assert_eq!(events[0]["type"], "message_start");
        assert_eq!(events[1]["type"], "content_block_start");
        assert_eq!(events[1]["content_block"]["type"], "text");
        let text: String = events
            .iter()
            .filter(|e| e.pointer("/delta/type").and_then(Value::as_str) == Some("text_delta"))
            .filter_map(|e| e.pointer("/delta/text").and_then(Value::as_str))
            .collect();
        assert_eq!(text, "hello");
        let delta = events.iter().find(|e| e["type"] == "message_delta").unwrap();
        assert_eq!(delta["delta"]["stop_reason"], "end_turn");
        assert_eq!(delta["usage"]["input_tokens"], 10);
        assert_eq!(delta["usage"]["output_tokens"], 5);
        assert_eq!(events.last().unwrap()["type"], "message_stop");
        // 只有一个 message_delta（finish 去重）
        assert_eq!(events.iter().filter(|e| e["type"] == "message_delta").count(), 1);
    }

    // TC-MT-06  SSE：tool_calls 按 index 路由 + id/name 迟到时延迟 start
    #[tokio::test]
    async fn sse_tool_calls_routing_and_late_start() {
        type Chunk = Result<Bytes, std::io::Error>;
        let chunks: Vec<Chunk> = vec![
            Ok(Bytes::from(
                "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"a\\\":\"}}]}}]}\n\n",
            )),
            Ok(Bytes::from(
                "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"t9\",\"function\":{\"name\":\"run\",\"arguments\":\"1}\"}}]}}]}\n\n",
            )),
            Ok(Bytes::from(
                "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n",
            )),
            Ok(Bytes::from("data: [DONE]\n\n")),
        ];
        let upstream = stream::iter(chunks);
        let events = collect_events(upstream).await;
        let starts: Vec<&Value> = events
            .iter()
            .filter(|e| e["type"] == "content_block_start" && e["content_block"]["type"] == "tool_use")
            .collect();
        assert_eq!(starts.len(), 1, "同一工具只 start 一次");
        assert_eq!(starts[0]["content_block"]["id"], "t9");
        assert_eq!(starts[0]["content_block"]["name"], "run");
        let json_args: String = events
            .iter()
            .filter(|e| e.pointer("/delta/type").and_then(Value::as_str) == Some("input_json_delta"))
            .filter_map(|e| e.pointer("/delta/partial_json").and_then(Value::as_str))
            .collect();
        assert_eq!(json_args, "{\"a\":1}");
        assert_eq!(events.last().unwrap()["type"], "message_stop");
        let delta = events.iter().find(|e| e["type"] == "message_delta").unwrap();
        assert_eq!(delta["delta"]["stop_reason"], "tool_use");
    }

    // TC-MT-07  SSE：UTF-8 多字节跨 chunk 不产生替换符
    #[tokio::test]
    async fn sse_utf8_split_across_chunks() {
        let payload = "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\n\n";
        let bytes = payload.as_bytes();
        let mid = bytes.len() - 2; // 把最后一个多字节字符切一半
        type Chunk = Result<Bytes, std::io::Error>;
        let chunks: Vec<Chunk> = vec![
            Ok(Bytes::copy_from_slice(&bytes[..mid])),
            Ok(Bytes::copy_from_slice(&bytes[mid..])),
            Ok(Bytes::from("data: [DONE]\n\n")),
        ];
        let upstream = stream::iter(chunks);
        let events = collect_events(upstream).await;
        let text: String = events
            .iter()
            .filter(|e| e.pointer("/delta/type").and_then(Value::as_str) == Some("text_delta"))
            .filter_map(|e| e.pointer("/delta/text").and_then(Value::as_str))
            .collect();
        assert_eq!(text, "你好");
    }

    // TC-MT-08  SSE：上游错误 → error 事件且无终止事件
    #[tokio::test]
    async fn sse_upstream_error_yields_error_event() {
        type Chunk = Result<Bytes, std::io::Error>;
        let chunks: Vec<Chunk> = vec![
            Ok(Bytes::from(
                "data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n",
            )),
            Err(std::io::Error::other("boom")),
        ];
        let upstream = stream::iter(chunks);
        let events = collect_events(upstream).await;
        assert_eq!(events.last().unwrap()["type"], "error");
        assert!(!events.iter().any(|e| e["type"] == "message_stop"), "错误后不得补发终止事件");
    }

    async fn collect_events<E, S>(upstream: S) -> Vec<Value>
    where
        E: std::error::Error + Send + 'static,
        S: futures::Stream<Item = Result<Bytes, E>> + Unpin,
    {
        let converted = create_anthropic_sse_stream(upstream);
        let chunks: Vec<Result<Vec<u8>, std::io::Error>> = converted.collect().await;
        let merged: String = chunks
            .into_iter()
            .map(|c| String::from_utf8(c.unwrap()).unwrap())
            .collect();
        merged
            .split("\n\n")
            .filter(|b| !b.trim().is_empty())
            .filter_map(|block| {
                block
                    .lines()
                    .find_map(|l| l.strip_prefix("data: "))
                    .and_then(|d| serde_json::from_str::<Value>(d).ok())
            })
            .collect()
    }
}
