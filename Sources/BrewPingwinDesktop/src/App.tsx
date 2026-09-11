import { useEffect, useState, useCallback, useRef } from "react";
import { listen } from "@tauri-apps/api/event";
import QRCode from "react-qr-code";
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
} from "./api/tauri";
import type {
  DesktopStatus,
  AgentTerminalState,
  PairingInfo,
  ApprovalMode,
  PendingApproval,
  RuntimeState,
} from "./api/types";
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

export default function App() {
  const [status, setStatus] = useState<DesktopStatus | null>(null);
  const [terminals, setTerminals] = useState<AgentTerminalState[]>([]);
  const [activeAgentId, setActiveAgentId] = useState<string>("opencode");
  const [loading, setLoading] = useState(true);
  const [panel, setPanel] = useState<"pairing" | "approval" | null>(null);
  const [pairing, setPairing] = useState<PairingInfo | null>(null);
  const [approvalMode, setApprovalModeState] = useState<ApprovalMode>("safe");
  const [pending, setPending] = useState<PendingApproval[]>([]);
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState<string | null>(null);
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

  // Poll status every 5 seconds (matches macOS)
  useEffect(() => {
    const timer = setInterval(() => {
      refreshStatus();
      refreshSecurity();
    }, 5000);
    return () => clearInterval(timer);
  }, [refreshStatus, refreshSecurity]);

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
    // 托盘「显示配对码」→ 自动展开配对面板
    const unlistenPairing = listen("pairing-revealed", () => {
      setPanel("pairing");
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

  // Auto-scroll to bottom on new output
  useEffect(() => {
    if (outputRef.current) {
      const el = outputRef.current;
      el.scrollTop = el.scrollHeight;
    }
  }, [terminals]);

  // ─── Actions ────────────────────────────────────────────────────────────

  const handleSwitchAgent = async (agentId: string) => {
    if (agentId === activeAgentId) return;
    await switchActiveAgent(agentId);
    setActiveAgentId(agentId);
    await refreshTerminal();
  };

  const runQuietly = async (action: () => Promise<void>) => {
    try {
      setError(null);
      await action();
    } catch (e) {
      setError(String(e));
    }
  };

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

  // ─── Derived State ──────────────────────────────────────────────────────

  const activeTerminal = terminals.find((t) => t.agentId === activeAgentId);
  const runtimeState: RuntimeState = status?.runtimeState ?? "idle";

  if (loading) {
    return (
      <div className="app-shell">
        <div className="no-agent-placeholder">
          <span className="prompt">brewping ❯ </span>
          <span className="message">Starting BrewPing Desktop...</span>
        </div>
      </div>
    );
  }

  return (
    <div className="app-shell">
      {/* ─── Agent Tab Bar (matches macOS AgentTabView) ───────────────── */}
      <div className="agent-tab-bar">
        <div className="logo">
          <span className="emoji">☕</span>
          <span className="brand">BrewPing</span>
        </div>

        <div className="tabs">
          {terminals.map((term) => (
            <button
              key={term.agentId}
              className={`agent-tab ${term.agentId === activeAgentId ? "active" : ""}`}
              onClick={() => handleSwitchAgent(term.agentId)}
            >
              <span className={`status-dot ${term.status}`} />
              <span>{term.agentName}</span>
            </button>
          ))}
        </div>

        <RuntimeBadge state={runtimeState} />

        <button
          className={`bar-btn ${panel === "approval" ? "active" : ""} ${pending.length > 0 ? "alert" : ""}`}
          onClick={() => setPanel(panel === "approval" ? null : "approval")}
          title="授权模式与待确认命令"
        >
          授权：{approvalMode}
          {pending.length > 0 && <span className="badge-count">{pending.length}</span>}
        </button>

        <button
          className={`bar-btn ${panel === "pairing" ? "active" : ""}`}
          onClick={() => setPanel(panel === "pairing" ? null : "pairing")}
          title="配对码与二维码"
        >
          配对
        </button>
      </div>

      {/* ─── Panels ───────────────────────────────────────────────────── */}
      {error && (
        <div className="panel-error" onClick={() => setError(null)}>
          {error}
        </div>
      )}

      {panel === "pairing" && (
        <PairingPanel
          pairing={pairing}
          copied={copied}
          onReveal={handleRevealPairing}
          onRegenerate={handleRegeneratePairing}
          onCopy={handleCopyCode}
        />
      )}

      {panel === "approval" && (
        <ApprovalPanel
          mode={approvalMode}
          pending={pending}
          onSetMode={handleSetApprovalMode}
          onDecide={handleDecide}
        />
      )}

      {/* ─── Terminal Output Area ─────────────────────────────────────── */}
      {activeTerminal ? (
        <div className="terminal-output" ref={outputRef}>
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
            <>
              {activeTerminal.outputLines.map((line) => (
                <OutputLineView key={line.id} line={line} />
              ))}
            </>
          )}
          <div className="blinking-cursor">█</div>
          <div className="scanline-overlay" />
        </div>
      ) : (
        <div className="no-agent-placeholder">
          <span className="prompt">brewping ❯ </span>
          <span className="message">No agents available</span>
          <span className="hint">Install opencode, claude, or codex to get started</span>
        </div>
      )}
    </div>
  );
}

