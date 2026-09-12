package com.brewping.android.ui.theme

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.lightColorScheme
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

// ─── 动效规范（对齐 iOS 端：SwiftUI 的 withAnimation(.easeOut, 0.15s) 与
//     NavigationStack push/pop 手感）────────────────────────────────────────────
//
// iOS 基准：
//   · 滚动/折叠等就地微动效 = 150ms easeOut；
//   · 导航转场 ≈ 220ms，标准缓出（详情从右滑入 / 返回时滑出）。
// 所有界面动效一律引用 [BrewMotion]，不要在调用点写裸数字。

object BrewMotion {
    /** 就地微动效：折叠箭头、颜色渐变（iOS .easeOut 0.15s）。 */
    const val Fast = 150
    /** 页面转场：列表 ↔ 详情（iOS NavigationStack push/pop 手感）。 */
    const val Normal = 220

    /** ≈ SwiftUI .easeOut：起步快、收尾缓。 */
    val FastEasing = CubicBezierEasing(0f, 0f, 0.2f, 1f)
    /** Material 标准「快出慢进」，用于位移类转场。 */
    val StandardEasing = FastOutSlowInEasing
}

// ─── 形状（iOS 持续圆角的 Compose 对应：卡片 14、大卡/弹层 16-20）──────────────

private val LatteShapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp),
    small = RoundedCornerShape(10.dp),
    medium = RoundedCornerShape(14.dp),
    large = RoundedCornerShape(16.dp),
    extraLarge = RoundedCornerShape(20.dp),
)

// 拿铁主题只做浅色（iOS 端同样固定浅色奶白画布；不跟随系统深色，
// 保证三端观感一致）。
private val LatteColorScheme = lightColorScheme(
    background = LatteBackground,
    surface = LatteCard,
    onSurface = LatteOnSurface,
    onSurfaceVariant = LatteOnSurfaceVariant,
    primary = LattePrimary,
    onPrimary = LattePrimaryForeground,
    secondary = LatteSecondary,
    onSecondary = LatteOnSecondary,
    surfaceVariant = LatteMuted,
    outline = LatteBorder,
    outlineVariant = LatteInputBorder,
    error = LatteDestructive,
    tertiary = LatteSuccess,
)

/**
 * 触感统一：iOS 按压是「整体轻微变暗」，Material 默认 ripple 在奶白底上
 * 显得生硬 —— 这里统一为黑色 8% 透明度的柔和波纹，全 app 生效。
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun BrewPingTheme(content: @Composable () -> Unit) {
    CompositionLocalProvider(
        LocalIndication provides ripple(
            bounded = true,
            color = Color.Black.copy(alpha = 0.08f),
        ),
    ) {
        MaterialTheme(
            colorScheme = LatteColorScheme,
            typography = BrewPingTypography,
            shapes = LatteShapes,
            content = content,
        )
    }
}
