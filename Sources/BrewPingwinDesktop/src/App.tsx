import { useEffect, useState, useCallback, useRef } from "react";
import { listen } from "@tauri-apps/api/event";
import QRCode from "react-qr-code";
import {
  Bot,
  ChevronDown,
  Cpu,
  ShieldCheck,
  ShieldAlert,
  SquareTerminal,
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
  getPendingApprovals,
  decideApproval,
  sendCommand,
  clearTerminal,
  getAgentModels,
  setDefaultModel,
} from "./api/tauri";
import type {
  DesktopStatus,
  AgentTerminalState,
  PairingInfo,
  ApprovalMode,
  PendingApproval,
  RuntimeState,
  AgentModelsInfo,
} from "./api/types";
import { Button } from "./components/ui/button";
import { Badge } from "./components/ui/badge";
import {
  ChatView,
  MessageList,
  buildMessages,
  deriveTitle,
  COMPOSER_PILL_CLASS,
  COMPOSER_SELECT_CLASS,
} from "./components/chat/chat-view";
import { cn } from "./lib/utils";
import "./styles/app.css";

/// 危险 code → 中文文案。与 Rust 侧 `DangerPattern` 的 code 一一对应，
/// 未知 code 兜底显示 detail（与 iOS 端 `localizedReasons()` 的策略一致）。
const DANGER_LABELS: Record<string, string> = {
  rm_root: "删除根目录（rm -rf /）",
  recursive_delete: "递归删除（rm -rf）",
  force_push: "强制推送（git push --force）",
  git_reset_hard: "硬重置（git reset --hard）",
  pipe_to_shell: "管道执行远程脚本（curl | sh）",
  sudo: "提权（sudo）",
  chmod_777: "开放全部权限（chmod 777）",
  write_device: "写入设备文件（> /dev/）",
  dd_disk: "磁盘裸写（dd if=）",
  drop_table: "删除数据表（DROP TABLE）",
  truncate_table: "清空数据表（TRUNCATE TABLE）",
  ask_all: "所有命令都需确认（askAll 模式）",
};

function dangerText(code: string, detail: string): string {
  return DANGER_LABELS[code] ?? (detail || code);
}

const APPROVAL_MODES: Array<{ id: ApprovalMode; label: string; summary: string }> = [
  { id: "safe", label: "safe", summary: "只拦截危险命令（默认）" },
  { id: "askAll", label: "askAll", summary: "每条命令都要确认" },
  { id: "auto", label: "auto", summary: "全程免确认" },
];

// ─── 历史归档（前端内存态：新对话时快照当前会话） ──────────────────────────────

interface ArchivedConversation {
  id: string;
  agentId: string;
  agentName: string;
  title: string;
  timestamp: number;
  messages: ReturnType<typeof buildMessages>;
}

type MainView = "chat" | "settings" | { archiveId: string };

