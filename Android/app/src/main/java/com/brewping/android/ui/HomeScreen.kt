package com.brewping.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Download
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.brewping.core.LocalePrefs
import com.brewping.android.R
import com.brewping.core.model.DesktopDevice
import com.brewping.core.model.DeviceOSType
import com.brewping.core.model.ManagedDevice
import com.brewping.android.ui.theme.BrewMotion
import com.brewping.android.ui.theme.LatteAccent
import com.brewping.android.ui.theme.LatteBackground
import com.brewping.android.ui.theme.LatteBorder
import com.brewping.android.ui.theme.LatteCard
import com.brewping.android.ui.theme.LatteDestructive
import com.brewping.android.ui.theme.LatteMuted
import com.brewping.android.ui.theme.LatteOnSurface
import com.brewping.android.ui.theme.LatteOnSurfaceVariant
import com.brewping.android.ui.theme.LattePrimary
import com.brewping.android.ui.theme.LattePrimaryForeground
import com.brewping.android.ui.theme.LatteSuccess
import com.brewping.android.ui.theme.LatteWarning

// ─── 主页（对齐 iOS：设备 tab + 对话列表 + 对话详情）────────────────────────────
//
// 连接机器后先显示对话列表（按绑定工作目录分组），点进去是对话详情
// （转录 + 输入框）。Agent / 模型 / 授权在对话详情的设置面板里按对话设置。
// 旧版的 Agent 列表 / 会话启停 / Message / Result 表单已随 iOS 一并移除
// （iOS 端「控制面板」同样已删除，功能并入对话设置）。

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(viewModel: HomeViewModel) {
    val devices by viewModel.devices.collectAsState()
    val activeDeviceID by viewModel.activeDeviceID.collectAsState()
    val online by viewModel.online.collectAsState()
    val agents by viewModel.agents.collectAsState()
    val route by viewModel.conversationRoute.collectAsState()
    val desktopDevice by viewModel.desktopDevice.collectAsState()
    /** 局域网扫描是否进行中：在进行中时不能断言「没有桌面端」（见下方 when 的说明） */
    val discoveryRunning by viewModel.discoveryRunning.collectAsState()
    val conversationsLoading by viewModel.conversationStore.loading.collectAsState()

    var showAddDevice by remember { mutableStateOf(false) }
    var editingDevice by remember { mutableStateOf<ManagedDevice?>(null) }
    /** 待配对设备（添加/发现后未配对 → 弹配对对话框：输码或扫码）。 */
    var showPairFor by remember { mutableStateOf<ManagedDevice?>(null) }
    /** 配对对话框预填的码（扫码所得；长度 6 时自动发起配对）。 */
    var pairInitialCode by remember { mutableStateOf("") }
    /** QR 扫码（"pair" = 配对对话框扫码；"form" = 添加设备表单扫码）。 */
    var showQrScan by remember { mutableStateOf(false) }
    var qrTarget by remember { mutableStateOf("form") }
    /**
     * 配对窗扫码期间暂存的目标设备：PairDialog 是 AlertDialog（独立窗口层），
     * 悬浮于普通 composable 之上——不先关掉会挡住全屏相机界面。
     * 扫码取消 → 恢复配对窗；扫到码 → 按 payload 恢复/新建并自动配对。
     */
    var pairScanReturn by remember { mutableStateOf<ManagedDevice?>(null) }
    /** 表单扫码结果（DeviceFormDialog 预填 host/port/name）。 */
    var qrFormPayload by remember { mutableStateOf<com.brewping.core.model.PairPayload?>(null) }
    /** Help / About 页（商店审核要求站内可达：使用说明 / 隐私政策 / 支持 / 商标免责）。 */
    var showHelp by remember { mutableStateOf(false) }
    val demoDeviceName = stringResource(R.string.demo_device_name)
    val discovered by viewModel.discoveredDevices.collectAsState()
    val pairingVersion by viewModel.pairingVersion.collectAsState()

    // ─── 深链配对（系统相机 / 微信扫桌面端二维码 → brewping://pair?...）──────────
    // 与「配对窗扫码」共用同一套「复用已有设备 / 新建并激活」逻辑，
    // 差别只在入口：那条来自 App 内相机，这条来自系统 Intent（冷启动或 onNewIntent）。
    val deepLinkPayload by com.brewping.core.model.PairingDeepLink.pendingAction.collectAsState()
    LaunchedEffect(deepLinkPayload) {
        val payload = deepLinkPayload ?: return@LaunchedEffect
        com.brewping.core.model.PairingDeepLink.consume()
        val target = if (payload.host.isNotEmpty()) {
            val existing = devices.firstOrNull {
                it.host.equals(payload.host, ignoreCase = true) &&
                    it.port.trim() == payload.port.trim()
            }
            if (existing != null) {
                // 同一台机器已在列表里：同步名称/系统类型，复用原条目（否则 token 会分裂）
                if (existing.name != payload.name || existing.osType != payload.osType) {
                    viewModel.updateDevice(
                        existing.copy(
                            name = payload.name.ifEmpty { existing.name },
                            osType = payload.osType,
                        ),
                    )
                }
                existing
            } else {
                ManagedDevice.new(
                    name = payload.name.ifEmpty { "Desktop" },
                    host = payload.host,
                    port = payload.port,
                    osType = payload.osType,
                ).also { viewModel.addDevice(it); viewModel.setActiveDevice(it.id) }
            }
        } else {
            null
        }
        // 预填 6 位码 → PairDialog 打开后 LaunchedEffect 自动发起配对（全程无手动操作）
        pairInitialCode = payload.code
        if (target != null) showPairFor = target
    }

    // 详情页内返回 = 关闭对话（系统返回键 + 顶栏返回钮一致）
    BackHandler(enabled = route != null) { viewModel.closeConversation() }

    Scaffold(
        containerColor = LatteBackground,
        topBar = {
            CenterAlignedTopAppBar(
                title = {
                    Text(
                        text = "BrewPing",
                        fontWeight = FontWeight.SemiBold,
                        color = LatteOnSurface,
                    )
                },
                actions = {
                    TextButton(onClick = { showHelp = true }) {
                        Text(
                            text = stringResource(R.string.help_about),
                            fontSize = 12.sp,
                            color = LatteOnSurfaceVariant,
                        )
                    }
                    LanguageMenuButton()
                },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(
                    containerColor = LatteBackground,
                ),
            )
        },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
        ) {
            // ─── Device Tab Bar（对齐 iOS deviceTabBar）─────────────────────
            DeviceTabBar(
                devices = devices,
                activeDeviceID = activeDeviceID,
                online = online,
                onSelect = { viewModel.setActiveDevice(it) },
                onAdd = { showAddDevice = true },
                onEdit = { editingDevice = it },
                onDelete = { viewModel.removeDevice(it) },
            )

            // ─── Content：对话列表 ↔ 对话详情（push/pop 转场，对齐 iOS NavigationStack）
            val routeKey = when (route) {
                is ConversationRoute.Existing -> "existing-" + (route as ConversationRoute.Existing).id
                is ConversationRoute.Draft -> "draft"
                null -> "list"
            }
            AnimatedContent(
                targetState = routeKey,
                modifier = Modifier.weight(1f),
                transitionSpec = {
                    val slide = tween<IntOffset>(BrewMotion.Normal, easing = BrewMotion.StandardEasing)
                    val fade = tween<Float>(BrewMotion.Fast, easing = BrewMotion.FastEasing)
                    if (targetState == "list") {
                        // 返回（pop）：进入=列表自左浅移淡入，离开=详情滑出右侧
                        (slideInHorizontally(slide) { -it / 3 } + fadeIn(fade)) togetherWith
                            (slideOutHorizontally(slide) { it } + fadeOut(fade))
                    } else {
                        // 前进（push）：详情自右滑入，列表向左浅移淡出
                        (slideInHorizontally(slide) { it } + fadeIn(fade)) togetherWith
                            (slideOutHorizontally(slide) { -it / 3 } + fadeOut(fade))
                    }
                },
                label = "nav",
            ) { key ->
                val detailId: String? =
                    if (key.startsWith("existing-")) key.removePrefix("existing-") else null
                val showDetail = key != "list"
                val device = desktopDevice
                when {
                    devices.isEmpty() -> Column(modifier = Modifier.fillMaxSize()) {
                        DiscoveredDevicesSection(
                            discovered = discovered,
                            knownKeys = devices.map { "${it.host}:${it.port}" }.toSet(),
                            onAdd = { found ->
                                val managed = viewModel.addDiscoveredDevice(found)
                                if (!viewModel.isPaired(managed.id)) showPairFor = managed
                            },
                        )
                        // 附近已发现可添加的设备 → 只显示"附近的设备"卡；
                        // 扫描结束仍没发现（桌面端没开 / 不在同一网络）→ 才提示去获取桌面端。
                        // 🚨 扫描**进行中**时不能断言「没有桌面端」：那会让「下载桌面端」卡先
                        // 渲染出来，等附近列表出来才消失（与 iOS 侧同一个坑，两侧同构修）。
                        if (discovered.isEmpty() && !discoveryRunning) {
                            EmptyStateCard(modifier = Modifier.padding(16.dp))
                        }
                    }
                    // 🚨 设备列表非空、但当前设备还没物化完（activeDeviceID 的收集器会先
                    // resetState() 把 desktopDevice 置空，再 connectToDevice）——这是
                    // 「瞬时未就绪」，不是「没有桌面端」。早先这里直接渲染 EmptyStateCard，
                    // 于是每次退出再进来都会闪一下「下载桌面端」。
                    device == null -> PreparingDeviceCard(modifier = Modifier.padding(16.dp))
                    showDetail -> ConversationDetailScreen(
                        conversationId = detailId,
                        device = device,
                        online = online,
                        agentNames = viewModel.agentNames,
                        agents = agents,
                        fallbackAgentId = viewModel.fallbackAgentId,
                        store = viewModel.conversationStore,
                        modelStore = viewModel.modelStore,
                        commandPhase = viewModel.commandPhase.collectAsState().value,
                        detailLoading = viewModel.conversationStore.detailLoading.collectAsState().value,
                        onBack = { viewModel.closeConversation() },
                        onSend = viewModel::sendInConversation,
                        onReload = viewModel::reloadConversation,
                        onSwitchAgent = viewModel::switchConversationAgent,
                        onSetApproval = viewModel::setConversationApproval,
                        onSetModel = viewModel::setConversationModel,
                        onFetchFolderRoots = viewModel::fetchFolderRoots,
                        onFetchFolder = viewModel::fetchFolder,
                        onBindWorkdir = { path, onDone ->
                            detailId?.let { viewModel.setConversationWorkdir(it, path) { onDone() } }
                        },
                        onDecideApproval = viewModel::decideApproval,
                        onDismissApproval = viewModel::clearPendingApproval,
                        onModelAgentChanged = viewModel::setModelAgent,
                    )
                    else -> Column(modifier = Modifier.fillMaxSize()) {
                        DiscoveredDevicesSection(
                            discovered = discovered,
                            knownKeys = devices.map { "${it.host}:${it.port}" }.toSet(),
                            onAdd = { found ->
                                val managed = viewModel.addDiscoveredDevice(found)
                                if (!viewModel.isPaired(managed.id)) showPairFor = managed
                            },
                        )
                        ConversationListScreen(
                            store = viewModel.conversationStore,
                            online = online,
                            agentNames = viewModel.agentNames,
                            isRefreshing = conversationsLoading,
                            onRefresh = { viewModel.refreshConversations() },
                            onOpenConversation = { viewModel.openConversation(it) },
                            onNewConversation = { viewModel.openDraftConversation() },
                            onPinConversation = { id, pinned -> viewModel.pinConversation(id, pinned) { viewModel.refreshConversations() } },
                            onArchiveConversation = { id -> viewModel.archiveConversation(id) { viewModel.refreshConversations() } },
                            onRestoreConversation = { id -> viewModel.restoreConversation(id) { viewModel.refreshConversations() } },
                            onDeleteConversation = { id -> viewModel.deleteConversation(id) { viewModel.refreshConversations() } },
                            onRePair = {
                                // 401 → 弹出当前设备的配对窗（输入 6 位码换新 token）
                                val active = desktopDevice ?: return@ConversationListScreen
                                devices.firstOrNull { it.id == active.id }?.let { showPairFor = it }
                            },
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }
        }
    }

    // ─── Add Device Dialog ────────────────────────────────────────────────────
    if (showAddDevice) {
        DeviceFormDialog(
            title = stringResource(R.string.add_device),
            scannedPayload = qrFormPayload,
            onScan = { qrTarget = "form"; showQrScan = true },
            onDismiss = { showAddDevice = false; qrFormPayload = null },
            onConfirm = { name, host, port, osType, code ->
                val managed = ManagedDevice.new(
                    name = name.ifEmpty { osType.label },
                    host = host,
                    port = port,
                    osType = osType,
                )
                viewModel.addDevice(managed)
                viewModel.setActiveDevice(managed.id)
                showAddDevice = false
                qrFormPayload = null
                if (code.length == 6) {
                    pairInitialCode = code
                    showPairFor = managed
                }
            },
            viewModel = viewModel,
        )
    }

    // ─── Edit Device Dialog ───────────────────────────────────────────────────
    editingDevice?.let { device ->
        DeviceFormDialog(
            title = stringResource(R.string.edit_device),
            initialName = device.name,
            initialHost = device.host,
            initialPort = device.port,
            initialOS = device.osType,
            onDismiss = { editingDevice = null },
            onConfirm = { name, host, port, osType, code ->
                val updated = device.copy(name = name, host = host, port = port, osType = osType)
                viewModel.updateDevice(updated)
                editingDevice = null
                if (code.length == 6 && !viewModel.isPaired(updated.id)) {
                    pairInitialCode = code
                    showPairFor = updated
                }
            },
            viewModel = viewModel,
        )
    }

    // ─── Pairing Dialog（配对：6 位码 / 扫码，对齐 iOS PairingURLHandler）───────
    showPairFor?.let { device ->
        PairDialog(
            device = device,
            initialCode = pairInitialCode,
            onDismiss = { showPairFor = null; pairInitialCode = "" },
            onScan = {
                // PairDialog 是 AlertDialog（独立窗口层），悬浮于普通 composable 之上，
                // 不先关掉会挡住全屏相机界面 —— 点扫码立即关窗并暂存目标设备；
                // 扫码取消 → 恢复配对窗；扫到码 → 按 payload 恢复/新建并自动配对。
                pairScanReturn = device
                showPairFor = null
                qrTarget = "pair"
                showQrScan = true
            },
            onPair = viewModel::pairWithCode,
        )
    }

    // ─── Help / About（商店审核要求站内可达）────────────────────────────────
    if (showHelp) {
        HelpScreen(
            onDismiss = { showHelp = false },
            onAddDemoDevice = { viewModel.addDemoDevice(demoDeviceName) },
        )
    }

    // ─── QR 扫码（配对码 / 添加设备表单）─────────────────────────────────────
    if (showQrScan) {
        QrScanScreen(
            onResult = { payload ->
                showQrScan = false
                if (qrTarget == "pair") {
                    // 扫到的码可能属于别的机器：以码为准换目标设备。
                    // host:port 与已有设备一致时**复用该条目**（并同步名称/系统类型），
                    // 否则会为同一台机器建出两条设备（一条扫码一条手动/发现），token 跟着分裂。
                    val target = if (payload.host.isNotEmpty() && payload.host != pairScanReturn?.host) {
                        val existing = devices.firstOrNull {
                            it.host.equals(payload.host, ignoreCase = true) &&
                                it.port.trim() == payload.port.trim()
                        }
                        if (existing != null) {
                            if (existing.name != payload.name || existing.osType != payload.osType) {
                                viewModel.updateDevice(
                                    existing.copy(name = payload.name.ifEmpty { existing.name }, osType = payload.osType),
                                )
                            }
                            existing
                        } else {
                            ManagedDevice.new(
                                name = payload.name.ifEmpty { "Desktop" },
                                host = payload.host,
                                port = payload.port,
                                osType = payload.osType,
                            ).also { viewModel.addDevice(it); viewModel.setActiveDevice(it.id) }
                        }
                    } else {
                        pairScanReturn
                    }
                    pairScanReturn = null
                    qrTarget = ""
                    // 预填 6 位码 → PairDialog 打开后 LaunchedEffect 自动发起配对，
                    // 成功自动关窗，全程无需手动操作
                    pairInitialCode = payload.code
                    if (target != null) showPairFor = target
                } else {
                    qrFormPayload = payload
                    showAddDevice = true
                    qrTarget = ""
                }
            },
            onDismiss = {
                showQrScan = false
                // 用户取消扫码：恢复之前的配对窗；清掉残留旧码，
                // 避免恢复窗口时用已失效的码自动重试一次
                if (qrTarget == "pair" && pairScanReturn != null) {
                    pairInitialCode = ""
                    showPairFor = pairScanReturn
                    pairScanReturn = null
                }
                qrTarget = ""
            },
        )
    }
}

// ─── 连接中占位（设备已添加，只是当前设备还在物化）────────────────────────────
/// 中性占位：**不能**用 EmptyStateCard —— 那等于告诉用户「还没有桌面端」，
/// 与他明明已经添加过设备的事实矛盾。
@Composable
private fun PreparingDeviceCard(modifier: Modifier = Modifier) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier.fillMaxWidth(),
    ) {
        CircularProgressIndicator(
            modifier = Modifier.size(16.dp),
            strokeWidth = 2.dp,
            color = LattePrimary,
        )
        Spacer(modifier = Modifier.width(10.dp))
        Text(
            text = stringResource(R.string.preparing_device),
            fontSize = 12.sp,
            color = LatteOnSurfaceVariant,
        )
    }
}

