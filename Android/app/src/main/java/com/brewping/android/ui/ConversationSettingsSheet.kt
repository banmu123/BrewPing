package com.brewping.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.sp
import com.brewping.android.R
import com.brewping.android.model.AgentEntry
import com.brewping.android.model.DesktopDevice
import com.brewping.android.model.ModelOption
import com.brewping.android.model.pathLabel
import com.brewping.android.store.ConversationStore
import com.brewping.android.store.ModelStore
import com.brewping.android.ui.theme.LatteCard
import com.brewping.android.ui.theme.LatteDestructive
import com.brewping.android.ui.theme.LatteOnSurface
import com.brewping.android.ui.theme.LatteOnSurfaceVariant
import com.brewping.android.ui.theme.LattePrimary

// ─── 对话设置（Agent / 模型 / 授权；均为**对话级**设置）────────────────────────
//
// 对齐 iOS `ConversationSettingsView`：从对话详情头部唤起的设置面板。
// 移动端交互 = 表单 + 菜单选择器：每项点开即选，选择立即生效并回写桌面端。
//
// 与桌面端同一套语义：
//   · Agent —— 对话级绑定；既有对话里切换由桌面端自动清除该对话的模型覆盖；
//   · 模型 —— 对话级覆盖 > 该 Agent 默认模型；草稿态改的是 Agent 默认模型；
//   · 授权 —— 对话级档位；草稿态只记本地，随首条消息随对话固化。

/** 授权三档（对齐 iOS ApprovalModeStore.Mode）。 */
enum class ApprovalModeUi(val raw: String) {
    Safe("safe"),
    AskAll("askAll"),
    Auto("auto");

