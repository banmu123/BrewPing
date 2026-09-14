//! 内置请求转发代理——内置 cc-switch 的「转发路由层」。
//!
//! Phase 1（透传）+ Phase 2（协议转换 / 故障转移 / 熔断），行为对齐 cc-switch：
//! - **本地监听** `127.0.0.1:<port>`（默认 15721，与 cc-switch 一致）；
//! - **别名路由**：`/claude/*`、`/codex/*`、`/gemini/*` 前缀剥掉后转发；
//! - **鉴权替换（核心设计）**：CLI 送来的 Authorization / x-api-key 一律丢弃，
//!   换成当前配置的真实 key；
//! - **协议转换**：入站 Anthropic（`/v1/messages`）→ 上游 `openai_chat` 时，
//!   请求/响应/SSE 全链路转换（`model_transform`，迁移自 cc-switch transform.rs
//!   + streaming.rs）；同协议组合仍逐字节透传；
//! - **故障转移**（`failoverEnabled`）：按 sortIndex 顺序逐个尝试，错误分类
//!   对齐 forwarder.rs（400/405/406/413/414/415/422/501 不可重试）；成功后若
//!   实际使用的配置 ≠ 请求开始时的 current，自动切换 current 并发前端事件
//!   （对齐 FailoverSwitchManager::try_switch 语义）；
//! - **熔断器**（简化三态）：连败 3 次 → Open 30s → 放行探测；failover 关闭
//!   （单配置）时跳过（对齐 bypass_circuit_breaker）；
//! - **切换即时生效**：每请求读 store；**无总超时**（仅 connect 15s）。
//!
//! 模块不依赖 tauri 类型（EventSink 同款约束）：事件经回调上抛，单测可独立跑。