// ─── Empty state（对齐 iOS emptyStateCard）────────────────────────────────────
@Composable
private fun EmptyStateCard(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = LatteCard,
        border = BorderStroke(1.dp, LatteBorder),
        modifier = modifier.fillMaxWidth(),
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.padding(24.dp),
        ) {
            Text(text = "☕", fontSize = 32.sp)
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = stringResource(R.string.add_first_computer),
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                color = LatteOnSurface,
            )
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = stringResource(R.string.empty_state_hint),
                fontSize = 12.sp,
                color = LatteOnSurfaceVariant,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )

            Spacer(modifier = Modifier.height(16.dp))
            // 没有桌面端？引导去下载（Mac / Windows）
            // 安装包统一从 GitHub Release 分发：Mac 分 Universal / Apple Silicon / Intel
            // 三个 DMG，另有 Windows 安装包；官网仅作介绍页。
            Button(
                onClick = {
                    try {
                        context.startActivity(
                            android.content.Intent(
                                android.content.Intent.ACTION_VIEW,
                                android.net.Uri.parse("https://github.com/banmu123/BrewPing/releases"),
                            )
                        )
                    } catch (_: android.content.ActivityNotFoundException) {
                        // 无浏览器：静默忽略（极罕见）
                    }
                },
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = LattePrimary,
                    contentColor = LattePrimaryForeground,
                ),
            ) {
                Icon(
                    imageVector = Icons.Filled.Download,
                    contentDescription = null,
                    modifier = Modifier.size(14.dp),
                )
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    text = stringResource(R.string.download_desktop),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
            Spacer(modifier = Modifier.height(6.dp))
            Text(
                text = stringResource(R.string.download_hint),
                fontSize = 10.sp,
                color = LatteOnSurfaceVariant.copy(alpha = 0.7f),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
        }
    }
}

