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
//! 五家 + custom。**端点按 agent 分派**（2026-09-14 对齐 cc-switch 源码实证）：
//! 顶层 `base_url`/`api_format` 是**转发代理语义**（Anthropic Messages 端点，
//! 零协议转换纯透传）；各 CLI 表单改用 `endpoints` 里对应 agent 的端点 ——
//! Claude Code 用 `/anthropic`、Codex 用 OpenAI Responses 端点（`wire_api="responses"`）、
//! OpenCode/pi 用 OpenAI 兼容 Chat 端点。列模型仍走各家 OpenAI 端点，见 `models_url`。
//! 数据取自厂商官方文档（经 cc-switch 预设交叉核对）；**严禁携带任何推广参数**（TC-PC-07 拦截）。

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

/// 单个 agent 的端点形态 —— **同一厂商在不同 agent 下要用不同 baseURL 与协议**。
///
/// 数据逐条对齐 cc-switch 的按 app_type 分预设实证（2026-09-14 源码核实：
/// `src/config/{claude,codex,opencode,pi}ProviderPresets.ts`），关键结论：
/// - **`/anthropic` 子路径只属于 Claude Code**（Anthropic Messages 兼容层）；
/// - Codex 一律 OpenAI 系端点：国内五家官方全部支持原生 Responses
///   （`wire_api = "responses"`；新版 Codex 已废弃 `"chat"`，写入即拒载）；
/// - OpenCode / pi 走 OpenAI 兼容 Chat 端点（`@ai-sdk/openai-compatible` /
///   `openai-completions`）。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentEndpoint {
    /// agent 标识：`claude-code` / `codex` / `opencode` / `pi`。
    pub agent: &'static str,
    /// 该 agent 应使用的 base_url。
    pub base_url: &'static str,
    /// Codex 专属：`wire_api` 取值（其余 agent 为空串）。
    pub wire_api: &'static str,
    /// OpenCode 专属：npm SDK 包名（其余 agent 为空串）。
    pub npm: &'static str,
    /// pi 专属：`api` 协议值（其余 agent 为空串）。
    pub pi_api: &'static str,
}

