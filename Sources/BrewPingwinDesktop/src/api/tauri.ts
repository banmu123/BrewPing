import { invoke } from "@tauri-apps/api/core";
import type { DesktopStatus, AgentEntry } from "./types";

/**
 * Fetch the full desktop status from the Rust backend.
 */
export async function getStatus(): Promise<DesktopStatus> {
  return invoke<DesktopStatus>("get_status");
}

/**
 * Get the list of discovered agents.
 */
export async function getAgents(): Promise<AgentEntry[]> {
  return invoke<AgentEntry[]>("get_agents");
}

/**
 * Set the default agent.
 */
export async function setDefaultAgent(agentId: string): Promise<string> {
  return invoke<string>("set_default_agent", { agent: agentId });
}

/**
 * Get the LAN IP address.
 */
export async function getLanIp(): Promise<string> {
  return invoke<string>("get_lan_ip");
}

/**
 * Get the HTTP server port.
 */
export async function getPort(): Promise<number> {
  return invoke<number>("get_port");
}
