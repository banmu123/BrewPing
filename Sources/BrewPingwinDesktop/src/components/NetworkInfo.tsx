interface Props {
  lanIp: string;
  port: number;
  deviceId: string;
  mdnsRunning: boolean;
}

export function NetworkInfo({ lanIp, port, deviceId, mdnsRunning }: Props) {
  return (
    <div className="card">
      <div className="card-header">
        <h2>网络信息</h2>
        <span className={`status-dot ${mdnsRunning ? "online" : "offline"}`} />
      </div>
      <div className="card-body">
        <div className="info-row">
          <span className="label">局域网 IP</span>
          <span className="value mono">{lanIp || "未检测"}</span>
        </div>
        <div className="info-row">
          <span className="label">HTTP 端口</span>
          <span className="value mono">{port}</span>
        </div>
        <div className="info-row">
          <span className="label">设备 ID</span>
          <span className="value mono">{deviceId}</span>
        </div>
        <div className="info-row">
          <span className="label">mDNS 广播</span>
          <span className={`value ${mdnsRunning ? "text-green" : "text-red"}`}>
            {mdnsRunning ? "运行中 (_brewping._tcp)" : "未启动"}
          </span>
        </div>
        <div className="info-row">
          <span className="label">服务类型</span>
          <span className="value mono">_brewping._tcp</span>
        </div>
        <div className="info-row">
          <span className="label">协议版本</span>
          <span className="value">1</span>
        </div>
      </div>
    </div>
  );
}
