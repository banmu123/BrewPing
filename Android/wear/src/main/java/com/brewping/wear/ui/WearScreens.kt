package com.brewping.wear.ui

import android.content.ActivityNotFoundException
import android.content.Intent
import android.speech.RecognizerIntent
import androidx.activity.compose.ManagedActivityResultLauncher
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.ActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.items
import androidx.wear.compose.material3.Button
import androidx.wear.compose.material3.Card
import androidx.wear.compose.material3.CircularProgressIndicator
import androidx.wear.compose.material3.ListHeader
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.Text
import androidx.wear.compose.material3.TimeText
import androidx.wear.compose.navigation.SwipeDismissableNavHost
import androidx.wear.compose.navigation.composable
import androidx.wear.compose.navigation.rememberSwipeDismissableNavController
import com.brewping.core.model.CommandRunStatus
import com.brewping.core.model.PendingApprovalInfo
import com.brewping.wear.R
import com.brewping.wear.data.mostRecentActive

/**
 * Wear v1 界面：黑色高对比、少信息、大按钮（任务 §17）。
 * 结构：Home（状态 / 审批数 / 对话 / 语音）→ Conversations / Conversation / Approval / Voice。
 */
object WearRoutes {
    const val HOME = "home"
    const val CONVERSATIONS = "conversations"
    const val CONVERSATION = "conversation/{id}"
    const val APPROVALS = "approvals"
    const val VOICE = "voice/{id}"
}

@Composable
fun WearApp(viewModel: WearViewModel) {
    val navController = rememberSwipeDismissableNavController()
    val lifecycleOwner = LocalLifecycleOwner.current
    val state by viewModel.state.collectAsState()

    // 轮询策略（任务 §18）：ON_RESUME 立即刷新 + 7s 轮询；ON_PAUSE 停止；
    // 不创建常驻 Service。ProvisionBus（配置到达）在 ViewModel 内自行订阅。
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> viewModel.startPolling()
                Lifecycle.Event.ON_PAUSE -> viewModel.stopPolling()
                else -> {}
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    MaterialTheme {
        SwipeDismissableNavHost(
            navController = navController,
            startDestination = WearRoutes.HOME,
        ) {
            composable(WearRoutes.HOME) {
                HomeScreen(
                    state = state,
                    onConversations = { navController.navigate(WearRoutes.CONVERSATIONS) },
                    onApprovals = { navController.navigate(WearRoutes.APPROVALS) },
                    onVoice = { id -> navController.navigate("voice/$id") },
                    onRefresh = { viewModel.refreshOnce() },
                )
            }
            composable(WearRoutes.CONVERSATIONS) {
                ConversationsScreen(
                    state = state,
                    onOpen = { id -> navController.navigate("conversation/$id") },
                )
            }
            composable(WearRoutes.CONVERSATION) { entry ->
                val id = entry.arguments?.getString("id").orEmpty()
                ConversationScreen(
                    id = id,
                    state = state,
                    onLoad = { viewModel.loadConversation(id) },
                    onVoice = { navController.navigate("voice/$id") },
                )
            }
            composable(WearRoutes.APPROVALS) {
                ApprovalScreen(
                    state = state,
                    onDecide = { id, approve -> viewModel.decide(id, approve) },
                )
            }
            composable(WearRoutes.VOICE) { entry ->
                val id = entry.arguments?.getString("id").orEmpty()
                VoiceScreen(
                    conversationId = id,
                    state = state,
                    onSend = { text -> viewModel.sendVoice(text, id) },
                    onDone = { navController.popBackStack() },
                    onClearTransient = { viewModel.clearTransient() },
                )
            }
        }
    }
}

// ─── 共享小组件 ───────────────────────────────────────────────────────────────

@Composable
fun phaseLabelRes(phase: String?): Int = when (phase) {
    CommandRunStatus.PHASE_QUEUED -> R.string.status_queued
    CommandRunStatus.PHASE_THINKING -> R.string.status_thinking
    CommandRunStatus.PHASE_STREAMING -> R.string.status_streaming
    CommandRunStatus.PHASE_STALLED -> R.string.status_stalled
    CommandRunStatus.PHASE_COMPLETED -> R.string.status_completed
    CommandRunStatus.PHASE_FAILED -> R.string.status_failed
    else -> R.string.status_idle
}