use axum::body::{Body, Bytes};
use axum::extract::{DefaultBodyLimit, OriginalUri, State};
use axum::http::{header, HeaderMap, HeaderName, HeaderValue, Method, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Router;
use crate::services::model_provider_store::{ApiFormat, ModelProviderConfig, ModelProviderStore};
use crate::services::model_transform;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

/// 请求侧要剥掉的 header：hop-by-hop 类 + CLI 送来的鉴权类。
const SKIPPED_REQ_HEADERS: &[&str] = &[
    "host",
    "content-length",
    "connection",
    "keep-alive",
    "transfer-encoding",
    "te",
    "trailers",
    "upgrade",
    "proxy-authenticate",
    "proxy-authorization",
    "authorization",
    "x-api-key",
    "x-goog-api-key",
];

/// 响应侧要剥掉的 header（content-length 交给 axum 按流重算）。
const SKIPPED_RES_HEADERS: &[&str] = &[
    "connection",
    "keep-alive",
    "transfer-encoding",
    "te",
    "trailers",
    "upgrade",
    "content-length",
];

/// failover 最大尝试配置数（对齐 cc-switch `max_attempts` 默认语义）。
const MAX_ATTEMPTS: usize = 3;
/// 熔断阈值：连续失败次数。
const BREAKER_FAILURE_THRESHOLD: u32 = 3;
/// 熔断打开时长（秒），超时后放一个探测请求。
const BREAKER_OPEN_SECS: u64 = 30;

/// 前端事件回调（由 lib.rs 注入 tauri emit；services 层不碰 tauri 类型）。
pub type ProxyEventSink = Arc<dyn Fn(&str, serde_json::Value) + Send + Sync>;

/// 共享转发客户端（连接池复用；不开 gzip/brotli feature，压缩透传）。
/// `pub(crate)`：`fetch_provider_models`（列模型）复用同一连接池。
pub(crate) fn http_client() -> reqwest::Client {
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    CLIENT
        .get_or_init(|| {
            reqwest::Client::builder()
                .connect_timeout(Duration::from_secs(15))
                // 刻意不设总超时：流式响应可持续数分钟以上
                .pool_idle_timeout(Duration::from_secs(90))
                .build()
                .expect("reqwest client build")
        })
        .clone()
}

// ─────────────────────────────── 熔断器（简化三态）───────────────────────────────

/// 简化熔断器：Closed →（连败 N 次）→ Open →（超时放行一次探测）→ 成功闭合 /
/// 失败重新计时。省略 cc-switch 的 error-rate 窗口与 HalfOpen 并发 permit
/// （单用户本机场景不需要），状态机语义保持一致。
#[derive(Debug)]
struct CircuitBreaker {
    failures: Mutex<u32>,
    opened_at: Mutex<Option<Instant>>,
}

impl CircuitBreaker {
    fn new() -> Self {
        Self {
            failures: Mutex::new(0),
            opened_at: Mutex::new(None),
        }
    }

    /// 是否放行（Open 超时后放行的请求即探测请求）。
    fn is_available(&self) -> bool {
        let opened = self.opened_at.lock().expect("breaker poisoned");
        match *opened {
            None => true,
            Some(at) => at.elapsed() >= Duration::from_secs(BREAKER_OPEN_SECS),
        }
    }

    fn record(&self, success: bool) {
        if success {
            *self.failures.lock().expect("breaker poisoned") = 0;
            *self.opened_at.lock().expect("breaker poisoned") = None;
            return;
        }
        let mut failures = self.failures.lock().expect("breaker poisoned");
        *failures += 1;
        if *failures >= BREAKER_FAILURE_THRESHOLD {
            *self.opened_at.lock().expect("breaker poisoned") = Some(Instant::now());
        }
    }
}

type BreakerMap = Arc<Mutex<HashMap<String, Arc<CircuitBreaker>>>>;

fn breaker_available(map: &BreakerMap, id: &str) -> bool {
    let mut guards = map.lock().expect("breaker map poisoned");
    guards
        .entry(id.to_string())
        .or_insert_with(|| Arc::new(CircuitBreaker::new()))
        .is_available()
}

fn breaker_record(map: &BreakerMap, id: &str, success: bool) {
    let mut guards = map.lock().expect("breaker map poisoned");
    // entry 而非 get：条目不存在时也要落地记录（get 会静默丢弃，
    // 导致“未探测过就连续失败”的 id 永远打不开熔断 —— TC-MPX-08 抓到的 bug）。
    guards
        .entry(id.to_string())
        .or_insert_with(|| Arc::new(CircuitBreaker::new()))
        .record(success);
}

// ─────────────────────────────── 代理状态与路由 ───────────────────────────────

/// axum 共享状态。
struct ProxyCtx {
    store: Arc<ModelProviderStore>,
    breakers: BreakerMap,
    sink: Option<ProxyEventSink>,
}

/// 代理路由：/health /status + 全量转发 fallback。
pub fn build_router(store: Arc<ModelProviderStore>) -> Router {
    build_router_with_sink(store, None)
}

/// 带 EventSink 的路由构造（Manager 启动时使用；切换/故障转移事件上抛前端）。
pub fn build_router_with_sink(store: Arc<ModelProviderStore>, sink: Option<ProxyEventSink>) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/status", get(health))
        .fallback(proxy_fallback)
        .layer(DefaultBodyLimit::max(200 * 1024 * 1024)) // 对齐 cc-switch 200MB
        .with_state(Arc::new(ProxyCtx {
            store,
            breakers: Arc::new(Mutex::new(HashMap::new())),
            sink,
        }))
}

async fn health(State(ctx): State<Arc<ProxyCtx>>) -> Response {
    let current = ctx.store.current().map(|c| c.name);
    json_response(
        StatusCode::OK,
        serde_json::json!({
            "status": "ok",
            "service": "brewping-model-proxy",
            "current": current,
        }),
    )
}

