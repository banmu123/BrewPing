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
  EnvironmentStatus,
  NodeVersionOption,
  AgentCliStatus,
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
  /** 草稿物化时固化的授权档位（对话级，之后各对话独立）；undefined 不传。 */
  approvalMode?: ApprovalMode | null,
): Promise<string> {
  return invoke<string>("send_command", {
    text,
    conversationId,
    workdir: workdir ?? null,
    approvalMode: approvalMode ?? null,
  });
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

/**
 * 设置 / 清除某个对话的授权档位（null = 清除，回落全局默认）。
 * 授权是**对话级**设置：只影响这一个对话。
 */
export async function setConversationApprovalMode(
  id: string,
  mode: ApprovalMode | null,
): Promise<void> {
  return invoke<void>("set_conversation_approval_mode", {
    conversationId: id,
    mode: mode ?? null,
  });
}

/**
 * 设置 / 清除某个对话的模型覆盖（modelId=null = 清除，回落该 Agent 默认模型）。
 * modelId 与 providerId 成对提交（同名模型可能来自多个厂商）。
 */
export async function setConversationModel(
  id: string,
  modelId: string | null,
  providerId: string | null,
): Promise<void> {
  return invoke<void>("set_conversation_model", {
    conversationId: id,
    modelId: modelId ?? null,
    providerId: providerId ?? null,
  });
}

// ─── 环境与 CLI 安装（设置页「环境与 AI CLI」区块）────────────────────────────

/**
 * 全量环境检测：Node / npm / NVM / Python / 各 Agent CLI 的安装状态与版本。
 * 探测要 spawn 若干 `--version`（约 1-2s），按需调用。
 */
export async function checkEnvironment(): Promise<EnvironmentStatus> {
  return invoke<EnvironmentStatus>("check_environment");
}

/**
 * 可安装的 Node 版本清单（nodejs.org dist index 按大版本聚合，推荐 = 最新 LTS；
 * 离线回落为 nvm 别名 "latest" / "lts"）。
 */
export async function getNodeVersions(): Promise<NodeVersionOption[]> {
  return invoke<NodeVersionOption[]>("get_node_versions");
}

/**
 * 安装 NVM（winget 优先，官方静默安装包兜底；Windows 可能弹 UAC）。
 * 进度经 `env-setup-log` / `env-setup-done` 事件流给前端，promise 在任务结束时 resolve。
 */
export async function installNvm(): Promise<unknown> {
  return invoke<unknown>("install_nvm");
}

/**
 * 经 NVM 安装指定版本的 Node（install → use → 验证），返回实际版本号。
 * 支持具体版本（"22.14.0"）与 nvm 别名（"latest" / "lts"）。
 */
export async function installNode(version: string): Promise<string> {
  return invoke<string>("install_node", { version });
}

/**
 * 安装某个 Agent 的官方 CLI（methodId 取自检测结果 methods[].id，如 "native"/"npm"/"pip"）。
 * 成功后返回该 Agent 的最新检测状态。
 */
export async function installAgentCli(
  agentId: string,
  methodId: string,
): Promise<AgentCliStatus> {
  return invoke<AgentCliStatus>("install_agent_cli", { agentId, methodId });
}

/**
 * 更新某个已安装的 Agent CLI 到最新版（官方更新通道：claude update / npm @latest /
 * aider-install 升级）。成功后返回该 Agent 的最新检测状态。
 */
export async function updateAgentCli(agentId: string): Promise<AgentCliStatus> {
  return invoke<AgentCliStatus>("update_agent_cli", { agentId });
}