    companion object {
        fun fromRaw(raw: String?): ApprovalModeUi =
            entries.firstOrNull { it.raw == raw } ?: Safe
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConversationSettingsSheet(
    onDismiss: () -> Unit,
    device: DesktopDevice,
    online: Boolean,
    agents: List<AgentEntry>,
    isDraft: Boolean,
    store: ConversationStore,
    modelStore: ModelStore,
    fallbackAgentId: String,
    draftAgentId: String?,
    draftApprovalMode: String?,
    onDraftAgentChange: (String?) -> Unit,
    onDraftApprovalChange: (String?) -> Unit,
    onChanged: () -> Unit,
    modelNotice: String?,
    onSwitchAgent: (conversationId: String?, agentId: String, onDone: () -> Unit) -> Unit,
    onSetApproval: (conversationId: String?, mode: String, onDone: () -> Unit) -> Unit,
    onSetModel: (conversationId: String?, modelId: String?, providerId: String?, onDone: () -> Unit) -> Unit,
    models: List<ModelOption>,
    /** 打开目录浏览（绑定 / 解绑对话工作目录；对齐桌面端 WorkdirPicker）。 */
    onBrowseWorkdir: () -> Unit = {},
) {
    val detail by store.detail.collectAsState()
    val detailError by store.detailError.collectAsState()
    val canSwitch = modelStore.canSwitch

    val installedAgents = agents.filter { it.installed }
    val currentAgentId: String =
        if (isDraft) (draftAgentId ?: fallbackAgentId) else (detail?.agentId ?: fallbackAgentId)

    // 当前选中模型的复合标识（provider/model）。草稿跟随 Agent 默认模型；
    // 既有对话优先自己的覆盖，未设置 = 跟随 Agent 配置（空串）。
    val currentModelComposite: String = when {
        isDraft -> modelStore.activeModelID.value ?: ""
        else -> {
            val detailNow = detail
            val overrideId = detailNow?.modelOverride
            if (overrideId.isNullOrEmpty()) {
                ""
            } else {
                val provider = detailNow.modelProviderOverride
                models.firstOrNull {
                    it.id == overrideId && (provider == null || it.providerID == provider)
                }?.compositeID ?: overrideId
            }
        }
    }

    val currentApproval: ApprovalModeUi = ApprovalModeUi.fromRaw(
        if (isDraft) (draftApprovalMode ?: ApprovalModeUi.Safe.raw)
        else (detail?.approvalMode ?: ApprovalModeUi.Safe.raw),
    )

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(bottom = 24.dp),
        ) {
            Text(
                text = stringResource(R.string.chat_settings),
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                color = LatteOnSurface,
                modifier = Modifier.padding(bottom = 8.dp),
            )

            // ─── Agent ───────────────────────────────────────────────────
            SectionHeader(stringResource(R.string.agent_section))
            Surface(shape = MaterialTheme.shapes.medium, color = LatteCard) {
                Column {
                    if (installedAgents.isEmpty()) {
                        Text(
                            text = if (online) {
                                stringResource(R.string.detecting_agents)
                            } else {
                                stringResource(R.string.no_agents_detected)
                            },
                            fontSize = 12.sp,
                            color = LatteOnSurfaceVariant,
                            modifier = Modifier.padding(12.dp),
                        )
                    } else {
                        installedAgents.forEachIndexed { index, agent ->
                            OptionRow(
                                label = agent.name,
                                selected = agent.id == currentAgentId,
                                onClick = {
                                    if (agent.id != currentAgentId) {
                                        if (isDraft) {
                                            onDraftAgentChange(agent.id)
                                        } else if (detail != null) {
                                            onSwitchAgent(detail!!.id, agent.id, onChanged)
                                        }
                                    }
                                },
                                divider = index < installedAgents.size - 1,
                            )
                        }
                    }
                }
            }
            if (!isDraft) {
                Text(
                    text = stringResource(R.string.switching_agent_clears),
                    fontSize = 10.sp,
                    color = LatteOnSurfaceVariant,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
            Text(
                text = stringResource(R.string.conversation_only),
                fontSize = 10.sp,
                color = LatteOnSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp, bottom = 12.dp),
            )

            // ─── Model ───────────────────────────────────────────────────
            if (canSwitch) {
                SectionHeader(stringResource(R.string.model))
                Surface(shape = MaterialTheme.shapes.medium, color = LatteCard) {
                    Column {
                        if (!isDraft) {
                            OptionRow(
                                label = stringResource(R.string.follow_agent_config),
                                selected = currentModelComposite.isEmpty(),
                                onClick = {
                                    if (detail != null && currentModelComposite.isNotEmpty()) {
                                        onSetModel(detail!!.id, null, null, onChanged)
                                    }
                                },
                                divider = models.isNotEmpty(),
                            )
                        }
                        models.forEachIndexed { index, model ->
                            OptionRow(
                                label = if (model.providerName.isEmpty()) model.name
                                else "${model.name} · ${model.providerName}",
                                selected = model.compositeID == currentModelComposite,
                                enabled = model.available,
                                onClick = {
                                    if (isDraft) {
                                        // 草稿没有对话可写：选模型 = 设置该 Agent 的默认模型（新对话的起点）
                                        modelStore.select(model.id, model.providerID)
                                    } else if (detail != null && model.compositeID != currentModelComposite) {
                                        onSetModel(detail!!.id, model.id, model.providerID, onChanged)
                                    }
                                },
                                divider = index < models.size - 1,
                            )
                        }
                    }
                }
                if (!isDraft && detail?.modelOverride != null) {
                    Text(
                        text = stringResource(R.string.chat_own_model),
                        fontSize = 10.sp,
                        color = LatteOnSurfaceVariant,
                        modifier = Modifier.padding(top = 4.dp),
                    )
                }
                modelNotice?.let { notice ->
                    Text(
                        text = notice,
                        fontSize = 10.sp,
                        color = LatteDestructive,
                        modifier = Modifier.padding(top = 4.dp),
                    )
                }
                Spacer(modifier = Modifier.padding(top = 12.dp))
            }

            // ─── Approval ────────────────────────────────────────────────
            SectionHeader(stringResource(R.string.approval_mode))
            Surface(shape = MaterialTheme.shapes.medium, color = LatteCard) {
                Column {
                    ApprovalModeUi.entries.forEachIndexed { index, mode ->
                        OptionRow(
                            label = approvalLabel(mode),
                            selected = mode == currentApproval,
                            onClick = {
                                if (isDraft) {
                                    // 草稿只记本地，随首条消息随对话固化；不动全局默认
                                    onDraftApprovalChange(mode.raw)
                                } else if (detail != null && mode != currentApproval) {
                                    onSetApproval(detail!!.id, mode.raw, onChanged)
                                }
                            },
                            divider = index < ApprovalModeUi.entries.size - 1,
                        )
                    }
                }
            }
            Text(
                text = approvalSummary(currentApproval),
                fontSize = 10.sp,
                color = LatteOnSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp),
            )

            // ─── Workdir（对话绑定的工作目录；与桌面端 WorkdirPicker 同语义）────
            SectionHeader(stringResource(R.string.working_folder))
            Surface(shape = MaterialTheme.shapes.medium, color = LatteCard) {
                Column {
                    val boundDir = detail?.workdirOverride?.takeIf { it.isNotEmpty() }
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onBrowseWorkdir() }
                            .padding(horizontal = 14.dp, vertical = 12.dp),
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = boundDir?.let { pathLabel(it) } ?: stringResource(R.string.unbound_folder),
                                fontSize = 15.sp,
                                color = LatteOnSurface,
                            )
                            if (boundDir != null) {
                                Text(
                                    text = boundDir,
                                    fontSize = 11.sp,
                                    color = LatteOnSurfaceVariant,
                                    maxLines = 1,
                                )
                            } else {
                                Text(
                                    text = stringResource(R.string.tap_to_bind),
                                    fontSize = 11.sp,
                                    color = LatteOnSurfaceVariant,
                                )
                            }
                        }
                        Text(
                            text = stringResource(R.string.browse),
                            fontSize = 12.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = LattePrimary,
                        )
                    }
                }
            }
            Text(
                text = stringResource(R.string.chat_folder_hint),
                fontSize = 10.sp,
                color = LatteOnSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp, bottom = 12.dp),
            )

            // ─── 错误 ────────────────────────────────────────────────────
            detailError?.let { error ->
                Text(
                    text = error,
                    fontSize = 12.sp,
                    color = LatteDestructive,
                    modifier = Modifier.padding(top = 12.dp),
                )
            }
        }
    }
}