/// 便捷宏：一个厂商的四个 agent 端点一次写齐（在 CATALOG 的 const 上下文里
/// 展开，数组字面量随目录成为 'static）。
///
/// 协议字段按 agent 固定（cc-switch 实证）：codex=`responses`、
/// opencode=`@ai-sdk/openai-compatible`、pi=`openai-completions`。
macro_rules! agent_endpoints {
    ($claude:expr, $codex:expr, $opencode:expr, $pi:expr $(,)?) => {
        &[
            AgentEndpoint {
                agent: "claude-code",
                base_url: $claude,
                wire_api: "",
                npm: "",
                pi_api: "",
            },
            AgentEndpoint {
                agent: "codex",
                base_url: $codex,
                wire_api: "responses",
                npm: "",
                pi_api: "",
            },
            AgentEndpoint {
                agent: "opencode",
                base_url: $opencode,
                wire_api: "",
                npm: "@ai-sdk/openai-compatible",
                pi_api: "",
            },
            AgentEndpoint {
                agent: "pi",
                base_url: $pi,
                wire_api: "",
                npm: "",
                pi_api: "openai-completions",
            },
        ]
    };
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
    /// 预填 base_url（**转发代理语义** = Anthropic 端点，与 `api_format` 配套；
    /// 各 CLI 表单应改用 `endpoints` 里对应 agent 的端点）。
    pub base_url: &'static str,
    /// 预填协议族。
    pub api_format: ApiFormat,
    /// 预填鉴权方式。
    pub auth_style: AuthStyle,
    /// 各 agent 专属端点（custom 为空表；前端按 agentId 解析，缺失回落顶层）。
    pub endpoints: &'static [AgentEndpoint],
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
        // codex/opencode/pi 走 OpenAI 端点（cc-switch：Kimi 官方 Codex 文档
        // 明写原生支持 Responses API，/v1 + wire_api="responses" 直连）
        endpoints: agent_endpoints!(
            "https://api.moonshot.cn/anthropic",
            "https://api.moonshot.cn/v1",
            "https://api.moonshot.cn/v1",
            "https://api.moonshot.cn/v1",
        ),
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
        // 官方 Anthropic 兼容端点（仅 Claude Code 用；**不是** Codex 端点）
        base_url: "https://api.deepseek.com/anthropic",
        api_format: ApiFormat::Anthropic,
        auth_style: AuthStyle::Bearer,
        // 🔴 codex 用**裸域** https://api.deepseek.com（官方 Codex 接入文档：
        // deepseek-v4 系原生 Responses，wire_api="responses" 直连裸域，无需
        // /v1 也无需 /anthropic）—— cc-switch codexProviderPresets 同款。
        // opencode/pi 走 /v1 OpenAI 兼容端点。
        endpoints: agent_endpoints!(
            "https://api.deepseek.com/anthropic",
            "https://api.deepseek.com",
            "https://api.deepseek.com/v1",
            "https://api.deepseek.com/v1",
        ),
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
        // Anthropic 协议端点（仅 Claude Code 用）
        base_url: "https://open.bigmodel.cn/api/anthropic",
        api_format: ApiFormat::Anthropic,
        auth_style: AuthStyle::Bearer,
        // 🔴 智谱三端点分立（官方明示「错误配置端点将无法使用套餐额度」）：
        // Anthropic=/api/anthropic、OpenAI Chat=/api/coding/paas/v4、
        // **OpenAI Responses=/api/v1**。codex 发 Responses wire → 必须用
        // /api/v1（cc-switch 实证同款）；opencode/pi 发 Chat wire →
        // /api/coding/paas/v4。
        endpoints: agent_endpoints!(
            "https://open.bigmodel.cn/api/anthropic",
            "https://open.bigmodel.cn/api/v1",
            "https://open.bigmodel.cn/api/coding/paas/v4",
            "https://open.bigmodel.cn/api/coding/paas/v4",
        ),
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
        base_url: "https://api.xiaomimimo.com/anthropic", // 仅 Claude Code 用
        api_format: ApiFormat::Anthropic,
        auth_style: AuthStyle::Bearer,
        // MiMo 官方 Codex 文档声明原生支持 Responses API（/v1 + responses，
        // cc-switch 与用户机器 cc-switch 投影实测均为该写法）
        endpoints: agent_endpoints!(
            "https://api.xiaomimimo.com/anthropic",
            "https://api.xiaomimimo.com/v1",
            "https://api.xiaomimimo.com/v1",
            "https://api.xiaomimimo.com/v1",
        ),
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
        base_url: "https://api.minimaxi.com/anthropic", // 仅 Claude Code 用
        api_format: ApiFormat::Anthropic,
        auth_style: AuthStyle::Bearer,
        // MiniMax 官方 API 参考已列 /v1/responses 为正式端点（原生 Responses）
        endpoints: agent_endpoints!(
            "https://api.minimaxi.com/anthropic",
            "https://api.minimaxi.com/v1",
            "https://api.minimaxi.com/v1",
            "https://api.minimaxi.com/v1",
        ),
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
        // 空表 = 前端回落顶层（同样为空）→ 只当「我要自己填」的显式选择
        endpoints: &[],
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

    // TC-PC-04  序列化契约：字段名 camelCase（含新增 endpoints）
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
        assert!(json.contains("endpoints"), "必须带 endpoints");
        assert!(json.contains("wireApi"), "endpoint 必须带 wireApi");
        assert!(json.contains("piApi"), "endpoint 必须带 piApi");
        assert!(!json.contains("base_url"), "不得出现 snake_case");
        assert!(!json.contains("wire_api"), "不得出现 snake_case");
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

    // TC-PC-09  顶层 base_url 全部为 Anthropic 协议端点 —— **仅转发代理语义**
    // （转发层做 Anthropic 入站透传）。各 CLI 表单用 endpoints 按 agent 分派，
    // 见 TC-PC-12。
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

    // TC-PC-12  🔴 per-agent 端点护栏（cc-switch 源码实证的对齐断言）：
    // 1. 除 custom 外每条恰好 4 个 agent 端点（claude-code/codex/opencode/pi 各一次）；
    // 2. codex 端点绝不含 /anthropic（新版 Codex 只认 OpenAI Responses 端点，
    //    填 /anthropic 必然协议不匹配 —— 本次修复的根因）；
    // 3. claude-code 端点 == 顶层 base_url（转发代理与 Claude 表单同源）；
    // 4. 协议字段只挂在各自的 agent 上（wireApi→codex、npm→opencode、piApi→pi）。
    #[test]
    fn catalog_per_agent_endpoints_valid() {
        const AGENTS: [&str; 4] = ["claude-code", "codex", "opencode", "pi"];
        for c in CATALOG.iter().filter(|c| c.id != "custom") {
            assert_eq!(
                c.endpoints.len(),
                4,
                "{} 必须带 4 个 agent 端点",
                c.id
            );
            for agent in AGENTS {
                let ep = c
                    .endpoints
                    .iter()
                    .find(|e| e.agent == agent)
                    .unwrap_or_else(|| panic!("{} 缺少 {} 端点", c.id, agent));
                assert!(
                    ep.base_url.starts_with("https://"),
                    "{} 的 {} 端点必须 https",
                    c.id,
                    agent
                );
                if agent == "codex" {
                    assert!(
                        !ep.base_url.contains("/anthropic"),
                        "{} 的 codex 端点不得用 /anthropic（Codex 只认 OpenAI 端点）",
                        c.id
                    );
                    assert_eq!(
                        ep.wire_api, "responses",
                        "{} 的 codex 端点必须 wire_api=responses（新版 Codex 已废弃 chat）",
                        c.id
                    );
                } else {
                    assert_eq!(ep.wire_api, "", "wireApi 只允许出现在 codex");
                }
                if agent == "opencode" {
                    assert_eq!(
                        ep.npm, "@ai-sdk/openai-compatible",
                        "{} 的 opencode 端点必须带 openai-compatible SDK",
                        c.id
                    );
                } else {
                    assert_eq!(ep.npm, "", "npm 只允许出现在 opencode");
                }
                if agent == "pi" {
                    assert_eq!(
                        ep.pi_api, "openai-completions",
                        "{} 的 pi 端点必须 openai-completions",
                        c.id
                    );
                } else {
                    assert_eq!(ep.pi_api, "", "piApi 只允许出现在 pi");
                }
                if agent == "claude-code" {
                    assert_eq!(
                        ep.base_url, c.base_url,
                        "{} 的 claude-code 端点必须与顶层 base_url 同源",
                        c.id
                    );
                }
            }
        }
    }

    // TC-PC-13  custom 无 endpoints；DeepSeek 的 codex 端点是裸域（官方文档钦定）
    #[test]
    fn catalog_custom_empty_and_deepseek_bare_domain() {
        let custom = CATALOG.iter().find(|c| c.id == "custom").unwrap();
        assert!(custom.endpoints.is_empty(), "custom 不得预填端点");
        let ds = CATALOG.iter().find(|c| c.id == "deepseek").unwrap();
        let codex = ds.endpoints.iter().find(|e| e.agent == "codex").unwrap();
        assert_eq!(
            codex.base_url, "https://api.deepseek.com",
            "DeepSeek codex 端点 = 官方 Codex 文档裸域（原生 Responses 直连）"
        );
    }
}
