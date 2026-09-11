import { useEffect, useState, useCallback, useRef } from "react";
import { listen } from "@tauri-apps/api/event";
import QRCode from "react-qr-code";
import {
  Archive,
  ArchiveRestore,
  Bot,
  CornerUpLeft,
  Cpu,
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
  setDefaultModel,
  listConversations,
  getConversation,
  activateConversation,
  setConversationArchived,
  deleteConversation,
  togglePinConversation,
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
} from "./api/types";
import { Button } from "./components/ui/button";
import { ChatView, fromTranscript } from "./components/chat/chat-view";
import { ComposerDropdown } from "./components/chat/composer-dropdown";
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
  const [activeConvId, setActiveConvId] = useState<string | null>(null);
  const [activeConv, setActiveConv] = useState<Conversation | null>(null);
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const outputRef = useRef<HTMLDivElement>(null);

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
      setActiveConv(await getConversation(id));
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
          setActiveConvId(st.activeConversationId);
          setActiveConv(await getConversation(st.activeConversationId));
        }
      } catch {
        // ignore
      }
      setLoading(false);
    };
    void init();
  }, [refreshStatus, refreshTerminal, refreshSecurity, refreshConversations, fetchConversation]);

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
      // 当前对话内容变了（消息追加）→ 同步转录
      setActiveConvId((id) => {
        if (id) void fetchConversation(id);
        return id;
      });
    });
    const unlistenActiveConv = listen("active-conversation-changed", (event) => {
      const id = (event.payload as string | null) ?? null;
      setActiveConvId(id);
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
      unlistenActiveConv.then((fn) => fn());
    };
  }, [refreshTerminal, refreshStatus, refreshSecurity, refreshConversations, fetchConversation]);

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
      // conversationId = null（草稿态）时后端创建新对话并激活，返回对话 ID
      const convId = await sendCommand(text, activeConvId);
      setActiveConvId(convId);
      await refreshConversations();
      setActiveConv(await getConversation(convId));
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
        setActiveConvId(null);
        setActiveConv(null);
      }
    });

  const handleSelectModel = (modelId: string) =>
    runQuietly(async () => {
      const agentForModel = activeConv?.agentId ?? activeAgentId;
      await setDefaultModel(agentForModel, modelId === "" ? null : modelId);
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
  /// 发送首条消息时后端才物化对话。旧对话保留，侧栏可切回。
  const handleNewConversation = () => {
    setActiveConvId(null);
    setActiveConv(null);
    setView("chat");
  };

  const handleOpenConversation = (id: string) =>
    runQuietly(async () => {
      await activateConversation(id);
      setActiveConvId(id);
      setActiveConv(await getConversation(id));
      setView("chat");
    });

  const handleArchiveConversation = (id: string) =>
    runQuietly(async () => {
      await setConversationArchived(id, true);
      // 归档 active → 后端已清 active 指针；本地同步回草稿态
      if (id === activeConvId) {
        setActiveConvId(null);
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
  // 所有 provider 的模型摊平。⚠️ 不同 provider 会暴露相同模型 id（如
  // mimo-v2.5-pro 同时来自 OpenCode Go 与小米 Token Plan），因此下拉项 key
  // 必须带 provider 前缀（否则两条都显示选中勾），提交时再还原成原始 id。
  const modelOptions = (models?.providers ?? []).flatMap((p) =>
    p.models.map((m) => ({
      key: `${p.id}::${m.id}`,
      id: m.id,
      name: m.name,
      provider: p.name,
    })),
  );
  const currentModelId =
    models?.preferredModelId ?? models?.activeModelId ?? "";
  // 选中判定用 provider 唯一 key；同 id 多 provider 时只勾第一个（后端
  // preferredModelId 不带 provider 信息，无法区分，展示顺序取第一个命中）。
  const currentModelKey =
    modelOptions.find((m) => m.id === currentModelId)?.key ?? "";

  // 侧栏三区：置顶 / 常规 / 归档（后端已按 pinned 优先 + 最新活动排好）
  const activeConversations = conversations.filter((c) => !c.archived);
  const archivedConversations = conversations.filter((c) => c.archived);

  // busy：调度指针在飞（方案 §2-A4）或终端在跑
  const isBusy =
    activeConv?.latestCommandId != null || activeTerminal?.status === "running";
  const messages = fromTranscript(activeConv?.messages ?? []);
  const draft = drafts[activeConvId ?? DRAFT_KEY] ?? "";

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

        {/* 对话列表：置顶区 + 常规区 + 归档区 */}
        <div className="min-h-0 flex-1 overflow-y-auto panel-scroll px-2 pb-2">
          {activeConversations.length === 0 ? (
            <div className="px-1.5 pt-1 text-[10px] leading-relaxed text-muted-foreground/60">
              还没有对话。发一条消息即自动创建。
            </div>
          ) : (
            <>
              {activeConversations.some((c) => c.isPinned) && (
                <div className="px-1.5 pb-1 pt-2 text-[10px] font-semibold uppercase tracking-[0.6px] text-muted-foreground">
                  置顶
                </div>
              )}
              {activeConversations
                .filter((c) => c.isPinned)
                .map((c) => renderConversationItem(c, false))}
              {activeConversations.some((c) => !c.isPinned) && (
                <div className="px-1.5 pb-1 pt-2 text-[10px] font-semibold uppercase tracking-[0.6px] text-muted-foreground">
                  对话
                </div>
              )}
              {activeConversations
                .filter((c) => !c.isPinned)
                .map((c) => renderConversationItem(c, false))}
            </>
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
                      onChange={(key) => {
                        // 还原成原始模型 id 再提交（setDefaultModel 只认 id）
                        const hit = modelOptions.find((m) => m.key === key);
                        handleSelectModel(hit ? hit.id : "");
                      }}
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
