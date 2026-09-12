import { invoke } from "@tauri-apps/api/core";
import type {
  DesktopStatus,
  AgentEntry,
  AgentTerminalState,
  PairingInfo,
  ApprovalMode,
  AgentModelsInfo,
  Conversation,
  ConversationSummary,
  BrowseRootsInfo,
  BrowseResultInfo,
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
 * Send a command to a conversation.
 * `conversationId` 缺省（草稿态）时后端创建新对话并激活；返回对话 ID。
 */
export async function sendCommand(
  text: string,
  conversationId: string | null,
  /** 草稿物化（conversationId=null）时绑定的工作目录；undefined 不传。 */
  workdir?: string | null,
): Promise<string> {
  return invoke<string>("send_command", { text, conversationId, workdir: workdir ?? null });
}

/**
 * Clear the terminal output for an agent.
 */
export async function clearTerminal(agentId: string): Promise<void> {
  return invoke<void>("clear_terminal", { agentId });
}

// ─── Model commands（桌面 composer 的模型切换） ──────────────────────────────

/**
 * 读取某个 Agent 的可选模型（读真实配置文件 + 用户偏好）。
 * 未知 agent 会 reject（"unknown agent"）。
 */
export async function getAgentModels(agentId: string): Promise<AgentModelsInfo> {
  return invoke<AgentModelsInfo>("get_agent_models", { agentId });
}

/**
 * 记住某个 Agent 的用户默认模型（modelId 传 null 清除偏好）。
 * providerId 可选：同名模型由多个 provider 提供时用于精确区分。
 */
export async function setDefaultModel(
  agentId: string,
  modelId: string | null,
  providerId?: string | null,
): Promise<void> {
  return invoke<void>("set_default_model", {
    agentId,
    modelId,
    providerId: providerId ?? null,
  });
}

// ─── Workdir / folder browse（composer 目录条） ──────────────────────────────

/** 某个 Agent 当前的工作目录（null = 未设置，CLI 用默认 cwd）。 */
export async function getAgentWorkdir(agentId: string): Promise<string | null> {
  return invoke<string | null>("get_agent_workdir", { agentId });
}

/**
 * 设置 / 清除某个 Agent 的工作目录（path 传 null 清除；后端经白名单校验）。
 * 返回校验后的规范路径。
 */
export async function setAgentWorkdir(
  agentId: string,
  path: string | null,
): Promise<string | null> {
  return invoke<string | null>("set_agent_workdir", { agentId, path });
}

/** 浏览根列表（主目录 + 各盘符）。 */
export async function browseRoots(): Promise<BrowseRootsInfo> {
  return invoke<BrowseRootsInfo>("browse_roots");
}

/** 浏览某个目录（path 传 null = 主目录）。 */
export async function browseFolder(
  path: string | null,
): Promise<BrowseResultInfo> {
  return invoke<BrowseResultInfo>("browse_folder", { path });
}

// ─── Conversation commands（多对话管理，方案 P3/P4） ─────────────────────────
/**
 * 列出对话（含归档由 includeArchived 控制；后端按 pinned 优先 + 最新活动排序）。
 */
export async function listConversations(
  includeArchived: boolean,
): Promise<ConversationSummary[]> {
  return invoke<ConversationSummary[]>("list_conversations", {
    includeArchived,
  });
}

/**
 * 读取完整对话（转录层，打开对话才加载）。
 */
export async function getConversation(id: string): Promise<Conversation> {
  return invoke<Conversation>("get_conversation", { conversationId: id });
}

/**
 * 激活某对话（切换窗口；触发 active-conversation-changed 事件）。
 */
export async function activateConversation(id: string): Promise<void> {
  return invoke<void>("activate_conversation", { conversationId: id });
}

/**
 * 归档 / 恢复对话（归档 = 「关闭窗口」，仍可从已归档区找回）。
 */
export async function setConversationArchived(
  id: string,
  archived: boolean,
): Promise<void> {
  return invoke<void>("set_conversation_archived", {
    conversationId: id,
    archived,
  });
}

/**
 * 彻底删除对话（仅归档态允许，后端校验）。
 */
export async function deleteConversation(id: string): Promise<void> {
  return invoke<void>("delete_conversation", { conversationId: id });
}

/**
 * 置顶 / 取消置顶。
 */
export async function togglePinConversation(
  id: string,
  pinned: boolean,
): Promise<void> {
  return invoke<void>("toggle_pin_conversation", {
    conversationId: id,
    pinned,
  });
}

/**
 * 更改对话的绑定目录（null / 空串 = 解绑）。目录不存在时后端拒绝。
 * 侧栏目录分组与执行 cwd 都以该绑定为准。
 */
export async function setConversationWorkdir(
  id: string,
  workdir: string | null,
): Promise<void> {
  return invoke<void>("set_conversation_workdir", {
    conversationId: id,
    workdir: workdir ?? "",
  });
}
