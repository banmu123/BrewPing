package com.brewping.android.ui

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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.brewping.android.model.AgentEntry
import com.brewping.android.model.CommandPhase
import com.brewping.android.model.DeviceOSType
import com.brewping.android.model.ManagedDevice
import com.brewping.android.model.SessionState
import com.brewping.android.ui.theme.BrewPingAmber
import com.brewping.android.ui.theme.BrewPingGreen
import com.brewping.android.ui.theme.BrewPingGreenDim
import com.brewping.android.ui.theme.BrewPingOnSurfaceVariant
import com.brewping.android.ui.theme.BrewPingPrimary
import com.brewping.android.ui.theme.BrewPingRed
import com.brewping.android.ui.theme.BrewPingSurfaceVariant

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(viewModel: HomeViewModel) {
    val devices by viewModel.devices.collectAsState()
    val activeDeviceID by viewModel.activeDeviceID.collectAsState()
    val online by viewModel.online.collectAsState()
    val agents by viewModel.agents.collectAsState()
    val sessionState by viewModel.sessionState.collectAsState()
    val sessionMessage by viewModel.sessionMessage.collectAsState()
    val lifecycleBusy by viewModel.lifecycleBusy.collectAsState()
    val commandPhase by viewModel.commandPhase.collectAsState()
    val messageText by viewModel.messageText.collectAsState()
    val sessionID by viewModel.sessionID.collectAsState()
    val sessionAgentID by viewModel.sessionAgentID.collectAsState()
    val sessionAgentName by viewModel.sessionAgentName.collectAsState()

    var showAddDevice by remember { mutableStateOf(false) }
    var editingDevice by remember { mutableStateOf<ManagedDevice?>(null) }

    val scrollState = rememberScrollState()

    Scaffold(
        topBar = {
            CenterAlignedTopAppBar(
                title = {
                    Text(
                        text = "BrewPing",
                        fontWeight = FontWeight.SemiBold,
                    )
                },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surface,
                ),
            )
        },
    ) { innerPadding ->
        Surface(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
            color = MaterialTheme.colorScheme.background,
        ) {
            Column(modifier = Modifier.fillMaxSize()) {
                // ─── Device Tab Bar ───────────────────────────────────────────
                DeviceTabBar(
                    devices = devices,
                    activeDeviceID = activeDeviceID,
                    online = online,
                    onSelect = { viewModel.setActiveDevice(it) },
                    onAdd = { showAddDevice = true },
                    onEdit = { editingDevice = it },
                    onDelete = { viewModel.removeDevice(it) },
                )

                // ─── Scrollable Content ───────────────────────────────────────
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(scrollState)
                        .padding(16.dp),
                ) {
                    // ─── Agents Section ───────────────────────────────────────
                    SectionCard(title = "AI Agents") {
                        if (agents.isEmpty()) {
                            Text(
                                text = if (online) "Detecting agents..." else "Connect to detect agents.",
                                style = MaterialTheme.typography.bodyMedium,
                                color = BrewPingOnSurfaceVariant,
                            )
                        } else {
                            agents.forEach { agent ->
                                AgentRow(
                                    agent = agent,
                                    isDefault = agent.active,
                                    onSetDefault = { viewModel.setDefaultAgent(agent.id) },
                                    lifecycleBusy = lifecycleBusy,
                                )
                            }
                        }
                    }

                    Spacer(modifier = Modifier.height(12.dp))

                    // ─── Active Agent / Session Section ───────────────────────
                    SectionCard(title = "Active Agent") {
                        // Only show agent name when there's an active session
                        // (matches iOS: uses sessionAgentNameFromStatus exclusively)
                        val displayName = sessionAgentName

                        if (displayName.isNotEmpty() && sessionState != SessionState.Offline) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    text = displayName,
                                    style = MaterialTheme.typography.titleMedium,
                                    fontWeight = FontWeight.SemiBold,
                                )
                                Spacer(modifier = Modifier.width(8.dp))
                                SessionStateDot(state = sessionState, online = online)
                                Spacer(modifier = Modifier.width(6.dp))
                                Text(
                                    text = sessionStateLabel(sessionState),
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = BrewPingOnSurfaceVariant,
                                )
                            }

                            // Session ID (matches iOS)
                            if (sessionID.isNotEmpty()) {
                                Spacer(modifier = Modifier.height(4.dp))
                                Column {
                                    Text(
                                        text = "Session ID",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = BrewPingOnSurfaceVariant,
                                    )
                                    Text(
                                        text = sessionID.take(12) + "...",
                                        style = MaterialTheme.typography.bodySmall,
                                    )
                                }
                            }

                            if (sessionMessage.isNotEmpty()) {
                                Spacer(modifier = Modifier.height(4.dp))
                                Text(
                                    text = sessionMessage,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = BrewPingOnSurfaceVariant,
                                )
                            }

                            Spacer(modifier = Modifier.height(8.dp))

                            if (sessionAgentID == "opencode") {
                                when (sessionState) {
                                    SessionState.Offline -> {
                                        Button(
                                            onClick = { viewModel.startSession() },
                                            enabled = !lifecycleBusy,
                                            colors = ButtonDefaults.buttonColors(containerColor = BrewPingGreen),
                                        ) {
                                            Text("Start Session")
                                        }
                                    }
                                    SessionState.Running -> {
                                        Button(
                                            onClick = { viewModel.stopSession() },
                                            enabled = !lifecycleBusy,
                                            colors = ButtonDefaults.buttonColors(containerColor = BrewPingRed),
                                        ) {
                                            Text("Stop Session")
                                        }
                                    }
                                    SessionState.Starting, SessionState.Stopping -> {
                                        Row(verticalAlignment = Alignment.CenterVertically) {
                                            CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                                            Spacer(modifier = Modifier.width(8.dp))
                                            Text(
                                                text = if (sessionState == SessionState.Starting) "Starting..." else "Stopping...",
                                                color = BrewPingOnSurfaceVariant,
                                            )
                                        }
                                    }
                                }
                            } else {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text("⚡", fontSize = 12.sp)
                                    Spacer(modifier = Modifier.width(6.dp))
                                    Text(
                                        text = "Ready — type a command below to send",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = BrewPingOnSurfaceVariant,
                                    )
                                }
                            }
                        } else if (online) {
                            // Online but no session — show "No active agent" + start button
                            Text(
                                text = "No active agent.",
                                style = MaterialTheme.typography.bodyMedium,
                                color = BrewPingOnSurfaceVariant,
                            )
                            Spacer(modifier = Modifier.height(8.dp))
                            Button(
                                onClick = { viewModel.startSession() },
                                enabled = !lifecycleBusy,
                                colors = ButtonDefaults.buttonColors(containerColor = BrewPingGreen),
                            ) {
                                Text("Start Session")
                            }
                        } else {
                            Text(
                                text = "Connect to a device first.",
                                style = MaterialTheme.typography.bodyMedium,
                                color = BrewPingOnSurfaceVariant,
                            )
                        }
                    }

                    Spacer(modifier = Modifier.height(12.dp))

                    // ─── Message Section ──────────────────────────────────────
                    SectionCard(title = "Message") {
                        OutlinedTextField(
                            value = messageText,
                            onValueChange = { viewModel.updateMessageText(it) },
                            label = { Text("Hello from Android") },
                            modifier = Modifier.fillMaxWidth(),
                            minLines = 2,
                            maxLines = 5,
                            enabled = sessionState == SessionState.Running,
                        )

                        Spacer(modifier = Modifier.height(8.dp))

                        Button(
                            onClick = { viewModel.sendMessage() },
                            enabled = sessionState == SessionState.Running
                                    && messageText.isNotBlank()
                                    && !commandPhase.isInFlight,
                        ) {
                            if (commandPhase.isInFlight) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(16.dp),
                                    strokeWidth = 2.dp,
                                    color = MaterialTheme.colorScheme.onPrimary,
                                )
                                Spacer(modifier = Modifier.width(8.dp))
                                Text("Sending...")
                            } else {
                                Text("Send")
                            }
                        }
                    }

                    Spacer(modifier = Modifier.height(12.dp))

                    // ─── Result Section ───────────────────────────────────────
                    SectionCard(title = "Result") {
                        ResultView(
                            phase = commandPhase,
                            agentName = sessionAgentName,
                        )
                    }

                    Spacer(modifier = Modifier.height(24.dp))
                }
            }
        }
    }

    // ─── Add Device Dialog ────────────────────────────────────────────────────
    if (showAddDevice) {
        DeviceFormDialog(
            title = "Add Device",
            onDismiss = { showAddDevice = false },
            onConfirm = { name, host, port, osType ->
                viewModel.addDevice(
                    ManagedDevice.new(
                        name = name.ifEmpty { osType.label },
                        host = host,
                        port = port,
                        osType = osType,
                    )
                )
                showAddDevice = false
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
            onConfirm = { name, host, port, osType ->
                viewModel.updateDevice(
                    device.copy(
                        name = name,
                        host = host,
                        port = port,
                        osType = osType,
                    )
                )
                editingDevice = null
            },
            viewModel = viewModel,
        )
    }
}