/// 转发主路径：路由链逐个尝试（failover），命中后按协议组合转发。
async fn proxy_fallback(
    State(ctx): State<Arc<ProxyCtx>>,
    method: Method,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    // 别名前缀 = 请求来源 Agent 的身份钥匙（接管写入 /claude /codex 后缀后生效；
    // 裸地址请求无身份 → 走通用路由，行为与旧版一致）。
    let (agent_id, _) = parse_proxy_alias(uri.path());
    let agent_key = agent_id.unwrap_or("");
    let (chain, start_id) = ctx.store.route_chain_for(agent_key);
    if chain.is_empty() {
        return json_error(
            StatusCode::SERVICE_UNAVAILABLE,
            "no active model provider config — add one and set it current",
        );
    }

    let bypass_breaker = chain.len() == 1; // 对齐：单配置（failover 关）跳过熔断
    let mut last_error: Option<Response> = None;

    for (attempt, cfg) in chain.iter().enumerate() {
        if attempt >= MAX_ATTEMPTS {
            break;
        }
        if !bypass_breaker && !breaker_available(&ctx.breakers, &cfg.id) {
            continue; // 熔断打开：跳过
        }

        match attempt_forward(&ctx, cfg, &method, &uri, &headers, &body).await {
            Ok(resp) => {
                if !bypass_breaker {
                    breaker_record(&ctx.breakers, &cfg.id, true);
                }
                // 对齐 FailoverSwitchManager：故障转移成功后把 current 切到
                // 实际生效的配置，并通知前端（"provider-switched" 同款语义）。
                // per-Agent：切的是**本请求来源 Agent** 的专属槽（store 内部
                // 有跨归属防护：归属他人的配置不会被写成 current）。
                if start_id.as_deref() != Some(cfg.id.as_str())
                    && ctx.store.switch_current_for(agent_key, &cfg.id).is_ok()
                {
                    if let Some(sink) = &ctx.sink {
                        sink(
                            "model-provider-switched",
                            serde_json::json!({
                                "providerId": cfg.id,
                                "providerName": cfg.name,
                                "agentId": agent_key,
                                "source": "failover",
                            }),
                        );
                    }
                }
                return resp;
            }
            Err(resp) => {
                let retryable = is_retryable_status(resp.status().as_u16());
                if !bypass_breaker {
                    breaker_record(&ctx.breakers, &cfg.id, false);
                }
                // 请求本身有错（400/422/…）：换厂商也没用，直接返回；
                // 其余（401/429/5xx/网络）：记下错误换下一家。
                if !retryable || attempt + 1 >= chain.len().min(MAX_ATTEMPTS) {
                    return resp;
                }
                last_error = Some(resp);
            }
        }
    }
    last_error.unwrap_or_else(|| {
        json_error(
            StatusCode::SERVICE_UNAVAILABLE,
            "all model provider configs failed (failover exhausted)",
        )
    })
}

/// 对齐 cc-switch 错误分类：请求自身有问题的状态码不可重试，
/// 其余 4xx（401/403/404/408/429 等）与全部 5xx 可换下一家。
fn is_retryable_status(status: u16) -> bool {
    !matches!(status, 400 | 405 | 406 | 413 | 414 | 415 | 422 | 501)
}

