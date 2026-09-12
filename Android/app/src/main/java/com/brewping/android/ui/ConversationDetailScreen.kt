package com.brewping.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.brewping.android.model.AgentEntry
import com.brewping.android.model.CommandPhase
import com.brewping.android.model.DesktopDevice
import com.brewping.android.model.TranscriptEntry
import com.brewping.android.model.pathLabel
import com.brewping.android.model.timeLabel
import com.brewping.android.store.ConversationStore
import com.brewping.android.store.ModelStore
import com.brewping.android.ui.theme.BrewMotion
import com.brewping.android.ui.theme.LatteBackground
import com.brewping.android.ui.theme.LatteBorder
import com.brewping.android.ui.theme.LatteCard
import com.brewping.android.ui.theme.LatteDestructive
import com.brewping.android.ui.theme.LatteMuted
import com.brewping.android.ui.theme.LatteOnSurface
import com.brewping.android.ui.theme.LatteOnSurfaceVariant
import com.brewping.android.ui.theme.LatteOnSecondary
import com.brewping.android.ui.theme.LattePrimary
import com.brewping.android.ui.theme.LattePrimaryForeground
import com.brewping.android.ui.theme.LatteSecondary
import com.brewping.android.ui.theme.LatteSuccess

// ─── 对话详情（转录 + 工作目录条 + 输入框，对齐 iOS ConversationDetailView）──────
//
// 两种形态共用一套视图：
//   · conversationId != null → 既有对话：转录来自桌面端 `GET /api/conversations/{id}`；
//   · conversationId == null → 新对话（草稿）：先本地显示已发内容，首条消息
//     物化成对话后再按新 id 提交。
// 命令提交与轮询复用 HomeViewModel 的 repository 链路（状态在 commandPhase）。

