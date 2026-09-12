import { useEffect, useState, useCallback, useRef } from "react";
import { createPortal } from "react-dom";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import QRCode from "react-qr-code";
import {
  Archive,
  ArchiveRestore,
  Bot,
  ChevronDown,
  Cpu,
  Folder,
  FolderOpen,
  Globe,
  Info,
  Layers,
  Minus,
  Pin,
  PinOff,
  QrCode,
  ShieldCheck,
  Square,
  SquarePen,
  SquareTerminal,
  Trash2,
  X,
} from "lucide-react";
import {
  getStatus,
  getTerminalState,
  switchActiveAgent,
  getPairingInfo,
  revealPairingCode,
  regeneratePairingCode,
  getApprovalMode,
  sendCommand,
  clearTerminal,
  getAgentModels,
  getAgentWorkdir,
  setDefaultModel,
  listConversations,
  getConversation,
  activateConversation,
  setConversationArchived,
  deleteConversation,
  togglePinConversation,
  setConversationWorkdir,
  setConversationApprovalMode,
  setConversationModel,
} from "./api/tauri";
import type {
  DesktopStatus,
  AgentTerminalState,
  PairingInfo,
  ApprovalMode,
  RuntimeState,
  AgentModelsInfo,
  Conversation,
  ConversationSummary,
  ConversationDelta,
} from "./api/types";
import { Button } from "./components/ui/button";
import { ChatView, fromTranscript } from "./components/chat/chat-view";
import { ComposerDropdown } from "./components/chat/composer-dropdown";
import { WorkdirPicker } from "./components/chat/workdir-picker";
import { EnvironmentCard } from "./components/settings/environment-card";
import { cn } from "./lib/utils";
import { useI18n, intlLocale, type LangMode } from "./i18n";
import "./styles/app.css";

const APPROVAL_MODES: Array<{ id: ApprovalMode; label: string; descKey: "approval.safe" | "approval.askAll" | "approval.auto" }> = [
  { id: "safe", label: "safe", descKey: "approval.safe" },
  { id: "askAll", label: "askAll", descKey: "approval.askAll" },
  { id: "auto", label: "auto", descKey: "approval.auto" },
];

/// 设置页左侧导航的分类（弹窗双栏布局，参考 WorkBuddy 设置弹窗）。
type SettingsSectionId = "general" | "machine" | "environment" | "pairing";

/// 草稿输入的存储键（尚无对话 ID 时）。
const DRAFT_KEY = "__draft__";
/// 目录过滤哨兵：未绑定目录的对话组（conv.workdirOverride == null）。
const UNBOUND = "__unbound__";
/// 目录过滤哨兵：显示全部目录组。
const ALL_DIRS = "__all__";

/** 路径末段（`D:\study\workFlow` → `workFlow`），目录分组标题用。 */
function pathLabel(path: string): string {
  const trimmed = path.replace(/[\\/]+$/, "");
  const idx = Math.max(trimmed.lastIndexOf("\\"), trimmed.lastIndexOf("/"));
  return idx >= 0 ? trimmed.slice(idx + 1) : trimmed;
}

/// 侧栏目录过滤下拉：全部对话 / 未绑定目录 / 各绑定目录（按最近活动序）。
function DirFilterMenu({
  current,
  dirs,
  onSelect,
}: {
  current: string;
  dirs: string[];
  onSelect: (filter: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const [pos, setPos] = useState<{ left: number; top: number } | null>(null);
  const rootRef = useRef<HTMLDivElement>(null);
  const popRef = useRef<HTMLDivElement>(null);
  const { t } = useI18n();

  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      const t = e.target as Node;
      // portal 后弹层在 rootRef 之外，须一并排除，否则点弹层条目会先关菜单
      if (
        rootRef.current &&
        !rootRef.current.contains(t) &&
        popRef.current &&
        !popRef.current.contains(t)
      ) {
        setOpen(false);
      }
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    window.addEventListener("mousedown", onDown);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("mousedown", onDown);
      window.removeEventListener("keydown", onKey);
    };
  }, [open]);

  const MENU_WIDTH = 224; // 与弹层 w-56 一致
  const toggle = () => {
    if (!open && rootRef.current) {
      // fixed 定位跟随触发按钮：左对齐按钮；靠窗口右缘时右移防溢出
      const r = rootRef.current.getBoundingClientRect();
      const left = Math.min(
        r.left,
        window.innerWidth - MENU_WIDTH - 8,
      );
      setPos({ left: Math.max(8, left), top: r.bottom + 4 });
    }
    setOpen((v) => !v);
  };

  const Row = ({
    value,
    label,
    desc,
    icon,
  }: {
    value: string;
    label: string;
    desc?: string;
    icon: React.ReactNode;
  }) => (
    <button
      type="button"
      className={cn(
        "flex w-full items-center gap-2 rounded-lg px-2.5 py-1.5 text-left text-xs transition-colors hover:bg-accent",
        current === value && "bg-accent font-medium text-foreground",
      )}
      onClick={() => {
        onSelect(value);
        setOpen(false);
      }}
      title={desc ?? label}
    >
      <span className="shrink-0 text-primary/70">{icon}</span>
      <span className="min-w-0 flex-1 truncate">{label}</span>
      {current === value && (
        <span className="shrink-0 text-[10px] text-primary">✓</span>
      )}
    </button>
  );

  return (
    <div ref={rootRef} className="relative">
      <button
        type="button"
        className={cn(
          "flex h-6 w-6 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-accent hover:text-foreground",
          current !== ALL_DIRS && "bg-accent text-primary",
        )}
        onClick={toggle}
        title={t("side.filterTooltip")}
      >
        <FolderOpen size={13} />
      </button>
      {open &&
        pos &&
        createPortal(
          <div
            ref={popRef}
            style={{ position: "fixed", left: pos.left, top: pos.top, width: MENU_WIDTH }}
            className="z-[var(--z-popover)] max-h-[60vh] overflow-y-auto rounded-xl border border-border bg-popover p-1.5 text-popover-foreground shadow-[0_8px_28px_rgba(63,46,30,0.14),0_2px_8px_rgba(63,46,30,0.08)] composer-popup-in"
          >
          <Row value={ALL_DIRS} label={t("side.filterAll")} icon={<Layers size={13} />} />
          <Row value={UNBOUND} label={t("side.unbound")} icon={<Folder size={13} />} />
          {dirs.length > 0 && (
            <>
              <div className="my-1 border-t border-border" />
              <div className="px-2.5 pb-0.5 pt-0.5 text-[10px] text-muted-foreground/70">
                {t("side.byDir")}
              </div>
              {dirs.map((d) => (
                <Row
                  key={d}
                  value={d}
                  label={pathLabel(d)}
                  desc={d}
                  icon={<FolderOpen size={13} />}
                />
              ))}
            </>
          )}
          </div>,
          document.body,
        )}
    </div>
  );
}

