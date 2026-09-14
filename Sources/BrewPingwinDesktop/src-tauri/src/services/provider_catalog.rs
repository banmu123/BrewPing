//! 内置厂商目录 —— 「选一个厂商」即自动预填 base_url / 协议 / 鉴权 / 模型名。
//!
//! 设计要点（对齐实施方案 §2.2 M2）：目录**只做预填模板，不做校验白名单**。
//! 用户选 `custom` 或改掉预填值都应被允许 —— 中转站地址千变万化，
//! 硬校验会挡住合法用法。目录的价值是「少打字」，不是「管住用户」。
//!
//! 全部为编译期常量，不含任何密钥；`get_provider_catalog` 原样序列化返回。
//! 本文件刻意保持**零 IO、零 tauri 依赖**（cargo test 裸跑前提）；
//! `models_url` 只是数据字段，网络调用放 lib.rs 的 command 层（fetch_provider_models）。
//!
//! 一期清单（2026-09-13 拍板）：Kimi / DeepSeek / GLM(智谱) / Xiaomi(小米) / MiniMax
//! 五家 + custom。五家全部走 **Anthropic Messages 端点**（零协议转换、纯透传）；
//! 列模型走各家 **OpenAI 端点**（Anthropic 协议无 GET /models），见 `models_url`。
//! 数据取自厂商官方文档；**严禁携带任何推广参数**（TC-PC-07 拦截）。

use crate::services::model_provider_store::{ApiFormat, AuthStyle};
use serde::Serialize;

/// 厂商性质分类（驱动 UI 分组与排序；独立枚举，保持 services 层自包含）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CatalogCategory {
    /// 厂商官方（Anthropic 官方等）
    Official,
    /// 国内官方
    CnOfficial,
    /// 聚合服务（一个 key 多家模型）
    Aggregator,
    /// 第三方 / 中转站
    ThirdParty,
    /// 自定义（空模板）
    Custom,
}

/// 一条厂商目录项（纯静态模板）。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogEntry {
    /// 稳定标识，作为前端 key（显式 id，不用数组下标 —— 吸取 cc-switch 教训）。
    pub id: &'static str,
    /// 展示名。
    pub name: &'static str,
    /// 展示别名 / 中文名（UI 优先用它，为空回落 name）。
    pub display_name: &'static str,
    /// 预填 base_url（可原样照抄官方文档；代理层负责路径拼接）。
    pub base_url: &'static str,
    /// 预填协议族。
    pub api_format: ApiFormat,
    /// 预填鉴权方式。
    pub auth_style: AuthStyle,
    /// 可选模型清单（静态兜底候选；离线可用，TC-PC-03 保证非 custom 非空）。
    pub models: &'static [&'static str],
    /// 列模型端点（OpenAI 格式；空串 = 不支持自动获取）。
    /// 转发走 Anthropic 端点（无 GET /models），列模型走 OpenAI 端点，**二者地址不同**。
    pub models_url: &'static str,
    /// 申请 Key 的地址（UI 给个链接）。
    pub console_url: &'static str,
    /// 官网（非推广链接；严禁携带 aff/邀请码）。
    pub website_url: &'static str,
    /// 厂商性质分类。
    pub category: CatalogCategory,
}

