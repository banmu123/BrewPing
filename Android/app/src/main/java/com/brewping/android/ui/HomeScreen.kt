package com.brewping.android.ui

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.brewping.android.model.DesktopDevice
import com.brewping.android.ui.theme.BrewPingAmber
import com.brewping.android.ui.theme.BrewPingGreen
import com.brewping.android.ui.theme.BrewPingGreenDim
import com.brewping.android.ui.theme.BrewPingOnSurfaceVariant
import com.brewping.android.ui.theme.BrewPingRed
import com.brewping.android.ui.theme.BrewPingSurfaceVariant

@Composable
fun HomeScreen(viewModel: HomeViewModel) {
    val uiState by viewModel.uiState.collectAsState()

    Surface(
        modifier = Modifier.fillMaxSize(),
        color = MaterialTheme.colorScheme.background,
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 24.dp, vertical = 48.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            // Header
            Text(
                text = "BrewPing",
                style = MaterialTheme.typography.headlineLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )

            Spacer(modifier = Modifier.weight(1f))

            // Content area
            when (val state = uiState) {
                is HomeUiState.Idle -> SearchingContent()
                is HomeUiState.Searching -> SearchingContent()
                is HomeUiState.Connecting -> ConnectingContent()
                is HomeUiState.Connected -> ConnectedContent(device = state.device)
                is HomeUiState.Disconnected -> DisconnectedContent(device = state.device)
                is HomeUiState.Error -> ErrorContent(message = state.message)
            }

            Spacer(modifier = Modifier.weight(1f))

            // Refresh button
            Button(
                onClick = { viewModel.refresh() },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(48.dp),
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = MaterialTheme.colorScheme.primary,
                ),
            ) {
                Text(
                    text = "Refresh",
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onPrimary,
                )
            }
        }
    }
}

// ─── State-specific content ───────────────────────────────────────────────────

@Composable
private fun SearchingContent() {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        PulsingDot(color = BrewPingAmber)
        Spacer(modifier = Modifier.height(16.dp))
        Text(
            text = "Searching for BrewPing Desktop...",
            style = MaterialTheme.typography.bodyLarge,
            color = BrewPingOnSurfaceVariant,
        )
    }
}

@Composable
private fun ConnectingContent() {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        PulsingDot(color = BrewPingAmber)
        Spacer(modifier = Modifier.height(16.dp))
        Text(
            text = "Connecting...",
            style = MaterialTheme.typography.bodyLarge,
            color = BrewPingOnSurfaceVariant,
        )
    }
}

@Composable
private fun ConnectedContent(device: DesktopDevice) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = Modifier.fillMaxWidth(),
    ) {
        // Desktop card
        DeviceCard(
            title = "BrewPing Desktop",
            name = device.name,
            statusDotColor = BrewPingGreen,
            statusText = "Online",
        )

        Spacer(modifier = Modifier.height(20.dp))

        // Agent section
        if (device.agentName.isNotEmpty()) {
            AgentCard(
                agentName = device.agentName,
                address = "${device.ip}:${device.port}",
                statusText = "Connected",
                statusDotColor = BrewPingGreen,
            )
        } else if (device.agents.isNotEmpty()) {
            // Show first available agent
            val agent = device.agents.firstOrNull { it.active }
                ?: device.agents.firstOrNull { it.installed }
                ?: device.agents.first()
            AgentCard(
                agentName = agent.name,
                address = "${device.ip}:${device.port}",
                statusText = if (agent.active) "Running" else "Available",
                statusDotColor = if (agent.active) BrewPingGreen else BrewPingAmber,
            )
        } else {
            AgentCard(
                agentName = "No agent",
                address = "${device.ip}:${device.port}",
                statusText = "Unknown",
                statusDotColor = BrewPingGreenDim,
            )
        }
    }
}

@Composable
private fun DisconnectedContent(device: DesktopDevice?) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        if (device != null) {
            DeviceCard(
                title = "BrewPing Desktop",
                name = device.name,
                statusDotColor = BrewPingRed,
                statusText = "Offline",
            )
            Spacer(modifier = Modifier.height(20.dp))
        }

        PulsingDot(color = BrewPingAmber)
        Spacer(modifier = Modifier.height(12.dp))
        Text(
            text = if (device != null) "Searching..." else "No BrewPing Desktop found",
            style = MaterialTheme.typography.bodyLarge,
            color = BrewPingOnSurfaceVariant,
        )
        if (device == null) {
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = "Make sure Desktop is running on your network",
                style = MaterialTheme.typography.bodySmall,
                color = BrewPingOnSurfaceVariant.copy(alpha = 0.7f),
            )
        }
    }
}

@Composable
private fun ErrorContent(message: String) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            text = "Error",
            style = MaterialTheme.typography.titleMedium,
            color = BrewPingRed,
        )
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            text = message,
            style = MaterialTheme.typography.bodyMedium,
            color = BrewPingOnSurfaceVariant,
        )
    }
}

// ─── Reusable components ──────────────────────────────────────────────────────

@Composable
private fun DeviceCard(
    title: String,
    name: String,
    statusDotColor: androidx.compose.ui.graphics.Color,
    statusText: String,
) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        color = BrewPingSurfaceVariant,
    ) {
        Column(modifier = Modifier.padding(20.dp)) {
            Text(
                text = title,
                style = MaterialTheme.typography.labelMedium,
                color = BrewPingOnSurfaceVariant,
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = name,
                style = MaterialTheme.typography.titleMedium.copy(
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 18.sp,
                ),
                color = MaterialTheme.colorScheme.onSurface,
            )
            Spacer(modifier = Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                StatusDot(color = statusDotColor)
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    text = statusText,
                    style = MaterialTheme.typography.bodyMedium,
                    color = BrewPingOnSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun AgentCard(
    agentName: String,
    address: String,
    statusText: String,
    statusDotColor: androidx.compose.ui.graphics.Color,
) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        color = BrewPingSurfaceVariant,
    ) {
        Column(modifier = Modifier.padding(20.dp)) {
            Text(
                text = "Agent",
                style = MaterialTheme.typography.labelMedium,
                color = BrewPingOnSurfaceVariant,
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = agentName,
                style = MaterialTheme.typography.titleMedium.copy(
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 18.sp,
                ),
                color = MaterialTheme.colorScheme.onSurface,
            )
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = address,
                style = MaterialTheme.typography.bodySmall,
                color = BrewPingOnSurfaceVariant,
            )
            Spacer(modifier = Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                StatusDot(color = statusDotColor)
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    text = statusText,
                    style = MaterialTheme.typography.bodyMedium,
                    color = BrewPingOnSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun StatusDot(color: androidx.compose.ui.graphics.Color) {
    Box(
        modifier = Modifier
            .size(8.dp)
            .background(color = color, shape = CircleShape)
    )
}

@Composable
private fun PulsingDot(color: androidx.compose.ui.graphics.Color) {
    val infiniteTransition = rememberInfiniteTransition(label = "pulse")
    val alpha by infiniteTransition.animateFloat(
        initialValue = 0.3f,
        targetValue = 1.0f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1000),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "pulseAlpha",
    )

    Box(
        modifier = Modifier
            .size(10.dp)
            .alpha(alpha)
            .background(color = color, shape = CircleShape)
    )
}