/// 单次转发尝试。Ok = 上游成功响应（已按协议组合处理）；Err = 失败响应。
async fn attempt_forward(
    ctx: &ProxyCtx,
    cfg: &ModelProviderConfig,
    method: &Method,
    uri: &axum::http::Uri,
    headers: &HeaderMap,
    body: &Bytes,
) -> Result<Response, Response> {
    let path = strip_proxy_alias(uri.path());
    let anthropic_inbound =
        method == Method::POST && path.starts_with("/v1/messages") && !body.is_empty();
    let convert = anthropic_inbound && cfg.api_format == ApiFormat::OpenaiChat;

    // 1) URL：转换模式重写端点为 /chat/completions（智能补 /v1）；
    //    透传模式剥别名后拼接（is_full_url 直接用 base）。
    let url = if convert {
        if cfg.is_full_url {
            cfg.base_url.clone()
        } else {
            openai_chat_endpoint(&cfg.base_url)
        }
    } else if cfg.is_full_url {
        cfg.base_url.clone()
    } else {
        join_url(&cfg.base_url, path)
    };
    let mut url = url;
    if let Some(q) = uri.query() {
        url.push('?');
        url.push_str(q);
    }
    let parsed: reqwest::Url = url
        .parse()
        .map_err(|e| json_error(StatusCode::BAD_GATEWAY, &format!("invalid upstream url {url:?}: {e}")))?;

    // 2) header：剥 hop-by-hop 与 CLI 鉴权 → 注入配置真实凭据
    let mut fwd_headers = HeaderMap::new();
    for (name, value) in headers.iter() {
        if SKIPPED_REQ_HEADERS.contains(&name.as_str()) {
            continue;
        }
        fwd_headers.insert(name.clone(), value.clone());
    }
    apply_auth_headers(&mut fwd_headers, cfg);

    // 3) 请求体：转换模式把 Anthropic body 换成 OpenAI body
    let out_body: Vec<u8> = if convert {
        let value: serde_json::Value = serde_json::from_slice(body)
            .map_err(|e| json_error(StatusCode::BAD_REQUEST, &format!("invalid anthropic body: {e}")))?;
        let preserve = model_transform::is_reasoning_vendor(
            value.get("model").and_then(|m| m.as_str()).unwrap_or(""),
        ) || model_transform::is_reasoning_vendor(&cfg.base_url);
        let mut converted = model_transform::anthropic_to_openai(value, preserve)
            .map_err(|e| json_error(StatusCode::BAD_REQUEST, &format!("transform request failed: {e}")))?;
        // 配置了默认模型 → 覆盖请求 model（对齐 cc-switch model_mapper）
        if let Some(model) = cfg.model.as_deref().filter(|m| !m.is_empty()) {
            converted["model"] = serde_json::json!(model);
        }
        serde_json::to_vec(&converted).unwrap_or_default()
    } else {
        body.to_vec()
    };

    // 4) 发送（流式读取响应）
    let req_method =
        reqwest::Method::from_bytes(method.as_str().as_bytes()).unwrap_or(reqwest::Method::GET);
    let mut req = http_client()
        .request(req_method, parsed)
        .headers(reqwest_header_map(fwd_headers));
    if !out_body.is_empty() {
        req = req.body(out_body);
    }
    let resp = req.send().await.map_err(|e| {
        json_error(
            StatusCode::BAD_GATEWAY,
            &format!("upstream request failed: {e}"),
        )
    })?;

    let status = StatusCode::from_u16(resp.status().as_u16())
        .unwrap_or(StatusCode::BAD_GATEWAY);
    let content_type = resp
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();

    // 5) 响应处理
    let mut builder = Response::builder().status(status);
    for (name, value) in resp.headers().iter() {
        if SKIPPED_RES_HEADERS.contains(&name.as_str()) {
            continue;
        }
        builder = builder.header(name.clone(), value.clone());
    }

    let is_sse = content_type.contains("text/event-stream");
    if convert && status.is_success() && is_sse {
        // OpenAI SSE → Anthropic SSE（流式状态机）
        let stream = model_transform::create_anthropic_sse_stream(resp.bytes_stream());
        builder
            .header(header::CONTENT_TYPE, "text/event-stream")
            .body(Body::from_stream(stream))
            .map_err(|e| json_error(StatusCode::BAD_GATEWAY, &format!("response build failed: {e}")))
    } else if convert && status.is_success() {
        // OpenAI JSON → Anthropic JSON
        let raw = resp.bytes().await.map_err(|e| {
            json_error(StatusCode::BAD_GATEWAY, &format!("upstream body read failed: {e}"))
        })?;
        let value: serde_json::Value = serde_json::from_slice(&raw).unwrap_or(serde_json::json!({}));
        let converted = model_transform::openai_to_anthropic(value)
            .map_err(|e| json_error(StatusCode::BAD_GATEWAY, &format!("transform response failed: {e}")))?;
        builder
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(serde_json::to_vec(&converted).unwrap_or_default()))
            .map_err(|e| json_error(StatusCode::BAD_GATEWAY, &format!("response build failed: {e}")))
    } else {
        // 同协议透传（含错误响应）
        builder
            .body(Body::from_stream(resp.bytes_stream()))
            .map_err(|e| json_error(StatusCode::BAD_GATEWAY, &format!("response build failed: {e}")))
    }
}