export default function App() {
  const { t, locale } = useI18n();
  const [status, setStatus] = useState<DesktopStatus | null>(null);
  /// 设置弹窗开关 + 当前分类（托盘「显示配对码」要能直接跳到配对分类）。
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [settingsSection, setSettingsSection] = useState<SettingsSectionId>("general");
  const [terminals, setTerminals] = useState<AgentTerminalState[]>([]);
  /// 草稿态（新对话）选定的 Agent —— 已有对话一律以 `conv.agentId` 为准
  /// （对话级，创建时绑定）；这里只是「下一条新对话用哪个 Agent」。
  const [draftAgentId, setDraftAgentId] = useState<string>("opencode");
  const [loading, setLoading] = useState(true);
  const [pairing, setPairing] = useState<PairingInfo | null>(null);
  /// 全局默认授权档位（`~/.brewping/approval.json`，轮询只更新它）。
  const [globalApprovalMode, setGlobalApprovalModeState] = useState<ApprovalMode>("safe");
  /// 草稿里手动选过的档位（null = 未选过，跟随全局默认）。仅草稿态使用；
  /// 新对话创建 / 回到草稿时清空，避免上一次的选择悄悄带进下一个草稿。
  const [draftApprovalMode, setDraftApprovalMode] = useState<ApprovalMode | null>(null);
  const [models, setModels] = useState<AgentModelsInfo | null>(null);
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState<string | null>(null);

  /// 窗口控制（无边框自绘标题栏）。
  /// 失败绝不能静默：窗口命令走 Tauri IPC，若 capabilities 未授予权限会 reject，
  /// 而 `void p` 会把错误吞掉，表现为「点了没反应」——这里统一记录。
  const winAction = useCallback((run: () => Promise<void>) => {
    run().catch((e) => {
      console.error("[window-control]", String(e));
    });
  }, []);
  const [dockOpen, setDockOpen] = useState(false);
  // ─── 多对话状态（后端 conversation store 为权威，方案 P4） ─────────────────
  const [conversations, setConversations] = useState<ConversationSummary[]>([]);
  /// 侧栏目录过滤：ALL_DIRS（全部）/ UNBOUND（未绑定）/ 具体目录路径。
  const [dirFilter, setDirFilter] = useState<string>(ALL_DIRS);
  /// 折叠的目录组（仅视觉折叠，不改过滤）。组头点击 = 折叠/展开，
  /// 保证所有目录组始终可见——只"切换"不"下钻"。
  const [collapsedGroups, setCollapsedGroups] = useState<Record<string, boolean>>({});
  const [activeConvId, setActiveConvId] = useState<string | null>(null);
  const [activeConv, setActiveConv] = useState<Conversation | null>(null);
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const outputRef = useRef<HTMLDivElement>(null);

  /// 当前会话 ID 的镜像 ref。
  ///
  /// 事件回调（Tauri 推送）里必须知道"现在看的是哪个会话"，但不能把读状态的
  /// 副作用塞进 `setState` 的 updater —— updater 必须是纯函数：React 可能延迟
  /// 到渲染阶段才调用它，StrictMode 下还会双调用，返回值相同又会被 eager
  /// bail-out 提前 return。之前正是这么写的，导致"消息追加了但界面不刷"。
  const activeConvIdRef = useRef<string | null>(null);
  const updateActiveConvId = useCallback((id: string | null) => {
    activeConvIdRef.current = id;
    setActiveConvId(id);
  }, []);

  /// 流式增量：后端逐块推送时先把累积文本放在这里，渲染成一条"正在生成"的
  /// 助手气泡；等真实条目落库（重取到同 commandId 的 assistant/error 条目）
  /// 立即丢弃，避免与转录重复。
  const [streaming, setStreaming] = useState<{
    convId: string;
    commandId: string;
    text: string;
  } | null>(null);

  // ─── Data Fetching ──────────────────────────────────────────────────────

  const refreshStatus = useCallback(async () => {
    try {
      const s = await getStatus();
      setStatus(s);
      setDraftAgentId(s.activeAgentId || "opencode");
    } catch {
      // ignore — will retry on next poll
    }
  }, []);

  const refreshTerminal = useCallback(async () => {
    try {
      const states = await getTerminalState();
      setTerminals(states);
    } catch {
      // ignore
    }
  }, []);

  /// 配对信息 + 授权模式（composer 里的授权下拉用）：与后端同一个进程内状态。
  const refreshSecurity = useCallback(async () => {
    try {
      const [info, mode] = await Promise.all([
        getPairingInfo(),
        getApprovalMode(),
      ]);
      setPairing(info);
      // 全局默认档位只作为「新对话的起点」（草稿未手选时的显示值）
      setGlobalApprovalModeState(mode as ApprovalMode);
    } catch {
      // 后端尚未就绪（Starting…）时静默重试
    }
  }, []);

  /// 对话列表（含归档，侧栏三区用）。
  const refreshConversations = useCallback(async () => {
    try {
      setConversations(await listConversations(true));
    } catch {
      // ignore
    }
  }, []);

  /// 当前对话的完整转录（按 id 拉取，事件与轮询共用）。
  const fetchConversation = useCallback(async (id: string) => {
    try {
      const conv = await getConversation(id);
      setActiveConv(conv);
      // 真实条目已落库 → 丢掉同命令的流式占位（不可变更新：返回 null 或原值）
      setStreaming((prev) =>
        prev && conv.messages.some((m) => m.commandId === prev.commandId)
          ? null
          : prev,
      );
    } catch {
      // 对话可能已被删除 → 回草稿态
      setActiveConv(null);
    }
  }, []);

  // Initial load
  useEffect(() => {
    const init = async () => {
      await Promise.all([
        refreshStatus(),
        refreshTerminal(),
        refreshSecurity(),
        refreshConversations(),
      ]);
      // 启动时从后端取回 active 对话（重启恢复）
      try {
        const st = await getStatus();
        if (st.activeConversationId) {
          updateActiveConvId(st.activeConversationId);
          setActiveConv(await getConversation(st.activeConversationId));
        }
      } catch {
        // ignore
      }
      setLoading(false);
    };
    void init();
  }, [refreshStatus, refreshTerminal, refreshSecurity, refreshConversations, fetchConversation, updateActiveConvId]);

  // Poll: status/security 5s；终端 2s（事件为主，轮询兜底防丢事件）；对话列表 5s
  useEffect(() => {
    const timer = setInterval(() => {
      refreshStatus();
      refreshSecurity();
      refreshConversations();
    }, 5000);
    const terminalTimer = setInterval(refreshTerminal, 2000);
    return () => {
      clearInterval(timer);
      clearInterval(terminalTimer);
    };
  }, [refreshStatus, refreshSecurity, refreshTerminal, refreshConversations]);

  // Listen for backend events (matches macOS reactive updates)
  useEffect(() => {
    const unlistenOutput = listen("terminal-updated", () => {
      refreshTerminal();
    });
    const unlistenAgent = listen("active-agent-changed", (event) => {
      const newId = event.payload as string;
      setDraftAgentId(newId);
      refreshTerminal();
    });
    const unlistenRuntime = listen("runtime-state-changed", () => {
      refreshStatus();
    });
    // 托盘「显示配对码」→ 打开设置弹窗并定位到配对分类
    const unlistenPairing = listen("pairing-revealed", () => {
      setSettingsOpen(true);
      setSettingsSection("pairing");
      refreshSecurity();
    });
    const unlistenRefresh = listen("refresh-agents", () => {
      refreshStatus();
      refreshTerminal();
    });
    // 多对话事件
    const unlistenConvs = listen("conversations-changed", () => {
      refreshConversations();
      // 当前对话内容变了（消息追加）→ 同步转录。
      // 读 ref 而不是把副作用塞进 setState updater（见 activeConvIdRef 注释）。
      const id = activeConvIdRef.current;
      if (id) void fetchConversation(id);
    });
    // 流式增量：命令执行期间后端边读边推，这里只做不可变替换 → 必然重渲染。
    // 增量只写当前 streaming 槽位，绝不原地改 activeConv.messages。
    const unlistenDelta = listen<ConversationDelta>("conversation-delta", (event) => {
      const d = event.payload;
      if (!d?.conversationId) return;
      setStreaming((prev) =>
        prev && prev.commandId === d.commandId
          ? { ...prev, text: d.text }
          : { convId: d.conversationId, commandId: d.commandId, text: d.text },
      );
    });
    const unlistenActiveConv = listen("active-conversation-changed", (event) => {
      const id = (event.payload as string | null) ?? null;
      updateActiveConvId(id);
      if (id) {
        void fetchConversation(id);
      } else {
        setActiveConv(null);
      }
    });

    return () => {
      unlistenOutput.then((fn) => fn());
      unlistenAgent.then((fn) => fn());
      unlistenRuntime.then((fn) => fn());
      unlistenPairing.then((fn) => fn());
      unlistenRefresh.then((fn) => fn());
      unlistenConvs.then((fn) => fn());
      unlistenDelta.then((fn) => fn());
      unlistenActiveConv.then((fn) => fn());
    };
  }, [refreshTerminal, refreshStatus, refreshSecurity, refreshConversations, fetchConversation, updateActiveConvId]);

  // ─── Models catalog（跟随当前对话的 agent） ───────────────────────────────

  /// 当前生效的 Agent：已有对话以 `conv.agentId` 为准（对话级，创建时绑定），
  /// 草稿态用草稿选定的 Agent。模型目录 / 终端 / 工作目录都跟随它。
  const effectiveAgentId = activeConv?.agentId ?? draftAgentId;

  const refreshModels = useCallback(async (agentId: string) => {
    try {
      setModels(await getAgentModels(agentId));
    } catch {
      setModels(null); // 未知 agent / 无配置 → 隐藏模型入口
    }
  }, []);

  useEffect(() => {
    setModels(null);
    void refreshModels(effectiveAgentId);
  }, [effectiveAgentId, refreshModels]);

  // ─── Workdir（目录上下文；三态）────────────────────────────────────────────
  // - 已有对话：绑定目录 = conv.workdirOverride（权威，侧栏分组同源），
  //   未绑定时展示回落（agent 偏好 agentWorkdir → CLI 默认）。
  // - 草稿态（新对话）：draftWorkdir 三态 —— undefined = 未选择（发送时
  //   快照当前 agent 偏好目录），null = 明确解绑（发送时不绑定），
  //   string = 创建时绑定的目录。首条消息发送时经 sendCommand(workdir) 一次性落库。
  const [agentWorkdir, setAgentWorkdirState] = useState<string | null>(null);
  const [draftWorkdir, setDraftWorkdir] = useState<string | null | undefined>(undefined);
  const refreshWorkdir = useCallback(async (agentId: string) => {
    try {
      setAgentWorkdirState(await getAgentWorkdir(agentId));
    } catch {
      setAgentWorkdirState(null);
    }
  }, []);

  /// 目录条选择：已有对话 → 写对话绑定（后端校验目录存在）；
  /// 草稿态 → 只改本地三态，发送首条消息时才随对话物化。
  const handleSetWorkdir = (path: string | null) =>
    runQuietly(async () => {
      if (activeConvId) {
        await setConversationWorkdir(activeConvId, path);
        setActiveConv((prev) =>
          prev && prev.id === activeConvId
            ? { ...prev, workdirOverride: path }
            : prev,
        );
        await refreshConversations();
      } else {
        setDraftWorkdir(path);
      }
    });

  // ─── Actions ────────────────────────────────────────────────────────────

  const runQuietly = async (action: () => Promise<void>) => {
    try {
      setError(null);
      await action();
    } catch (e) {
      setError(String(e));
    }
  };

  const handleSend = (text: string) =>
    runQuietly(async () => {
      // conversationId = null（草稿态）时后端创建新对话并激活，返回对话 ID。
      // 新对话创建即记录「当时的目录」：草稿里显式选择过的优先（含明确清除
      // = null 不绑定），否则快照当前生效目录（agent 偏好），保证目录与
      // 对话一一对应、不落到全局共用。
      const bindWorkdir = activeConvId
        ? undefined
        : draftWorkdir !== undefined
          ? draftWorkdir
          : (agentWorkdir ?? null);
      // 新对话创建即记录「当时的授权档位」：草稿里选的档位随对话固化，
      // 保证每个对话的授权互不影响（不写到全局默认，不影响既有对话）。
      const bindApproval = activeConvId ? undefined : draftApprovalMode;
      const convId = await sendCommand(text, activeConvId, bindWorkdir, bindApproval);
      updateActiveConvId(convId);
      setStreaming(null);
      setDraftWorkdir(undefined);
      // 草稿档位随首条消息固化进对话，草稿选择清空（下一个草稿重新跟随全局默认）
      setDraftApprovalMode(null);
      await refreshConversations();
      const conv = await getConversation(convId);
      setActiveConv(conv);
      // 不自动切 dirFilter：发消息只是"切换"当前对话，历史列表保持原视野，
      // 避免其他目录的对话突然消失（下钻感）。筛选只走右上角目录菜单。
      await refreshTerminal();
    });

  /// 切换 Agent。
  /// Agent 是**对话级**绑定（创建时固化）：在已有对话里切到别的 Agent 会
  /// 进入草稿态（下一条消息以新 Agent 开新对话），旧对话原样保留、可随时
  /// 切回；草稿态则直接改草稿的 Agent（并同步后端 active agent）。
  const handleSwitchAgent = (agentId: string) =>
    runQuietly(async () => {
      if (agentId === convAgentId) return;
      await switchActiveAgent(agentId);
      setDraftAgentId(agentId);
      await refreshTerminal();
      // 对话绑定 agent（方案 §6.2）：当前对话属于别的 agent 时切到草稿态，
      // 下一条消息会以新 agent 开新对话；旧对话保留可随时切回。
      if (activeConv && activeConv.agentId !== agentId) {
        updateActiveConvId(null);
        setActiveConv(null);
        // 回到草稿：草稿里的临时选择（档位）清空，重新跟随全局默认
        setDraftApprovalMode(null);
      }
    });

  // key 形如 `${providerId}::${modelId}`，拆开后配对提交，后端才能区分
  // 同名模型来自哪家（"跟随 Agent 配置" 传 key=""，即清除偏好）。
  //
  // 模型是**对话级**设置：已有对话写该对话的模型覆盖（只影响这一个对话，
  // 其它对话不受影响）；草稿态没有对话可写，改的是该 Agent 的默认模型
  // （= 新对话的起点，仍随对话创建时继承为"跟随 Agent 配置"）。
  const handleSelectModel = (key: string) =>
    runQuietly(async () => {
      const modelId = key === "" ? null : key.slice(key.indexOf("::") + 2);
      const providerId = key === "" ? null : key.slice(0, key.indexOf("::"));
      if (activeConvId) {
        await setConversationModel(activeConvId, modelId, providerId);
        setActiveConv((prev) =>
          prev && prev.id === activeConvId
            ? { ...prev, modelOverride: modelId, modelProviderOverride: providerId }
            : prev,
        );
      } else {
        await setDefaultModel(effectiveAgentId, modelId, providerId);
        await refreshModels(effectiveAgentId);
      }
    });

  /// 切换授权档位。授权是**对话级**设置：
  /// - 已有对话 → 写该对话的档位（其它对话不受影响）；
  /// - 草稿态 → 只改草稿（发送首条消息时随对话固化，全局默认不动）。
  const handleSetApprovalMode = (mode: ApprovalMode) =>
    runQuietly(async () => {
      if (activeConvId) {
        await setConversationApprovalMode(activeConvId, mode);
        setActiveConv((prev) =>
          prev && prev.id === activeConvId ? { ...prev, approvalMode: mode } : prev,
        );
      } else {
        // 草稿：只记在本地（随首条消息随对话固化），不动全局默认，
        // 也就不会影响任何已有对话。
        setDraftApprovalMode(mode);
      }
    });

  const handleClearTerminal = () =>
    runQuietly(() => clearTerminal(effectiveAgentId));

  const handleRevealPairing = () =>
    runQuietly(async () => {
      setPairing(await revealPairingCode());
    });

  const handleRegeneratePairing = () =>
    runQuietly(async () => {
      setPairing(await regeneratePairingCode());
    });

  const handleCopyCode = () =>
    runQuietly(async () => {
      if (!pairing?.code) return;
      await navigator.clipboard.writeText(pairing.code);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1500);
    });

  /// 「新对话」：进入草稿态（对齐 Lody draft——不调任何 API，无文件产生），
  /// 发送首条消息时后端才物化对话。目录选择走 composer 上方的目录条
  /// （草稿三态），可浏览 / 输入路径 / 最近使用 / 留空不绑定。
  const handleNewConversation = () => {
    updateActiveConvId(null);
    setActiveConv(null);
    setDraftWorkdir(undefined);
    setDraftApprovalMode(null);
    setSettingsOpen(false);
  };

  const handleOpenConversation = (id: string) =>
    runQuietly(async () => {
      await activateConversation(id);
      updateActiveConvId(id);
      const conv = await getConversation(id);
      setActiveConv(conv);
      // 不自动切 dirFilter：打开历史对话 = 切换当前对话，列表视野不动
      //（目录条仍随对话绑定自动显示，见 effectiveWorkdir）。
      setSettingsOpen(false);
    });

  const handleArchiveConversation = (id: string) =>
    runQuietly(async () => {
      await setConversationArchived(id, true);
      // 归档 active → 后端已清 active 指针；本地同步回草稿态
      if (id === activeConvId) {
        updateActiveConvId(null);
        setActiveConv(null);
      }
      await refreshConversations();
    });

  const handleRestoreConversation = (id: string) =>
    runQuietly(async () => {
      await setConversationArchived(id, false);
      await refreshConversations();
    });

  const handleDeleteConversation = (id: string) =>
    runQuietly(async () => {
      await deleteConversation(id);
      await refreshConversations();
    });

  const handleTogglePin = (id: string, pinned: boolean) =>
    runQuietly(async () => {
      await togglePinConversation(id, pinned);
      await refreshConversations();
    });

  // ─── Derived State ──────────────────────────────────────────────────────

  const convAgentId = effectiveAgentId;
  const activeTerminal =
    terminals.find((t) => t.agentId === convAgentId) ?? null;
  const agentNameMap = new Map(
    (status?.agents ?? []).map((a) => [a.id, a.name] as const),
  );
  const convAgentName =
    agentNameMap.get(convAgentId) ?? activeConv?.agentId ?? convAgentId;
  const runtimeState: RuntimeState = status?.runtimeState ?? "idle";
  const installedAgents = (status?.agents ?? []).filter((a) => a.installed);

  // 工作目录跟随「当前对话的 agent」：切到属于其他 agent 的历史对话时，
  // 目录条与后续文件操作同步切换（与 command_runner 的生效规则一致）。
  useEffect(() => {
    setAgentWorkdirState(null);
    void refreshWorkdir(convAgentId);
  }, [convAgentId, refreshWorkdir]);

  // ─── 目录上下文（对话绑定优先，草稿三态次之，agent 偏好兜底）──────────────
  // 侧栏分组、目录条、执行 cwd 三者都以 conv.workdirOverride 为单一数据源。
  // 已有对话未绑定时显示 agent 偏好（与 command_runner 的执行回落链一致，
  // 目录条永远反映「当前对话真正生效的目录」）。
  const effectiveWorkdir = activeConvId
    ? (activeConv?.workdirOverride ?? agentWorkdir)
    : draftWorkdir !== undefined
      ? draftWorkdir
      : agentWorkdir;
  const isDraftConv = activeConvId === null;

  // 最近使用的目录（含已归档对话的绑定；conversations 已按最近活动排序）
  const recentDirs: string[] = [];
  {
    const seen = new Set<string>();
    for (const c of conversations) {
      const d = c.workdirOverride;
      if (d && !seen.has(d)) {
        seen.add(d);
        recentDirs.push(d);
      }
    }
  }

  // 所有 provider 的模型摊平。⚠️ 不同 provider 会暴露相同模型 id（如
  // mimo-v2.5-pro 同时来自 OpenCode Go 与小米 Token Plan），因此下拉项 key
  // 必须带 provider 前缀（否则两条都显示选中勾），提交时 key 拆回
  // modelId + providerId 一并提交（后端配对记录，执行时 opencode 拼成
  // `--model provider/model`）。
  const modelOptions = (models?.providers ?? []).flatMap((p) =>
    p.models.map((m) => ({
      key: `${p.id}::${m.id}`,
      id: m.id,
      name: m.name,
      provider: p.name,
      providerId: p.id,
    })),
  );
  // 当前生效模型 = **对话级覆盖**（用户在这个对话里选的）> 该 Agent 的默认
  // 模型偏好（全局，作为"跟随 Agent 配置"的落点）> Agent 配置里的 active。
  const convModelOverride = activeConv?.modelOverride ?? null;
  const convProviderOverride = activeConv?.modelProviderOverride ?? null;
  const currentModelId =
    convModelOverride ?? models?.preferredModelId ?? models?.activeModelId ?? "";
  const currentProviderId = convModelOverride
    ? convProviderOverride
    : models?.preferredProviderId ?? null;
  // 选中判定：id 匹配的前提下，若偏好记录了 provider 则精确到 provider；
  // 旧记录（无 provider）退回第一个 id 命中。
  const currentModelKey =
    modelOptions.find(
      (m) =>
        m.id === currentModelId &&
        (currentProviderId == null || m.providerId === currentProviderId),
    )?.key ?? "";

  // 生效授权档位 = **对话级**（创建时固化 / 对话内改档位）
  //               > 草稿里手选的 > 全局默认。旧对话（未固化档位）回落全局。
  const effectiveApprovalMode: ApprovalMode =
    activeConv?.approvalMode ?? (draftApprovalMode ?? globalApprovalMode);

  // 侧栏三区：置顶 / 常规 / 归档（后端已按 pinned 优先 + 最新活动排好）
  // 侧栏：目录分组 + 归档（后端已按 pinned 优先 + 最新活动排好，
  // 组内保持该顺序 = 置顶自然在组首）
  const activeConversations = conversations.filter((c) => !c.archived);
  const archivedConversations = conversations.filter((c) => c.archived);

  // 目录组：key = 绑定目录 ?? UNBOUND；组序按组内最新活动降序，未绑定组垫底
  const groupMap = new Map<string, ConversationSummary[]>();
  for (const c of activeConversations) {
    const key = c.workdirOverride ?? UNBOUND;
    const arr = groupMap.get(key);
    if (arr) arr.push(c);
    else groupMap.set(key, [c]);
  }
  const dirGroups = [...groupMap.entries()]
    .map(([key, items]) => ({ key, items }))
    .sort((a, b) => {
      if (a.key === UNBOUND) return 1;
      if (b.key === UNBOUND) return -1;
      return (b.items[0]?.updatedAtMs ?? 0) - (a.items[0]?.updatedAtMs ?? 0);
    });
  // 过滤后要渲染的组（ALL_DIRS = 全部；具体目录可能暂时没有对话 → 空态提示）
  const visibleGroups =
    dirFilter === ALL_DIRS
      ? dirGroups
      : dirGroups.filter((g) => g.key === dirFilter);

  // busy：调度指针在飞（方案 §2-A4）或终端在跑
  const isBusy =
    activeConv?.latestCommandId != null || activeTerminal?.status === "running";

  // 渲染用的消息列表 = 权威转录 +（可选）当前会话正在生成的那条流式气泡。
  //
  // 关键约束：
  // - 增量**不**写进 activeConv.messages（那是后端权威转录，只由重取替换），
  //   而是单独开一个对象，每次都 { ...prev, text } 造新引用 → 必然重渲染；
  // - 只有当增量的 convId 等于当前会话时才拼上去，避免串到别的会话/旧快照上；
  // - 真实条目落库后 fetchConversation 会把 streaming 置空，不会重复渲染。
  const baseMessages = fromTranscript(activeConv?.messages ?? []);
  const streamingText =
    streaming && streaming.convId === activeConvId ? streaming.text : null;
  const messages =
    streamingText !== null && streamingText.length > 0
      ? [
          ...baseMessages,
          {
            id: `streaming_${streaming!.commandId}`,
            role: "assistant" as const,
            text: streamingText,
          },
        ]
      : baseMessages;
  const draft = drafts[activeConvId ?? DRAFT_KEY] ?? "";

  // 命令在飞期间轮询当前对话：与既有「事件为主、轮询兜底防丢事件」一致。
  // 即便 conversations-changed 丢了一帧，最终回复也一定会显示出来，
  // 且 latestCommandId 清空后能立刻解除 busy（不再卡在"正在思考…"）。
  useEffect(() => {
    if (!activeConvId || !isBusy) return;
    const id = activeConvId;
    const timer = setInterval(() => void fetchConversation(id), 700);
    return () => clearInterval(timer);
  }, [activeConvId, isBusy, fetchConversation]);

  // 终端 dock 展开 + 新输出 → 自动贴底
  useEffect(() => {
    if (dockOpen && outputRef.current) {
      const el = outputRef.current;
      el.scrollTop = el.scrollHeight;
    }
  }, [terminals, dockOpen]);

  if (loading) {
    return (
      <div className="flex h-svh w-full flex-col overflow-hidden bg-background">
        <div className="no-agent-placeholder font-mono">
          <span className="prompt">brewping ❯ </span>
          <span className="message">Starting BrewPing...</span>
        </div>
      </div>
    );
  }

  const renderConversationItem = (c: ConversationSummary, archived: boolean) => (
    <div
      key={c.id}
      className={cn(
        "group mb-0.5 flex w-full items-center gap-1 rounded-md pr-1 text-left hover:bg-accent",
        activeConvId === c.id && !archived && "bg-accent font-medium",
      )}
    >
      <button
        className="min-w-0 flex-1 rounded-md px-1.5 py-1.5"
        onClick={() => (archived ? undefined : void handleOpenConversation(c.id))}
        disabled={archived}
        title={c.title ?? t("side.untitled")}
      >
        <div className="flex items-center gap-1">
          {c.isPinned && <Pin size={10} className="shrink-0 text-primary/70" />}
          <span className="truncate text-xs text-foreground">
            {c.title ?? t("side.untitled")}
          </span>
        </div>
        {/* 元信息行：锁单行（英文 "4 msgs"/"05:43 PM" 比中文长，防换行破版），
            agent 名可截断吸收超长，时间统一 24 小时制 */}
        <div className="mt-0.5 flex items-center gap-1 overflow-hidden whitespace-nowrap text-[9px] text-muted-foreground">
          <span className="min-w-0 truncate">{agentNameMap.get(c.agentId) ?? c.agentId}</span>
          <span className="shrink-0">·</span>
          <span className="shrink-0">{t("side.msgCount", { n: c.messageCount })}</span>
          <span className="shrink-0">·</span>
          <span className="shrink-0">
            {new Date(c.updatedAtMs).toLocaleTimeString(intlLocale(locale), {
              hour: "2-digit",
              minute: "2-digit",
              hour12: false,
            })}
          </span>
        </div>
      </button>
      <div className="flex shrink-0 items-center gap-0.5 opacity-0 transition-opacity group-hover:opacity-100">
        {archived ? (
          <>
            <button
              className="flex h-6 w-6 items-center justify-center rounded-md text-muted-foreground hover:bg-background hover:text-foreground"
              title={t("side.restore")}
              onClick={() => void handleRestoreConversation(c.id)}
            >
              <ArchiveRestore size={13} />
            </button>
            <button
              className="flex h-6 w-6 items-center justify-center rounded-md text-muted-foreground hover:bg-destructive/10 hover:text-destructive"
              title={t("side.deleteForever")}
              onClick={() => void handleDeleteConversation(c.id)}
            >
              <Trash2 size={13} />
            </button>
          </>
        ) : (
          <>
            <button
              className="flex h-6 w-6 items-center justify-center rounded-md text-muted-foreground hover:bg-background hover:text-foreground"
              title={c.isPinned ? t("side.unpin") : t("side.pin")}
              onClick={() => void handleTogglePin(c.id, !c.isPinned)}
            >
              {c.isPinned ? <PinOff size={13} /> : <Pin size={13} />}
            </button>
            <button
              className="flex h-6 w-6 items-center justify-center rounded-md text-muted-foreground hover:bg-background hover:text-foreground"
              title={t("side.archive")}
              onClick={() => void handleArchiveConversation(c.id)}
            >
              <Archive size={13} />
            </button>
          </>
        )}
      </div>
    </div>
  );

  return (
    <div className="flex h-svh w-full flex-col overflow-hidden bg-background">
      {/* ─── 自定义标题栏（无边框窗口：整条可拖拽；品牌名不重复展示，只留窗口控制）── */}
      <div data-tauri-drag-region className="flex h-7 shrink-0 select-none items-center justify-end bg-background">
        <div className="flex h-full">
          <button
            type="button"
            className="flex h-full w-11 items-center justify-center text-muted-foreground hover:bg-accent hover:text-foreground"
            onClick={() => winAction(() => getCurrentWindow().minimize())}
            title={t("win.minimize")}
          >
            <Minus size={14} />
          </button>
          <button
            type="button"
            className="flex h-full w-11 items-center justify-center text-muted-foreground hover:bg-accent hover:text-foreground"
            onClick={() => winAction(() => getCurrentWindow().toggleMaximize())}
            title={t("win.maximize")}
          >
            <Square size={11} />
          </button>
          <button
            type="button"
            className="flex h-full w-11 items-center justify-center text-muted-foreground hover:bg-destructive hover:text-white"
            onClick={() => winAction(() => getCurrentWindow().close())}
            title={t("win.close")}
          >
            <X size={14} />
          </button>
        </div>
      </div>

      <div className="flex min-h-0 flex-1">
      {/* ─── 左侧边栏（悬浮圆角卡片：四周留缝、内容裁切在圆角内） ─────────────── */}
      <aside className="mb-2 ml-2 mr-1 mt-1 flex w-52 shrink-0 flex-col overflow-hidden rounded-2xl border border-border/50 bg-card shadow-xs">
        {/* 品牌行（无边框，与下方自然衔接；高度与主区标题行对齐） */}
        <div className="flex h-9 shrink-0 items-center gap-1.5 px-3.5">
          <span className="text-[11px]">☕</span>
          <span className="font-mono text-[11px] font-semibold text-primary/90">BrewPing</span>
          <span className="ml-auto flex items-center gap-1">
            <span className={`runtime-dot h-1.5 w-1.5 ${runtimeState === "online" ? "online" : runtimeState === "starting" ? "starting" : "offline"}`} />
            <span className="text-[9px] text-muted-foreground">
              {runtimeState === "online" ? "ONLINE" : runtimeState === "starting" ? "STARTING…" : "OFFLINE"}
            </span>
          </span>
        </div>

        {/* 新对话（轻量行样式：图标 + 文字，悬停浅棕面） */}
        <div className="px-2 pt-2">
          <button
            className={cn(
              "flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-xs text-muted-foreground hover:bg-accent hover:text-foreground",
              activeConvId === null && "bg-accent font-medium text-foreground",
            )}
            onClick={handleNewConversation}
          >
            <SquarePen size={14} className="shrink-0" />
            <span>{t("side.newChat")}</span>
          </button>
        </div>

        {/* 对话列表：目录分组（可过滤）+ 归档区 */}
        <div className="min-h-0 flex-1 overflow-y-auto panel-scroll px-2 pb-2">
          {/* 目录过滤行（对齐参考截图的「本地项目」分组头 + 右侧工具图标） */}
          <div className="flex items-center justify-between px-1.5 pb-0.5 pt-2">
            <span className="truncate text-[10px] font-semibold uppercase tracking-[0.6px] text-muted-foreground">
              {dirFilter === ALL_DIRS
                ? t("side.filterAll")
                : dirFilter === UNBOUND
                  ? t("side.unbound")
                  : pathLabel(dirFilter)}
            </span>
            <DirFilterMenu current={dirFilter} dirs={recentDirs} onSelect={setDirFilter} />
          </div>

          {activeConversations.length === 0 ? (
            <div className="px-1.5 pt-1 text-[10px] leading-relaxed text-muted-foreground/60">
              {t("side.empty")}
            </div>
          ) : visibleGroups.length === 0 ? (
            <div className="px-1.5 pt-1 text-[10px] leading-relaxed text-muted-foreground/60">
              {t("side.groupEmpty")}
            </div>
          ) : (
            visibleGroups.map((group) => (
              <div key={group.key}>
                {/* 组头 = 折叠/展开（所有目录组保持可见，只切换视野不下钻）；
                    按目录筛选只走右上角的目录菜单 */}
                <button
                  type="button"
                  className="mt-1.5 flex w-full items-center gap-1.5 rounded-md px-1.5 py-1 text-left transition-colors hover:bg-accent/60"
                  onClick={() =>
                    setCollapsedGroups((prev) => ({
                      ...prev,
                      [group.key]: !prev[group.key],
                    }))
                  }
                  title={
                    group.key === UNBOUND
                      ? t("side.unboundTooltip")
                      : t("side.groupTooltip", { path: group.key })
                  }
                >
                  <ChevronDown
                    size={11}
                    className={cn(
                      "shrink-0 text-muted-foreground/60 transition-transform",
                      collapsedGroups[group.key] && "-rotate-90",
                    )}
                  />
                  <Folder
                    size={12}
                    className="shrink-0 text-primary/75"
                  />
                  <span className="min-w-0 truncate text-[11px] font-medium text-foreground/85">
                    {group.key === UNBOUND ? t("side.unbound") : pathLabel(group.key)}
                  </span>
                  <span className="ml-auto shrink-0 text-[9px] text-muted-foreground/60">
                    {group.items.length}
                  </span>
                </button>
                {!collapsedGroups[group.key] &&
                  group.items.map((c) => renderConversationItem(c, false))}
              </div>
            ))
          )}

          {archivedConversations.length > 0 && (
            <>
              <div className="mt-2 border-t border-border/60 px-1.5 pb-1 pt-2 text-[10px] font-semibold uppercase tracking-[0.6px] text-muted-foreground/70">
                {t("side.archived")}
              </div>
              {archivedConversations.map((c) => renderConversationItem(c, true))}
            </>
          )}
        </div>

        {/* 底部：齿轮（设置 + 配对）—— 打开模态设置弹窗 */}
        <div className="shrink-0 border-t border-border p-2.5">
          <button
            className="flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-xs text-muted-foreground hover:bg-accent hover:text-foreground"
            onClick={() => setSettingsOpen(true)}
            title={t("side.settingsTooltip")}
          >
            <span className="text-sm leading-none">⚙</span>
            <span>{t("side.settings")}</span>
          </button>
        </div>
      </aside>

      {/* ─── 主区域 ───────────────────────────────────────────────────────── */}
      <main className="flex h-full min-w-0 flex-1 flex-col">
        {error && (
          <div
            className="shrink-0 cursor-pointer border-b border-destructive/35 bg-destructive/10 px-3.5 py-1.5 text-[10px] text-destructive break-all"
            onClick={() => setError(null)}
          >
            {error}
          </div>
        )}

        <>
            {/* 顶栏：与内容同底色、无分隔线（参考 WorkBuddy），标题随对话自动生成 */}
            <div className="flex h-9 shrink-0 items-center gap-2 px-4">
              <span className="truncate text-sm font-medium text-foreground">
                {activeConv?.title ?? t("top.newChat")}
              </span>
              <span className="shrink-0 rounded-full bg-secondary px-2 py-0.5 text-[10px] text-secondary-foreground/80">
                {convAgentName}
              </span>
              <span className="ml-auto flex shrink-0 items-center gap-1.5">
                <span className={`runtime-dot h-1.5 w-1.5 ${runtimeState === "online" ? "online" : runtimeState === "starting" ? "starting" : "offline"}`} />
                <span className="text-[10px] text-muted-foreground">
                  {runtimeState === "online" ? t("top.online") : runtimeState === "starting" ? t("top.starting") : t("top.offline")}
                </span>
              </span>
            </div>
            <ChatView
              messages={messages}
              agentName={convAgentName}
              isBusy={isBusy}
              draft={draft}
              onDraftChange={(text) =>
                setDrafts((prev) => ({ ...prev, [activeConvId ?? DRAFT_KEY]: text }))
              }
              onSend={handleSend}
              composerTopBar={
                <WorkdirPicker
                  workdir={effectiveWorkdir}
                  recentDirs={recentDirs}
                  hint={
                    isDraftConv
                      ? t("wd.hintNew")
                      : t("wd.hintBound")
                  }
                  onChange={handleSetWorkdir}
                />
              }
              composerToolbar={
                <div className="flex min-w-0 flex-1 items-center gap-1">
                  {/* 切换 Agent */}
                  <ComposerDropdown
                    title={t("bar.switchAgent")}
                    icon={<Bot size={14} className="shrink-0" />}
                    value={convAgentId}
                    options={
                      installedAgents.length === 0
                        ? [{ value: convAgentId, label: convAgentName }]
                        : installedAgents.map((a) => ({ value: a.id, label: a.name }))
                    }
                    onChange={handleSwitchAgent}
                    triggerClassName="max-w-40"
                  />

                  {/* 切换模型（agent 没有可用模型时隐藏） */}
                  {modelOptions.length > 0 && (
                    <ComposerDropdown
                      title={t("bar.pickModel")}
                      icon={<Cpu size={14} className="shrink-0" />}
                      value={currentModelKey}
                      options={[
                        { value: "", label: t("bar.followAgent") },
                        ...modelOptions.map((m) => ({
                          value: m.key,
                          label: m.name,
                          description: m.provider,
                        })),
                      ]}
                      onChange={handleSelectModel}
                      triggerClassName="max-w-48"
                    />
                  )}

                  {/* 切换授权模式（对话级：只影响当前对话 / 草稿） */}
                  <ComposerDropdown
                    title={t("bar.approval")}
                    icon={<ShieldCheck size={14} className="shrink-0" />}
                    value={effectiveApprovalMode}
                    options={APPROVAL_MODES.map((m) => ({
                      value: m.id,
                      label: t("bar.approvalItem", { label: m.label }),
                      description: t(m.descKey),
                    }))}
                    onChange={(v) => handleSetApprovalMode(v as ApprovalMode)}
                    triggerClassName={cn(
                      "max-w-36",
                      effectiveApprovalMode === "askAll" && "text-warning",
                      effectiveApprovalMode === "auto" && "text-success",
                    )}
                  />

                  <div className="ml-auto flex items-center gap-1">
                    <button
                      className={cn(
                        "flex h-7 w-7 items-center justify-center rounded-lg text-muted-foreground transition-colors hover:bg-accent hover:text-foreground",
                        dockOpen && "bg-accent text-primary",
                      )}
                      onClick={() => setDockOpen(!dockOpen)}
                      title={t("bar.terminal")}
                    >
                      <SquareTerminal size={15} />
                    </button>
                  </div>
                </div>
              }
            />

            {/* 终端 dock：可折叠（per-agent 原始输出，旁路角色） */}
            {dockOpen && (
              <div className="flex h-56 shrink-0 flex-col border-t border-border bg-card">
                <div className="flex h-9 shrink-0 items-center justify-between border-b border-border/60 px-3.5">
                  <span className="text-[10px] font-semibold uppercase tracking-[0.6px] text-muted-foreground">
                    {t("bar.terminalOf", { agent: convAgentName })}
                  </span>
                  <div className="flex items-center gap-1.5">
                    <Button variant="ghost" size="sm" className="h-6 px-2 text-xs" onClick={handleClearTerminal}>
                      {t("common.clear")}
                    </Button>
                    <Button variant="ghost" size="sm" className="h-6 px-2 text-xs" onClick={() => setDockOpen(false)}>
                      {t("common.collapse")}
                    </Button>
                  </div>
                </div>
                {activeTerminal ? (
                  <div className="terminal-output panel-scroll" ref={outputRef}>
                    {activeTerminal.outputLines.length === 0 ? (
                      <div className="terminal-empty">
                        <span className="prompt">brewping ❯ </span>
                        <span className="hint">Waiting for commands...</span>
                        <span className="hint-dim">Send a message from iPhone or Watch</span>
                        <span className="divider">
                          ═══════════════════════════════════════
                        </span>
                      </div>
                    ) : (
                      activeTerminal.outputLines.map((line) => (
                        <OutputLineView key={line.id} line={line} />
                      ))
                    )}
                    <div className="blinking-cursor">█</div>
                    <div className="scanline-overlay" />
                  </div>
                ) : (
                  <div className="no-agent-placeholder font-mono">
                    <span className="prompt">brewping ❯ </span>
                    <span className="message">No agents available</span>
                    <span className="hint">Install opencode, claude, or codex to get started</span>
                  </div>
                )}
              </div>
            )}
          </>
      </main>
      </div>

      {/* 设置弹窗：模态覆盖层（点遮罩 / Esc / 右上角 ✕ 关闭） */}
      {settingsOpen && (
        <SettingsView
          status={status}
          pairing={pairing}
          copied={copied}
          runtimeState={runtimeState}
          section={settingsSection}
          onSectionChange={setSettingsSection}
          onReveal={handleRevealPairing}
          onRegenerate={handleRegeneratePairing}
          onCopy={handleCopyCode}
          onClose={() => setSettingsOpen(false)}
        />
      )}
    </div>
  );
}