// ─── Device Tab Bar ──────────────────────────────────────────────────────────

@Composable
private fun DeviceTabBar(
    devices: List<ManagedDevice>,
    activeDeviceID: String,
    online: Boolean,
    onSelect: (String) -> Unit,
    onAdd: () -> Unit,
    onEdit: (ManagedDevice) -> Unit,
    onDelete: (String) -> Unit,
) {
    Surface(
        color = LatteCard,
        modifier = Modifier.fillMaxWidth(),
    ) {
        LazyRow(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            items(devices, key = { it.id }) { device ->
                DeviceTab(
                    device = device,
                    isActive = device.id == activeDeviceID,
                    isOnline = online && device.id == activeDeviceID,
                    onClick = { onSelect(device.id) },
                    onEdit = { onEdit(device) },
                    onDelete = { onDelete(device.id) },
                )
            }

            // Add button
            item {
                IconButton(onClick = onAdd) {
                    Text("+", fontSize = 22.sp, color = LattePrimary, fontWeight = FontWeight.Bold)
                }
            }
        }
    }
}

@Composable
private fun DeviceTab(
    device: ManagedDevice,
    isActive: Boolean,
    isOnline: Boolean,
    onClick: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    var showMenu by remember { mutableStateOf(false) }

    Surface(
        shape = RoundedCornerShape(8.dp),
        color = if (isActive) LatteAccent else LatteMuted,
        border = if (isActive) {
            BorderStroke(1.dp, LattePrimary.copy(alpha = 0.4f))
        } else {
            BorderStroke(1.dp, LatteBorder.copy(alpha = 0.6f))
        },
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .clickable { onClick() },
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(
                        text = device.osType.label,
                        fontSize = 10.sp,
                        color = LatteOnSurfaceVariant,
                    )
                    Text(
                        text = device.name.ifEmpty { device.host },
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                        color = LatteOnSurface,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.width(width = 96.dp),
                    )
                }
                Box(
                    modifier = Modifier
                        .size(5.dp)
                        .background(
                            color = when {
                                isActive && isOnline -> LatteSuccess
                                isActive -> LatteWarning
                                else -> LatteMuted
                            },
                            shape = CircleShape,
                        ),
                )
            }

            // Context menu
            Box {
                Text(
                    text = "▾",
                    fontSize = 10.sp,
                    color = LatteOnSurfaceVariant,
                    modifier = Modifier
                        .padding(start = 4.dp)
                        .clickable { showMenu = true },
                )
                DropdownMenu(
                    expanded = showMenu,
                    onDismissRequest = { showMenu = false },
                    containerColor = LatteCard,
                ) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.edit), color = LatteOnSurface) },
                        onClick = { showMenu = false; onEdit() },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.delete), color = LatteDestructive) },
                        onClick = { showMenu = false; onDelete() },
                    )
                }
            }
        }
    }
}