/// openai_chat 上游端点推导：base 尾部智能补 `/v1/chat/completions`。
/// `https://api.deepseek.com` → `.../v1/chat/completions`；
/// `https://x.com/v1` → `.../v1/chat/completions`；已带完整路径不再重复。
fn openai_chat_endpoint(base: &str) -> String {
    let base = base.trim_end_matches('/');
    if base.ends_with("/chat/completions") {
        return base.to_string();
    }
    if base.ends_with("/v1") {
        return format!("{base}/chat/completions");
    }
    format!("{base}/v1/chat/completions")
}

/// 统一 JSON 错误形态（`{"error":{...}}` 两协议族都能识别）。
fn json_error(status: StatusCode, message: &str) -> Response {
    json_response(
        status,
        serde_json::json!({ "error": { "type": "brewping_proxy", "message": message } }),
    )
}

fn json_response(status: StatusCode, value: serde_json::Value) -> Response {
    match serde_json::to_string(&value) {
        Ok(body) => Response::builder()
            .status(status)
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(body))
            .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response()),
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

/// 识别 cc-switch 风格的别名前缀，返回 (agent 身份, 剥离后路径)：
/// `/claude/v1/messages` → `(Some("claude-code"), "/v1/messages")`。
/// agent 身份用于 per-Agent 路由（Agent→厂商归属，见 model_provider_store）；
/// 未知别名（/gemini）只剥前缀不携带身份。
fn parse_proxy_alias(path: &str) -> (Option<&'static str>, &str) {
    for (prefix, agent) in [
        ("/claude", Some("claude-code")),
        ("/codex", Some("codex")),
        ("/pi", Some("pi")),
        ("/opencode", Some("opencode")),
        ("/gemini", None),
    ] {
        if let Some(rest) = path.strip_prefix(prefix) {
            return (agent, if rest.is_empty() { "/" } else { rest });
        }
    }
    (None, path)
}

fn strip_proxy_alias(path: &str) -> &str {
    parse_proxy_alias(path).1
}

/// base + path 拼接（base 去尾斜杠；保留 base 自带路径段，如 `.../anthropic`）。
fn join_url(base: &str, path: &str) -> String {
    let base = base.trim_end_matches('/');
    if path.starts_with('/') {
        format!("{base}{path}")
    } else {
        format!("{base}/{path}")
    }
}

/// 按配置注入鉴权头（对齐 cc-switch AuthStrategy：Auto 按协议族默认，
/// Bearer / XApiKey 显式覆盖——anthropic 兼容中转站常要求 Bearer）。
fn apply_auth_headers(headers: &mut HeaderMap, cfg: &ModelProviderConfig) {
    headers.remove(header::AUTHORIZATION);
    headers.remove("x-api-key");
    headers.remove("x-goog-api-key");

    let use_bearer = match cfg.auth_style {
        crate::services::model_provider_store::AuthStyle::Bearer => true,
        crate::services::model_provider_store::AuthStyle::XApiKey => false,
        crate::services::model_provider_store::AuthStyle::Auto => cfg.api_format.default_auth_is_bearer(),
    };
    if use_bearer {
        if let Ok(v) = HeaderValue::from_str(&format!("Bearer {}", cfg.api_key)) {
            headers.insert(header::AUTHORIZATION, v);
        }
    } else if let Ok(v) = HeaderValue::from_str(&cfg.api_key) {
        headers.insert(HeaderName::from_static("x-api-key"), v);
    }
    // Anthropic 协议族：客户端没带版本头时补默认值
    if cfg.api_format.default_version_header_needed() && !headers.contains_key("anthropic-version") {
        headers.insert(
            HeaderName::from_static("anthropic-version"),
            HeaderValue::from_static("2023-06-01"),
        );
    }
}

/// axum 的 HeaderMap → reqwest 的 HeaderMap（同一 http 库版本，逐条搬运）。
fn reqwest_header_map(headers: HeaderMap) -> reqwest::header::HeaderMap {
    let mut out = reqwest::header::HeaderMap::with_capacity(headers.len());
    for (name, value) in headers.iter() {
        if let (Ok(n), Ok(v)) = (
            reqwest::header::HeaderName::from_bytes(name.as_str().as_bytes()),
            reqwest::header::HeaderValue::from_bytes(value.as_bytes()),
        ) {
            out.insert(n, v);
        }
    }
    out
}