// ─── 设置视图（齿轮）：机器信息 + 配对（授权入口在 composer 工具栏） ─────────

function SettingsView({
  status,
  pairing,
  copied,
  runtimeState,
  section,
  onSectionChange,
  onReveal,
  onRegenerate,
  onCopy,
  onClose,
}: {
  status: DesktopStatus | null;
  pairing: PairingInfo | null;
  copied: boolean;
  runtimeState: RuntimeState;
  section: SettingsSectionId;
  onSectionChange: (id: SettingsSectionId) => void;
  onReveal: () => void;
  onRegenerate: () => void;
  onCopy: () => void;
  onClose: () => void;
}) {
  const { t, locale, langMode, setLangMode } = useI18n();
  const expiry = pairing?.expiresAt
    ? new Date(pairing.expiresAt).toLocaleTimeString(intlLocale(locale))
    : null;

  // 语言三选项（跟随系统 / 中文 / English），显示解析结果
  const LANG_OPTIONS: Array<{ id: LangMode; label: string; desc: string }> = [
    { id: "system", label: t("lang.system"), desc: t("lang.current", { name: locale === "zh" ? t("lang.zh") : t("lang.en") }) },
    { id: "zh", label: t("lang.zh"), desc: locale === "zh" ? t("lang.current", { name: t("lang.zh") }) : "" },
    { id: "en", label: t("lang.en"), desc: locale === "en" ? t("lang.current", { name: t("lang.en") }) : "" },
  ];

  // 左侧分类导航（label/icon 每渲染重建以跟随语言切换）
  const NAV_ITEMS: Array<{ id: SettingsSectionId; label: string; icon: React.ReactNode }> = [
    { id: "general", label: t("set.navGeneral"), icon: <Globe size={13} /> },
    { id: "machine", label: t("set.navMachine"), icon: <Info size={13} /> },
    { id: "environment", label: t("set.navEnvironment"), icon: <Cpu size={13} /> },
    { id: "pairing", label: t("set.navPairing"), icon: <QrCode size={13} /> },
  ];
  const activeLabel = NAV_ITEMS.find((n) => n.id === section)?.label ?? "";

  // Esc 关闭弹窗
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      {/* 遮罩：点击空白关闭 */}
      <div className="absolute inset-0 bg-black/40" onClick={onClose} />
      <div className="relative flex h-[80vh] max-h-[720px] w-[780px] max-w-[94vw] overflow-hidden rounded-2xl border border-border bg-background shadow-panel">
      {/* 左侧分类导航（双栏布局，参考 WorkBuddy 设置弹窗） */}
      <nav className="flex w-36 shrink-0 flex-col gap-0.5 overflow-y-auto bg-card p-2">
        {NAV_ITEMS.map((item) => (
          <button
            key={item.id}
            type="button"
            className={cn(
              "flex items-center gap-2 rounded-md px-2 py-1.5 text-left text-xs transition-colors hover:bg-accent hover:text-foreground",
              section === item.id && "bg-accent font-medium text-foreground",
            )}
            onClick={() => onSectionChange(item.id)}
          >
            <span className="shrink-0 text-muted-foreground">{item.icon}</span>
            <span className="min-w-0 truncate">{item.label}</span>
          </button>
        ))}
      </nav>
      {/* 右侧：标题行 + 内容 */}
      <div className="flex min-h-0 flex-1 flex-col">
        <div className="flex h-12 shrink-0 items-center justify-between px-4">
          <span className="text-sm font-medium text-foreground">{activeLabel}</span>
          <button
            className="flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground hover:bg-accent hover:text-foreground"
            onClick={onClose}
            title={t("set.close")}
          >
            <X size={15} />
          </button>
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto panel-scroll px-4 pb-4">
          <div className="mx-auto flex w-full max-w-md flex-col gap-3.5">
            {/* ── 语言 / Language ── */}
            {section === "general" && (
          <section className="rounded-lg border border-border bg-card p-3">
            <div className="mb-2 text-[10px] font-semibold uppercase tracking-[0.6px] text-muted-foreground">
              {t("lang.title")}
            </div>
            <div className="flex flex-col gap-1">
              {LANG_OPTIONS.map((opt) => (
                <button
                  key={opt.id}
                  type="button"
                  className={cn(
                    "flex items-center gap-2 rounded-lg px-2.5 py-1.5 text-left text-xs transition-colors hover:bg-accent",
                    langMode === opt.id && "bg-accent font-medium text-foreground",
                  )}
                  onClick={() => setLangMode(opt.id)}
                  title={opt.desc || opt.label}
                >
                  <span className="min-w-0 flex-1 truncate">{opt.label}</span>
                  {opt.desc && (
                    <span className="shrink-0 text-[10px] font-normal text-muted-foreground/70">
                      {opt.desc}
                    </span>
                  )}
                  {langMode === opt.id && (
                    <span className="shrink-0 text-[10px] text-primary">✓</span>
                  )}
                </button>
              ))}
            </div>
          </section>
            )}

            {/* ── 本机信息 ── */}
            {section === "machine" && (
          <section className="rounded-lg border border-border bg-card p-3">
            <div className="mb-2 text-[10px] font-semibold uppercase tracking-[0.6px] text-muted-foreground">
              {t("set.machine")}
            </div>
            <dl className="grid grid-cols-[84px_1fr] gap-y-1.5 text-xs">
              <dt className="text-muted-foreground">{t("set.deviceName")}</dt>
              <dd className="select-text truncate text-foreground">{status?.host ?? "—"}</dd>
              <dt className="text-muted-foreground">{t("set.deviceId")}</dt>
              <dd className="select-text truncate font-mono text-foreground">{status?.deviceId ?? "—"}</dd>
              <dt className="text-muted-foreground">{t("set.platform")}</dt>
              <dd className="text-foreground">
                {status?.platform ?? "—"} · v{status?.version ?? "—"}
              </dd>
              <dt className="text-muted-foreground">{t("set.service")}</dt>
              <dd className="text-foreground">{t(`state.${runtimeState}`)}</dd>
            </dl>
          </section>
            )}

            {/* ── 环境与 AI CLI（Node / NVM / 各智能体 CLI 的检测与安装引导）── */}
            {section === "environment" && <EnvironmentCard />}

            {/* ── 配对 ── */}
            {section === "pairing" && (
          <section className="rounded-lg border border-border bg-card p-3">
            <div className="mb-2 text-[10px] font-semibold uppercase tracking-[0.6px] text-muted-foreground">
              {t("set.pairing")}
            </div>

            {pairing?.code ? (
              <>
                <div className="flex items-center gap-2">
                  <span className="select-text font-mono text-xl font-semibold tracking-[3px] text-foreground">
                    {pairing.code}
                  </span>
                  <Button variant="outline" size="sm" onClick={onCopy}>
                    {copied ? t("common.copied") : t("common.copy")}
                  </Button>
                  <Button variant="outline" size="sm" onClick={onRegenerate} title={t("common.refresh")}>
                    {t("common.refresh")}
                  </Button>
                </div>
                {expiry && (
                  <div className="mt-1.5 text-[10px] leading-relaxed text-muted-foreground">
                    {t("set.expiry", { time: expiry })}
                  </div>
                )}

                {pairing.url ? (
                  <div className="mt-2.5 flex flex-col items-center gap-1.5">
                    <div className="inline-flex rounded-lg border border-border bg-white p-2 leading-none">
                      <QRCode value={pairing.url} size={148} bgColor="#ffffff" fgColor="#4A3B2D" />
                    </div>
                    <div className="text-[10px] leading-relaxed text-muted-foreground">
                      {t("set.scanHint")}
                    </div>
                    <div className="break-all text-[10px] leading-relaxed text-muted-foreground/65">
                      {pairing.url}
                    </div>
                  </div>
                ) : (
                  <div className="mt-1.5 text-[10px] leading-relaxed text-muted-foreground">
                    {t("set.waitingNet")}
                  </div>
                )}

                <div className="mt-1.5 break-all text-[10px] leading-relaxed text-muted-foreground/65">
                  {t("set.manualCode")}
                </div>
              </>
            ) : (
              <>
                <Button variant="default" className="w-full" onClick={onReveal}>
                  {t("set.showCode")}
                </Button>
                <div className="mt-1.5 break-all text-[10px] leading-relaxed text-muted-foreground/65">
                  {t("set.codeHint")}
                </div>
              </>
            )}
          </section>
            )}

          </div>
        </div>
      </div>
      </div>
    </div>
  );
}

// ─── Output Line Component ────────────────────────────────────────────────────

function OutputLineView({ line }: { line: { text: string; type: string } }) {
  const isUserInput = line.type === "system" && line.text.startsWith("> ");
  const isIOS = line.text.includes("[iOS]");
  const isWatch = line.text.includes("[Watch]");

  let className = `output-line ${line.type}`;
  if (isIOS) className += " source-ios";
  if (isWatch) className += " source-watch";

  if (isUserInput) {
    return (
      <div className="output-line system user-input">
        <span className="prompt-prefix">brewping ❯ </span>
        <span>{line.text.slice(2)}</span>
      </div>
    );
  }

  return <div className={className}>{line.text}</div>;
}