// ─── Runtime State Badge ─────────────────────────────────────────────────────

/// 启动期间显示灰点 + "STARTING…"，让用户区分"还没好"和"真的没起来"。
/// 与 macOS `MenuBarView.runtimeBadge` 的语义一致。
function RuntimeBadge({ state }: { state: RuntimeState }) {
  const map: Record<RuntimeState, { dot: string; label: string }> = {
    online: { dot: "online", label: "ONLINE" },
    starting: { dot: "starting", label: "STARTING…" },
    offline: { dot: "offline", label: "OFFLINE" },
    idle: { dot: "offline", label: "OFFLINE" },
  };
  const view = map[state] ?? map.idle;
  return (
    <div className="runtime-badge">
      <span className={`dot ${view.dot}`} />
      <span className={`label ${view.dot}`}>{view.label}</span>
    </div>
  );
}

// ─── Pairing Panel (对齐 macOS MenuBarView 的 Pairing 区块) ───────────────────

function PairingPanel({
  pairing,
  copied,
  onReveal,
  onRegenerate,
  onCopy,
}: {
  pairing: PairingInfo | null;
  copied: boolean;
  onReveal: () => void;
  onRegenerate: () => void;
  onCopy: () => void;
}) {
  const expiry = pairing?.expiresAt ? new Date(pairing.expiresAt).toLocaleTimeString() : null;

  return (
    <div className="panel">
      <div className="panel-title">配对（Pairing）</div>

      {pairing?.code ? (
        <>
          <div className="pairing-code-row">
            <span className="pairing-code">{pairing.code}</span>
            <button className="panel-btn" onClick={onCopy}>
              {copied ? "已复制" : "复制"}
            </button>
            <button className="panel-btn" onClick={onRegenerate} title="作废当前码并生成新的">
              刷新
            </button>
          </div>
          {expiry && <div className="panel-hint">过期时间 {expiry}</div>}

          {pairing.url ? (
            <div className="qr-wrap">
              <div className="qr-box">
                <QRCode value={pairing.url} size={148} bgColor="#ffffff" fgColor="#000000" />
              </div>
              <div className="panel-hint">用 iPhone 上的 BrewPing 扫码</div>
              <div className="panel-hint dim">{pairing.url}</div>
            </div>
          ) : (
            <div className="panel-hint">等待网络就绪…</div>
          )}

          <div className="panel-hint dim">
            也可以在 iPhone 的 BrewPing 里手动输入这个 6 位码。
          </div>
        </>
      ) : (
        <>
          <button className="panel-btn wide" onClick={onReveal}>
            显示配对码
          </button>
          <div className="panel-hint dim">
            配对码只在需要时生成，10 分钟内有效且一次性。
            iPhone 用它换取长期访问令牌。
          </div>
        </>
      )}
    </div>
  );
}

// ─── Approval Panel (对齐 macOS ApprovalGate) ────────────────────────────────

function ApprovalPanel({
  mode,
  pending,
  onSetMode,
  onDecide,
}: {
  mode: ApprovalMode;
  pending: PendingApproval[];
  onSetMode: (mode: ApprovalMode) => void;
  onDecide: (id: string, action: "approve" | "deny" | "always_approve") => void;
}) {
  return (
    <div className="panel">
      <div className="panel-title">授权（Approval）</div>

      <div className="mode-row">
        {APPROVAL_MODES.map((item) => (
          <button
            key={item.id}
            className={`panel-btn ${mode === item.id ? "active" : ""}`}
            onClick={() => onSetMode(item.id)}
            title={item.summary}
          >
            {item.label}
          </button>
        ))}
      </div>
      <div className="panel-hint dim">
        {APPROVAL_MODES.find((m) => m.id === mode)?.summary ?? ""}
      </div>

      <div className="panel-title sub">
        待确认命令 {pending.length > 0 ? `(${pending.length})` : ""}
      </div>

      {pending.length === 0 ? (
        <div className="panel-hint dim">暂无挂起命令。</div>
      ) : (
        pending.map((approval) => (
          <div key={approval.id} className="approval-item">
            <div className="approval-text">{approval.text}</div>
            <div className="approval-reasons">
              {approval.reasons.map((reason) => (
                <span key={reason.code} className="reason-chip">
                  {dangerText(reason.code, reason.detail)}
                </span>
              ))}
            </div>
            <div className="approval-actions">
              <button className="panel-btn primary" onClick={() => onDecide(approval.id, "approve")}>
                批准
              </button>
              <button className="panel-btn" onClick={() => onDecide(approval.id, "always_approve")}>
                总是允许
              </button>
              <button className="panel-btn danger" onClick={() => onDecide(approval.id, "deny")}>
                拒绝
              </button>
            </div>
          </div>
        ))
      )}

      <div className="panel-hint dim">
        挂起命令 5 分钟内未处理会自动作废（不会执行）。
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