// ─── 代理进程管理（启停 / 状态；随主进程启动自动拉起已启用的代理）────────────

/// 代理运行状态（前端展示用）。
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProxyStatus {
    pub running: bool,
    /// 实际绑定的端口（未运行时为 None）。
    pub port: Option<u16>,
    /// 最近一次启动失败的错误（停止后仍保留，供 UI 提示）。
    pub error: Option<String>,
}

struct RunningProxy {
    join: tokio::task::JoinHandle<()>,
    shutdown: tokio::sync::watch::Sender<bool>,
    port: u16,
}

/// 转发代理管理器：按存储的 proxyEnabled/proxyPort 启停 axum 实例。
/// 配置内容（providers/current/failover）变化**不需要**重启——handler 每请求读 store。
pub struct ModelProxyManager {
    store: Arc<ModelProviderStore>,
    runtime: tokio::sync::Mutex<Option<RunningProxy>>,
    last_error: std::sync::Mutex<Option<String>>,
    sink: std::sync::Mutex<Option<ProxyEventSink>>,
}

impl ModelProxyManager {
    pub fn new(store: Arc<ModelProviderStore>) -> Self {
        Self {
            store,
            runtime: tokio::sync::Mutex::new(None),
            last_error: std::sync::Mutex::new(None),
            sink: std::sync::Mutex::new(None),
        }
    }

    /// 注入前端事件回调（须在 apply/start 之前调用）。
    pub fn set_event_sink(&self, sink: ProxyEventSink) {
        *self.sink.lock().expect("sink poisoned") = Some(sink);
    }

    /// 使代理状态与 (enabled, port) 一致：
    /// 关 → 停；开且同端口在跑 → no-op；其余 → 重启。返回最终状态。
    ///
    /// 🚨 锁纪律：`runtime` 锁必须在调用 `status()` **之前**释放——
    /// tokio::sync::Mutex 不可重入，持锁调 status() 会永久死锁，
    /// 并把所有等这把锁的命令（get_model_providers 等）一起拖死。
    pub async fn apply(&self, enabled: bool, port: u16) -> ProxyStatus {
        {
            let mut rt = self.runtime.lock().await;
            if enabled {
                let already_running = rt.as_ref().is_some_and(|r| r.port == port);
                if !already_running {
                    if let Some(old) = rt.take() {
                        old.shutdown.send(true).ok();
                        let _ = old.join.await;
                    }
                    let sink = self.sink.lock().expect("sink poisoned").clone();
                    match Self::start(self.store.clone(), sink, port).await {
                        Ok(running) => {
                            *self.last_error.lock().expect("proxy error poisoned") = None;
                            *rt = Some(running);
                        }
                        Err(e) => {
                            log::error!("[ModelProxy] start failed: {e}");
                            *self.last_error.lock().expect("proxy error poisoned") = Some(e);
                        }
                    }
                }
            } else if let Some(old) = rt.take() {
                old.shutdown.send(true).ok();
                let _ = old.join.await;
                *self.last_error.lock().expect("proxy error poisoned") = None;
            }
        } // ← runtime 锁在此释放，status() 才能拿到锁
        self.status().await
    }

    async fn start(
        store: Arc<ModelProviderStore>,
        sink: Option<ProxyEventSink>,
        port: u16,
    ) -> Result<RunningProxy, String> {
        let addr = std::net::SocketAddr::from(([127, 0, 0, 1], port));
        let listener = tokio::net::TcpListener::bind(addr)
            .await
            .map_err(|e| format!("bind 127.0.0.1:{port} failed: {e}"))?;
        let bound = listener
            .local_addr()
            .map(|a| a.port())
            .unwrap_or(port);
        let router = build_router_with_sink(store, sink);
        let (tx, mut rx) = tokio::sync::watch::channel(false);
        let join = tokio::spawn(async move {
            if let Err(e) = axum::serve(listener, router)
                .with_graceful_shutdown(async move {
                    let _ = rx.changed().await;
                })
                .await
            {
                log::error!("[ModelProxy] server error: {e}");
            }
        });
        log::info!("[ModelProxy] listening on 127.0.0.1:{bound}");
        Ok(RunningProxy {
            join,
            shutdown: tx,
            port: bound,
        })
    }