@Composable
fun connectionErrorLabel(error: ConnectionError?): Int = when (error) {
    ConnectionError.Auth -> R.string.auth_failed
    ConnectionError.Server -> R.string.server_error
    ConnectionError.Offline -> R.string.desktop_offline
    // Network 涵盖连不上 / 超时；「本地网络不可访问」（API 37 权限拒绝）留有独立文案位
    ConnectionError.Network -> R.string.connect_failed
    null -> R.string.status_idle
}

// ─── Home ────────────────────────────────────────────────────────────────────

@Composable
fun HomeScreen(
    state: WearUiState,
    onConversations: () -> Unit,
    onApprovals: () -> Unit,
    onVoice: (String?) -> Unit,
    onRefresh: () -> Unit,
) {
    TimeText()
    ScalingLazyColumn {
        item { ListHeader { Text(stringResource(R.string.current_status)) } }

        if (state.provisioned == null) {
            item {
                Card(onClick = {}) {
                    Text(stringResource(R.string.not_configured))
                    Text(stringResource(R.string.waiting_for_phone))
                }
            }
        } else {
            item {
                Card(onClick = {}) {
                    Text(stringResource(R.string.connected_to, state.provisioned.deviceName))
                    when {
                        !state.paired -> Text(stringResource(R.string.auth_failed))
                        state.connectionError != null ->
                            Text(stringResource(connectionErrorLabel(state.connectionError)))
                        !state.online -> Text(stringResource(R.string.desktop_offline))
                        else -> {
                            Text(stringResource(phaseLabelRes(state.activeRun?.phase)))
                            state.lastOutput?.let { Text(it, maxLines = 3) }
                        }
                    }
                }
            }
            item {
                Button(onClick = onApprovals) {
                    Text(stringResource(R.string.approvals) + " (${state.approvals.size})")
                }
            }
            item {
                Button(onClick = onConversations) {
                    Text(stringResource(R.string.conversations))
                }
            }
            item {
                // 语音默认发给最近一条对话（没有对话时落到 Voice 页提示）
                Button(
                    onClick = { onVoice(state.conversations.mostRecentActive()?.id) },
                    enabled = state.online,
                ) {
                    Text(stringResource(R.string.voice_command))
                }
            }
            item {
                Button(onClick = onRefresh) {
                    Text(stringResource(R.string.refresh))
                }
            }
        }
    }
}

// ─── Conversations ───────────────────────────────────────────────────────────

@Composable
fun ConversationsScreen(
    state: WearUiState,
    onOpen: (String) -> Unit,
) {
    TimeText()
    ScalingLazyColumn {
        item { ListHeader { Text(stringResource(R.string.conversations)) } }
        if (state.conversations.isEmpty()) {
            item { Text(stringResource(R.string.no_conversations)) }
        }
        items(state.conversations, key = { it.id }) { conv ->
            Card(onClick = { onOpen(conv.id) }) {
                Text(conv.title ?: conv.id, maxLines = 2)
            }
        }
    }
}

// ─── Conversation ────────────────────────────────────────────────────────────

@Composable
fun ConversationScreen(
    id: String,
    state: WearUiState,
    onLoad: () -> Unit,
    onVoice: () -> Unit,
) {
    LaunchedEffect(id) { onLoad() }
    TimeText()
    ScalingLazyColumn {
        item {
            Card(onClick = {}) {
                Text(stringResource(phaseLabelRes(state.activeRun?.phase)))
            }
        }
        val entries = state.detail?.messages.orEmpty().takeLast(8)
        if (entries.isEmpty() && !state.detailLoading) {
            item { Text(stringResource(R.string.no_conversations)) }
        }
        items(entries, key = { it.uid }) { entry ->
            Card(onClick = {}) {
                Text(entry.text, maxLines = 6)
            }
        }
        item {
            Button(onClick = onVoice, enabled = state.online) {
                Text(stringResource(R.string.voice_command))
            }
        }
    }
}