@Composable
private fun approvalLabel(mode: ApprovalModeUi): String = when (mode) {
    ApprovalModeUi.Safe -> stringResource(R.string.approval_safe)
    ApprovalModeUi.AskAll -> stringResource(R.string.approval_ask_all)
    ApprovalModeUi.Auto -> stringResource(R.string.approval_auto)
}

@Composable
private fun approvalSummary(mode: ApprovalModeUi): String = when (mode) {
    ApprovalModeUi.Safe -> stringResource(R.string.approval_safe_summary)
    ApprovalModeUi.AskAll -> stringResource(R.string.approval_ask_all_summary)
    ApprovalModeUi.Auto -> stringResource(R.string.approval_auto_summary)
}

@Composable
private fun SectionHeader(title: String) {
    Text(
        text = title,
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
        color = LatteOnSurfaceVariant,
        modifier = Modifier.padding(bottom = 6.dp),
    )
}

@Composable
private fun OptionRow(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    divider: Boolean,
    enabled: Boolean = true,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        Text(
            text = label,
            fontSize = 15.sp,
            fontWeight = if (selected) FontWeight.Medium else FontWeight.Normal,
            color = if (enabled) LatteOnSurface else LatteOnSurfaceVariant.copy(alpha = 0.6f),
            modifier = Modifier.weight(1f),
        )
        if (selected) {
            Icon(
                imageVector = Icons.Filled.Check,
                contentDescription = null,
                tint = LattePrimary,
                modifier = Modifier.size(16.dp),
            )
        }
    }
    if (divider) {
        HorizontalDivider(color = LatteOnSurfaceVariant.copy(alpha = 0.12f), thickness = 0.5.dp)
    }
}