// ─── Device Tab Bar (matches iOS deviceTabBar) ────────────────────────────────

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
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
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
                    Text("+", fontSize = 22.sp, color = BrewPingPrimary, fontWeight = FontWeight.Bold)
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
        color = if (isActive) BrewPingPrimary.copy(alpha = 0.12f) else MaterialTheme.colorScheme.surfaceVariant,
        border = if (isActive) {
            BorderStroke(1.dp, BrewPingPrimary.copy(alpha = 0.4f))
        } else null,
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
                        color = BrewPingOnSurfaceVariant,
                    )
                    Text(
                        text = device.name.ifEmpty { device.host },
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                    )
                }
                Box(
                    modifier = Modifier
                        .size(5.dp)
                        .background(
                            color = when {
                                isActive && isOnline -> BrewPingGreen
                                isActive -> BrewPingAmber
                                else -> BrewPingGreenDim
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
                    color = BrewPingOnSurfaceVariant,
                    modifier = Modifier
                        .padding(start = 4.dp)
                        .clickable { showMenu = true },
                )
                DropdownMenu(
                    expanded = showMenu,
                    onDismissRequest = { showMenu = false },
                ) {
                    DropdownMenuItem(
                        text = { Text("Edit") },
                        onClick = { showMenu = false; onEdit() },
                    )
                    DropdownMenuItem(
                        text = { Text("Delete", color = BrewPingRed) },
                        onClick = { showMenu = false; onDelete() },
                    )
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
    onDismiss: () -> Unit,
    onConfirm: (name: String, host: String, port: String, osType: DeviceOSType) -> Unit,
    viewModel: HomeViewModel,
) {
    var name by remember { mutableStateOf(initialName) }
    var host by remember { mutableStateOf(initialHost) }
    var port by remember { mutableStateOf(initialPort) }
    var osType by remember { mutableStateOf(initialOS) }
    var discoveryMessage by remember { mutableStateOf("") }

    val discoveryRunning by viewModel.discoveryRunning.collectAsState()

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
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
                Text("System", style = MaterialTheme.typography.labelMedium, color = BrewPingOnSurfaceVariant)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    DeviceOSType.entries.forEach { os ->
                        FilterChip(
                            selected = osType == os,
                            onClick = { osType = os },
                            label = { Text(os.label) },
                            colors = FilterChipDefaults.filterChipColors(
                                selectedContainerColor = BrewPingPrimary.copy(alpha = 0.15f),
                                selectedLabelColor = BrewPingPrimary,
                            ),
                        )
                    }
                }

                // Auto Discover button
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
                        Text("Auto Discover")
                    }
                }

                if (discoveryMessage.isNotEmpty()) {
                    Text(
                        text = discoveryMessage,
                        style = MaterialTheme.typography.bodySmall,
                        color = BrewPingOnSurfaceVariant,
                    )
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm(name, host, port, osType) },
                enabled = host.trim().isNotEmpty(),
            ) {
                Text(if (initialHost.isEmpty()) "Add" else "Save")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
        },
    )
}