@Composable
fun ConversationDetailScreen(
    conversationId: String?,
    device: DesktopDevice,
    online: Boolean,
    agentNames: Map<String, String>,
    agents: List<AgentEntry>,
    fallbackAgentId: String,
    store: ConversationStore,
    modelStore: ModelStore,
    commandPhase: CommandPhase,
    detailLoading: Boolean,
    onBack: () -> Unit,
    onSend: (
        conversationId: String?,
        text: String,
        draftAgentId: String?,
        draftApprovalMode: String?,
        onMaterialized: (String?) -> Unit,
    ) -> Unit,
    onReload: (conversationId: String?) -> Unit,
    onSwitchAgent: (conversationId: String?, agentId: String, onDone: () -> Unit) -> Unit,
    onSetApproval: (conversationId: String?, mode: String, onDone: () -> Unit) -> Unit,
    onSetModel: (conversationId: String?, modelId: String?, providerId: String?, onDone: () -> Unit) -> Unit,
    onFetchFolderRoots: (onResult: (com.brewping.android.model.FolderRoots?) -> Unit) -> Unit,
    onFetchFolder: (path: String?, onResult: (com.brewping.android.model.FolderBrowse?) -> Unit) -> Unit,
    onBindWorkdir: (path: String?) -> Unit,
) {
    val detail by store.detail.collectAsState()
    val detailError by store.detailError.collectAsState()
    val models by modelStore.models.collectAsState()
    val modelNotice by modelStore.notice.collectAsState()

    var draft by remember { mutableStateOf("") }
    /** 刚发出、尚未落进服务端转录的那条用户消息（发出后立刻显示，避免"点了没反应"）。 */
    var pendingUserText by remember { mutableStateOf<String?>(null) }
    /** 新对话草稿发送时由桌面端物化的对话 id（之后视图按既有对话工作）。 */
    var materializedID by remember { mutableStateOf<String?>(null) }
    var showSettings by remember { mutableStateOf(false) }
    /** 目录浏览（绑定 / 解绑对话工作目录）。 */
    var showFolderBrowser by remember { mutableStateOf(false) }
    /** 草稿态选定的 Agent（null = 跟随桌面端当前默认 Agent）。 */
    var draftAgentId by remember { mutableStateOf<String?>(null) }
    /** 草稿态选定的授权档位（null = 跟随桌面端全局默认），随首条消息固化。 */
    var draftApprovalMode by remember { mutableStateOf<String?>(null) }

    val activeConversationId: String? = conversationId ?: materializedID
    val isDraft: Boolean = activeConversationId == null
    val resolvedAgentId: String = detail?.agentId
        ?: if (isDraft) (draftAgentId ?: fallbackAgentId) else fallbackAgentId
    val agentName = agentNames[resolvedAgentId] ?: resolvedAgentId
    val conversationTitle = if (isDraft) "New Conversation" else (detail?.title ?: "(untitled)")

    // 进入 / 物化后拉取权威转录；模型列表跟随当前对话的 Agent
    LaunchedEffect(activeConversationId, resolvedAgentId) {
        if (activeConversationId != null) {
            store.open(activeConversationId, device)
        }
        if (online) {
            modelStore.refresh(device, resolvedAgentId)
        }
    }

    // 命令结束后：清掉本地挂起项 + 重取权威转录（助手条目此时已落库）
    var wasInFlight by remember { mutableStateOf(false) }
    LaunchedEffect(commandPhase) {
        if (wasInFlight && !commandPhase.isInFlight) {
            pendingUserText = null
            onReload(activeConversationId)
        }
        wasInFlight = commandPhase.isInFlight
    }

    // ─── 渲染项：服务端转录 + 本地挂起项（发出的消息 / 进行中的状态）──────────
    val items = remember(detail, pendingUserText, commandPhase, isDraft) {
        buildItems(detail?.messages.orEmpty(), pendingUserText, commandPhase, isDraft)
    }

    val listState = rememberLazyListState()
    LaunchedEffect(items.size, commandPhase) {
        if (items.isNotEmpty()) {
            listState.animateScrollToItem(items.size - 1)
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(LatteBackground)
            .imePadding(),
    ) {
        // ─── 头部（可点：进入对话设置）────────────────────────────────────
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .clickable { showSettings = true }
                .padding(horizontal = 8.dp, vertical = 10.dp),
        ) {
            IconButton(onClick = onBack) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    tint = LatteOnSurface,
                )
            }
            Text(
                text = conversationTitle,
                fontSize = 16.sp,
                fontWeight = FontWeight.Medium,
                color = LatteOnSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                text = agentName,
                fontSize = 11.sp,
                color = LatteOnSecondary.copy(alpha = 0.9f),
                modifier = Modifier
                    .background(LatteSecondary, CircleShape)
                    .padding(horizontal = 8.dp, vertical = 3.dp),
            )
            Spacer(modifier = Modifier.weight(1f))
            Icon(
                imageVector = Icons.Filled.Tune,
                contentDescription = "Chat Settings",
                tint = LatteOnSurfaceVariant,
                modifier = Modifier.size(14.dp),
            )
            Spacer(modifier = Modifier.width(6.dp))
            // 在线状态色渐变（150ms，柔和切换）
            val dotColor by androidx.compose.animation.animateColorAsState(
                targetValue = if (online) LatteSuccess else LatteDestructive,
                animationSpec = androidx.compose.animation.core.tween(
                    BrewMotion.Fast, easing = BrewMotion.FastEasing,
                ),
                label = "onlineDot",
            )
            Box(
                modifier = Modifier
                    .size(6.dp)
                    .background(color = dotColor, shape = CircleShape),
            )
            Spacer(modifier = Modifier.width(4.dp))
            Text(
                text = if (online) "Online" else "Offline",
                fontSize = 11.sp,
                color = LatteOnSurfaceVariant,
            )
        }
        Surface(color = LatteBorder.copy(alpha = 0.6f), modifier = Modifier.fillMaxWidth().height(1.dp)) {}

        // ─── 消息区 ──────────────────────────────────────────────────────
        LazyColumn(
            state = listState,
            verticalArrangement = Arrangement.spacedBy(18.dp),
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(
                horizontal = 16.dp, vertical = 14.dp,
            ),
        ) {
            if (items.isEmpty() && !commandPhase.isInFlight) {
                item(key = "__empty__") {
                    Text(
                        text = "No messages yet.",
                        fontSize = 13.sp,
                        color = LatteOnSurfaceVariant,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 40.dp),
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    )
                }
            }
            items(items, key = { it.uid }) { item ->
                ChatRow(item = item)
            }
            if (commandPhase.isInFlight) {
                item(key = "__thinking__") {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(modifier = Modifier.size(14.dp), strokeWidth = 2.dp)
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(
                            text = "$agentName is thinking…",
                            fontSize = 12.sp,
                            color = LatteOnSurfaceVariant,
                        )
                    }
                }
            }
            detailError?.let { error ->
                item(key = "__detail_error__") {
                    Text(
                        text = error,
                        fontSize = 12.sp,
                        fontFamily = FontFamily.Monospace,
                        color = LatteDestructive,
                    )
                }
            }
            if (detailLoading && items.isEmpty()) {
                item(key = "__loading__") {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(modifier = Modifier.size(14.dp), strokeWidth = 2.dp)
                        Spacer(modifier = Modifier.width(8.dp))
                        Text("Loading…", fontSize = 12.sp, color = LatteOnSurfaceVariant)
                    }
                }
            }
        }

        // ─── 工作目录条 ──────────────────────────────────────────────────
        val boundDir = detail?.workdirOverride?.takeIf { it.isNotEmpty() }
        Surface(
            shape = RoundedCornerShape(12.dp),
            color = LatteCard,
            border = androidx.compose.foundation.BorderStroke(1.dp, LatteBorder),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                Icon(
                    imageVector = Icons.Filled.Folder,
                    contentDescription = null,
                    tint = LattePrimary.copy(alpha = 0.85f),
                    modifier = Modifier.size(12.dp),
                )
                Spacer(modifier = Modifier.width(6.dp))
                if (boundDir != null) {
                    Text(
                        text = pathLabel(boundDir),
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                        color = LatteOnSurface,
                    )
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(
                        text = boundDir,
                        fontSize = 11.sp,
                        fontFamily = FontFamily.Monospace,
                        color = LatteOnSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                } else {
                    Text(
                        text = "Unbound Folder",
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                        color = LatteOnSurface,
                    )
                }
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    text = if (boundDir == null) {
                        "Not bound — the CLI default folder is used."
                    } else {
                        "This chat's folder. File operations use it."
                    },
                    fontSize = 10.sp,
                    color = LatteOnSurfaceVariant.copy(alpha = 0.8f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = if (boundDir == null) Modifier.weight(1f) else Modifier.widthIn(max = 120.dp),
                )
            }
        }
        Spacer(modifier = Modifier.height(8.dp))

        // ─── Composer ────────────────────────────────────────────────────
        val canSend = online && draft.isNotBlank()
        // 发送钮可用态渐变（对齐 iOS 的柔和过渡）
        val sendBg by androidx.compose.animation.animateColorAsState(
            targetValue = if (canSend) LattePrimary else LatteMuted,
            animationSpec = androidx.compose.animation.core.tween(
                BrewMotion.Fast, easing = BrewMotion.FastEasing,
            ),
            label = "sendBg",
        )
        val sendTint by androidx.compose.animation.animateColorAsState(
            targetValue = if (canSend) LattePrimaryForeground else LatteOnSurfaceVariant,
            animationSpec = androidx.compose.animation.core.tween(
                BrewMotion.Fast, easing = BrewMotion.FastEasing,
            ),
            label = "sendTint",
        )
        Surface(
            shape = RoundedCornerShape(16.dp),
            color = LatteCard,
            border = androidx.compose.foundation.BorderStroke(1.dp, LatteBorder),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp)
                .navigationBarsPadding(),
        ) {
            Row(
                verticalAlignment = Alignment.Bottom,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                androidx.compose.foundation.text.BasicTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    textStyle = androidx.compose.ui.text.TextStyle(
                        fontSize = 15.sp,
                        lineHeight = 20.sp,
                        color = LatteOnSurface,
                    ),
                    cursorBrush = androidx.compose.ui.graphics.SolidColor(LattePrimary),
                    maxLines = 5,
                    modifier = Modifier.weight(1f),
                    decorationBox = { inner ->
                        Box {
                            if (draft.isEmpty()) {
                                Text(
                                    text = "Message $agentName",
                                    fontSize = 15.sp,
                                    color = LatteOnSurfaceVariant.copy(alpha = 0.75f),
                                )
                            }
                            inner()
                        }
                    },
                )
                Spacer(modifier = Modifier.width(10.dp))
                Box(
                    modifier = Modifier
                        .size(32.dp)
                        .background(color = sendBg, shape = CircleShape)
                        .clickable(enabled = canSend) {
                            val text = draft.trim()
                            if (text.isEmpty()) return@clickable
                            draft = ""
                            pendingUserText = text
                            if (isDraft) {
                                // 新对话草稿：先物化（Agent / 授权档位随创建固化），再按新对话 id 提交
                                onSend(null, text, draftAgentId, draftApprovalMode) { materialized ->
                                    if (materialized == null) {
                                        pendingUserText = null
                                        draft = text
                                    } else {
                                        materializedID = materialized
                                    }
                                }
                            } else {
                                onSend(activeConversationId, text, null, null) { }
                            }
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.Send,
                        contentDescription = "Send",
                        tint = sendTint,
                        modifier = Modifier.size(15.dp),
                    )
                }
            }
        }
        Spacer(modifier = Modifier.height(10.dp))
    }

    // ─── 对话设置（Agent / 模型 / 授权，均按对话独立）─────────────────────────
    if (showSettings) {
        ConversationSettingsSheet(
            onDismiss = { showSettings = false },
            device = device,
            online = online,
            agents = agents,
            isDraft = isDraft,
            store = store,
            modelStore = modelStore,
            fallbackAgentId = fallbackAgentId,
            draftAgentId = draftAgentId,
            draftApprovalMode = draftApprovalMode,
            onDraftAgentChange = { draftAgentId = it },
            onDraftApprovalChange = { draftApprovalMode = it },
            onChanged = {
                onReload(activeConversationId)
            },
            modelNotice = modelNotice,
            onSwitchAgent = onSwitchAgent,
            onSetApproval = onSetApproval,
            onSetModel = onSetModel,
            models = models,
            onBrowseWorkdir = {
                showSettings = false
                showFolderBrowser = true
            },
        )
    }

    // ─── 目录浏览（绑定 / 解绑对话工作目录）───────────────────────────────────
    if (showFolderBrowser) {
        FolderBrowserSheet(
            currentDir = detail?.workdirOverride?.takeIf { it.isNotEmpty() },
            onDismiss = { showFolderBrowser = false },
            onFetchRoots = onFetchFolderRoots,
            onFetchFolder = onFetchFolder,
            onBind = { path ->
                showFolderBrowser = false
                activeConversationId?.let { id ->
                    onBindWorkdir(path) {
                        onReload(id)
                    }
                }
            },
        )
    }
}

