use mdns_sd::{ServiceDaemon, ServiceInfo};
use std::collections::HashMap;

/// mDNS broadcaster for `_brewping._tcp` service.
pub struct MdnsBroadcaster {
    daemon: Option<ServiceDaemon>,
    service_name: String,
}

impl MdnsBroadcaster {
    pub fn new() -> Self {
        Self {
            daemon: None,
            service_name: String::new(),
        }
    }

    /// Start broadcasting the BrewPing service via mDNS.
    ///
    /// Service type: `_brewping._tcp`
    /// TXT records: version, agent, platform, protocolVersion, deviceId, deviceName
    pub fn start(
        &mut self,
        port: u16,
        device_id: &str,
        device_name: &str,
        lan_ip: &str,
        default_agent: &str,
    ) -> Result<(), String> {
        self.stop();

        let daemon = ServiceDaemon::new().map_err(|e| format!("mDNS daemon error: {}", e))?;

        let service_type = "_brewping._tcp.local.";
        let instance_name = device_name;

        // TXT record fields (matching macOS implementation exactly)
        let mut properties = HashMap::new();
        properties.insert("version".to_string(), "0.1".to_string());
        properties.insert("agent".to_string(), default_agent.to_string());
        properties.insert(
            "platform".to_string(),
            std::env::consts::OS.to_string(),
        );
        properties.insert("protocolVersion".to_string(), "1".to_string());
        properties.insert("deviceId".to_string(), device_id.to_string());
        properties.insert("deviceName".to_string(), device_name.to_string());

        let ip_addr: std::net::IpAddr = lan_ip
            .parse()
            .map_err(|e| format!("Invalid LAN IP '{}': {}", lan_ip, e))?;

        let hostname = format!("{}.local.", device_name);

        let service_info = ServiceInfo::new(
            service_type,
            instance_name,
            &hostname,
            ip_addr,
            port,
            properties,
        )
        .map_err(|e| format!("ServiceInfo error: {}", e))?;

        daemon
            .register(service_info)
            .map_err(|e| format!("mDNS register error: {}", e))?;

        self.daemon = Some(daemon);
        self.service_name = format!("{}{}", instance_name, service_type);

        log::info!(
            "mDNS broadcasting: {} on {}:{} ({})",
            instance_name,
            lan_ip,
            port,
            device_id
        );
        Ok(())
    }

    /// Stop broadcasting.
    pub fn stop(&mut self) {
        if let Some(daemon) = self.daemon.take() {
            let _ = daemon.shutdown();
            log::info!("mDNS broadcasting stopped");
        }
        self.service_name.clear();
    }

    pub fn is_broadcasting(&self) -> bool {
        self.daemon.is_some()
    }
}

/// mDNS status for the UI.
#[derive(Debug, Clone, serde::Serialize)]
pub struct MdnsStatus {
    pub broadcasting: bool,
    pub service_type: String,
    pub instance_name: String,
}
