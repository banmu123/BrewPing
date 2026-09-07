import { useEffect, useState, useCallback } from "react";
import { getStatus, setDefaultAgent } from "./api/tauri";
import type { DesktopStatus } from "./api/types";
import { StatusCard } from "./components/StatusCard";
import { AgentList } from "./components/AgentList";
import { NetworkInfo } from "./components/NetworkInfo";

export default function App() {
  const [status, setStatus] = useState<DesktopStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    try {
      const s = await getStatus();
      setStatus(s);
      setError(null);
    } catch (e) {
      setError(String(e));
    } finally {
      setLoading(false);
    }
  }, []);

  // Poll status every 5 seconds
  useEffect(() => {
    refresh();
    const timer = setInterval(refresh, 5000);
    return () => clearInterval(timer);
  }, [refresh]);

  const handleSetDefault = async (agentId: string) => {
    try {
      await setDefaultAgent(agentId);
      await refresh();
    } catch (e) {
      setError(String(e));
    }
  };

  if (loading) {
    return (
      <div className="app">
        <div className="loading">正在启动 BrewPing Desktop...</div>
      </div>
    );
  }

  return (
    <div className="app">
      <header className="app-header">
        <h1>
          <span className="logo">☕</span> BrewPing Desktop
        </h1>
        <span className="platform-badge">{status?.platform}</span>
      </header>

      {error && (
        <div className="error-banner">
          <span>⚠️</span> {error}
          <button onClick={() => setError(null)}>✕</button>
        </div>
      )}

      <div className="content">
        <StatusCard status={status} />

        <AgentList
          agents={status?.agents ?? []}
          defaultAgent={status?.defaultAgent ?? ""}
          onSetDefault={handleSetDefault}
        />

        <NetworkInfo
          lanIp={status?.lanIp ?? ""}
          port={status?.port ?? 0}
          deviceId={status?.deviceId ?? ""}
          mdnsRunning={status?.mdnsRunning ?? false}
        />
      </div>

      <footer className="app-footer">
        <span className="version">v{status?.version ?? "0.1.0"}</span>
        <span className="platform">
          平台：{status?.platform ?? "unknown"} | ID:{" "}
          {status?.deviceId?.slice(0, 16) ?? "-"}
        </span>
      </footer>
    </div>
  );
}
