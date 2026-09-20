package com.brewping.android.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.brewping.android.BrewPingConfig
import com.brewping.android.R
import com.brewping.android.ui.theme.LatteAccent
import com.brewping.android.ui.theme.LatteBackground
import com.brewping.android.ui.theme.LatteBorder
import com.brewping.android.ui.theme.LatteCard
import com.brewping.android.ui.theme.LatteOnSurface
import com.brewping.android.ui.theme.LatteOnSurfaceVariant
import com.brewping.android.ui.theme.LattePrimary

/**
 * Help / About 页（对齐 iOS `ios/BrewPing/HelpView.swift`）。
 *
 * 商店审核要求每个 App 都能在**站内**找到：
 *   - 使用说明（"需要配套电脑端"——Mac / Windows 都支持）
 *   - 隐私政策入口
 *   - 支持联系方式
 *   - 第三方商标免责声明
 * 缺这些会被追问（iOS 侧是 2.1 / 5.1.2 / 5.2.1）。
 *
 * 与 iOS 的两处**有意差异**：
 *   1. 语言切换不放在这里 —— Android 顶栏已有 `LanguageMenuButton`（
 *      功能等价，只是位置不同，见 `HomeScreen.kt`）；
 *   2. 暂无「添加演示设备」段 —— Android 尚未实现 Demo 模式（对齐清单 P1）。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HelpScreen(onDismiss: () -> Unit) {
    val context = LocalContext.current
    val version = remember(context) { BrewPingConfig.displayVersion(context) }

    fun open(url: String) {
        runCatching {
            context.startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse(url))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }
    }

    Scaffold(
        containerColor = LatteBackground,
        topBar = {
            CenterAlignedTopAppBar(
                title = {
                    Text(
                        text = stringResource(R.string.help_about),
                        fontWeight = FontWeight.SemiBold,
                        color = LatteOnSurface,
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onDismiss) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.back),
                            tint = LatteOnSurfaceVariant,
                        )
                    }
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
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            // ─── 使用说明 ────────────────────────────────────────────────────
            HelpSection(stringResource(R.string.help_how_title)) {
                HelpBody(stringResource(R.string.help_how_body))
                HelpBullet(stringResource(R.string.help_how_phone))
                HelpBullet(stringResource(R.string.help_how_desktop, BrewPingConfig.DESKTOP_APP_NAME))
            }

            // ─── 配置电脑（4 步）────────────────────────────────────────────
            HelpSection(stringResource(R.string.help_setup_title)) {
                NumberedStep(1, stringResource(R.string.help_step_install, BrewPingConfig.DESKTOP_APP_NAME))
                NumberedStep(2, stringResource(R.string.help_step_wifi))
                NumberedStep(3, stringResource(R.string.help_step_code, BrewPingConfig.DESKTOP_APP_NAME))
                NumberedStep(4, stringResource(R.string.help_step_enter))
                Spacer(Modifier.height(2.dp))
                HelpFootnote(stringResource(R.string.help_no_account))
            }

            // ─── 隐私 ────────────────────────────────────────────────────────
            HelpSection(stringResource(R.string.help_privacy_title)) {
                LinkRow(
                    label = stringResource(R.string.help_privacy_link),
                    onClick = { open(BrewPingConfig.PRIVACY_POLICY_URL) },
                )
                Spacer(Modifier.height(6.dp))
                HelpFootnote(stringResource(R.string.help_privacy_body))
            }

            // ─── 支持 ────────────────────────────────────────────────────────
            HelpSection(stringResource(R.string.help_support_title)) {
                LinkRow(
                    label = BrewPingConfig.SUPPORT_EMAIL,
                    onClick = { open("mailto:" + BrewPingConfig.SUPPORT_EMAIL) },
                )
            }

            // ─── 法律信息（商标免责）────────────────────────────────────────
            HelpSection(stringResource(R.string.help_legal_title)) {
                HelpFootnote(stringResource(R.string.help_legal_body))
            }

            // ─── 关于 ────────────────────────────────────────────────────────
            HelpSection(stringResource(R.string.help_about_title)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    HelpBody(stringResource(R.string.help_version))
                    Text(
                        text = version,
                        fontSize = 13.sp,
                        color = LatteOnSurfaceVariant,
                    )
                }
            }

            Spacer(Modifier.height(4.dp))
        }
    }
}

// ─── 组内小组件（刻意保持最小依赖：只用 material3 基础件 + Latte 令牌）──────────

@Composable
private fun HelpSection(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            text = title,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            color = LatteOnSurfaceVariant,
            modifier = Modifier.padding(start = 4.dp),
        )
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(LatteCard, RoundedCornerShape(14.dp))
                .border(1.dp, LatteBorder, RoundedCornerShape(14.dp))
                .padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            content()
        }
    }
}

/** 正文（读得清但略弱于标题） */
@Composable
private fun HelpBody(text: String) {
    Text(text = text, fontSize = 13.sp, color = LatteOnSurface, lineHeight = 19.sp)
}

/** 脚注（对齐 iOS 的 .footnote + .secondary） */
@Composable
private fun HelpFootnote(text: String) {
    Text(text = text, fontSize = 12.sp, color = LatteOnSurfaceVariant, lineHeight = 18.sp)
}

/** 项目符号行 */
@Composable
private fun HelpBullet(text: String) {
    Row(modifier = Modifier.fillMaxWidth()) {
        Text(text = "·", fontSize = 13.sp, color = LatteOnSurfaceVariant)
        Spacer(Modifier.width(8.dp))
        Text(
            text = text,
            fontSize = 13.sp,
            color = LatteOnSurface,
            lineHeight = 19.sp,
        )
    }
}

/** 序号步骤（对齐 iOS `numberedStep`） */
@Composable
private fun NumberedStep(index: Int, text: String) {
    Row(modifier = Modifier.fillMaxWidth()) {
        Text(
            text = "$index.",
            fontSize = 13.sp,
            color = LatteOnSurfaceVariant,
            modifier = Modifier.width(20.dp),
        )
        Text(
            text = text,
            fontSize = 13.sp,
            color = LatteOnSurface,
            lineHeight = 19.sp,
        )
    }
}

/** 可点链接行（隐私政策 / 支持邮箱） */
@Composable
private fun LinkRow(label: String, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(LatteAccent, RoundedCornerShape(8.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = label,
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
            color = LattePrimary,
        )
    }
}
