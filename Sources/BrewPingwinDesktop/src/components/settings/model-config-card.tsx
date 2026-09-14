import { useCallback, useEffect, useMemo, useState } from "react";
import {
  Check,
  ChevronDown,
  ChevronRight,
  Copy,
  ExternalLink,
  FileCode2,
  Loader2,
  Pencil,
  Plus,
  RefreshCw,
  Trash2,
  X,
} from "lucide-react";
import {
  activateCodexProvider,
  activatePiProvider,
  deleteClaudeProvider,
  deleteCodexProvider,
  deleteModelProvider,
  deleteOpenCodeProvider,
  deletePiProvider,
  fetchProviderModels,
  getAgentModels,
  getAgents,
  getClaudeProvider,
  getCliTakeover,
  getCodexProviders,
  getModelProviders,
  getOpenCodeProviders,
  getPiProviders,
  getProviderCatalog,
  saveClaudeProvider,
  saveCodexProvider,
  saveModelProvider,
  saveOpenCodeProvider,
  savePiProvider,
  setCliTakeover,
  setDefaultModel,
  setModelFailover,
  setModelProxy,
  switchModelProvider,
} from "../../api/tauri";
import type {
  AgentEntry,
  AgentModelsInfo,
  ApiFormat,
  AuthStyle,
  CatalogCategory,
  CatalogEntry,
  ClaudeProviderEntry,
  ClaudeProvidersInfo,
  CliTakeoverInfo,
  CodexProviderEntry,
  CodexProvidersInfo,
  ModelProviderConfig,
  ModelProvidersInfo,
  OpenCodeProviderEntry,
  OpenCodeProvidersInfo,
  PiProviderEntry,
  PiProvidersInfo,
} from "../../api/types";
import { AgentModelTabs, type AgentTabItem } from "./agent-model-tabs";
import { AgentProviderPanel } from "./agent-provider-panel";
import {
  ClaudeProviderEmpty,
  ClaudeProviderForm,
  emptyClaudeProvider,
  normalizeClaudeTiers,
} from "./claude-provider-form";
import {
  CodexProviderForm,
  emptyCodexProvider,
} from "./codex-provider-form";
import { CodexProviderPanel } from "./codex-provider-panel";
import { OpenCodeProviderForm, emptyOpenCodeProvider } from "./opencode-provider-form";
import { OpenCodeProviderPanel } from "./opencode-provider-panel";
import { PiProviderForm, emptyPiProvider } from "./pi-provider-form";
import { PiProviderPanel } from "./pi-provider-panel";
import { Badge } from "../ui/badge";
import { Button } from "../ui/button";
import { useI18n } from "../../i18n";
import { cn } from "../../lib/utils";

// ─── 设置页「模型配置」卡片（内置 cc-switch 式多厂商接入 + 请求转发）────────────
//
// 自包含数据源（挂载时 get_model_providers），与 EnvironmentCard 同款模式。
// 代理启停 / 配置增删改切全部即时返回最新快照，本地无需推导状态。
//
// P2 骨架：状态摘要行（代理）→ Agent 归属 Tab 栏 → 厂商面板（专属 + 通用带徽章）
// → 折叠收纳（CLI 接入 / Agent 模型偏好）。当前厂商与设为当前都按 tab 归属路由。

const FORMAT_OPTIONS: ApiFormat[] = ["anthropic", "openai_chat", "openai_responses"];
const AUTH_OPTIONS: AuthStyle[] = ["auto", "bearer", "x-api-key"];

/** 记忆上次的 Agent tab（localStorage；失效自动回落「通用」）。 */
const TAB_STORAGE_KEY = "brewping.modelTab";

const inputCls =
  "h-7 w-full rounded-md border border-border bg-background px-2 text-xs text-foreground outline-none placeholder:text-muted-foreground/60 focus:border-primary/40";
const fieldLabelCls =
  "mb-0.5 block text-[10px] text-muted-foreground";

function emptyDraft(agentId: string): ModelProviderConfig {
  return {
    id: "",
    name: "",
    baseUrl: "",
    apiKey: "",
    hasKey: false,
    apiFormat: "anthropic",
    authStyle: "auto",
    isFullUrl: false,
    model: null,
    notes: null,
    createdAtMs: 0,
    sortIndex: 0,
    agentId,
  };
}

/** category 分组排序权重（custom 恒最后；未识别分类居中）。 */
const CATEGORY_ORDER: Record<CatalogCategory, number> = {
  official: 0,
  cn_official: 1,
  aggregator: 2,
  third_party: 3,
  custom: 99,
};

/**
 * 生效端点预览（纯前端镜像后端拼接逻辑，让「智能补 /v1」可验证）：
 * - isFullUrl：base 已是完整端点，原样使用；
 * - openai_chat：转换模式端点推导（尾部智能补 /v1/chat/completions）；
 * - openai_responses：透传拼接 /v1/responses；
 * - anthropic：透传拼接 /v1/messages（Claude Code 入站的主要路径）。
 */
function previewEndpoint(
  baseUrl: string,
  apiFormat: ApiFormat,
  isFullUrl: boolean,
): string {
  const base = baseUrl.trim().replace(/\/+$/, "");
  if (!base) return "—";
  if (isFullUrl) return base;
  if (apiFormat === "openai_chat") {
    if (base.endsWith("/chat/completions")) return base;
    if (base.endsWith("/v1")) return `${base}/chat/completions`;
    return `${base}/v1/chat/completions`;
  }
  if (apiFormat === "openai_responses") return `${base}/v1/responses`;
  return `${base}/v1/messages`;
}

