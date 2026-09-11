import { invoke } from "@tauri-apps/api/core";
import type {
  DesktopStatus,
  AgentEntry,
  AgentTerminalState,
  PairingInfo,
  ApprovalMode,
  PendingApproval,
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

// ─── Pairing commands ────────────────────────────────────────────────────────

/**
 * 读取当前配对信息（不会生成新码）。
 */
export async function getPairingInfo(): Promise<PairingInfo> {
  return invoke<PairingInfo>("get_pairing_info");
}

/**
 * 显示配对码：生成（或复用未过期的）配对码。
 */
export async function revealPairingCode(): Promise<PairingInfo> {
  return invoke<PairingInfo>("reveal_pairing_code");
}

/**
 * 强制轮换配对码（旧的立即作废）。
 */
export async function regeneratePairingCode(): Promise<PairingInfo> {
  return invoke<PairingInfo>("regenerate_pairing_code");
}

// ─── Approval commands ───────────────────────────────────────────────────────

/**
 * 读取当前授权模式。
 */
export async function getApprovalMode(): Promise<string> {
  return invoke<string>("get_approval_mode");
}

/**
 * 切换授权模式。
 */
export async function setApprovalMode(mode: ApprovalMode): Promise<string> {
  return invoke<string>("set_approval_mode", { mode });
}

/**
 * 列出全部待确认命令。
 */
export async function getPendingApprovals(): Promise<PendingApproval[]> {
  return invoke<PendingApproval[]>("get_pending_approvals");
}

/**
 * 对某条挂起命令做出决定：approve / deny / always_approve。
 */
export async function decideApproval(
  id: string,
  action: "approve" | "deny" | "always_approve",
): Promise<string> {
  return invoke<string>("decide_approval", { id, action });
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