// ─── Agent Row ────────────────────────────────────────────────────────────────

@Composable
private fun AgentRow(
    agent: AgentEntry,
    isDefault: Boolean,
    onSetDefault: () -> Unit,
    lifecycleBusy: Boolean,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        StatusDot(color = if (agent.installed) BrewPingGreen else BrewPingGreenDim)
        Spacer(modifier = Modifier.width(8.dp))

        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = agent.name,
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.Medium,
                )
                if (isDefault) {
                    Spacer(modifier = Modifier.width(6.dp))
                    Surface(
                        shape = RoundedCornerShape(4.dp),
                        color = BrewPingGreen.copy(alpha = 0.15f),
                    ) {
                        Text(
                            text = "Default",
                            style = MaterialTheme.typography.labelMedium,
                            color = BrewPingGreen,
                            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                        )
                    }
                }
            }
            Text(
                text = agent.version.ifEmpty { if (agent.installed) "Installed" else "Not Installed" },
                style = MaterialTheme.typography.bodySmall,
                color = BrewPingOnSurfaceVariant,
            )
        }

        if (!isDefault && agent.installed && agent.executable) {
            TextButton(
                onClick = onSetDefault,
                enabled = !lifecycleBusy,
            ) {
                Text("Set Default")
            }
        }
    }
}

// ─── Result View ──────────────────────────────────────────────────────────────

