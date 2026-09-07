import type { DesktopStatus } from "../api/types";

interface Props {
  status: DesktopStatus | null;
}

export function StatusCard({ status }: Props) {
  const isOnline = !!status;
  const hasSession = !!status?.session;

  return (
    <div className="card">
      <div className="card-header">
        <h2>桌面状态</h2>
        <span className={`status-dot ${isOnline ? "online" : "offline"}`} />
      </div>
      <div className="card-body">
        <div className="info-row">
          <span className="label">主机名</span>
          <span className="value">{status?.host ?? "-"}</span>
        </div>
        <div className="info-row">
          <span className="label">状态</span>
          <span className={`value ${isOnline ? "text-green" : "text-red"}`}>
            {isOnline ? "在线" : "离线"}
          </span>
        </div>
        <div className="info-row">
          <span className="label">默认代理</span>
          <span className="value">{status?.defaultAgent ?? "-"}</span>
        </div>
        <div className="info-row">
          <span className="label">会话</span>
          <span className={`value ${hasSession ? "text-green" : "text-gray"}`}>
            {hasSession
              ? `${status!.session!.agentName} (${status!.session!.status})`
              : "无"}
          </span>
        </div>
      </div>
    </div>
  );
}