    /// 当前运行状态。
    pub async fn status(&self) -> ProxyStatus {
        let rt = self.runtime.lock().await;
        match rt.as_ref() {
            Some(r) => ProxyStatus {
                running: true,
                port: Some(r.port),
                error: None,
            },
            None => ProxyStatus {
                running: false,
                port: None,
                error: self
                    .last_error
                    .lock()
                    .expect("proxy error poisoned")
                    .clone(),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::model_provider_store::{AuthStyle, ModelProviderConfig};

    fn cfg(api_format: ApiFormat, auth: AuthStyle, key: &str) -> ModelProviderConfig {
        ModelProviderConfig {
            api_format,
            auth_style: auth,
            api_key: key.to_string(),
            base_url: "https://api.example.com".to_string(),
            ..Default::default()
        }
    }

    fn header_get<'a>(headers: &'a HeaderMap, name: &str) -> Option<&'a HeaderValue> {
        headers.get(name)
    }

    // TC-MPX-01  别名前缀剥除（cc-switch 端点习惯）+ agent 身份解析（per-Agent 路由钥匙）
    #[test]
    fn strips_alias_prefixes() {
        assert_eq!(strip_proxy_alias("/v1/messages"), "/v1/messages");
        assert_eq!(strip_proxy_alias("/claude/v1/messages"), "/v1/messages");
        assert_eq!(strip_proxy_alias("/codex/v1/responses"), "/v1/responses");
        assert_eq!(strip_proxy_alias("/pi/v1/messages"), "/v1/messages");
        assert_eq!(strip_proxy_alias("/opencode/v1/messages"), "/v1/messages");
        assert_eq!(strip_proxy_alias("/gemini/v1beta/models"), "/v1beta/models");
        assert_eq!(strip_proxy_alias("/claude"), "/");
        assert_eq!(strip_proxy_alias("/chat/completions"), "/chat/completions");
        assert_eq!(strip_proxy_alias("/v1beta/other"), "/v1beta/other");

        assert_eq!(parse_proxy_alias("/claude/v1/messages").0, Some("claude-code"));
        assert_eq!(parse_proxy_alias("/codex/v1/responses").0, Some("codex"));
        assert_eq!(parse_proxy_alias("/pi/v1/messages").0, Some("pi"));
        assert_eq!(parse_proxy_alias("/opencode/x").0, Some("opencode"));
        assert_eq!(parse_proxy_alias("/gemini/v1beta/models").0, None, "gemini 无 Agent 身份");
        assert_eq!(parse_proxy_alias("/v1/messages").0, None, "裸路径无身份");
    }

    // TC-MPX-02  URL 拼接（保留 base 自带路径段；去尾斜杠；query 由调用方追加）
    #[test]
    fn joins_urls() {
        assert_eq!(join_url("https://api.x.com", "/v1/messages"), "https://api.x.com/v1/messages");
        assert_eq!(join_url("https://api.x.com/", "/v1/messages"), "https://api.x.com/v1/messages");
        assert_eq!(join_url("https://api.x.com/anthropic", "/v1/messages"), "https://api.x.com/anthropic/v1/messages");
        assert_eq!(join_url("https://api.x.com", "v1/messages"), "https://api.x.com/v1/messages");
    }

    // TC-MPX-03  鉴权注入：Auto 按协议族（anthropic→x-api-key+版本头；openai→Bearer）
    #[test]
    fn auth_auto_follows_api_format() {
        let mut h = HeaderMap::new();
        h.insert(header::AUTHORIZATION, HeaderValue::from_static("Bearer cli-placeholder"));
        h.insert("x-api-key", HeaderValue::from_static("cli-key"));
        apply_auth_headers(&mut h, &cfg(ApiFormat::Anthropic, AuthStyle::Auto, "sk-real"));
        assert_eq!(header_get(&h, "x-api-key").unwrap(), "sk-real");
        assert!(h.get(header::AUTHORIZATION).is_none(), "CLI 送来的 Bearer 必须被丢弃");
        assert_eq!(header_get(&h, "anthropic-version").unwrap(), "2023-06-01", "缺版本头时补默认");

        let mut h = HeaderMap::new();
        apply_auth_headers(&mut h, &cfg(ApiFormat::OpenaiChat, AuthStyle::Auto, "sk-real"));
        assert_eq!(header_get(&h, header::AUTHORIZATION.as_str()).unwrap(), "Bearer sk-real");
        assert!(h.get("x-api-key").is_none());
        assert!(h.get("anthropic-version").is_none(), "openai 族不带 anthropic 版本头");
    }

    // TC-MPX-04  鉴权注入：显式覆盖 + 已带版本头不重复注入
    #[test]
    fn auth_explicit_override_and_version_header() {
        let mut h = HeaderMap::new();
        apply_auth_headers(&mut h, &cfg(ApiFormat::Anthropic, AuthStyle::Bearer, "sk-real"));
        assert_eq!(header_get(&h, header::AUTHORIZATION.as_str()).unwrap(), "Bearer sk-real");
        assert!(h.get("x-api-key").is_none());

        let mut h = HeaderMap::new();
        apply_auth_headers(&mut h, &cfg(ApiFormat::OpenaiChat, AuthStyle::XApiKey, "sk-real"));
        assert_eq!(header_get(&h, "x-api-key").unwrap(), "sk-real");
        assert!(h.get(header::AUTHORIZATION).is_none());

        h.insert("anthropic-version", HeaderValue::from_static("2099-01-01"));
        apply_auth_headers(&mut h, &cfg(ApiFormat::Anthropic, AuthStyle::Auto, "k"));
        assert_eq!(header_get(&h, "anthropic-version").unwrap(), "2099-01-01");
    }

    // TC-MPX-05  错误分类：请求自身错误不可重试（对齐 cc-switch）
    #[test]
    fn retryable_status_classification() {
        for status in [400, 405, 406, 413, 414, 415, 422, 501] {
            assert!(!is_retryable_status(status), "{status} 应不可重试");
        }
        for status in [401, 403, 404, 408, 429, 500, 502, 503, 529] {
            assert!(is_retryable_status(status), "{status} 应可重试");
        }
    }

    // TC-MPX-06  openai_chat 端点推导
    #[test]
    fn chat_endpoint_derivation() {
        assert_eq!(
            openai_chat_endpoint("https://api.deepseek.com"),
            "https://api.deepseek.com/v1/chat/completions"
        );
        assert_eq!(
            openai_chat_endpoint("https://api.x.com/v1/"),
            "https://api.x.com/v1/chat/completions"
        );
        assert_eq!(
            openai_chat_endpoint("https://x.com/v1/chat/completions"),
            "https://x.com/v1/chat/completions"
        );
    }

    // TC-MPX-07  熔断器：连败 N 次打开、超时探测、成功闭合
    #[test]
    fn circuit_breaker_states() {
        let b = CircuitBreaker::new();
        assert!(b.is_available());
        b.record(false);
        b.record(false);
        assert!(b.is_available(), "未达阈值仍放行");
        b.record(false);
        assert!(!b.is_available(), "达到阈值必须打开");

        // 时间未到：拒绝；时间到：放行探测
        // （不 sleep：直接改 opened_at 模拟超时）
        *b.opened_at.lock().unwrap() = Some(Instant::now() - Duration::from_secs(BREAKER_OPEN_SECS + 1));
        assert!(b.is_available(), "超时后放行探测");

        b.record(true);
        assert!(b.is_available(), "探测成功闭合");
        b.record(false);
        assert!(b.is_available(), "闭合后失败重新计数");
    }

    // TC-MPX-08  熔断器注册表：按 id 隔离
    #[test]
    fn breaker_map_isolated_by_id() {
        let map: BreakerMap = Arc::new(Mutex::new(HashMap::new()));
        for _ in 0..BREAKER_FAILURE_THRESHOLD {
            breaker_record(&map, "a", false);
        }
        assert!(!breaker_available(&map, "a"));
        assert!(breaker_available(&map, "b"), "不同 id 互不影响");
    }
}