// ─── 渲染项 ──────────────────────────────────────────────────────────────────

private data class ChatItem(
    val uid: String,
    /** user / assistant / error / system */
    val role: String,
    val text: String,
    val createdAtMs: Double,
)

private fun buildItems(
    messages: List<TranscriptEntry>,
    pendingUserText: String?,
    commandPhase: CommandPhase,
    isDraft: Boolean,
): List<ChatItem> {
    val list = messages.map { ChatItem(it.uid, it.role, it.text, it.createdAtMs) }.toMutableList()
    pendingUserText?.let {
        list.add(ChatItem("local-user", "user", it, System.currentTimeMillis().toDouble()))
    }
    // 草稿态没有服务端转录可查，助手输出直接来自提交引擎的状态机
    if (isDraft) {
        when (val phase = commandPhase) {
            is CommandPhase.Completed -> list.add(ChatItem("local-assistant", "assistant", phase.response, 0.0))
            is CommandPhase.CompletedRaw -> list.add(ChatItem("local-assistant", "assistant", phase.rawOutput, 0.0))
            is CommandPhase.Failed -> list.add(ChatItem("local-error", "error", phase.error, 0.0))
            else -> Unit
        }
    }
    return list
}

@Composable
private fun ChatRow(item: ChatItem) {
    SelectionContainer {
        when (item.role) {
            "user" -> Column(
                horizontalAlignment = Alignment.End,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (item.createdAtMs > 0) {
                        Text(
                            text = timeLabel(item.createdAtMs),
                            fontSize = 10.sp,
                            color = LatteOnSurfaceVariant,
                        )
                        Spacer(modifier = Modifier.width(6.dp))
                    }
                    Text(
                        text = "You",
                        fontSize = 9.sp,
                        fontWeight = FontWeight.Medium,
                        color = LattePrimary,
                        modifier = Modifier
                            .size(18.dp)
                            .background(LattePrimary.copy(alpha = 0.15f), CircleShape)
                            .wrapContentSize(Alignment.Center),
                    )
                }
                Spacer(modifier = Modifier.height(4.dp))
                Box(
                    modifier = Modifier
                        .widthIn(max = 320.dp)
                        .background(
                            color = LatteSecondary,
                            shape = RoundedCornerShape(16.dp),
                        ),
                ) {
                    Text(
                        text = item.text,
                        fontSize = 15.sp,
                        lineHeight = 21.sp,
                        color = LatteOnSecondary,
                        modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                    )
                }
            }
            "error" -> Text(
                text = item.text,
                fontSize = 12.sp,
                fontFamily = FontFamily.Monospace,
                color = LatteDestructive,
                modifier = Modifier.fillMaxWidth(),
            )
            "system" -> Text(
                text = item.text,
                fontSize = 11.sp,
                color = LatteOnSurfaceVariant.copy(alpha = 0.8f),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
            else -> MarkdownText(text = item.text, modifier = Modifier.fillMaxWidth())
        }
    }
}
