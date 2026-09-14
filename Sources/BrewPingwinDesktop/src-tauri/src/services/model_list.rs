//! 模型列表拉取的纯解析部分（command 层 `fetch_provider_models` 的解析与归一化）。
//!
//! 目录层（provider_catalog）保持零 IO，本文件也只放**纯函数**；
//! 网络调用在 lib.rs 的 command 层完成。解析失败一律返回空 Vec ——
//! 前端据此回落目录静态候选（「自动获取是锦上添花，不是必过步骤」）。

/// 解析 OpenAI `GET /models` 响应 `{"data":[{"id":"..."}]}` → 去重排序后的模型 id 列表。
/// 异常输入（null / `{}` / 非 JSON / 条目缺 id）返回空 Vec，绝不 panic。
pub fn parse_openai_models(body: &str) -> Vec<String> {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(body) else {
        return Vec::new();
    };
    let Some(arr) = v.get("data").and_then(|d| d.as_array()) else {
        return Vec::new();
    };
    let ids: Vec<String> = arr
        .iter()
        .filter_map(|m| m.get("id").and_then(|i| i.as_str()))
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    dedup_sort(ids)
}

/// 去重 + 字典序排序（排序稳定性由 sort_unstable 对同一输入的确定性保证）。
pub fn dedup_sort(mut ids: Vec<String>) -> Vec<String> {
    ids.sort_unstable();
    ids.dedup();
    ids
}

#[cfg(test)]
mod tests {
    use super::*;

    // TC-ML-01  标准 OpenAI 响应 → id 列表（去重 + 排序）
    #[test]
    fn parses_standard_openai_response() {
        let body = r#"{"object":"list","data":[{"id":"b-model","object":"model"},
            {"id":"a-model","object":"model"},{"id":"a-model","object":"model"}]}"#;
        assert_eq!(
            parse_openai_models(body),
            vec!["a-model".to_string(), "b-model".to_string()]
        );
    }

    // TC-ML-02  异常输入（null / {} / 非 JSON / 缺 id）→ 空 Vec，不 panic
    #[test]
    fn abnormal_inputs_yield_empty_vec() {
        assert!(parse_openai_models("null").is_empty());
        assert!(parse_openai_models("{}").is_empty());
        assert!(parse_openai_models("not json at all").is_empty());
        assert!(parse_openai_models(r#"{"data":[{"object":"model"}]}"#).is_empty());
        assert!(parse_openai_models(r#"{"data":[{"id":""}]}"#).is_empty());
        assert!(parse_openai_models("").is_empty());
    }

    // TC-ML-03  去重 + 空列表稳定性
    #[test]
    fn dedup_sort_handles_empty_and_dupes() {
        assert!(dedup_sort(Vec::new()).is_empty());
        assert_eq!(
            dedup_sort(vec!["x".into(), "x".into(), "a".into()]),
            vec!["a".to_string(), "x".to_string()]
        );
    }
}