// ─── Pairing Dialog（配对：6 位码 / 扫码）────────────────────────────────────

@Composable
private fun PairDialog(
    device: ManagedDevice,
    initialCode: String = "",
    onDismiss: () -> Unit,
    onScan: () -> Unit,
    onPair: (ManagedDevice, code: String, onResult: (Boolean, String) -> Unit) -> Unit,
) {
    var code by remember { mutableStateOf(initialCode) }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var messageOk by remember { mutableStateOf(false) }

    // 扫码预填 6 位码 → 自动发起配对
    LaunchedEffect(initialCode) {
        if (initialCode.length == 6) {
            busy = true
            message = null
            onPair(device, initialCode) { ok, msg ->
                busy = false
                message = msg
                messageOk = ok
                if (ok) onDismiss()
            }
        }
    }

    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        containerColor = LatteCard,
        title = {
            Text(
                stringResource(R.string.pairing_device_title, device.name.ifEmpty { device.host }),
                color = LatteOnSurface,
            )
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    text = stringResource(R.string.pairing_instructions),
                    fontSize = 12.sp,
                    color = LatteOnSurfaceVariant,
                )
                OutlinedTextField(
                    value = code,
                    onValueChange = { code = it.filter { c -> c.isDigit() }.take(6) },
                    label = { Text(stringResource(R.string.six_digit_pairing_code)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth(),
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = onScan, enabled = !busy) {
                        Text(stringResource(R.string.scan_qr_code), color = LattePrimary)
                    }
                }
                message?.let {
                    Text(
                        text = it,
                        fontSize = 12.sp,
                        color = if (messageOk) LatteSuccess else LatteDestructive,
                    )
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = !busy && code.length == 6,
                onClick = {
                    busy = true
                    message = null
                    onPair(device, code) { ok, msg ->
                        busy = false
                        message = msg
                        messageOk = ok
                        if (ok) onDismiss()
                    }
                },
            ) {
                Text(
                    if (busy) stringResource(R.string.pairing_in_progress) else stringResource(R.string.pair),
                    color = LattePrimary,
                )
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, enabled = !busy) {
                Text(stringResource(R.string.cancel), color = LatteOnSurfaceVariant)
            }
        },
    )
}

