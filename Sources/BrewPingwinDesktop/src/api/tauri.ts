import { invoke } from "@tauri-apps/api/core";
import type {
  DesktopStatus,
  AgentEntry,
  AgentTerminalState,
} from "./types";

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

// ─── Terminal commands ───────────────────────────────────────────────────────

/**
 * Get the terminal state for all agents.
 */
export async function getTerminalState(): Promise<AgentTerminalState[]> {
  return invoke<AgentTerminalState[]>("get_terminal_state");
}

/**
 * Get the currently active agent ID.
 */
export async function getActiveAgentId(): Promise<string> {
  return invoke<string>("get_active_agent_id");
}

/**
 * Switch the active terminal agent.
 */
export async function switchActiveAgent(agentId: string): Promise<void> {
  return invoke<void>("switch_active_agent", { agentId });
}

/**
 * Send a command to the active agent.
 */
export async function sendCommand(text: string): Promise<void> {
  return invoke<void>("send_command", { text });
}

/**
 * Clear the terminal output for an agent.
 */
export async function clearTerminal(agentId: string): Promise<void> {
  return invoke<void>("clear_terminal", { agentId });
}
