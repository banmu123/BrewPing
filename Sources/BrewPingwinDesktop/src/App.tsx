import { useEffect, useState, useCallback, useRef } from "react";
import { createPortal } from "react-dom";
import { listen } from "@tauri-apps/api/event";
import QRCode from "react-qr-code";
import {
  Archive,
  ArchiveRestore,
  Bot,
  ChevronDown,
  CornerUpLeft,
  Cpu,
  Folder,
  FolderOpen,
  Layers,
  Pin,
  PinOff,
  ShieldCheck,
  SquarePen,
  SquareTerminal,
  Trash2,
} from "lucide-react";
import {
  getStatus,
  getTerminalState,
  switchActiveAgent,
  getPairingInfo,
  revealPairingCode,
  regeneratePairingCode,
  getApprovalMode,
  setApprovalMode,
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
import { cn } from "./lib/utils";
import "./styles/app.css";

const APPROVAL_MODES: Array<{ id: ApprovalMode; label: string; summary: string }> = [
  { id: "safe", label: "safe", summary: "只拦截危险命令（默认）" },
  { id: "askAll", label: "askAll", summary: "每条命令都要确认" },
  { id: "auto", label: "auto", summary: "全程免确认" },
];

type MainView = "chat" | "settings";

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
        title="按目录筛选对话"
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
          <Row value={ALL_DIRS} label="全部对话" icon={<Layers size={13} />} />
          <Row value={UNBOUND} label="未绑定目录" icon={<Folder size={13} />} />
          {dirs.length > 0 && (
            <>
              <div className="my-1 border-t border-border" />
              <div className="px-2.5 pb-0.5 pt-0.5 text-[10px] text-muted-foreground/70">
                按目录
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
  const [status, setStatus] = useState<DesktopStatus | null>(null);
  const [terminals, setTerminals] = useState<AgentTerminalState[]>([]);
  const [activeAgentId, setActiveAgentId] = useState<string>("opencode");
  const [loading, setLoading] = useState(true);
  const [view, setView] = useState<MainView>("chat");
  const [pairing, setPairing] = useState<PairingInfo | null>(null);
  const [approvalMode, setApprovalModeState] = useState<ApprovalMode>("safe");
  const [models, setModels] = useState<AgentModelsInfo | null>(null);
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState<string | null>(null);
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
      setActiveAgentId(s.activeAgentId || "opencode");
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
      setApprovalModeState(mode as ApprovalMode);
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
      setActiveAgentId(newId);
      refreshTerminal();
    });
    const unlistenRuntime = listen("runtime-state-changed", () => {
      refreshStatus();
    });
    // 托盘「显示配对码」→ 打开设置视图（配对卡在里面）
    const unlistenPairing = listen("pairing-revealed", () => {
      setView("settings");
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

  // ─── Models catalog（跟随当前 agent） ─────────────────────────────────────

  const refreshModels = useCallback(async (agentId: string) => {
    try {
      setModels(await getAgentModels(agentId));
    } catch {
      setModels(null); // 未知 agent / 无配置 → 隐藏模型入口
    }
  }, []);

  useEffect(() => {
    setModels(null);
    void refreshModels(activeAgentId);
  }, [activeAgentId, refreshModels]);

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
      const convId = await sendCommand(text, activeConvId, bindWorkdir);
      updateActiveConvId(convId);
      setStreaming(null);
      setDraftWorkdir(undefined);
      await refreshConversations();
      const conv = await getConversation(convId);
      setActiveConv(conv);
      // 不自动切 dirFilter：发消息只是"切换"当前对话，历史列表保持原视野，
      // 避免其他目录的对话突然消失（下钻感）。筛选只走右上角目录菜单。
      await refreshTerminal();
    });

  const handleSwitchAgent = (agentId: string) =>
    runQuietly(async () => {
      if (agentId === activeAgentId) return;
      await switchActiveAgent(agentId);
      setActiveAgentId(agentId);
      await refreshTerminal();
      // 对话绑定 agent（方案 §6.2）：当前对话属于别的 agent 时切到草稿态，
      // 下一条消息会以新 agent 开新对话；旧对话保留可随时切回。
      if (activeConv && activeConv.agentId !== agentId) {
        updateActiveConvId(null);
        setActiveConv(null);
      }
    });

  // key 形如 `${providerId}::${modelId}`，拆开后配对提交，后端才能区分
  // 同名模型来自哪家（"跟随 Agent 配置" 传 key=""，即清除偏好）。
  const handleSelectModel = (key: string) =>
    runQuietly(async () => {
      const agentForModel = activeConv?.agentId ?? activeAgentId;
      if (key === "") {
        await setDefaultModel(agentForModel, null, null);
      } else {
        const sep = key.indexOf("::");
        const providerId = key.slice(0, sep);
        const modelId = key.slice(sep + 2);
        await setDefaultModel(agentForModel, modelId, providerId);
      }
      await refreshModels(agentForModel);
    });

  const handleSetApprovalMode = (mode: ApprovalMode) =>
    runQuietly(async () => {
      setApprovalModeState(mode);
      const applied = await setApprovalMode(mode);
      setApprovalModeState(applied as ApprovalMode);
      await refreshSecurity();
    });

  const handleClearTerminal = () =>
    runQuietly(() => clearTerminal(activeConv?.agentId ?? activeAgentId));

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
    setView("chat");
  };

  const handleOpenConversation = (id: string) =>
    runQuietly(async () => {
      await activateConversation(id);
      updateActiveConvId(id);
      const conv = await getConversation(id);
      setActiveConv(conv);
      // 不自动切 dirFilter：打开历史对话 = 切换当前对话，列表视野不动
      //（目录条仍随对话绑定自动显示，见 effectiveWorkdir）。
      setView("chat");
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

  const convAgentId = activeConv?.agentId ?? activeAgentId;
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
  const currentModelId =
    models?.preferredModelId ?? models?.activeModelId ?? "";
  const currentProviderId = models?.preferredProviderId ?? null;
  // 选中判定：id 匹配的前提下，若偏好记录了 provider 则精确到 provider；
  // 旧记录（无 provider）退回第一个 id 命中。
  const currentModelKey =
    modelOptions.find(
      (m) =>
        m.id === currentModelId &&
        (currentProviderId == null || m.providerId === currentProviderId),
    )?.key ?? "";

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
          <span className="message">Starting BrewPing Desktop...</span>
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
        title={c.title ?? "（尚未命名）"}
      >
        <div className="flex items-center gap-1">
          {c.isPinned && <Pin size={10} className="shrink-0 text-primary/70" />}
          <span className="truncate text-xs text-foreground">
            {c.title ?? "（尚未命名）"}
          </span>
        </div>
        <div className="mt-0.5 flex items-center gap-1 text-[9px] text-muted-foreground">
          <span>{agentNameMap.get(c.agentId) ?? c.agentId}</span>
          <span>·</span>
          <span>{c.messageCount} 条</span>
          <span>·</span>
          <span>
            {new Date(c.updatedAtMs).toLocaleTimeString([], {
              hour: "2-digit",
              minute: "2-digit",
            })}
          </span>
        </div>
      </button>
      <div className="flex shrink-0 items-center gap-0.5 opacity-0 transition-opacity group-hover:opacity-100">
        {archived ? (
          <>
            <button
              className="flex h-6 w-6 items-center justify-center rounded-md text-muted-foreground hover:bg-background hover:text-foreground"
              title="恢复对话"
              onClick={() => void handleRestoreConversation(c.id)}
            >
              <ArchiveRestore size={13} />
            </button>
            <button
              className="flex h-6 w-6 items-center justify-center rounded-md text-muted-foreground hover:bg-destructive/10 hover:text-destructive"
              title="彻底删除"
              onClick={() => void handleDeleteConversation(c.id)}
            >
              <Trash2 size={13} />
            </button>
          </>
        ) : (
          <>
            <button
              className="flex h-6 w-6 items-center justify-center rounded-md text-muted-foreground hover:bg-background hover:text-foreground"
              title={c.isPinned ? "取消置顶" : "置顶"}
              onClick={() => void handleTogglePin(c.id, !c.isPinned)}
            >
              {c.isPinned ? <PinOff size={13} /> : <Pin size={13} />}
            </button>
            <button
              className="flex h-6 w-6 items-center justify-center rounded-md text-muted-foreground hover:bg-background hover:text-foreground"
              title="关闭并归档"
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
    <div className="flex h-svh w-full overflow-hidden bg-background">
      {/* ─── 左侧边栏（与主区的分界只靠底色差，不用硬分隔线） ───────────────── */}
      <aside className="flex h-full w-52 shrink-0 flex-col border-r border-border/50 bg-card">
        {/* 品牌行（无边框，与下方自然衔接） */}
        <div className="flex h-11 shrink-0 items-center gap-1.5 px-3.5">
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
              activeConvId === null && view === "chat" && "bg-accent font-medium text-foreground",
            )}
            onClick={handleNewConversation}
          >
            <SquarePen size={14} className="shrink-0" />
            <span>新对话</span>
          </button>
        </div>

        {/* 对话列表：目录分组（可过滤）+ 归档区 */}
        <div className="min-h-0 flex-1 overflow-y-auto panel-scroll px-2 pb-2">
          {/* 目录过滤行（对齐参考截图的「本地项目」分组头 + 右侧工具图标） */}
          <div className="flex items-center justify-between px-1.5 pb-0.5 pt-2">
            <span className="truncate text-[10px] font-semibold uppercase tracking-[0.6px] text-muted-foreground">
              {dirFilter === ALL_DIRS
                ? "全部对话"
                : dirFilter === UNBOUND
                  ? "未绑定目录"
                  : pathLabel(dirFilter)}
            </span>
            <DirFilterMenu current={dirFilter} dirs={recentDirs} onSelect={setDirFilter} />
          </div>

          {activeConversations.length === 0 ? (
            <div className="px-1.5 pt-1 text-[10px] leading-relaxed text-muted-foreground/60">
              还没有对话。发一条消息即自动创建。
            </div>
          ) : visibleGroups.length === 0 ? (
            <div className="px-1.5 pt-1 text-[10px] leading-relaxed text-muted-foreground/60">
              该目录下暂无对话。可从右侧目录菜单重新选择。
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
                      ? "未绑定目录的对话（点击折叠/展开）"
                      : `${group.key}（点击折叠/展开）`
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
                    {group.key === UNBOUND ? "未绑定目录" : pathLabel(group.key)}
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
                已归档
              </div>
              {archivedConversations.map((c) => renderConversationItem(c, true))}
            </>
          )}
        </div>

        {/* 底部：齿轮（设置 + 配对） */}
        <div className="shrink-0 border-t border-border p-2.5">
          <button
            className={cn(
              "flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-xs text-muted-foreground hover:bg-accent hover:text-foreground",
              view === "settings" && "bg-accent font-medium text-foreground",
            )}
            onClick={() => setView(view === "settings" ? "chat" : "settings")}
            title="机器信息 / 配对码"
          >
            <span className="text-sm leading-none">⚙</span>
            <span>设置与配对</span>
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

        {view === "settings" ? (
          <SettingsView
            status={status}
            pairing={pairing}
            copied={copied}
            runtimeState={runtimeState}
            onReveal={handleRevealPairing}
            onRegenerate={handleRegeneratePairing}
            onCopy={handleCopyCode}
            onClose={() => setView("chat")}
          />
        ) : (
          <>
            {/* 顶栏：与内容同底色、无分隔线（参考 WorkBuddy），标题随对话自动生成 */}
            <div className="flex h-11 shrink-0 items-center gap-2 px-4">
              <span className="truncate text-sm font-medium text-foreground">
                {activeConv?.title ?? "新对话"}
              </span>
              <span className="shrink-0 rounded-full bg-secondary px-2 py-0.5 text-[10px] text-secondary-foreground/80">
                {convAgentName}
              </span>
              <span className="ml-auto flex shrink-0 items-center gap-1.5">
                <span className={`runtime-dot h-1.5 w-1.5 ${runtimeState === "online" ? "online" : runtimeState === "starting" ? "starting" : "offline"}`} />
                <span className="text-[10px] text-muted-foreground">
                  {runtimeState === "online" ? "在线" : runtimeState === "starting" ? "启动中…" : "离线"}
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
                      ? "新对话将记录此目录（可另选或清除后不绑定）"
                      : "本对话绑定的工作目录；更改只影响当前对话"
                  }
                  onChange={handleSetWorkdir}
                />
              }
              composerToolbar={
                <div className="flex min-w-0 flex-1 items-center gap-1">
                  {/* 切换 Agent */}
                  <ComposerDropdown
                    title="切换 Agent"
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
                      title="选择模型"
                      icon={<Cpu size={14} className="shrink-0" />}
                      value={currentModelKey}
                      options={[
                        { value: "", label: "跟随 Agent 配置" },
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

                  {/* 切换授权模式 */}
                  <ComposerDropdown
                    title="授权模式"
                    icon={<ShieldCheck size={14} className="shrink-0" />}
                    value={approvalMode}
                    options={APPROVAL_MODES.map((m) => ({
                      value: m.id,
                      label: `授权 ${m.label}`,
                      description: m.summary,
                    }))}
                    onChange={(v) => handleSetApprovalMode(v as ApprovalMode)}
                    triggerClassName={cn(
                      "max-w-36",
                      approvalMode === "askAll" && "text-warning",
                      approvalMode === "auto" && "text-success",
                    )}
                  />

                  <div className="ml-auto flex items-center gap-1">
                    <button
                      className={cn(
                        "flex h-7 w-7 items-center justify-center rounded-lg text-muted-foreground transition-colors hover:bg-accent hover:text-foreground",
                        dockOpen && "bg-accent text-primary",
                      )}
                      onClick={() => setDockOpen(!dockOpen)}
                      title="终端输出"
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
                    终端输出 · {convAgentName}
                  </span>
                  <div className="flex items-center gap-1.5">
                    <Button variant="ghost" size="sm" className="h-6 px-2 text-xs" onClick={handleClearTerminal}>
                      清空
                    </Button>
                    <Button variant="ghost" size="sm" className="h-6 px-2 text-xs" onClick={() => setDockOpen(false)}>
                      收起
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
        )}
      </main>
    </div>
  );
}

// ─── 设置视图（齿轮）：机器信息 + 配对（授权入口在 composer 工具栏） ─────────

function SettingsView({
  status,
  pairing,
  copied,
  runtimeState,
  onReveal,
  onRegenerate,
  onCopy,
  onClose,
}: {
  status: DesktopStatus | null;
  pairing: PairingInfo | null;
  copied: boolean;
  runtimeState: RuntimeState;
  onReveal: () => void;
  onRegenerate: () => void;
  onCopy: () => void;
  onClose: () => void;
}) {
  const expiry = pairing?.expiresAt ? new Date(pairing.expiresAt).toLocaleTimeString() : null;

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      {/* 标题行：与内容同底色、无分隔线，自然融合 */}
      <div className="flex h-11 shrink-0 items-center justify-between px-4">
        <span className="text-sm font-medium text-foreground">设置与配对</span>
        <button
          className="flex items-center gap-1 rounded-md px-2 py-1 text-xs text-muted-foreground hover:bg-accent hover:text-foreground"
          onClick={onClose}
        >
          <CornerUpLeft size={13} />
          返回对话
        </button>
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto panel-scroll px-3.5 py-3">
        <div className="mx-auto flex w-full max-w-md flex-col gap-3.5">
          {/* ── 机器信息 ── */}
          <section className="rounded-lg border border-border bg-card p-3">
            <div className="mb-2 text-[10px] font-semibold uppercase tracking-[0.6px] text-muted-foreground">
              本机信息
            </div>
            <dl className="grid grid-cols-[84px_1fr] gap-y-1.5 text-xs">
              <dt className="text-muted-foreground">设备名</dt>
              <dd className="select-text truncate text-foreground">{status?.host ?? "—"}</dd>
              <dt className="text-muted-foreground">设备 ID</dt>
              <dd className="select-text truncate font-mono text-foreground">{status?.deviceId ?? "—"}</dd>
              <dt className="text-muted-foreground">局域网地址</dt>
              <dd className="select-text truncate font-mono text-foreground">
                {status ? `http://${status.lanIp}:${status.port}` : "—"}
              </dd>
              <dt className="text-muted-foreground">mDNS 广播</dt>
              <dd className="text-foreground">{status?.mdnsRunning ? "运行中" : "未运行"}</dd>
              <dt className="text-muted-foreground">平台 / 版本</dt>
              <dd className="text-foreground">
                {status?.platform ?? "—"} · v{status?.version ?? "—"}
              </dd>
              <dt className="text-muted-foreground">服务状态</dt>
              <dd className="text-foreground">{runtimeState}</dd>
            </dl>
            <div className="mt-2 border-t border-border pt-2 text-[10px] leading-relaxed text-muted-foreground/65">
              iPhone / Apple Watch 通过同一局域网访问上面的地址；手机端 App 扫下方二维码即可配对。
            </div>
          </section>

          {/* ── 配对 ── */}
          <section className="rounded-lg border border-border bg-card p-3">
            <div className="mb-2 text-[10px] font-semibold uppercase tracking-[0.6px] text-muted-foreground">
              配对（Pairing）
            </div>

            {pairing?.code ? (
              <>
                <div className="flex items-center gap-2">
                  <span className="select-text font-mono text-xl font-semibold tracking-[3px] text-foreground">
                    {pairing.code}
                  </span>
                  <Button variant="outline" size="sm" onClick={onCopy}>
                    {copied ? "已复制" : "复制"}
                  </Button>
                  <Button variant="outline" size="sm" onClick={onRegenerate} title="作废当前码并生成新的">
                    刷新
                  </Button>
                </div>
                {expiry && (
                  <div className="mt-1.5 text-[10px] leading-relaxed text-muted-foreground">
                    过期时间 {expiry}
                  </div>
                )}

                {pairing.url ? (
                  <div className="mt-2.5 flex flex-col items-center gap-1.5">
                    <div className="inline-flex rounded-lg border border-border bg-white p-2 leading-none">
                      <QRCode value={pairing.url} size={148} bgColor="#ffffff" fgColor="#4A3B2D" />
                    </div>
                    <div className="text-[10px] leading-relaxed text-muted-foreground">
                      用 iPhone 上的 BrewPing 扫码
                    </div>
                    <div className="break-all text-[10px] leading-relaxed text-muted-foreground/65">
                      {pairing.url}
                    </div>
                  </div>
                ) : (
                  <div className="mt-1.5 text-[10px] leading-relaxed text-muted-foreground">
                    等待网络就绪…
                  </div>
                )}

                <div className="mt-1.5 break-all text-[10px] leading-relaxed text-muted-foreground/65">
                  也可以在 iPhone 的 BrewPing 里手动输入这个 6 位码。
                </div>
              </>
            ) : (
              <>
                <Button variant="default" className="w-full" onClick={onReveal}>
                  显示配对码
                </Button>
                <div className="mt-1.5 break-all text-[10px] leading-relaxed text-muted-foreground/65">
                  配对码只在需要时生成，10 分钟内有效且一次性。
                  iPhone 用它换取长期访问令牌。
                </div>
              </>
            )}
          </section>

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
