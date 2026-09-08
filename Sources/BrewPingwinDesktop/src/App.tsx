import { useEffect, useState, useCallback, useRef } from "react";
import { listen } from "@tauri-apps/api/event";
import {
  getStatus,
  getTerminalState,
  switchActiveAgent,
  sendCommand,
  clearTerminal,
} from "./api/tauri";
import type { DesktopStatus, AgentTerminalState } from "./api/types";
import "./styles/app.css";

export default function App() {
  const [status, setStatus] = useState<DesktopStatus | null>(null);
  const [terminals, setTerminals] = useState<AgentTerminalState[]>([]);
  const [activeAgentId, setActiveAgentId] = useState<string>("opencode");
  const [inputText, setInputText] = useState("");
  const [loading, setLoading] = useState(true);
  const inputRef = useRef<HTMLInputElement>(null);
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

  // Initial load
  useEffect(() => {
    const init = async () => {
      await Promise.all([refreshStatus(), refreshTerminal()]);
      setLoading(false);
    };
    init();
  }, [refreshStatus, refreshTerminal]);

  // Poll status every 5 seconds (matches macOS)
  useEffect(() => {
    const timer = setInterval(refreshStatus, 5000);
    return () => clearInterval(timer);
  }, [refreshStatus]);

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

    return () => {
      unlistenOutput.then((fn) => fn());
      unlistenAgent.then((fn) => fn());
    };
  }, [refreshTerminal]);

  // Auto-scroll to bottom on new output
  useEffect(() => {
    if (outputRef.current) {
      const el = outputRef.current;
      el.scrollTop = el.scrollHeight;
    }
  }, [terminals]);

  // Focus input on mount
  useEffect(() => {
    if (!loading && inputRef.current) {
      inputRef.current.focus();
    }
  }, [loading]);

  // ─── Actions ────────────────────────────────────────────────────────────

  const handleSwitchAgent = async (agentId: string) => {
    if (agentId === activeAgentId) return;
    await switchActiveAgent(agentId);
    setActiveAgentId(agentId);
    await refreshTerminal();
  };

  const handleSend = async () => {
    const trimmed = inputText.trim();
    if (!trimmed) return;
    setInputText("");
    await sendCommand(trimmed);
    await refreshTerminal();
    // Re-focus input
    inputRef.current?.focus();
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter") {
      handleSend();
    }
  };

  // ─── Derived State ──────────────────────────────────────────────────────

  const activeTerminal = terminals.find((t) => t.agentId === activeAgentId);
  const installedAgents = status?.agents.filter((a) => a.installed) ?? [];
  const hasInput = inputText.trim().length > 0;

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

        <div className="online-indicator">
          <span className="dot" />
          <span className="label">ONLINE</span>
        </div>
      </div>

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

      {/* ─── Input Bar (matches macOS inputBar) ───────────────────────── */}
      {/* TODO: 暂时隐藏输入栏，后续启用
      <div className="input-bar">
        <span className="prompt-char">❯</span>
        <input
          ref={inputRef}
          type="text"
          value={inputText}
          onChange={(e) => setInputText(e.target.value)}
          onKeyDown={handleKeyDown}
          placeholder="Type a command..."
          spellCheck={false}
          autoComplete="off"
        />
        <button
          className={`send-btn ${hasInput ? "enabled" : ""}`}
          onClick={handleSend}
          disabled={!hasInput}
        >
          SEND
        </button>
      </div>
      */}
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