/// 一期 6 条：5 家国内官方 + custom。二期扩充时直接 append（TC-PC-01 是下界断言）。
pub const CATALOG: &[CatalogEntry] = &[
    CatalogEntry {
        id: "kimi",
        name: "Kimi (Moonshot)",
        display_name: "Kimi (月之暗面)",
        base_url: "https://api.moonshot.cn/anthropic", // Anthropic 兼容端点，零协议转换
        api_format: ApiFormat::Anthropic,
        auth_style: AuthStyle::Bearer,
        models: &["kimi-k3", "kimi-k2-turbo-preview", "kimi-latest"],
        models_url: "https://api.moonshot.cn/v1/models",
        console_url: "https://platform.moonshot.cn/console/api-keys",
        website_url: "https://www.moonshot.cn",
        category: CatalogCategory::CnOfficial,
    },
    CatalogEntry {
        id: "deepseek",
        name: "DeepSeek",
        display_name: "DeepSeek (深度求索)",
        // 官方 Anthropic 兼容端点（不再是裸域名 + openai_chat）
        base_url: "https://api.deepseek.com/anthropic",
        api_format: ApiFormat::Anthropic,
        auth_style: AuthStyle::Bearer,
        // [1m] 为官方上下文长度后缀；若转发报 model 不存在可改 deepseek-v4-pro
        models: &["deepseek-v4-pro[1m]", "deepseek-chat", "deepseek-reasoner"],
        models_url: "https://api.deepseek.com/models",
        console_url: "https://platform.deepseek.com/api_keys",
        website_url: "https://www.deepseek.com",
        category: CatalogCategory::CnOfficial,
    },
    CatalogEntry {
        id: "zhipu",
        name: "GLM (Zhipu)",
        display_name: "GLM (智谱)",
        // Anthropic 协议端点（/api/paas/v4 是 OpenAI 端点，不用）
        base_url: "https://open.bigmodel.cn/api/anthropic",
        api_format: ApiFormat::Anthropic,
        auth_style: AuthStyle::Bearer,
        // glm-5.1 为旗舰（需显式指定才用得上）；额度吃紧可换 glm-4.7
        models: &["glm-5.1", "glm-4.7", "glm-4.6"],
        models_url: "https://open.bigmodel.cn/api/paas/v4/models",
        console_url: "https://open.bigmodel.cn/usercenter/apikeys",
        website_url: "https://open.bigmodel.cn",
        category: CatalogCategory::CnOfficial,
    },
    CatalogEntry {
        id: "xiaomi",
        name: "MiMo (Xiaomi)",
        display_name: "MiMo (小米)",
        base_url: "https://api.xiaomimimo.com/anthropic",
        api_format: ApiFormat::Anthropic,
        auth_style: AuthStyle::Bearer,
        // MiMo 的 Anthropic 端点是否做 Claude 型号名映射未明确，显式填主力型号兜底
        models: &["mimo-v2.5-pro"],
        models_url: "https://api.xiaomimimo.com/v1/models",
        console_url: "https://platform.xiaomimimo.com/console/api-keys",
        website_url: "https://platform.xiaomimimo.com",
        category: CatalogCategory::CnOfficial,
    },
    CatalogEntry {
        id: "minimax",
        name: "MiniMax",
        display_name: "MiniMax (稀宇)",
        // 国内正式域名 api.minimaxi.com（多一个 i；api.minimax.chat 是旧域名）
        base_url: "https://api.minimaxi.com/anthropic",
        api_format: ApiFormat::Anthropic,
        auth_style: AuthStyle::Bearer,
        models: &["MiniMax-M3"],
        models_url: "https://api.minimaxi.com/v1/models",
        console_url: "https://platform.minimaxi.com/user-center/basic-information/interface-key",
        website_url: "https://www.minimaxi.com",
        category: CatalogCategory::CnOfficial,
    },
    CatalogEntry {
        id: "custom",
        name: "自定义 / 中转站",
        display_name: "自定义 / 中转站",
        base_url: "",
        api_format: ApiFormat::Anthropic,
        auth_style: AuthStyle::Auto,
        models: &[],
        models_url: "",
        console_url: "",
        website_url: "",
        category: CatalogCategory::Custom,
    },
];

/// 按 id 查目录（command 层 `fetch_provider_models` 用）。
pub fn find(id: &str) -> Option<&'static CatalogEntry> {
    CATALOG.iter().find(|c| c.id == id)
}

#[cfg(test)]
mod tests {
    use super::*;

    // TC-PC-01  目录非空，且 id 全局唯一
    #[test]
    fn catalog_ids_unique() {
        assert!(CATALOG.len() >= 6, "一期至少 5 家预置厂商 + custom");
        let mut ids: Vec<&str> = CATALOG.iter().map(|c| c.id).collect();
        ids.sort_unstable();
        let len = ids.len();
        ids.dedup();
        assert_eq!(ids.len(), len, "id 必须唯一");
    }

    // TC-PC-02  除 custom 外每条都有合法 base_url
    #[test]
    fn catalog_base_urls_valid() {
        for c in CATALOG {
            if c.id == "custom" {
                assert_eq!(c.base_url, "", "custom 必须为空模板");
                continue;
            }
            assert!(
                c.base_url.starts_with("https://") || c.base_url.starts_with("http://"),
                "{} 的 base_url 必须是 http(s)",
                c.id
            );
        }
    }

