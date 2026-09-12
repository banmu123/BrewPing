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
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.brewping.android.model.DesktopDevice
import com.brewping.android.model.DeviceOSType
import com.brewping.android.model.ManagedDevice
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
    /** 表单扫码结果（DeviceFormDialog 预填 host/port/name）。 */
    var qrFormPayload by remember { mutableStateOf<com.brewping.android.model.PairPayload?>(null) }
    val discovered by viewModel.discoveredDevices.collectAsState()
    val pairingVersion by viewModel.pairingVersion.collectAsState()

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
                    val slide = tween<IntOffset>(BrewMotion.Normal, easing = BrewMotion.StandardEasing)                    val fade = tween<Float>(BrewMotion.Fast, easing = BrewMotion.FastEasing)
                    if (targetState == "list") {
                        // 返回（pop）：详情滑出右侧，列表自左浅移淡入
                        (slideOutHorizontally(slide) { it } + fadeOut(fade)) togetherWith
                            (slideInHorizontally(slide) { -it / 3 } + fadeIn(fade))
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
                        EmptyStateCard(modifier = Modifier.padding(16.dp))
                    }
                    device == null -> EmptyStateCard(modifier = Modifier.padding(16.dp))
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
                        onBindWorkdir = { path ->
                            detailId?.let { viewModel.setConversationWorkdir(it, path) {} }
                        },
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
            title = "Add Device",
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
                viewModel.setActive(managed.id)
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
            title = "Edit Device",
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
            onScan = { qrTarget = "pair"; showQrScan = true },
            onPair = viewModel::pairWithCode,
        )
    }

    // ─── QR 扫码（配对码 / 添加设备表单）─────────────────────────────────────
    if (showQrScan) {
        QrScanScreen(
            onResult = { payload ->
                showQrScan = false
                if (qrTarget == "pair") {
                    // 扫到的码可能属于别的机器：以码为准换目标设备
                    val target = if (payload.host.isNotEmpty() && payload.host != showPairFor?.host) {
                        ManagedDevice.new(
                            name = payload.name.ifEmpty { "Desktop" },
                            host = payload.host,
                            port = payload.port,
                        ).also { viewModel.addDevice(it); viewModel.setActive(it.id) }
                    } else {
                        showPairFor
                    }
                    pairInitialCode = payload.code
                    if (target != null) showPairFor = target
                } else {
                    qrFormPayload = payload
                    showAddDevice = true
                }
            },
            onDismiss = { showQrScan = false },
        )
    }
}

// ─── Empty state（对齐 iOS emptyStateCard）────────────────────────────────────

@Composable
private fun EmptyStateCard(modifier: Modifier = Modifier) {
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
                text = "Add your first computer",
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                color = LatteOnSurface,
            )
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = "Run BrewPing on your computer, then add it with \"+\" to send commands from your phone.",
                fontSize = 12.sp,
                color = LatteOnSurfaceVariant,
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
                        text = { Text("Edit", color = LatteOnSurface) },
                        onClick = { showMenu = false; onEdit() },
                    )
                    DropdownMenuItem(
                        text = { Text("Delete", color = LatteDestructive) },
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

    // 扫码预填 6 位码 → 自动发起配对
    LaunchedEffect(initialCode) {
        if (initialCode.length == 6) {
            busy = true
            message = null
            onPair(device, initialCode) { ok, msg ->
                busy = false
                message = msg
                if (ok) onDismiss()
            }
        }
    }

    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        containerColor = LatteCard,
        title = { Text("Pair \"${device.name.ifEmpty { device.host }}\"", color = LatteOnSurface) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    text = "1. Open the BrewPing app on the desktop and click \"Show Pairing Code\".\n2. Enter the 6-digit code, or scan the QR code next to it.",
                    fontSize = 12.sp,
                    color = LatteOnSurfaceVariant,
                )
                OutlinedTextField(
                    value = code,
                    onValueChange = { code = it.filter { c -> c.isDigit() }.take(6) },
                    label = { Text("6-digit pairing code") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth(),
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = onScan, enabled = !busy) {
                        Text("Scan QR Code", color = LattePrimary)
                    }
                }
                message?.let {
                    Text(
                        text = it,
                        fontSize = 12.sp,
                        color = if (it.startsWith("Paired")) LatteSuccess else LatteDestructive,
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
                        if (ok) onDismiss()
                    }
                },
            ) {
                Text(if (busy) "Pairing…" else "Pair", color = LattePrimary)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, enabled = !busy) {
                Text("Cancel", color = LatteOnSurfaceVariant)
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
                    text = "Nearby:",
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
                            Text("Add", color = LattePrimary)
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
    scannedPayload: com.brewping.android.model.PairPayload? = null,
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

    // 扫码预填：host / port / 名称 / 配对码（对齐 iOS PairingURLHandler）
    LaunchedEffect(scannedPayload) {
        scannedPayload?.let { payload ->
            if (payload.host.isNotEmpty()) host = payload.host
            if (payload.port.isNotEmpty()) port = payload.port
            if (payload.name.isNotEmpty() && name.isEmpty()) name = payload.name
            if (payload.code.isNotEmpty()) pairingCode = payload.code
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
                    label = { Text("Name (e.g. Chenzk)") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = host,
                    onValueChange = { host = it },
                    label = { Text("Host (IP or hostname)") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = port,
                    onValueChange = { port = it },
                    label = { Text("Port") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )

                // OS Type picker
                Text("System", style = MaterialTheme.typography.labelMedium, color = LatteOnSurfaceVariant)
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
                            Text("Searching...")
                        } else {
                            Text("Auto Discover", color = LattePrimary)
                        }
                    }
                    TextButton(onClick = onScan, enabled = !discoveryRunning) {
                        Text("Scan QR", color = LattePrimary)
                    }
                }

                // 配对码（可选：填了保存后自动发起配对）
                OutlinedTextField(
                    value = pairingCode,
                    onValueChange = { pairingCode = it.filter { c -> c.isDigit() }.take(6) },
                    label = { Text("Pairing code (optional)") },
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
                Text(if (initialHost.isEmpty()) "Add" else "Save", color = LattePrimary)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel", color = LatteOnSurfaceVariant)
            }
        },
    )
}