export default function App() {
  const [status, setStatus] = useState<DesktopStatus | null>(null);
  const [terminals, setTerminals] = useState<AgentTerminalState[]>([]);
  const [activeAgentId, setActiveAgentId] = useState<string>("opencode");
  const [loading, setLoading] = useState(true);
  const [view, setView] = useState<MainView>("chat");
  const [pairing, setPairing] = useState<PairingInfo | null>(null);
  const [approvalMode, setApprovalModeState] = useState<ApprovalMode>("safe");
  const [pending, setPending] = useState<PendingApproval[]>([]);
  const [models, setModels] = useState<AgentModelsInfo | null>(null);
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [dockOpen, setDockOpen] = useState(false);
  const [history, setHistory] = useState<ArchivedConversation[]>([]);
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

  /// 配对信息 + 授权模式 + 待确认队列：与后端同一个进程内状态，
  /// 手机端批准后这里也会在下一个轮询周期同步到。
  const refreshSecurity = useCallback(async () => {
    try {
      const [info, mode, list] = await Promise.all([
        getPairingInfo(),
        getApprovalMode(),
        getPendingApprovals(),
      ]);
      setPairing(info);
      setApprovalModeState(mode as ApprovalMode);
      setPending(list);
    } catch {
      // 后端尚未就绪（Starting…）时静默重试
    }
  }, []);

  // Initial load
  useEffect(() => {
    const init = async () => {
      await Promise.all([refreshStatus(), refreshTerminal(), refreshSecurity()]);
      setLoading(false);
    };
    init();
  }, [refreshStatus, refreshTerminal, refreshSecurity]);

  // Poll: status/security 5s；终端 2s（事件为主，轮询兜底防丢事件）
  useEffect(() => {
    const timer = setInterval(() => {
      refreshStatus();
      refreshSecurity();
    }, 5000);
    const terminalTimer = setInterval(refreshTerminal, 2000);
    return () => {
      clearInterval(timer);
      clearInterval(terminalTimer);
    };
  }, [refreshStatus, refreshSecurity, refreshTerminal]);

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

    return () => {
      unlistenOutput.then((fn) => fn());
      unlistenAgent.then((fn) => fn());
      unlistenRuntime.then((fn) => fn());
      unlistenPairing.then((fn) => fn());
      unlistenRefresh.then((fn) => fn());
    };
  }, [refreshTerminal, refreshStatus, refreshSecurity]);

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
      await sendCommand(text);
      // 事件之外再主动刷一次，保证用户气泡立刻可见
      await refreshTerminal();
    });

  const handleSwitchAgent = (agentId: string) =>
    runQuietly(async () => {
      if (agentId === activeAgentId) return;
      await switchActiveAgent(agentId);
      setActiveAgentId(agentId);
      await refreshTerminal();
    });

  const handleSelectModel = (modelId: string) =>
    runQuietly(async () => {
      await setDefaultModel(activeAgentId, modelId === "" ? null : modelId);
      await refreshModels(activeAgentId);
    });

  const handleSetApprovalMode = (mode: ApprovalMode) =>
    runQuietly(async () => {
      setApprovalModeState(mode);
      const applied = await setApprovalMode(mode);
      setApprovalModeState(applied as ApprovalMode);
      await refreshSecurity();
    });

  const handleDecide = (id: string, action: "approve" | "deny" | "always_approve") =>
    runQuietly(async () => {
      await decideApproval(id, action);
      await refreshSecurity();
      await refreshTerminal();
    });

  const handleClearTerminal = () =>
    runQuietly(() => clearTerminal(activeAgentId));

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

  /// 「新对话」：把当前会话快照进历史（有内容才归档），然后清空终端重开。
  const handleNewConversation = () =>
    runQuietly(async () => {
      const activeTerminal =
        terminals.find((t) => t.agentId === activeAgentId) ?? null;
      const snapshot = activeTerminal
        ? buildMessages(activeTerminal.outputLines)
        : [];
      if (snapshot.length > 0) {
        const arch: ArchivedConversation = {
          id: `arch_${Date.now()}`,
          agentId: activeAgentId,
          agentName: activeTerminal?.agentName ?? activeAgentId,
          title: deriveTitle(snapshot),
          timestamp: Date.now(),
          messages: snapshot,
        };
        setHistory((prev) => [arch, ...prev]);
      }
      await clearTerminal(activeAgentId);
      await refreshTerminal();
      setView("chat");
    });

  // ─── Derived State ──────────────────────────────────────────────────────

  const activeTerminal = terminals.find((t) => t.agentId === activeAgentId) ?? null;
  const activeAgentName = activeTerminal?.agentName ?? activeAgentId;
  const runtimeState: RuntimeState = status?.runtimeState ?? "idle";
  const installedAgents = (status?.agents ?? []).filter((a) => a.installed);
  // 所有 provider 的模型摊平（模型 id 冲突时保留 provider 前缀展示，值仍用 id）
  const modelOptions = (models?.providers ?? []).flatMap((p) =>
    p.models.map((m) => ({ id: m.id, name: m.name, provider: p.name })),
  );
  const currentModelId =
    models?.preferredModelId ?? models?.activeModelId ?? "";
  const viewingArchive =
    typeof view === "object" ? history.find((h) => h.id === view.archiveId) ?? null : null;

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

  return (
    <div className="flex h-svh w-full overflow-hidden bg-background">
      {/* ─── 左侧边栏 ─────────────────────────────────────────────────────── */}
      <aside className="flex h-full w-52 shrink-0 flex-col border-r border-border bg-card">
        {/* 品牌行 */}
        <div className="flex h-11 shrink-0 items-center gap-1.5 border-b border-border px-3.5">
          <span className="text-[11px]">☕</span>
          <span className="font-mono text-[11px] font-semibold text-primary/90">BrewPing</span>
          <span className="ml-auto flex items-center gap-1">
            <span className={`runtime-dot h-1.5 w-1.5 ${runtimeState === "online" ? "online" : runtimeState === "starting" ? "starting" : "offline"}`} />
            <span className="text-[9px] text-muted-foreground">
              {runtimeState === "online" ? "ONLINE" : runtimeState === "starting" ? "STARTING…" : "OFFLINE"}
            </span>
          </span>
        </div>

        {/* 新对话 */}
        <div className="p-2.5">
          <Button variant="default" className="w-full" onClick={handleNewConversation}>
            + 新对话
          </Button>
        </div>

        {/* 历史对话列表 */}
        <div className="min-h-0 flex-1 overflow-y-auto panel-scroll px-2 pb-2">
          <div className="px-1.5 pb-1 pt-1 text-[10px] font-semibold uppercase tracking-[0.6px] text-muted-foreground">
            历史对话
          </div>
          {history.length === 0 ? (
            <div className="px-1.5 text-[10px] leading-relaxed text-muted-foreground/60">
              点「新对话」会归档当前会话并开始新的
            </div>
          ) : (
            history.map((h) => (
              <button
                key={h.id}
                className={cn(
                  "mb-0.5 w-full rounded-md px-1.5 py-1.5 text-left hover:bg-accent",
                  typeof view === "object" && view.archiveId === h.id &&
                    "bg-accent font-medium",
                )}
                onClick={() => setView({ archiveId: h.id })}
              >
                <div className="truncate text-xs text-foreground">{h.title}</div>
                <div className="mt-0.5 flex items-center gap-1 text-[9px] text-muted-foreground">
                  <span>{h.agentName}</span>
                  <span>·</span>
                  <span>
                    {new Date(h.timestamp).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}
                  </span>
                </div>
              </button>
            ))
          )}
        </div>

        {/* 底部：齿轮（设置 + 配对 + 授权详情） */}
        <div className="shrink-0 border-t border-border p-2.5">
          <button
            className={cn(
              "flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-xs text-muted-foreground hover:bg-accent hover:text-foreground",
              view === "settings" && "bg-accent font-medium text-foreground",
            )}
            onClick={() => setView(view === "settings" ? "chat" : "settings")}
            title="机器信息 / 配对码 / 授权设置"
          >
            <span className="text-sm leading-none">⚙</span>
            <span>设置与配对</span>
            {pending.length > 0 && (
              <Badge variant="warning" className="ml-auto h-3.5 min-w-3.5 px-1 text-[9px] leading-none">
                {pending.length}
              </Badge>
            )}
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
            approvalMode={approvalMode}
            pending={pending}
            runtimeState={runtimeState}
            onReveal={handleRevealPairing}
            onRegenerate={handleRegeneratePairing}
            onCopy={handleCopyCode}
            onSetMode={handleSetApprovalMode}
            onDecide={handleDecide}
            onClose={() => setView("chat")}
          />
        ) : viewingArchive ? (
          <div className="flex min-h-0 flex-1 flex-col">
            <div className="flex h-9 shrink-0 items-center justify-between border-b border-border bg-card px-3.5">
              <span className="truncate text-[10px] font-semibold uppercase tracking-[0.6px] text-muted-foreground">
                历史对话 · {viewingArchive.agentName} · {viewingArchive.title}
              </span>
              <Button variant="ghost" size="sm" className="h-6 px-2 text-xs" onClick={() => setView("chat")}>
                返回当前对话
              </Button>
            </div>
            <div className="min-h-0 flex-1 overflow-y-auto py-4 panel-scroll">
              <MessageList
                messages={viewingArchive.messages}
                agentName={viewingArchive.agentName}
                isStreaming={false}
              />
            </div>
          </div>
        ) : (
          <>
            <ChatView
              terminal={activeTerminal}
              agentName={activeAgentName}
              onSend={handleSend}
              composerToolbar={
                <div className="flex min-w-0 flex-1 items-center gap-0.5">
                  {/* 切换 Agent */}
                  <label className={COMPOSER_PILL_CLASS} title="切换 Agent">
                    <Bot size={14} className="shrink-0" />
                    <select
                      className={COMPOSER_SELECT_CLASS}
                      value={activeAgentId}
                      onChange={(e) => handleSwitchAgent(e.target.value)}
                    >
                      {installedAgents.length === 0 && (
                        <option value={activeAgentId}>{activeAgentName}</option>
                      )}
                      {installedAgents.map((a) => (
                        <option key={a.id} value={a.id}>
                          {a.name}
                        </option>
                      ))}
                    </select>
                    <ChevronDown size={12} className="shrink-0 opacity-60" />
                  </label>

                  {/* 切换模型（agent 没有可用模型时隐藏） */}
                  {modelOptions.length > 0 && (
                    <label className={COMPOSER_PILL_CLASS} title="选择模型">
                      <Cpu size={14} className="shrink-0" />
                      <select
                        className={cn(COMPOSER_SELECT_CLASS, "max-w-44")}
                        value={currentModelId}
                        onChange={(e) => handleSelectModel(e.target.value)}
                      >
                        <option value="">跟随 Agent 配置</option>
                        {modelOptions.map((m) => (
                          <option key={m.id} value={m.id}>
                            {m.name} · {m.provider}
                          </option>
                        ))}
                      </select>
                      <ChevronDown size={12} className="shrink-0 opacity-60" />
                    </label>
                  )}

                  {/* 切换授权模式 */}
                  <label
                    className={cn(
                      COMPOSER_PILL_CLASS,
                      approvalMode === "askAll" && "text-warning",
                      approvalMode === "auto" && "text-success",
                    )}
                    title="授权模式"
                  >
                    <ShieldCheck size={14} className="shrink-0" />
                    <select
                      className={COMPOSER_SELECT_CLASS}
                      value={approvalMode}
                      onChange={(e) => handleSetApprovalMode(e.target.value as ApprovalMode)}
                    >
                      {APPROVAL_MODES.map((m) => (
                        <option key={m.id} value={m.id}>
                          授权 {m.label}
                        </option>
                      ))}
                    </select>
                    <ChevronDown size={12} className="shrink-0 opacity-60" />
                  </label>

                  <div className="ml-auto flex items-center gap-1">
                    {pending.length > 0 && (
                      <button
                        className="flex h-7 items-center gap-1 rounded-lg px-2 text-xs font-medium text-warning hover:bg-warning/10"
                        onClick={() => setView("settings")}
                        title="有命令待确认，去设置页处理"
                      >
                        <ShieldAlert size={14} className="shrink-0" />
                        待确认 {pending.length}
                      </button>
                    )}
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

            {/* 终端 dock：可折叠 */}
            {dockOpen && (
              <div className="flex h-56 shrink-0 flex-col border-t border-border bg-card">
                <div className="flex h-9 shrink-0 items-center justify-between border-b border-border/60 px-3.5">
                  <span className="text-[10px] font-semibold uppercase tracking-[0.6px] text-muted-foreground">
                    终端输出 · {activeAgentName}
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

// ─── 设置视图（齿轮）：机器信息 + 配对 + 授权详情 ─────────────────────────────

function SettingsView({
  status,
  pairing,
  copied,
  approvalMode,
  pending,
  runtimeState,
  onReveal,
  onRegenerate,
  onCopy,
  onSetMode,
  onDecide,
  onClose,
}: {
  status: DesktopStatus | null;
  pairing: PairingInfo | null;
  copied: boolean;
  approvalMode: ApprovalMode;
  pending: PendingApproval[];
  runtimeState: RuntimeState;
  onReveal: () => void;
  onRegenerate: () => void;
  onCopy: () => void;
  onSetMode: (mode: ApprovalMode) => void;
  onDecide: (id: string, action: "approve" | "deny" | "always_approve") => void;
  onClose: () => void;
}) {
  const expiry = pairing?.expiresAt ? new Date(pairing.expiresAt).toLocaleTimeString() : null;

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      {/* 标题行 */}
      <div className="flex h-11 shrink-0 items-center justify-between border-b border-border bg-card px-3.5">
        <span className="text-[10px] font-semibold uppercase tracking-[0.6px] text-primary/80">
          设置与配对
        </span>
        <Button variant="ghost" size="sm" className="h-7 px-2 text-xs" onClick={onClose}>
          返回对话
        </Button>
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

          {/* ── 授权 ── */}
          <section className="rounded-lg border border-border bg-card p-3">
            <div className="mb-2 text-[10px] font-semibold uppercase tracking-[0.6px] text-muted-foreground">
              授权（Approval）
            </div>

            <div className="flex gap-1.5">
              {APPROVAL_MODES.map((item) => {
                const active = approvalMode === item.id;
                return (
                  <Button
                    key={item.id}
                    variant={active ? "secondary" : "outline"}
                    size="sm"
                    className={cn(active && "border-primary/45 bg-primary/10 font-semibold text-primary")}
                    onClick={() => onSetMode(item.id)}
                    title={item.summary}
                  >
                    {item.label}
                  </Button>
                );
              })}
            </div>
            <div className="mt-1.5 break-all text-[10px] leading-relaxed text-muted-foreground/65">
              {APPROVAL_MODES.find((m) => m.id === approvalMode)?.summary ?? ""}
            </div>

            <div className="mb-2 mt-3 border-t border-border pt-2.5 text-[10px] font-semibold uppercase tracking-[0.6px] text-muted-foreground">
              待确认命令 {pending.length > 0 ? `(${pending.length})` : ""}
            </div>

            {pending.length === 0 ? (
              <div className="break-all text-[10px] leading-relaxed text-muted-foreground/65">
                暂无挂起命令。
              </div>
            ) : (
              pending.map((approval) => (
                <div
                  key={approval.id}
                  className="mt-2 rounded-md border border-warning/35 bg-warning/5 p-2"
                >
                  <div className="select-text break-all whitespace-pre-wrap text-[11px] text-foreground">
                    {approval.text}
                  </div>
                  <div className="mt-1.5 flex flex-wrap gap-1">
                    {approval.reasons.map((reason) => (
                      <Badge key={reason.code} variant="warning" className="px-1.5 py-0.5 text-[9px]">
                        {dangerText(reason.code, reason.detail)}
                      </Badge>
                    ))}
                  </div>
                  <div className="mt-2 flex gap-1.5">
                    <Button variant="default" size="sm" onClick={() => onDecide(approval.id, "approve")}>
                      批准
                    </Button>
                    <Button variant="outline" size="sm" onClick={() => onDecide(approval.id, "always_approve")}>
                      总是允许
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      className="border-destructive/50 text-destructive hover:bg-destructive/10 hover:text-destructive"
                      onClick={() => onDecide(approval.id, "deny")}
                    >
                      拒绝
                    </Button>
                  </div>
                </div>
              ))
            )}

            <div className="mt-1.5 break-all text-[10px] leading-relaxed text-muted-foreground/65">
              挂起命令 5 分钟内未处理会自动作废（不会执行）。
            </div>
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