// ─── Discovered Devices（局域网自动发现，一键添加）────────────────────────────

@Composable
private fun DiscoveredDevicesSection(
    discovered: List<DesktopDevice>,
    knownKeys: Set<String>,
    onAdd: (DesktopDevice) -> Unit,
) {
    val newOnes = discovered.filter { "${it.ip}:${it.port}" !in knownKeys }
    if (newOnes.isEmpty()) return
    Surface(
        color = LatteCard,
        modifier = Modifier.fillMaxWidth(),
    ) {
        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
        ) {
            item(key = "__label__") {
                Text(
                    text = stringResource(R.string.nearby),
                    fontSize = 12.sp,
                    color = LatteOnSurfaceVariant,
                    modifier = Modifier.padding(vertical = 10.dp),
                )
            }
            items(newOnes, key = { it.id }) { found ->
                Surface(
                    shape = RoundedCornerShape(8.dp),
                    color = LatteAccent,
                    border = BorderStroke(1.dp, LattePrimary.copy(alpha = 0.4f)),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.padding(start = 10.dp),
                    ) {
                        Column {
                            Text(
                                text = found.name.ifEmpty { found.ip },
                                fontSize = 12.sp,
                                fontWeight = FontWeight.Medium,
                                color = LatteOnSurface,
                                maxLines = 1,
                            )
                            Text(
                                text = "${found.ip}:${found.port}",
                                fontSize = 9.sp,
                                color = LatteOnSurfaceVariant,
                            )
                        }
                        TextButton(onClick = { onAdd(found) }) {
                            Text(stringResource(R.string.add), color = LattePrimary)
                        }
                    }
                }
            }
        }
    }
}