    // TC-PC-03  除 custom 外每条 models 非空
    #[test]
    fn catalog_models_present() {
        for c in CATALOG {
            if c.id == "custom" {
                continue;
            }
            assert!(!c.models.is_empty(), "{} 必须带预置模型", c.id);
        }
    }

    // TC-PC-04  序列化契约：字段名 camelCase（含新增字段）
    #[test]
    fn catalog_serializes_camel_case() {
        let json = serde_json::to_string(&CATALOG[0]).unwrap();
        assert!(json.contains("baseUrl"), "必须 camelCase baseUrl");
        assert!(json.contains("apiFormat"), "必须 camelCase apiFormat");
        assert!(json.contains("consoleUrl"), "必须 camelCase consoleUrl");
        assert!(json.contains("displayName"), "必须 camelCase displayName");
        assert!(json.contains("modelsUrl"), "必须 camelCase modelsUrl");
        assert!(json.contains("websiteUrl"), "必须 camelCase websiteUrl");
        assert!(json.contains("category"), "必须带 category");
        assert!(!json.contains("base_url"), "不得出现 snake_case");
    }

    // TC-PC-05  除 custom 外每条都有合法 https console_url
    #[test]
    fn catalog_console_urls_valid() {
        for c in CATALOG {
            if c.id == "custom" {
                assert_eq!(c.console_url, "", "custom 无 console_url");
                continue;
            }
            assert!(
                c.console_url.starts_with("https://"),
                "{} 的 console_url 必须 https",
                c.id
            );
        }
    }

    // TC-PC-06  category == Custom 的只有一条，且 id == "custom"
    #[test]
    fn catalog_single_custom_entry() {
        let customs: Vec<&CatalogEntry> = CATALOG
            .iter()
            .filter(|c| c.category == CatalogCategory::Custom)
            .collect();
        assert_eq!(customs.len(), 1, "custom 模板有且仅有一条");
        assert_eq!(customs[0].id, "custom");
    }

    // TC-PC-07  🔴 禁止出现推广参数（aff / 邀请码 / 促销链接）
    // 把「不许带推广参数」写成断言：从 cc-switch 复制粘贴时立刻被测试拦下。
    #[test]
    fn catalog_has_no_promotion_params() {
        for c in CATALOG {
            assert!(!c.base_url.contains("aff="), "{} base_url 不得带推广参数", c.id);
            assert!(!c.models_url.contains("aff="), "{} models_url 不得带推广参数", c.id);
            assert!(!c.console_url.contains("aff="), "{} console_url 不得带推广参数", c.id);
            assert!(!c.website_url.contains("aff="), "{} website_url 不得带推广参数", c.id);
            assert!(
                !c.console_url.contains("invite") && !c.website_url.contains("invite"),
                "{} 不得带邀请码链接",
                c.id
            );
        }
    }

    // TC-PC-08  display_name 非空（UI 优先用它，为空才回落 name）
    #[test]
    fn catalog_display_names_present() {
        for c in CATALOG {
            assert!(!c.display_name.is_empty(), "{} 必须给 display_name", c.id);
        }
    }

    // TC-PC-09  一期专属护栏：五家全部走 Anthropic 协议端点（零协议转换前提）
    // 二期若加入 openai_chat 厂商，需有意识地放开此断言。
    #[test]
    fn catalog_phase1_all_anthropic() {
        for c in CATALOG.iter().filter(|c| c.id != "custom") {
            assert_eq!(
                c.api_format,
                ApiFormat::Anthropic,
                "{} 一期必须走 Anthropic 协议端点",
                c.id
            );
        }
    }

    // TC-PC-10  一期专属护栏：六条 id 齐全
    #[test]
    fn catalog_phase1_ids_present() {
        let ids: Vec<&str> = CATALOG.iter().map(|c| c.id).collect();
        for want in ["kimi", "deepseek", "zhipu", "xiaomi", "minimax", "custom"] {
            assert!(ids.contains(&want), "目录缺少 {}", want);
        }
    }

    // TC-PC-11  models_url 为 https 或空串（custom 为空 = 前端禁用「获取列表」）
    #[test]
    fn catalog_models_urls_valid() {
        for c in CATALOG {
            assert!(
                c.models_url.is_empty() || c.models_url.starts_with("https://"),
                "{} 的 models_url 必须 https 或空",
                c.id
            );
        }
    }
}