export function ModelConfigCard() {
  const { t } = useI18n();
  const [info, setInfo] = useState<ModelProvidersInfo | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  /** 正在编辑的配置（null = 关闭表单；id 为空 = 新建）。 */
  const [editing, setEditing] = useState<ModelProviderConfig | null>(null);
  /** 两步删除确认：待确认的配置 id。 */
  const [confirmId, setConfirmId] = useState<string | null>(null);
  /** 代理端口输入草稿（失焦 / 回车时若变化则提交）。 */
  const [portDraft, setPortDraft] = useState("");
  /** CLI 接管状态（Claude Code / Codex）。 */
  const [cliInfo, setCliInfo] = useState<CliTakeoverInfo | null>(null);
  /** 内置厂商目录（静态模板，挂载时拉一次）。 */
  const [catalog, setCatalog] = useState<CatalogEntry[]>([]);
  /** 表单当前选中的厂商（用于预填与 console 链接）。 */
  const [selectedVendor, setSelectedVendor] = useState("");

  // ── P2：Agent 归属 tab ──
  /** 当前 tab 的归属 id（"" = 通用；其余为 agent id）。 */
  const [activeTab, setActiveTab] = useState(() => {
    try {
      return localStorage.getItem(TAB_STORAGE_KEY) ?? "";
    } catch {
      return "";
    }
  });
  /** 折叠收纳区（默认全部收起，主视图只留 摘要行 + tab + 面板）。 */
  const [proxyOpen, setProxyOpen] = useState(false);
  const [cliOpen, setCliOpen] = useState(false);
  const [prefsOpen, setPrefsOpen] = useState(false);

  const selectTab = useCallback((id: string) => {
    setActiveTab(id);
    setConfirmId(null);
    try {
      localStorage.setItem(TAB_STORAGE_KEY, id);
    } catch {
      /* 隐私模式等场景写不进就算了，仅不记忆 */
    }
  }, []);

  /** 目录按 category 分组（custom 恒最后），供厂商下拉的 optgroup。 */
  const groupedCatalog = useMemo(() => {
    const sorted = [...catalog].sort(
      (a, b) =>
        (CATEGORY_ORDER[a.category] ?? 50) - (CATEGORY_ORDER[b.category] ?? 50),
    );
    const groups: { category: CatalogCategory; entries: CatalogEntry[] }[] = [];
    for (const c of sorted) {
      const last = groups[groups.length - 1];
      if (last && last.category === c.category) last.entries.push(c);
      else groups.push({ category: c.category, entries: [c] });
    }
    return groups;
  }, [catalog]);

  /** 高级选项（默认折叠）：拉取模型列表状态。 */
  const [advancedOpen, setAdvancedOpen] = useState(false);
  const [fetchingModels, setFetchingModels] = useState(false);
  /** 从上游拉到的真实模型清单（null = 未拉取，回落目录静态候选）。 */
  const [fetchedModels, setFetchedModels] = useState<string[] | null>(null);
  const [fetchErr, setFetchErr] = useState<string | null>(null);

  // ── OpenCode 厂商（直接读写本机 opencode.json，对标 cc-switch）──────────────
  /** opencode 已配置厂商（唯一真相 = opencode.json）。 */
  const [ocInfo, setOcInfo] = useState<OpenCodeProvidersInfo | null>(null);
  const [ocLoading, setOcLoading] = useState(false);
  const [ocError, setOcError] = useState<string | null>(null);
  const [ocBusy, setOcBusy] = useState(false);
  /** 正在编辑的 opencode 厂商（null = 表单关闭；isEdit=false 时是新建）。 */
  const [ocEditing, setOcEditing] = useState<OpenCodeProviderEntry | null>(null);
  const [ocIsEdit, setOcIsEdit] = useState(false);
  /** 拉取 opencode 厂商模型清单状态。 */
  const [ocFetching, setOcFetching] = useState(false);
  const [ocFetchErr, setOcFetchErr] = useState<string | null>(null);
  /** 两步删除确认：待确认的 opencode 厂商 key。 */
  const [ocConfirmId, setOcConfirmId] = useState<string | null>(null);

  /** opencode 表单默认 npm 包（取后端清单首项；无清单时回落兼容模式）。 */
  const defaultOpenCodeNpm =
    ocInfo?.npmPackages[0]?.value ?? "@ai-sdk/openai-compatible";

  // ── Claude Code 厂商（整体覆盖本机 ~/.claude/settings.json，对标 cc-switch）──
  // 与 opencode 不同：Claude Code 只有「一份」配置，所以是编辑单例而不是列表。
  const [clInfo, setClInfo] = useState<ClaudeProvidersInfo | null>(null);
  const [clLoading, setClLoading] = useState(false);
  const [clError, setClError] = useState<string | null>(null);
  const [clBusy, setClBusy] = useState(false);
  /** 是否展开编辑表单（null 语义不需要：草稿从 clInfo.provider 复制而来）。 */
  const [clEditing, setClEditing] = useState<ClaudeProviderEntry | null>(null);
  const [clConfirmDelete, setClConfirmDelete] = useState(false);

  // ── Codex 厂商（写本机 ~/.codex/config.toml，对标 cc-switch）────────────────
  const [cxInfo, setCxInfo] = useState<CodexProvidersInfo | null>(null);
  const [cxLoading, setCxLoading] = useState(false);
  const [cxError, setCxError] = useState<string | null>(null);
  const [cxBusy, setCxBusy] = useState(false);
  const [cxEditing, setCxEditing] = useState<CodexProviderEntry | null>(null);
  const [cxIsEdit, setCxIsEdit] = useState(false);
  const [cxConfirmId, setCxConfirmId] = useState<string | null>(null);
  /** 正在切换生效项的 Codex key。 */
  const [cxBusyId, setCxBusyId] = useState<string | null>(null);
  const [cxFetching, setCxFetching] = useState(false);
  const [cxFetchErr, setCxFetchErr] = useState<string | null>(null);

  // ── pi 厂商（写本机 ~/.pi/agent/models.json，对标 cc-switch）────────────────
  const [piInfo, setPiInfo] = useState<PiProvidersInfo | null>(null);
  const [piLoading, setPiLoading] = useState(false);
  const [piError, setPiError] = useState<string | null>(null);
  const [piBusy, setPiBusy] = useState(false);
  const [piEditing, setPiEditing] = useState<PiProviderEntry | null>(null);
  const [piIsEdit, setPiIsEdit] = useState(false);
  const [piConfirmId, setPiConfirmId] = useState<string | null>(null);
  /** 正在切换默认项 / 删除中的 pi key。 */
  const [piBusyId, setPiBusyId] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      // allSettled：两个请求互不拖累，任何一个 reject 都不阻塞 loading 结束
      const [snapRes, takeoverRes] = await Promise.allSettled([
        getModelProviders(),
        getCliTakeover(),
      ]);
      if (snapRes.status === "fulfilled") {
        setInfo(snapRes.value);
        setPortDraft(String(snapRes.value.proxyPort));
      } else {
        setError(String(snapRes.reason));
      }
      if (takeoverRes.status === "fulfilled") {
        setCliInfo(takeoverRes.value);
      } else {
        setError((prev) => prev ?? String(takeoverRes.reason));
      }
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  // 厂商目录是静态数据：挂载时拉一次，失败不影响主流程（下拉隐藏即可）
  useEffect(() => {
    getProviderCatalog()
      .then(setCatalog)
      .catch(() => {});
  }, []);

  // ── Agent 模型绑定（各 Agent 当前生效模型 + 可选列表）──────────────────────
  const [agents, setAgents] = useState<AgentEntry[]>([]);
  /** agentId → 模型目录快照（未知 agent / 无配置 = null）。 */
  const [agentModels, setAgentModels] = useState<Record<string, AgentModelsInfo | null>>({});
  /** 展开的 Agent（同一时间一个，保持卡片紧凑）。 */
  const [expandedAgent, setExpandedAgent] = useState<string | null>(null);
  /** 正在写偏好的 Agent（按钮转圈用）。 */
  const [agentBusy, setAgentBusy] = useState<string | null>(null);

  const refreshAgentModels = useCallback(async (agentId: string) => {
    try {
      const info = await getAgentModels(agentId);
      setAgentModels((prev) => ({ ...prev, [agentId]: info }));
    } catch {
      setAgentModels((prev) => ({ ...prev, [agentId]: null }));
    }
  }, []);

  // 挂载时拉 agent 列表 + 逐个拉模型目录（都是本机文件读取，量小）
  useEffect(() => {
    let cancelled = false;
    getAgents()
      .then((list) => {
        if (cancelled) return;
        setAgents(list);
        list.forEach((a) => void refreshAgentModels(a.id));
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [refreshAgentModels]);

  // 记忆的 tab 指向已消失的 agent（如配置变更）→ 回落「通用」
  useEffect(() => {
    if (activeTab !== "" && !agents.some((a) => a.id === activeTab)) {
      setActiveTab("");
    }
  }, [agents, activeTab]);

  // ── P2 派生：tab 列表 / 当前 tab 的厂商与生效当前 / 对应 CLI 接入项 ──
  const tabs: AgentTabItem[] = useMemo(
    () => [
      { id: "", name: t("mp.tabGeneral") },
      ...agents.map((a) => ({ id: a.id, name: a.name })),
    ],
    [agents, t],
  );

  /** 当前 tab 的厂商：专属 + （专属 tab 时）通用。顺序 = 专属在前。 */
  const tabProviders = useMemo(() => {
    const all = info?.providers ?? [];
    const own = all.filter((p) => p.agentId === activeTab);
    if (activeTab === "") return own;
    return [...own, ...all.filter((p) => p.agentId === "")];
  }, [info, activeTab]);

  /** 当前 tab 的生效当前厂商（专属槽 → 通用槽 → null，镜像后端 resolve_current_for）。 */
  const tabCurrentId = useMemo(() => {
    if (!info) return null;
    if (activeTab === "") return info.currentId ?? null;
    return info.currentByAgent?.[activeTab] ?? info.currentId ?? null;
  }, [info, activeTab]);

  /** tab 归属对应的 CLI 接入项（claude-code→claude_code；无对应 CLI = null 不提示）。 */
  const cliForTab = useMemo(() => {
    if (activeTab === "") return null;
    const cliId = activeTab.replace(/-/g, "_");
    return cliInfo?.items.find((i) => i.id === cliId) ?? null;
  }, [activeTab, cliInfo]);

  /** 选模型 = 记住该 Agent 的用户默认（后端持久化，启动 Agent 时以参数传入）。 */
  const pickAgentModel = (agentId: string, modelId: string, providerId: string | null) => {
    setAgentBusy(agentId);
    setDefaultModel(agentId, modelId, providerId)
      .then(() => refreshAgentModels(agentId))
      .catch((e) => setError(String(e)))
      .finally(() => setAgentBusy(null));
  };

  /** 清除偏好 → 回落 CLI 自己配置里的当前模型。 */
  const clearAgentModel = (agentId: string) => {
    setAgentBusy(agentId);
    setDefaultModel(agentId, null, null)
      .then(() => refreshAgentModels(agentId))
      .catch((e) => setError(String(e)))
      .finally(() => setAgentBusy(null));
  };

  // 选中厂商 → 预填 name / baseUrl / 协议 / 鉴权 / model（name、model 已填则保留用户输入）。
  // 目录只做预填模板不做校验（中转站地址千变万化，custom 也可随意改）。
  const applyVendor = (id: string) => {
    setSelectedVendor(id);
    // 切厂商即换数据源：已拉取的模型清单作废
    setFetchedModels(null);
    setFetchErr(null);
    const c = catalog.find((x) => x.id === id);
    if (!c) return;
    setEditing((prev) =>
      prev
        ? {
            ...prev,
            name: prev.name.trim() || c.displayName || c.name,
            baseUrl: c.baseUrl || prev.baseUrl,
            apiFormat: c.apiFormat,
            authStyle: c.authStyle,
            // 🔴 model 必须随厂商切换：代理映射模式下 cfg.model 非空即覆盖请求体
            // model，残留旧厂商型号会被真实转发出去（必 400/404）
            model: prev.model?.trim() ? prev.model : (c.models[0] ?? null),
            // 🔴 A 厂商的完整端点对 B 厂商无意义，切换必须重置
            isFullUrl: false,
          }
        : prev,
    );
  };

  const activeCatalog = catalog.find((x) => x.id === selectedVendor);
  /** 高级选项的可点选候选：上游拉到的优先，否则目录静态候选。 */
  const candidateModels = fetchedModels ?? activeCatalog?.models ?? [];

  /** 拉取上游真实模型列表（失败回落静态候选，绝不阻塞手填）。 */
  const handleFetchModels = () => {
    if (!activeCatalog || !editing) return;
    setFetchingModels(true);
    setFetchErr(null);
    fetchProviderModels(activeCatalog.id, editing.apiKey || null)
      .then(setFetchedModels)
      .catch((e) => {
        const msg = String(e);
        if (msg.includes("401") || msg.includes("403")) {
          setFetchErr(t("mp.invalidKey"));
        } else if (msg.includes("missing api key")) {
          setFetchErr(t("mp.fetchNeedKey"));
        } else {
          setFetchErr(`${t("mp.fetchFailed")}: ${msg}`);
        }
      })
      .finally(() => setFetchingModels(false));
  };

  /** 关闭表单并复位临时状态（含高级选项）。 */
  const closeForm = () => {
    setSelectedVendor("");
    setEditing(null);
    setAdvancedOpen(false);
    setFetchedModels(null);
    setFetchErr(null);
  };

  const run = useCallback(async (action: () => Promise<ModelProvidersInfo>) => {
    setBusy(true);
    setError(null);
    try {
      setInfo(await action());
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy(false);
    }
  }, []);

  // 代理启停（以端口草稿提交；非法值回落已存端口）
  const toggleProxy = (enabled: boolean) => {
    if (!info) return;
    const port = Number.parseInt(portDraft, 10);
    const next = Number.isFinite(port) && port > 0 ? port : info.proxyPort;
    void run(() => setModelProxy(enabled, next));
  };

  // 故障转移开关
  const toggleFailover = (enabled: boolean) => {
    void run(() => setModelFailover(enabled));
  };

  // CLI 接入启停（返回 CliTakeoverInfo，单独 set 而非走 run）
  const toggleTakeover = (cli: string, enable: boolean) => {
    setBusy(true);
    setError(null);
    setCliTakeover(cli, enable)
      .then(setCliInfo)
      .catch((e) => setError(String(e)))
      .finally(() => setBusy(false));
  };

  // 端口修改（回车 / 失焦时若与已存值不同则提交）
  const applyPort = () => {
    if (!info) return;
    const port = Number.parseInt(portDraft, 10);
    if (!Number.isFinite(port) || port <= 0 || port === info.proxyPort) return;
    void run(() => setModelProxy(info.proxyEnabled, port));
  };

  const handleSave = () => {
    if (!editing) return;
    const draft: ModelProviderConfig = {
      ...editing,
      name: editing.name.trim(),
      baseUrl: editing.baseUrl.trim(),
    };
    void run(() => saveModelProvider(draft)).then(closeForm);
  };

  const handleDelete = (id: string) => {
    if (confirmId !== id) {
      setConfirmId(id);
      return;
    }
    setConfirmId(null);
    void run(() => deleteModelProvider(id));
  };

  // ── OpenCode 厂商：读（本机 opencode.json）──────────────────────────────────
  const refreshOpenCode = useCallback(async () => {
    setOcLoading(true);
    try {
      setOcInfo(await getOpenCodeProviders());
      setOcError(null);
    } catch (e) {
      setOcError(String(e));
    } finally {
      setOcLoading(false);
    }
  }, []);

  // 挂载时拉一次；切到 opencode tab 时再刷（用户可能刚在别处改过文件）
  useEffect(() => {
    void refreshOpenCode();
  }, [refreshOpenCode]);

  useEffect(() => {
    if (activeTab === "opencode") void refreshOpenCode();
  }, [activeTab, refreshOpenCode]);

  /** 保存 opencode 厂商（写 opencode.json）。 */
  const handleOpenCodeSave = () => {
    if (!ocEditing) return;
    setOcBusy(true);
    setOcError(null);
    saveOpenCodeProvider({
      ...ocEditing,
      id: ocEditing.id.trim(),
      name: ocEditing.name.trim(),
      baseURL: ocEditing.baseURL.trim(),
      apiKey: ocEditing.apiKey.trim(),
      models: ocEditing.models.filter((m) => m.id.trim()),
    })
      .then((next) => {
        setOcInfo(next);
        setOcEditing(null);
      })
      .catch((e) => setOcError(String(e)))
      .finally(() => setOcBusy(false));
  };

  /** 删除 opencode 厂商（写 opencode.json）。 */
  const handleOpenCodeDelete = (id: string) => {
    setOcBusy(true);
    setOcError(null);
    deleteOpenCodeProvider(id)
      .then(setOcInfo)
      .catch((e) => setOcError(String(e)))
      .finally(() => setOcBusy(false));
  };

  /**
   * 拉取该厂商上游模型清单（OpenAI `/models` 端点）。
   * 复用 provider_catalog 的静态目录：先按 baseURL 匹配已知厂商拿 models_url；
   * 匹配不到（自定义地址）则提示手动填写 —— 不猜端点，不硬拼路径。
   */
  const handleOpenCodeFetchModels = () => {
    if (!ocEditing) return;
    const base = ocEditing.baseURL.trim().replace(/\/+$/, "");
    const entry = catalog.find(
      (c) => c.baseUrl.replace(/\/+$/, "") === base && c.modelsUrl,
    );
    if (!entry) {
      setOcFetchErr(t("oc.fetchUnsupported"));
      return;
    }
    setOcFetching(true);
    setOcFetchErr(null);
    fetchProviderModels(entry.id, ocEditing.apiKey || null)
      .then((list) => {
        // 合并进现有模型清单（保留用户已填的显示名）
        const known = new Map(ocEditing.models.map((m) => [m.id, m]));
        const merged = list.map((id) => known.get(id) ?? { id, name: "" });
        setOcEditing({ ...ocEditing, models: merged });
      })
      .catch((e) => {
        const msg = String(e);
        if (msg.includes("401") || msg.includes("403")) {
          setOcFetchErr(t("mp.invalidKey"));
        } else if (msg.includes("missing api key")) {
          setOcFetchErr(t("mp.fetchNeedKey"));
        } else {
          setOcFetchErr(`${t("mp.fetchFailed")}: ${msg}`);
        }
      })
      .finally(() => setOcFetching(false));
  };

  // ── Claude Code 厂商：读 / 存 / 删（本机 ~/.claude/settings.json）──────────
  const refreshClaude = useCallback(async () => {
    setClLoading(true);
    try {
      setClInfo(await getClaudeProvider());
      setClError(null);
    } catch (e) {
      setClError(String(e));
    } finally {
      setClLoading(false);
    }
  }, []);

  useEffect(() => {
    void refreshClaude();
  }, [refreshClaude]);

  useEffect(() => {
    if (activeTab === "claude-code") void refreshClaude();
  }, [activeTab, refreshClaude]);

  /** 打开编辑：从当前配置复制一份草稿（补齐三档）。 */
  const handleClaudeEdit = () => {
    setClConfirmDelete(false);
    setClError(null);
    setClEditing(normalizeClaudeTiers(clInfo?.provider ?? emptyClaudeProvider()));
  };

  const handleClaudeSave = () => {
    if (!clEditing) return;
    setClBusy(true);
    setClError(null);
    saveClaudeProvider({
      ...clEditing,
      name: clEditing.name.trim(),
      baseURL: clEditing.baseURL.trim(),
      apiKey: clEditing.apiKey.trim(),
      tiers: clEditing.tiers.map((t) => ({
        ...t,
        model: t.model.trim(),
        name: t.name.trim(),
      })),
    })
      .then((next) => {
        setClInfo(next);
        setClEditing(null);
      })
      .catch((e) => setClError(String(e)))
      .finally(() => setClBusy(false));
  };

  const handleClaudeDelete = () => {
    setClBusy(true);
    setClError(null);
    deleteClaudeProvider()
      .then((next) => {
        setClInfo(next);
        setClEditing(null);
        setClConfirmDelete(false);
      })
      .catch((e) => setClError(String(e)))
      .finally(() => setClBusy(false));
  };

  // ── Codex 厂商：读 / 存 / 删 / 切生效（本机 ~/.codex/config.toml）────────
  const refreshCodex = useCallback(async () => {
    setCxLoading(true);
    try {
      setCxInfo(await getCodexProviders());
      setCxError(null);
    } catch (e) {
      setCxError(String(e));
    } finally {
      setCxLoading(false);
    }
  }, []);

  useEffect(() => {
    void refreshCodex();
  }, [refreshCodex]);

  useEffect(() => {
    if (activeTab === "codex") void refreshCodex();
  }, [activeTab, refreshCodex]);

  const handleCodexSave = () => {
    if (!cxEditing) return;
    setCxBusy(true);
    setCxError(null);
    saveCodexProvider({
      ...cxEditing,
      id: cxEditing.id.trim(),
      name: cxEditing.name.trim(),
      baseURL: cxEditing.baseURL.trim(),
      apiKey: cxEditing.apiKey.trim(),
      model: cxEditing.model.trim(),
    })
      .then((next) => {
        setCxInfo(next);
        setCxEditing(null);
      })
      .catch((e) => setCxError(String(e)))
      .finally(() => setCxBusy(false));
  };

  const handleCodexDelete = (id: string) => {
    setCxBusy(true);
    setCxError(null);
    deleteCodexProvider(id)
      .then(setCxInfo)
      .catch((e) => setCxError(String(e)))
      .finally(() => setCxBusy(false));
  };

  const handleCodexActivate = (id: string) => {
    setCxBusyId(id);
    setCxError(null);
    activateCodexProvider(id)
      .then(setCxInfo)
      .catch((e) => setCxError(String(e)))
      .finally(() => setCxBusyId(null));
  };

  /** 复用 provider_catalog 的静态目录按 baseURL 匹配来拉模型（同 opencode）。 */
  const handleCodexFetchModels = () => {
    if (!cxEditing) return;
    const base = cxEditing.baseURL.trim().replace(/\/+$/, "");
    const entry = catalog.find(
      (c) => c.baseUrl.replace(/\/+$/, "") === base && c.modelsUrl,
    );
    if (!entry) {
      setCxFetchErr(t("oc.fetchUnsupported"));
      return;
    }
    setCxFetching(true);
    setCxFetchErr(null);
    fetchProviderModels(entry.id, cxEditing.apiKey || null)
      .then((list) => {
        // Codex 的 config.toml 顶层 model 只存一条 → 取首个候选填进去
        if (list.length > 0 && !cxEditing.model.trim()) {
          setCxEditing({ ...cxEditing, model: list[0] });
        }
      })
      .catch((e) => {
        const msg = String(e);
        if (msg.includes("401") || msg.includes("403")) {
          setCxFetchErr(t("mp.invalidKey"));
        } else if (msg.includes("missing api key")) {
          setCxFetchErr(t("mp.fetchNeedKey"));
        } else {
          setCxFetchErr(`${t("mp.fetchFailed")}: ${msg}`);
        }
      })
      .finally(() => setCxFetching(false));
  };

  // ── pi 厂商：读 / 存 / 删 / 切默认（本机 ~/.pi/agent/models.json）─────────
  const refreshPi = useCallback(async () => {
    setPiLoading(true);
    try {
      setPiInfo(await getPiProviders());
      setPiError(null);
    } catch (e) {
      setPiError(String(e));
    } finally {
      setPiLoading(false);
    }
  }, []);

  useEffect(() => {
    void refreshPi();
  }, [refreshPi]);

  useEffect(() => {
    if (activeTab === "pi") void refreshPi();
  }, [activeTab, refreshPi]);

  const handlePiSave = () => {
    if (!piEditing) return;
    setPiBusy(true);
    setPiError(null);
    savePiProvider({
      ...piEditing,
      id: piEditing.id.trim(),
      name: piEditing.name.trim(),
      baseURL: piEditing.baseURL.trim(),
      apiKey: piEditing.apiKey.trim(),
      models: piEditing.models
        .filter((m) => m.id.trim())
        .map((m) => ({ id: m.id.trim(), name: m.name.trim() })),
    })
      .then((next) => {
        setPiInfo(next);
        setPiEditing(null);
      })
      .catch((e) => setPiError(String(e)))
      .finally(() => setPiBusy(false));
  };

  const handlePiDelete = (id: string) => {
    setPiBusy(true);
    setPiError(null);
    deletePiProvider(id)
      .then(setPiInfo)
      .catch((e) => setPiError(String(e)))
      .finally(() => setPiBusy(false));
  };

  const handlePiActivate = (id: string) => {
    setPiBusyId(id);
    setPiError(null);
    activatePiProvider(id)
      .then(setPiInfo)
      .catch((e) => setPiError(String(e)))
      .finally(() => setPiBusyId(null));
  };

  const copyEndpoint = () => {
    if (!info) return;
    void navigator.clipboard
      .writeText(`http://127.0.0.1:${info.proxyPort}`)
      .catch(() => {});
  };

  const endpoint = info ? `http://127.0.0.1:${info.proxyPort}` : "";

  /** 表单顶部的归属提示文案（新建 = 当前 tab；编辑 = 后端锁定的原归属）。 */
  const editingOwnerName = editing
    ? editing.agentId === ""
      ? t("mp.ownerGeneral")
      : (agents.find((a) => a.id === editing.agentId)?.name ?? editing.agentId)
    : "";

  return (
    <section className="rounded-lg border border-border bg-card p-3">
      {/* 标题行：右侧添加配置（带当前 tab 归属） */}
      <div className="mb-2 flex items-center justify-between">
        <div className="text-[10px] font-semibold uppercase tracking-[0.6px] text-muted-foreground">
          {t("mp.title")}
        </div>
        {editing === null && (
          <Button
            variant="ghost"
            size="sm"
            className="h-6 gap-1 px-2 text-[10px]"
            disabled={busy}
            onClick={() => {
              setConfirmId(null);
              setEditing(emptyDraft(activeTab));
            }}
          >
            <Plus size={11} />
            {t("mp.add")}
          </Button>
        )}
      </div>
      <div className="mb-2 text-[10px] leading-relaxed text-muted-foreground/80">
        {t("mp.hint")}
      </div>

      {/* ── 状态摘要行（转发代理）：常显一行，端口/故障转移收进展开区 ── */}
      <div className="mb-2 rounded-md border border-border/70 bg-background/60 px-2.5 py-1.5">
        <div className="flex items-center gap-1.5">
          <span className="shrink-0 text-xs font-medium text-foreground">
            {t("mp.proxy")}
          </span>
          {info?.proxyRunning ? (
            <Badge variant="success" className="shrink-0 px-1.5 py-0 text-[9px]">
              {t("mp.stateRunning")}
            </Badge>
          ) : info?.proxyError ? (
            <Badge variant="warning" className="shrink-0 px-1.5 py-0 text-[9px]">
              {t("mp.stateError")}
            </Badge>
          ) : (
            <Badge variant="secondary" className="shrink-0 px-1.5 py-0 text-[9px]">
              {t("mp.stateStopped")}
            </Badge>
          )}
          <span className="min-w-0 flex-1 truncate font-mono text-[10px] text-muted-foreground">
            {endpoint || "—"}
          </span>
          {endpoint && (
            <Button
              variant="ghost"
              size="sm"
              className="h-5 w-5 shrink-0 p-0"
              onClick={copyEndpoint}
              title={t("common.copy")}
            >
              <Copy size={11} />
            </Button>
          )}
          <button
            type="button"
            className="flex h-5 w-5 shrink-0 items-center justify-center rounded text-muted-foreground hover:bg-accent hover:text-foreground"
            onClick={() => setProxyOpen((v) => !v)}
            title={t("mp.proxyDetails")}
          >
            {proxyOpen ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
          </button>
        </div>

        {proxyOpen && (
          <>
            <dl className="mt-2 grid grid-cols-[72px_1fr] items-center gap-y-1.5 text-xs">
              <dt className="text-muted-foreground">{t("mp.enable")}</dt>
              <dd>
                <Button
                  variant={info?.proxyEnabled ? "default" : "outline"}
                  size="sm"
                  className="h-6 px-2.5 text-[10px]"
                  disabled={busy || loading || !info}
                  onClick={() => toggleProxy(!info?.proxyEnabled)}
                >
                  {busy && <Loader2 size={10} className="mr-1 animate-spin" />}
                  {info?.proxyEnabled ? t("mp.disable") : t("mp.enable")}
                </Button>
              </dd>
              <dt className="text-muted-foreground">{t("mp.port")}</dt>
              <dd>
                <input
                  className={cn(inputCls, "h-6 w-20 font-mono")}
                  inputMode="numeric"
                  value={portDraft}
                  onChange={(e) => setPortDraft(e.target.value.replace(/[^\d]/g, ""))}
                  onBlur={applyPort}
                  onKeyDown={(e) => {
                    if (e.key === "Enter") applyPort();
                  }}
                />
              </dd>
              <dt className="text-muted-foreground">{t("mp.failover")}</dt>
              <dd className="flex items-center gap-1.5">
                <Button
                  variant={info?.failoverEnabled ? "default" : "outline"}
                  size="sm"
                  className="h-6 px-2.5 text-[10px]"
                  disabled={busy || loading || !info}
                  onClick={() => toggleFailover(!info?.failoverEnabled)}
                >
                  {info?.failoverEnabled ? t("mp.disable") : t("mp.enable")}
                </Button>
                <span className="text-[10px] text-muted-foreground/70">
                  {t("mp.failoverHint")}
                </span>
              </dd>
            </dl>
            <div className="mt-1.5 text-[10px] leading-relaxed text-muted-foreground/70">
              {t("mp.endpointHint", { port: info?.proxyPort ?? 15721 })}
            </div>
            {info?.proxyError && (
              <div className="mt-1 break-all text-[10px] leading-relaxed text-destructive">
                {info.proxyError}
              </div>
            )}
          </>
        )}
      </div>

      {/* ── Agent 归属 Tab 栏（通用 + 各已发现 Agent）── */}
      <AgentModelTabs tabs={tabs} activeId={activeTab} onSelect={selectTab} />

      {/* ── 厂商面板（按 tab 过滤） / 配置表单（编辑时替代面板）── */}
      {editing ? (
        <div className="flex flex-col gap-2.5 rounded-md border border-border p-2.5">          <div className="flex items-center justify-between">
            <span className="text-xs font-medium text-foreground">
              {editing.id ? t("mp.edit") : t("mp.add")}
            </span>
            <button
              type="button"
              className="flex h-6 w-6 items-center justify-center rounded-md text-muted-foreground hover:bg-accent hover:text-foreground"
              onClick={closeForm}
              title={t("mp.cancel")}
            >
              <X size={13} />
            </button>
          </div>

          {/* 归属提示：新建跟随当前 tab；编辑时后端强制保留原归属 */}
          <div className="rounded-md bg-muted/60 px-2 py-1 text-[10px] text-muted-foreground">
            {t("mp.ownerHint", { name: editingOwnerName })}
          </div>

          {/* 厂商选择：预填模板（非校验白名单），custom/手改随意；按分类分组，custom 恒最后 */}
          {catalog.length > 0 && (
            <div>
              <span className={fieldLabelCls}>{t("mp.vendor")}</span>
              <select
                className={inputCls}
                value={selectedVendor}
                onChange={(e) => applyVendor(e.target.value)}
              >
                <option value="">{t("mp.vendorPick")}</option>
                {groupedCatalog.map((g) => (
                  <optgroup
                    key={g.category}
                    label={t(`mp.presetCategory.${g.category}`)}
                  >
                    {g.entries.map((c) => (
                      <option key={c.id} value={c.id}>
                        {c.displayName || c.name}
                      </option>
                    ))}
                  </optgroup>
                ))}
              </select>
              {activeCatalog?.consoleUrl && (
                <a
                  href={activeCatalog.consoleUrl}
                  target="_blank"
                  rel="noreferrer"
                  className="mt-1 inline-flex items-center gap-1 text-[10px] text-primary hover:underline"
                >
                  <ExternalLink size={10} />
                  {t("mp.getKey")}
                </a>
              )}
            </div>
          )}

          <div>
            <span className={fieldLabelCls}>{t("mp.name")}</span>
            <input
              className={inputCls}
              placeholder={t("mp.namePlaceholder")}
              value={editing.name}
              onChange={(e) => setEditing({ ...editing, name: e.target.value })}
            />
          </div>

          <div>
            <span className={fieldLabelCls}>{t("mp.baseUrl")}</span>
            <input
              className={cn(inputCls, "font-mono")}
              placeholder={t("mp.baseUrlPlaceholder")}
              value={editing.baseUrl}
              onChange={(e) =>
                setEditing({ ...editing, baseUrl: e.target.value })
              }
            />
            <label className="mt-1 flex items-center gap-1.5 text-[10px] text-muted-foreground">
              <input
                type="checkbox"
                className="h-3 w-3 accent-[var(--primary)]"
                checked={editing.isFullUrl}
                onChange={(e) =>
                  setEditing({ ...editing, isFullUrl: e.target.checked })
                }
              />
              {t("mp.isFullUrl")}
            </label>
          </div>

          <div>
            <span className={fieldLabelCls}>{t("mp.apiKey")}</span>
            <input
              className={cn(inputCls, "font-mono")}
              type="password"
              autoComplete="off"
              /* 出参是掩码：回填后不动它 = 后端保留旧 Key（E2E-05） */
              placeholder={
                editing.hasKey ? t("mp.apiKeyKeepHint") : t("mp.apiKeyPlaceholder")
              }
              value={editing.apiKey}
              onChange={(e) =>
                setEditing({ ...editing, apiKey: e.target.value })
              }
            />
          </div>

          <div className="grid grid-cols-2 gap-2">
            <div>
              <span className={fieldLabelCls}>{t("mp.apiFormat")}</span>
              <select
                className={inputCls}
                value={editing.apiFormat}
                onChange={(e) =>
                  setEditing({
                    ...editing,
                    apiFormat: e.target.value as ApiFormat,
                  })
                }
              >
                {FORMAT_OPTIONS.map((f) => (
                  <option key={f} value={f}>
                    {t(`mp.format.${f}`)}
                  </option>
                ))}
              </select>
            </div>
            <div>
              <span className={fieldLabelCls}>{t("mp.authStyle")}</span>
              <select
                className={inputCls}
                value={editing.authStyle}
                onChange={(e) =>
                  setEditing({
                    ...editing,
                    authStyle: e.target.value as AuthStyle,
                  })
                }
              >
                {AUTH_OPTIONS.map((a) => (
                  <option key={a} value={a}>
                    {t(`mp.auth.${a}`)}
                  </option>
                ))}
              </select>
            </div>
          </div>

          <div className="grid grid-cols-2 gap-2">
            <div>
              <span className={fieldLabelCls}>{t("mp.model")}</span>
              <input
                className={inputCls}
                placeholder={t("mp.modelPlaceholder")}
                list="catalog-models"
                value={editing.model ?? ""}
                onChange={(e) =>
                  setEditing({
                    ...editing,
                    model: e.target.value.trim() || null,
                  })
                }
              />
              {activeCatalog && activeCatalog.models.length > 0 && (
                <datalist id="catalog-models">
                  {activeCatalog.models.map((m) => (
                    <option key={m} value={m} />
                  ))}
                </datalist>
              )}
            </div>
            <div>
              <span className={fieldLabelCls}>{t("mp.notes")}</span>
              <input
                className={inputCls}
                value={editing.notes ?? ""}
                onChange={(e) =>
                  setEditing({
                    ...editing,
                    notes: e.target.value.trim() || null,
                  })
                }
              />
            </div>
          </div>

          {/* 高级选项（默认折叠，低频功能不干扰主流程）：
              ① 获取上游真实模型列表（失败回落目录静态候选）
              ② 模型映射说明（把代理层「cfg.model 覆盖请求体 model」的隐式行为显式化）
              ③ 生效端点预览（实时镜像后端拼接逻辑，可核对最终请求地址） */}
          <div className="border-t border-border/70 pt-2">
            <button
              type="button"
              className="flex items-center gap-1 text-[10px] text-muted-foreground hover:text-foreground"
              onClick={() => setAdvancedOpen((v) => !v)}
            >
              {advancedOpen ? (
                <ChevronDown size={11} />
              ) : (
                <ChevronRight size={11} />
              )}
              {t("mp.advanced")}
            </button>

            {advancedOpen && (
              <div className="mt-2 flex flex-col gap-2">
                <div className="flex items-center gap-2">
                  <span className={fieldLabelCls}>
                    {t("mp.availableModels")}
                  </span>
                  <Button
                    variant="outline"
                    size="sm"
                    className="h-6 px-2 text-[10px]"
                    disabled={fetchingModels || !activeCatalog?.modelsUrl}
                    title={
                      !activeCatalog?.modelsUrl
                        ? t("mp.fetchUnsupported")
                        : undefined
                    }
                    onClick={handleFetchModels}
                  >
                    {fetchingModels ? (
                      <Loader2 size={10} className="mr-1 animate-spin" />
                    ) : (
                      <RefreshCw size={10} />
                    )}
                    {fetchingModels ? t("mp.fetching") : t("mp.fetchModels")}
                  </Button>
                  {activeCatalog && !activeCatalog.modelsUrl && (
                    <span className="text-[10px] text-muted-foreground/70">
                      {t("mp.fetchUnsupported")}
                    </span>
                  )}
                </div>
                {fetchErr && (
                  <p className="text-[10px] leading-relaxed text-warning">
                    {fetchErr}
                  </p>
                )}
                {candidateModels.length > 0 && (
                  <div className="flex flex-wrap gap-1">
                    {candidateModels.map((m) => (
                      <button
                        key={m}
                        type="button"
                        className={cn(
                          "h-6 max-w-full truncate rounded-md border px-2 text-[10px] transition-colors",
                          editing.model === m
                            ? "border-primary bg-primary text-primary-foreground"
                            : "border-border bg-background text-foreground hover:bg-accent/60",
                        )}
                        onClick={() => setEditing({ ...editing, model: m })}
                      >
                        {m}
                      </button>
                    ))}
                  </div>
                )}
                <p className="text-[10px] leading-relaxed text-muted-foreground/70">
                  {t("mp.modelMappingHint")}
                </p>
                <div>
                  <span className={fieldLabelCls}>
                    {t("mp.effectiveEndpoint")}
                  </span>
                  <code className="block break-all rounded bg-muted/60 px-1.5 py-1 font-mono text-[10px] text-foreground">
                    {previewEndpoint(
                      editing.baseUrl,
                      editing.apiFormat,
                      editing.isFullUrl,
                    )}
                  </code>
                </div>
              </div>
            )}
          </div>

          <div className="flex justify-end gap-2">
            <Button
              variant="outline"
              size="sm"
              className="h-7 px-3 text-[11px]"
              disabled={busy}
              onClick={closeForm}
            >
              {t("mp.cancel")}
            </Button>
            <Button
              size="sm"
              className="h-7 px-3 text-[11px]"
              disabled={
                busy || !editing.name.trim() || !editing.baseUrl.trim()
              }
              onClick={handleSave}
            >
              {busy && <Loader2 size={11} className="mr-1 animate-spin" />}
              {t("mp.save")}
            </Button>
          </div>
        </div>
      ) : loading ? (
        <div className="flex items-center justify-center py-4 text-muted-foreground">
          <Loader2 size={14} className="animate-spin" />
        </div>
      ) : (
        <AgentProviderPanel
          agentId={activeTab}
          providers={tabProviders}
          currentId={tabCurrentId}
          busy={busy}
          confirmId={confirmId}
          takeoverItem={cliForTab}
          onSetCurrent={(id) =>
            void run(() => switchModelProvider(id, activeTab))
          }
          onEdit={(p) => {
            setConfirmId(null);
            setEditing({ ...p });
          }}
          onDelete={handleDelete}
          onConnectCli={() => {
            if (cliForTab) toggleTakeover(cliForTab.id, true);
          }}
          onAdd={() => {
            setConfirmId(null);
            setEditing(emptyDraft(activeTab));
          }}
        />
      )}

      {/* ── OpenCode 专属：厂商写入本机 opencode.json（对标 cc-switch）──
          仅在 opencode tab 下出现 —— 这是「给 opencode CLI 加厂商」的入口，
          与上面的转发链路配置是两套东西，刻意分开放避免混淆。 */}
      {activeTab === "opencode" && (
        <div className="mt-2 rounded-md border border-primary/25 bg-primary/[0.03] p-2.5">
          <div className="mb-1 flex items-center gap-1.5">
            <span className="text-xs font-medium text-foreground">
              {t("oc.title")}
            </span>
            <Badge variant="secondary" className="px-1.5 py-0 text-[9px]">
              opencode.json
            </Badge>
          </div>
          {ocEditing ? (
            <OpenCodeProviderForm
              value={ocEditing}
              npmPackages={ocInfo?.npmPackages ?? []}
              existingIds={(ocInfo?.providers ?? []).map((p) => p.id)}
              busy={ocBusy}
              isEdit={ocIsEdit}
              onChange={setOcEditing}
              onCancel={() => {
                setOcEditing(null);
                setOcFetchErr(null);
              }}
              onSave={handleOpenCodeSave}
              onFetchModels={handleOpenCodeFetchModels}
              fetchingModels={ocFetching}
              fetchErr={ocFetchErr}
            />
          ) : (
            <OpenCodeProviderPanel
              info={ocInfo}
              loading={ocLoading}
              confirmId={ocConfirmId}
              onAdd={() => {
                setOcConfirmId(null);
                setOcIsEdit(false);
                setOcFetchErr(null);
                setOcEditing(emptyOpenCodeProvider(defaultOpenCodeNpm));
              }}
              onEdit={(p) => {
                setOcConfirmId(null);
                setOcIsEdit(true);
                setOcFetchErr(null);
                setOcEditing({
                  ...p,
                  models: p.models.length
                    ? p.models.map((m) => ({ ...m }))
                    : [{ id: "", name: "" }],
                });
              }}
              onDelete={(id) => {
                if (ocConfirmId !== id) {
                  setOcConfirmId(id);
                  return;
                }
                setOcConfirmId(null);
                handleOpenCodeDelete(id);
              }}
            />
          )}
          {ocError && (
            <div className="mt-1.5 break-all text-[10px] leading-relaxed text-destructive">
              {ocError}
            </div>
          )}
        </div>
      )}

      {/* ── Claude Code 专属：整体覆盖写入本机 ~/.claude/settings.json ──
          与 opencode 的多厂商列表不同：Claude Code 只有一份配置，故为「单例编辑」。 */}
      {activeTab === "claude-code" && (
        <div className="mt-2 rounded-md border border-primary/25 bg-primary/[0.03] p-2.5">
          <div className="mb-1 flex items-center gap-1.5">
            <span className="text-xs font-medium text-foreground">
              {t("cl.title")}
            </span>
            <Badge variant="secondary" className="px-1.5 py-0 text-[9px]">
              settings.json
            </Badge>
          </div>

          {clInfo?.configFile && (
            <div
              className="mb-1.5 flex items-center gap-1 truncate font-mono text-[10px] text-muted-foreground/70"
              title={clInfo.configFile}
            >
              <FileCode2 size={10} className="shrink-0" />
              <span className="truncate">{clInfo.configFile}</span>
              {!clInfo.exists && (
                <Badge
                  variant="secondary"
                  className="shrink-0 px-1.5 py-0 text-[9px]"
                >
                  {t("oc.notCreated")}
                </Badge>
              )}
            </div>
          )}

          {clEditing ? (
            <ClaudeProviderForm
              value={clEditing}
              busy={clBusy}
              error={clError}
              onChange={setClEditing}
              onCancel={() => {
                setClEditing(null);
                setClError(null);
              }}
              onSave={handleClaudeSave}
            />
          ) : clLoading ? (
            <div className="flex items-center justify-center py-4 text-muted-foreground">
              <Loader2 size={14} className="animate-spin" />
            </div>
          ) : clInfo?.configured ? (
            <div className="flex flex-col gap-1.5">
              <div className="flex items-center gap-1.5 rounded-md border border-border px-2.5 py-1.5">
                <Check size={13} className="shrink-0 text-primary" />
                <span className="min-w-0 flex-1 truncate text-xs font-medium text-foreground">
                  {clInfo.provider.name || t("cl.title")}
                </span>
                <Badge
                  variant={clInfo.provider.apiKey ? "success" : "secondary"}
                  className={cn(
                    "shrink-0 px-1.5 py-0 text-[9px]",
                    !clInfo.provider.apiKey && "opacity-70",
                  )}
                >
                  {clInfo.provider.apiKey ? t("mp.keySet") : t("mp.keyMissing")}
                </Badge>
                <div className="flex shrink-0 items-center gap-0.5">
                  <Button
                    variant="ghost"
                    size="sm"
                    className="h-6 w-6 p-0"
                    title={t("mp.edit")}
                    onClick={handleClaudeEdit}
                  >
                    <Pencil size={11} />
                  </Button>
                  <Button
                    variant={clConfirmDelete ? "destructive" : "ghost"}
                    size="sm"
                    className={cn(
                      "h-6 p-0",
                      clConfirmDelete ? "w-auto px-2 text-[10px]" : "w-6",
                    )}
                    title={t("mp.delete")}
                    disabled={clBusy}
                    onClick={() => {
                      if (!clConfirmDelete) {
                        setClConfirmDelete(true);
                        return;
                      }
                      handleClaudeDelete();
                    }}
                  >
                    <Trash2 size={11} />
                    {clConfirmDelete && t("mp.confirmDelete")}
                  </Button>
                </div>
              </div>
              <div
                className="truncate font-mono text-[10px] text-muted-foreground"
                title={clInfo.provider.baseURL}
              >
                {clInfo.provider.baseURL || "—"}
              </div>
              {clInfo.provider.tiers.some((x) => x.model) && (
                <div className="flex flex-wrap gap-1">
                  {clInfo.provider.tiers
                    .filter((x) => x.model)
                    .map((x) => (
                      <Badge
                        key={x.tier}
                        variant="secondary"
                        className="px-1.5 py-0 font-mono text-[9px]"
                      >
                        {x.tier}: {x.model}
                      </Badge>
                    ))}
                </div>
              )}
            </div>
          ) : (
            <ClaudeProviderEmpty onAdd={handleClaudeEdit} loading={clLoading} />
          )}

          {clError && !clEditing && (
            <div className="mt-1.5 break-all text-[10px] leading-relaxed text-destructive">
              {clError}
            </div>
          )}
        </div>
      )}

      {/* ── Codex 专属：厂商写入本机 ~/.codex/config.toml ── */}
      {activeTab === "codex" && (
        <div className="mt-2 rounded-md border border-primary/25 bg-primary/[0.03] p-2.5">
          <div className="mb-1 flex items-center gap-1.5">
            <span className="text-xs font-medium text-foreground">
              {t("cx.title")}
            </span>
            <Badge variant="secondary" className="px-1.5 py-0 text-[9px]">
              config.toml
            </Badge>
          </div>
          {cxEditing ? (
            <CodexProviderForm
              value={cxEditing}
              wireApis={cxInfo?.wireApis ?? []}
              existingIds={(cxInfo?.providers ?? []).map((p) => p.id)}
              busy={cxBusy}
              isEdit={cxIsEdit}
              onChange={setCxEditing}
              onCancel={() => {
                setCxEditing(null);
                setCxFetchErr(null);
              }}
              onSave={handleCodexSave}
              onFetchModels={handleCodexFetchModels}
              fetchingModels={cxFetching}
              fetchErr={cxFetchErr}
            />
          ) : (
            <CodexProviderPanel
              info={cxInfo}
              loading={cxLoading}
              confirmId={cxConfirmId}
              busyId={cxBusyId}
              onAdd={() => {
                setCxConfirmId(null);
                setCxIsEdit(false);
                setCxFetchErr(null);
                setCxEditing(
                  emptyCodexProvider(
                    cxInfo?.wireApis[0]?.value ?? "chat",
                  ),
                );
              }}
              onEdit={(p) => {
                setCxConfirmId(null);
                setCxIsEdit(true);
                setCxFetchErr(null);
                setCxEditing({ ...p });
              }}
              onDelete={(id) => {
                if (cxConfirmId !== id) {
                  setCxConfirmId(id);
                  return;
                }
                setCxConfirmId(null);
                handleCodexDelete(id);
              }}
              onActivate={handleCodexActivate}
            />
          )}
          {cxError && (
            <div className="mt-1.5 break-all text-[10px] leading-relaxed text-destructive">
              {cxError}
            </div>
          )}
        </div>
      )}

      {/* ── pi 专属：厂商写入本机 ~/.pi/agent/models.json ── */}
      {activeTab === "pi" && (
        <div className="mt-2 rounded-md border border-primary/25 bg-primary/[0.03] p-2.5">
          <div className="mb-1 flex items-center gap-1.5">
            <span className="text-xs font-medium text-foreground">
              {t("pi.title")}
            </span>
            <Badge variant="secondary" className="px-1.5 py-0 text-[9px]">
              models.json
            </Badge>
          </div>
          {piEditing ? (
            <PiProviderForm
              value={piEditing}
              apis={piInfo?.apis ?? []}
              existingIds={(piInfo?.providers ?? []).map((p) => p.id)}
              busy={piBusy}
              isEdit={piIsEdit}
              error={piError}
              onChange={setPiEditing}
              onCancel={() => {
                setPiEditing(null);
                setPiError(null);
              }}
              onSave={handlePiSave}
            />
          ) : (
            <PiProviderPanel
              info={piInfo}
              loading={piLoading}
              confirmId={piConfirmId}
              busyId={piBusyId}
              onAdd={() => {
                setPiConfirmId(null);
                setPiIsEdit(false);
                setPiError(null);
                setPiEditing(
                  emptyPiProvider(piInfo?.apis[0]?.value ?? "anthropic-messages"),
                );
              }}
              onEdit={(p) => {
                setPiConfirmId(null);
                setPiIsEdit(true);
                setPiError(null);
                setPiEditing({
                  ...p,
                  models: p.models.length
                    ? p.models.map((m) => ({ ...m }))
                    : [{ id: "", name: "" }],
                });
              }}
              onDelete={(id) => {
                if (piConfirmId !== id) {
                  setPiConfirmId(id);
                  return;
                }
                setPiConfirmId(null);
                handlePiDelete(id);
              }}
              onActivate={handlePiActivate}
            />
          )}
          {piError && !piEditing && (
            <div className="mt-1.5 break-all text-[10px] leading-relaxed text-destructive">
              {piError}
            </div>
          )}
        </div>
      )}

      {/* ── 折叠收纳：CLI 接入（完整列表；单个 Agent 的快捷接入在面板黄条里）── */}
      <div className="mt-3 rounded-md border border-border/70 bg-background/60 p-2.5">
        <button
          type="button"
          className="flex w-full items-center gap-1 text-xs font-medium text-foreground"
          onClick={() => setCliOpen((v) => !v)}
        >
          {cliOpen ? (
            <ChevronDown size={12} className="shrink-0 text-muted-foreground" />
          ) : (
            <ChevronRight size={12} className="shrink-0 text-muted-foreground" />
          )}
          {t("mp.takeover")}
        </button>

        {cliOpen && (
          <>
            <div className="mt-1 text-[10px] leading-relaxed text-muted-foreground/70">
              {t("mp.takeoverHint", { port: info?.proxyPort ?? 15721 })}
            </div>

            <div className="mt-2 flex flex-col gap-1.5">
              {(cliInfo?.items ?? []).map((item) => (
                <div
                  key={item.id}
                  className="flex items-center gap-2 rounded-md border border-border px-2.5 py-1.5"
                >
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-1.5">
                      <span className="text-xs font-medium text-foreground">
                        {item.name}
                      </span>
                      {item.active && (
                        <Badge
                          variant="success"
                          className="px-1.5 py-0 text-[9px]"
                        >
                          {t("mp.takeoverActive")}
                        </Badge>
                      )}
                      {!item.installed && (
                        <Badge variant="secondary" className="px-1.5 py-0 text-[9px]">
                          {t("mp.cliNotInstalled")}
                        </Badge>
                      )}
                    </div>
                    <div
                      className="truncate font-mono text-[10px] text-muted-foreground"
                      title={item.configFile}
                    >
                      {item.configFile || "—"}
                    </div>
                  </div>
                  <Button
                    variant={item.active ? "outline" : "default"}
                    size="sm"
                    className="h-6 shrink-0 px-2.5 text-[10px]"
                    /* 未安装 / 不支持置灰；代理未运行不拦——首次接入会自动拉起 */
                    disabled={busy || !item.installed || !item.supported}
                    title={
                      !item.installed
                        ? t("mp.cliNotInstalled")
                        : !item.supported
                          ? t("mp.takeoverUnsupported")
                          : undefined
                    }
                    onClick={() => toggleTakeover(item.id, !item.active)}
                  >
                    {busy && <Loader2 size={10} className="mr-1 animate-spin" />}
                    {item.active ? t("mp.takeoverOff") : t("mp.takeoverOn")}
                  </Button>
                </div>
              ))}
              {cliInfo !== null && (cliInfo.items?.length ?? 0) === 0 && (
                <div className="py-2 text-center text-[10px] text-muted-foreground">
                  {t("mp.takeoverEmpty")}
                </div>
              )}
            </div>
            {!info?.proxyRunning && (
              <div className="mt-1.5 text-[10px] leading-relaxed text-warning">
                {t("mp.takeoverNeedsProxy")}
              </div>
            )}
          </>
        )}
      </div>

      {/* ── 折叠收纳：Agent 模型偏好（各 Agent 当前生效模型 + 完整可选列表）── */}
      <div className="mt-2 rounded-md border border-border/70 bg-background/60 p-2.5">
        <button
          type="button"
          className="flex w-full items-center gap-1 text-xs font-medium text-foreground"
          onClick={() => setPrefsOpen((v) => !v)}
        >
          {prefsOpen ? (
            <ChevronDown size={12} className="shrink-0 text-muted-foreground" />
          ) : (
            <ChevronRight size={12} className="shrink-0 text-muted-foreground" />
          )}
          {t("mp.agentModels")}
        </button>

        {prefsOpen && (
          <>
            <div className="mt-1 text-[10px] leading-relaxed text-muted-foreground/70">
              {t("mp.agentModelsHint")}
            </div>

            <div className="mt-2 flex flex-col gap-1.5">
              {agents.map((a) => {
                const info = agentModels[a.id] ?? null;
                const expanded = expandedAgent === a.id;
                const preferred = info?.preferredModelId ?? null;
                const effective = preferred ?? info?.activeModelId ?? null;
                const modelCount =
                  info?.providers.reduce((n, p) => n + p.models.length, 0) ?? 0;
                return (
                  <div key={a.id} className="rounded-md border border-border">
                    {/* 摘要行：Agent 名 + 当前生效模型（点击展开完整列表） */}
                    <button
                      type="button"
                      className="flex w-full items-center gap-1.5 rounded-md px-2.5 py-1.5 text-left hover:bg-accent/50"
                      onClick={() => setExpandedAgent(expanded ? null : a.id)}
                    >
                      {expanded ? (
                        <ChevronDown size={12} className="shrink-0 text-muted-foreground" />
                      ) : (
                        <ChevronRight size={12} className="shrink-0 text-muted-foreground" />
                      )}
                      <span className="shrink-0 text-xs font-medium text-foreground">
                        {a.name}
                      </span>
                      {agentBusy === a.id && (
                        <Loader2 size={10} className="shrink-0 animate-spin text-muted-foreground" />
                      )}
                      {info?.preferredStillValid === false && (
                        <Badge variant="warning" className="shrink-0 px-1.5 py-0 text-[9px]">
                          {t("mp.agentModelInvalid")}
                        </Badge>
                      )}
                      <span className="ml-auto min-w-0 truncate font-mono text-[10px] text-muted-foreground">
                        {effective ?? "—"}
                      </span>
                      {effective && (
                        <Badge
                          variant={preferred ? "success" : "secondary"}
                          className="shrink-0 px-1.5 py-0 text-[9px]"
                        >
                          {preferred ? t("mp.agentPrefBadge") : t("mp.agentFollowBadge")}
                        </Badge>
                      )}
                    </button>

                    {/* 展开区：按 provider 分组的完整模型列表 */}
                    {expanded && (
                      <div className="border-t border-border/70 px-2.5 py-2">
                        {!info || modelCount === 0 ? (
                          <div className="py-1 text-[10px] text-muted-foreground">
                            {t("mp.agentModelsEmpty")}
                          </div>
                        ) : (
                          <>
                            {info.providers.map((p) => (
                              <div key={p.id} className="mb-2 last:mb-0">
                                <div className="mb-1 text-[10px] text-muted-foreground">
                                  {p.name}
                                </div>
                                <div className="flex flex-wrap gap-1">
                                  {p.models.map((m) => {
                                    const selected = m.isDefault;
                                    return (
                                      <button
                                        key={m.id}
                                        type="button"
                                        title={m.id}
                                        className={cn(
                                          "h-6 max-w-full truncate rounded-md border px-2 text-[10px] transition-colors",
                                          selected
                                            ? "border-primary bg-primary text-primary-foreground"
                                            : "border-border bg-background text-foreground hover:bg-accent/60",
                                          !m.available && !selected && "opacity-50",
                                        )}
                                        onClick={() => pickAgentModel(a.id, m.id, p.id)}
                                      >
                                        {m.name}
                                      </button>
                                    );
                                  })}
                                </div>
                              </div>
                            ))}
                            {preferred && (
                              <div className="mt-2 flex justify-end">
                                <Button
                                  variant="ghost"
                                  size="sm"
                                  className="h-6 px-2 text-[10px]"
                                  disabled={agentBusy === a.id}
                                  onClick={() => clearAgentModel(a.id)}
                                >
                                  {t("mp.agentModelClear")}
                                </Button>
                              </div>
                            )}
                          </>
                        )}
                      </div>
                    )}
                  </div>
                );
              })}
              {agents.length === 0 && (
                <div className="py-2 text-center text-[10px] text-muted-foreground">
                  {t("mp.agentModelsEmpty")}
                </div>
              )}
            </div>
          </>
        )}
      </div>

      {error && (
        <div className="mt-2 break-all text-[10px] leading-relaxed text-destructive">
          {error}
        </div>
      )}
    </section>
  );
}