// ─── Device Form Dialog ──────────────────────────────────────────────────────

@Composable
private fun DeviceFormDialog(
    title: String,
    initialName: String = "",
    initialHost: String = "",
    initialPort: String = "8787",
    initialOS: DeviceOSType = DeviceOSType.Mac,
    scannedPayload: com.brewping.core.model.PairPayload? = null,
    onScan: () -> Unit = {},
    onDismiss: () -> Unit,
    onConfirm: (name: String, host: String, port: String, osType: DeviceOSType, pairingCode: String) -> Unit,
    viewModel: HomeViewModel,
) {
    var name by remember { mutableStateOf(initialName) }
    var host by remember { mutableStateOf(initialHost) }
    var port by remember { mutableStateOf(initialPort) }
    var osType by remember { mutableStateOf(initialOS) }
    var pairingCode by remember { mutableStateOf("") }
    var discoveryMessage by remember { mutableStateOf("") }

    val discoveryRunning by viewModel.discoveryRunning.collectAsState()

    // 扫码预填：host / port / 名称 / 系统类型 / 配对码（对齐 iOS PairingURLHandler）
    // osType 必须预填，否则 Windows 机器会以默认 Mac 建档
    LaunchedEffect(scannedPayload) {
        scannedPayload?.let { payload ->
            if (payload.host.isNotEmpty()) host = payload.host
            if (payload.port.isNotEmpty()) port = payload.port
            if (payload.name.isNotEmpty() && name.isEmpty()) name = payload.name
            if (payload.code.isNotEmpty()) pairingCode = payload.code
            osType = payload.osType
        }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = LatteCard,
        title = { Text(title, color = LatteOnSurface) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text(stringResource(R.string.name_label)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = host,
                    onValueChange = { host = it },
                    label = { Text(stringResource(R.string.host_label)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = port,
                    onValueChange = { port = it },
                    label = { Text(stringResource(R.string.port_label)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )

                // OS Type picker
                Text(stringResource(R.string.system_label), style = MaterialTheme.typography.labelMedium, color = LatteOnSurfaceVariant)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    DeviceOSType.entries.forEach { os ->
                        FilterChip(
                            selected = osType == os,
                            onClick = { osType = os },
                            label = { Text(os.label) },
                            colors = FilterChipDefaults.filterChipColors(
                                selectedContainerColor = LattePrimary.copy(alpha = 0.15f),
                                selectedLabelColor = LattePrimary,
                            ),
                        )
                    }
                }

                // Auto Discover + Scan QR
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(
                        onClick = {
                            viewModel.autoDiscoverForSheet { h, p, n, msg ->
                                if (h.isNotEmpty()) {
                                    host = h
                                    port = p
                                    name = n
                                }
                                discoveryMessage = msg
                            }
                        },
                        enabled = !discoveryRunning,
                    ) {
                        if (discoveryRunning) {
                            CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                            Spacer(modifier = Modifier.width(4.dp))
                            Text(stringResource(R.string.searching))
                        } else {
                            Text(stringResource(R.string.auto_discover), color = LattePrimary)
                        }
                    }
                    TextButton(onClick = onScan, enabled = !discoveryRunning) {
                        Text(stringResource(R.string.scan_qr), color = LattePrimary)
                    }
                }

                // 配对码（可选：填了保存后自动发起配对）
                OutlinedTextField(
                    value = pairingCode,
                    onValueChange = { pairingCode = it.filter { c -> c.isDigit() }.take(6) },
                    label = { Text(stringResource(R.string.pairing_code_optional)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth(),
                )

                if (discoveryMessage.isNotEmpty()) {
                    Text(
                        text = discoveryMessage,
                        style = MaterialTheme.typography.bodySmall,
                        color = LatteOnSurfaceVariant,
                    )
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm(name, host, port, osType, pairingCode.trim()) },
                enabled = host.trim().isNotEmpty(),
            ) {
                Text(if (initialHost.isEmpty()) stringResource(R.string.add) else stringResource(R.string.save), color = LattePrimary)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.cancel), color = LatteOnSurfaceVariant)
            }
        },
    )
}

// ─── Language menu（App 内切换，对齐 iOS LangMode system/zh/en）───────────────

@Composable
private fun LanguageMenuButton() {
    var showMenu by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val currentMode = remember(context) { LocalePrefs.mode(context) }

    Box {
        TextButton(onClick = { showMenu = true }) {
            Text(
                text = stringResource(R.string.language),
                fontSize = 12.sp,
                color = LatteOnSurfaceVariant,
            )
        }
        DropdownMenu(
            expanded = showMenu,
            onDismissRequest = { showMenu = false },
            containerColor = LatteCard,
        ) {
            // 语言名按惯例用各自语言显示，不随界面语言翻译
            fun pick(mode: LocalePrefs.LangMode) {
                LocalePrefs.setMode(context, mode)
                showMenu = false
                (context as? android.app.Activity)?.recreate()
            }
            DropdownMenuItem(
                text = { Text(stringResource(R.string.follow_system), color = LatteOnSurface) },
                onClick = { pick(LocalePrefs.LangMode.System) },
                trailingIcon = {
                    if (currentMode == LocalePrefs.LangMode.System) {
                        Icon(Icons.Filled.Check, contentDescription = null, tint = LattePrimary, modifier = Modifier.size(16.dp))
                    }
                },
            )
            DropdownMenuItem(
                text = { Text("中文", color = LatteOnSurface) },
                onClick = { pick(LocalePrefs.LangMode.Zh) },
                trailingIcon = {
                    if (currentMode == LocalePrefs.LangMode.Zh) {
                        Icon(Icons.Filled.Check, contentDescription = null, tint = LattePrimary, modifier = Modifier.size(16.dp))
                    }
                },
            )
            DropdownMenuItem(
                text = { Text("English", color = LatteOnSurface) },
                onClick = { pick(LocalePrefs.LangMode.En) },
                trailingIcon = {
                    if (currentMode == LocalePrefs.LangMode.En) {
                        Icon(Icons.Filled.Check, contentDescription = null, tint = LattePrimary, modifier = Modifier.size(16.dp))
                    }
                },
            )
        }
    }
}