@Composable
private fun ResultView(phase: CommandPhase, agentName: String = "") {
    when (phase) {
        is CommandPhase.Idle -> {
            Text(
                text = "No message sent yet.",
                style = MaterialTheme.typography.bodyMedium,
                color = BrewPingOnSurfaceVariant,
            )
        }
        is CommandPhase.Sending -> {
            Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                Spacer(modifier = Modifier.width(8.dp))
                Text("Sending...", color = BrewPingOnSurfaceVariant)
            }
        }
        is CommandPhase.Delivered -> {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("✓ ", color = BrewPingGreen, fontSize = 16.sp)
                Text("Delivered", color = BrewPingGreen)
                Spacer(modifier = Modifier.width(8.dp))
                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
            }
        }
        is CommandPhase.Working -> {
            Row(verticalAlignment = Alignment.CenterVertically) {
                StatusDot(color = BrewPingAmber)
                Spacer(modifier = Modifier.width(8.dp))
                Text("Working", color = BrewPingAmber)
                Spacer(modifier = Modifier.width(8.dp))
                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
            }
        }
        is CommandPhase.Completed -> {
            ResultContent(
                icon = "✓",
                iconColor = BrewPingGreen,
                label = "Completed",
                duration = phase.duration,
                agentName = agentName,
                modelId = phase.modelId,
                content = phase.response,
            )
        }
        is CommandPhase.CompletedRaw -> {
            ResultContent(
                icon = "✓",
                iconColor = BrewPingGreen,
                label = "Completed",
                duration = phase.duration,
                agentName = agentName,
                modelId = phase.modelId,
                content = phase.rawOutput,
                subtitle = "Raw screen output",
            )
        }
        is CommandPhase.Failed -> {
            ResultContent(
                icon = "✗",
                iconColor = BrewPingRed,
                label = "Failed",
                duration = phase.duration,
                agentName = agentName,
                modelId = phase.modelId,
                content = phase.error,
                failureReason = phase.failureReason,
            )
        }
    }
}

@Composable
private fun ResultContent(
    icon: String,
    iconColor: androidx.compose.ui.graphics.Color,
    label: String,
    duration: Double?,
    agentName: String = "",
    modelId: String?,
    content: String,
    subtitle: String? = null,
    failureReason: String? = null,
) {
    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(icon, color = iconColor, fontSize = 16.sp)
            Spacer(modifier = Modifier.width(6.dp))
            Text(
                text = label + if (duration != null) " · ${String.format("%.1f", duration)}s" else "",
                color = iconColor,
                fontWeight = FontWeight.Medium,
            )
        }
        // Agent name + model line (matches iOS agentModelLine)
        if (agentName.isNotEmpty() || modelId != null) {
            Spacer(modifier = Modifier.height(2.dp))
            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (agentName.isNotEmpty()) {
                    Text(
                        text = agentName,
                        style = MaterialTheme.typography.bodySmall,
                        color = BrewPingOnSurfaceVariant,
                    )
                }
                if (modelId != null) {
                    Text(
                        text = modelId,
                        style = MaterialTheme.typography.bodySmall,
                        color = BrewPingOnSurfaceVariant,
                    )
                }
            }
        }
        if (failureReason != null) {
            Text(
                text = failureReasonLabel(failureReason),
                style = MaterialTheme.typography.bodySmall,
                color = BrewPingRed,
            )
        }
        if (subtitle != null) {
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = BrewPingOnSurfaceVariant)
        }
        if (content.isNotEmpty()) {
            Spacer(modifier = Modifier.height(4.dp))
            Surface(
                shape = RoundedCornerShape(8.dp),
                color = BrewPingSurfaceVariant,
            ) {
                Text(
                    text = content,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(12.dp),
                )
            }
        }
    }
}

private fun failureReasonLabel(reason: String): String = when (reason) {
    "quota_exceeded" -> "Quota exceeded"
    "authentication_failed" -> "Authentication failed"
    "rate_limited" -> "Rate limited"
    "network_error" -> "Network error"
    "model_unavailable" -> "Model unavailable"
    "provider_error" -> "Provider error"
    "timeout" -> "Timeout"
    "process_exited" -> "Process exited"
    else -> reason
}

// ─── Section Card ─────────────────────────────────────────────────────────────

@Composable
private fun SectionCard(
    title: String,
    content: @Composable () -> Unit,
) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        color = BrewPingSurfaceVariant,
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text(
                text = title,
                style = MaterialTheme.typography.labelMedium,
                color = BrewPingOnSurfaceVariant,
                modifier = Modifier.padding(bottom = 8.dp),
            )
            content()
        }
    }
}

// ─── Status dots ──────────────────────────────────────────────────────────────

@Composable
private fun StatusDot(color: androidx.compose.ui.graphics.Color) {
    Box(
        modifier = Modifier
            .size(8.dp)
            .background(color = color, shape = CircleShape),
    )
}

@Composable
private fun SessionStateDot(state: SessionState, online: Boolean = false) {
    val color = when (state) {
        SessionState.Running -> BrewPingGreen
        SessionState.Starting, SessionState.Stopping -> BrewPingAmber
        SessionState.Offline -> if (online) BrewPingGreenDim else BrewPingRed
    }
    StatusDot(color = color)
}

private fun sessionStateLabel(state: SessionState): String = when (state) {
    SessionState.Running -> "Running"
    SessionState.Starting -> "Starting"
    SessionState.Stopping -> "Stopping"
    SessionState.Offline -> "Offline"
}