// ─── Approval ────────────────────────────────────────────────────────────────

@Composable
fun ApprovalScreen(
    state: WearUiState,
    onDecide: (String, Boolean) -> Unit,
) {
    TimeText()
    ScalingLazyColumn {
        item { ListHeader { Text(stringResource(R.string.pending_approval)) } }
        if (state.approvals.isEmpty()) {
            item { Text(stringResource(R.string.no_approvals)) }
        }
        items(state.approvals, key = { it.id }) { approval ->
            ApprovalCard(
                approval = approval,
                busy = state.decisionInFlight,
                decided = approval.id in state.decidedIds,
                onDecide = onDecide,
            )
        }
        if (state.decisionSent) {
            item { Text(stringResource(R.string.decision_sent)) }
        }
    }
}

@Composable
private fun ApprovalCard(
    approval: PendingApprovalInfo,
    busy: Boolean,
    decided: Boolean,
    onDecide: (String, Boolean) -> Unit,
) {
    Card(onClick = {}) {
        Text(approval.text.ifEmpty { approval.id }, maxLines = 5)
        Button(
            onClick = { onDecide(approval.id, true) },
            // 请求过程中 disabled；已处理的不再提交（任务 §15 防抖）
            enabled = !busy && !decided,
        ) {
            Text(stringResource(R.string.approve))
        }
        Button(
            onClick = { onDecide(approval.id, false) },
            enabled = !busy && !decided,
        ) {
            Text(stringResource(R.string.reject))
        }
    }
}

// ─── Voice ───────────────────────────────────────────────────────────────────

@Composable
fun VoiceScreen(
    conversationId: String,
    state: WearUiState,
    onSend: (String) -> Unit,
    onDone: () -> Unit,
    onClearTransient: () -> Unit,
) {
    var recognized by remember { mutableStateOf<String?>(null) }
    var speechUnavailable by rememberSaveable { mutableStateOf(false) }
    var launched by rememberSaveable { mutableStateOf(false) }
    var consumed by rememberSaveable { mutableStateOf(false) }

    val launcher: ManagedActivityResultLauncher<Intent, ActivityResult> =
        rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            val text = result.data
                ?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
                ?.firstOrNull()
            recognized = text?.takeIf { it.isNotBlank() }
        }

    // 进入页面即拉起系统语音识别（任务 §15：系统 Speech Recognizer，不做录音上传）
    LaunchedEffect(Unit) {
        if (launched) return@LaunchedEffect
        launched = true
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        }
        try {
            launcher.launch(intent)
        } catch (_: ActivityNotFoundException) {
            speechUnavailable = true
        }
    }

    // 发送成功 → 自动返回（一次性消费）
    LaunchedEffect(state.sendDone) {
        if (state.sendDone && !consumed) {
            consumed = true
            onClearTransient()
            onDone()
        }
    }

    val noTarget = state.provisioned != null &&
        conversationId.isEmpty() &&
        state.conversations.mostRecentActive() == null

    TimeText()
    ScalingLazyColumn {
        item { ListHeader { Text(stringResource(R.string.voice_command)) } }
        when {
            noTarget -> item { Text(stringResource(R.string.no_conversations)) }
            speechUnavailable -> item { Text(stringResource(R.string.speech_unavailable)) }
            state.sending -> item {
                CircularProgressIndicator()
                Text(stringResource(R.string.sending))
            }
            state.sendError != null -> item { Text(stringResource(R.string.send_failed)) }
            else -> {
                item {
                    Card(onClick = {}) {
                        Text(recognized ?: stringResource(R.string.speak_now), maxLines = 5)
                    }
                }
                item {
                    Button(
                        onClick = { recognized?.let(onSend) },
                        enabled = !recognized.isNullOrEmpty() && !state.sending,
                    ) {
                        Text(stringResource(R.string.confirm_send))
                    }
                }
            }
        }
        item {
            Button(onClick = onDone) {
                Text(stringResource(R.string.cancel))
            }
        }
    }
}
