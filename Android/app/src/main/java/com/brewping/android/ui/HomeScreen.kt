package com.brewping.android.ui

import androidx.compose.foundation.background
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.brewping.android.model.AgentEntry
import com.brewping.android.model.CommandPhase
import com.brewping.android.model.SessionState
import com.brewping.android.ui.theme.BrewPingAmber
import com.brewping.android.ui.theme.BrewPingGreen
import com.brewping.android.ui.theme.BrewPingGreenDim
import com.brewping.android.ui.theme.BrewPingOnSurfaceVariant
import com.brewping.android.ui.theme.BrewPingRed
import com.brewping.android.ui.theme.BrewPingSurfaceVariant

@Composable
fun HomeScreen(viewModel: HomeViewModel) {
    val macAddress by viewModel.macAddress.collectAsState()
    val port by viewModel.port.collectAsState()
    val online by viewModel.online.collectAsState()
    val hostName by viewModel.hostName.collectAsState()
    val agents by viewModel.agents.collectAsState()
    val sessionState by viewModel.sessionState.collectAsState()
    val sessionMessage by viewModel.sessionMessage.collectAsState()
    val lifecycleBusy by viewModel.lifecycleBusy.collectAsState()
    val commandPhase by viewModel.commandPhase.collectAsState()
    val messageText by viewModel.messageText.collectAsState()
    val discoveryRunning by viewModel.discoveryRunning.collectAsState()
    val discoveryMessage by viewModel.discoveryMessage.collectAsState()

    val scrollState = rememberScrollState()

    Surface(
        modifier = Modifier.fillMaxSize(),
        color = MaterialTheme.colorScheme.background,
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(scrollState)
                .padding(16.dp),
        ) {
            // Header
            Text(
                text = "BrewPing",
                style = MaterialTheme.typography.headlineLarge,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.padding(bottom = 16.dp),
            )

            // ─── Mac Section ──────────────────────────────────────────────────
            SectionCard(title = "Mac") {
                // IP Address field
                OutlinedTextField(
                    value = macAddress,
                    onValueChange = { viewModel.updateMacAddress(it) },
                    label = { Text("Mac Address (e.g. 192.168.3.94)") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !online,
                )

                Spacer(modifier = Modifier.height(8.dp))

                // Port + Auto button
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    OutlinedTextField(
                        value = port,
                        onValueChange = { viewModel.updatePort(it) },
                        label = { Text("Port") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        singleLine = true,
                        modifier = Modifier.width(100.dp),
                        enabled = !online,
                    )
                    Spacer(modifier = Modifier.width(12.dp))
                    TextButton(
                        onClick = { viewModel.autoDiscover() },
                        enabled = !discoveryRunning && !online,
                    ) {
                        if (discoveryRunning) {
                            CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                            Spacer(modifier = Modifier.width(4.dp))
                            Text("Searching...")
                        } else {
                            Text("Auto")
                        }
                    }
                }

                Spacer(modifier = Modifier.height(8.dp))

                // Status dot + Check button
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    StatusDot(color = if (online) BrewPingGreen else BrewPingRed)
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(
                        text = if (online) "Connected" else "Offline",
                        style = MaterialTheme.typography.bodyMedium,
                        color = BrewPingOnSurfaceVariant,
                    )
                    Spacer(modifier = Modifier.weight(1f))
                    TextButton(
                        onClick = { viewModel.checkConnection() },
                        enabled = !discoveryRunning && macAddress.isNotBlank(),
                    ) {
                        if (discoveryRunning) {
                            CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                            Spacer(modifier = Modifier.width(4.dp))
                            Text("Checking...")
                        } else {
                            Text("Check")
                        }
                    }
                }

                // Hostname
                if (hostName.isNotEmpty()) {
                    Text(
                        text = hostName,
                        style = MaterialTheme.typography.bodySmall,
                        color = BrewPingOnSurfaceVariant,
                    )
                }

                // Discovery message
                if (discoveryMessage.isNotEmpty()) {
                    val isError = discoveryMessage.contains("failed", ignoreCase = true)
                    Text(
                        text = discoveryMessage,
                        style = MaterialTheme.typography.bodySmall,
                        color = if (isError) BrewPingRed else BrewPingOnSurfaceVariant,
                    )
                }
            }

            Spacer(modifier = Modifier.height(12.dp))

            // ─── Agents Section ───────────────────────────────────────────────
            SectionCard(title = "Available AI Agents") {
                if (agents.isEmpty()) {
                    Text(
                        text = if (online) "Detecting agents..." else "Connect to the Mac to detect agents.",
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

            // ─── Active Agent / Session Section ───────────────────────────────
            val activeAgent = agents.firstOrNull { it.active }
            SectionCard(title = "Active Agent") {
                if (activeAgent != null) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = activeAgent.name,
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Spacer(modifier = Modifier.width(8.dp))
                        SessionStateDot(state = sessionState)
                        Spacer(modifier = Modifier.width(6.dp))
                        Text(
                            text = sessionStateLabel(sessionState),
                            style = MaterialTheme.typography.bodyMedium,
                            color = BrewPingOnSurfaceVariant,
                        )
                    }

                    // Session message
                    if (sessionMessage.isNotEmpty()) {
                        Text(
                            text = sessionMessage,
                            style = MaterialTheme.typography.bodySmall,
                            color = BrewPingOnSurfaceVariant,
                        )
                    }

                    Spacer(modifier = Modifier.height(8.dp))

                    // Start / Stop button (only for opencode-type agents)
                    if (activeAgent.id == "opencode") {
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
                        Text(
                            text = "This agent runs commands on demand — no persistent session to manage.",
                            style = MaterialTheme.typography.bodySmall,
                            color = BrewPingOnSurfaceVariant,
                        )
                    }
                } else {
                    Text(
                        text = if (online) "No active agent." else "Connect to the Mac first.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = BrewPingOnSurfaceVariant,
                    )
                }
            }

            Spacer(modifier = Modifier.height(12.dp))

            // ─── Message Section ──────────────────────────────────────────────
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

            // ─── Result Section ───────────────────────────────────────────────
            SectionCard(title = "Result") {
                ResultView(phase = commandPhase)
            }

            // Footer
            Spacer(modifier = Modifier.height(24.dp))
            Text(
                text = "Dev use only: the Mac Agent must run on the same local network. This API has no authentication.",
                style = MaterialTheme.typography.bodySmall,
                color = BrewPingOnSurfaceVariant.copy(alpha = 0.6f),
                modifier = Modifier.padding(horizontal = 4.dp),
            )
            Spacer(modifier = Modifier.height(16.dp))
        }
    }
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
        // Green/gray dot
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

        // Set Default button
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
private fun ResultView(phase: CommandPhase) {
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
            if (modelId != null) {
                Spacer(modifier = Modifier.width(8.dp))
                Text(modelId, style = MaterialTheme.typography.bodySmall, color = BrewPingOnSurfaceVariant)
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
private fun SessionStateDot(state: SessionState) {
    val color = when (state) {
        SessionState.Running -> BrewPingGreen
        SessionState.Starting, SessionState.Stopping -> BrewPingAmber
        SessionState.Offline -> BrewPingRed
    }
    StatusDot(color = color)
}

private fun sessionStateLabel(state: SessionState): String = when (state) {
    SessionState.Running -> "Running"
    SessionState.Starting -> "Starting"
    SessionState.Stopping -> "Stopping"
    SessionState.Offline -> "Offline"
}
