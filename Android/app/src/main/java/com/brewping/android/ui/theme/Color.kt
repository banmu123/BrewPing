package com.brewping.android.ui.theme

import androidx.compose.ui.graphics.Color

// ─── BrewPing 拿铁主题（与 iOS `LatteTheme.swift` / Windows 桌面端 `styles/app.css` 一一对应）──
//
// 换算自桌面端：
//   --background hsl(40 44% 97%)  奶白画布      --card      hsl(42 50% 99%)  奶泡卡片
//   --foreground hsl(24 32% 22%)  深咖文本      --primary   hsl(24 45% 40%)  暖咖品牌
//   --secondary  hsl(36 38% 91%)  米色气泡      --accent    hsl(34 42% 88%)  浅棕悬停面
//   --border     hsl(33 26% 85%)                --success   hsl(96 28% 36%)  抹茶绿
//   --warning    hsl(33 75% 42%)  焦糖琥珀      --destructive hsl(10 55% 44%) 暖红陶土
//
// 用法：视图里一律使用 Latte* 色，不要再写 Color(0xFF...) 字面量或 Material 默认蓝，
// 否则会与 iOS / Windows 端配色割裂。

/** 奶白画布（页面底色） */
val LatteBackground = Color(0xFFFBF8F4)
/** 奶泡卡片（比画布更亮一档，用于卡片/列表行/输入框底） */
val LatteCard = Color(0xFFFEFDFB)
/** 深咖主文本 */
val LatteOnSurface = Color(0xFF4A3526)
/** 暖咖品牌色（按钮/强调/发送钮） */
val LattePrimary = Color(0xFF945D38)
/** 主色上的前景（奶白） */
val LattePrimaryForeground = Color(0xFFFDFCFA)
/** 米色（用户气泡底色） */
val LatteSecondary = Color(0xFFF1EADF)
/** 米色上的深咖文本 */
val LatteOnSecondary = Color(0xFF583E2D)
/** 弱化面（禁用/次级底） */
val LatteMuted = Color(0xFFF1ECE4)
/** 弱化文本（时间戳、元信息、说明） */
val LatteOnSurfaceVariant = Color(0xFF876E5A)
/** 浅棕悬停面（选中行、chip 底） */
val LatteAccent = Color(0xFFEDE2D4)
/** 细边框 */
val LatteBorder = Color(0xFFE3DACF)
/** 输入控件边框 */
val LatteInputBorder = Color(0xFFD8CDC0)
/** 抹茶绿（成功/在线/已完成，低饱和） */
val LatteSuccess = Color(0xFF577542)
/** 焦糖琥珀（警告/进行中/Starting） */
val LatteWarning = Color(0xFFBB731B)
/** 暖红陶土（错误/离线/删除） */
val LatteDestructive = Color(0xFFAE4732)

// ─── 兼容别名（旧视图引用名；值已切换为拿铁色，逐步迁移后删除）────────────────
val BrewPingBackground = LatteBackground
val BrewPingSurface = LatteCard
val BrewPingOnSurface = LatteOnSurface
val BrewPingOnSurfaceVariant = LatteOnSurfaceVariant
val BrewPingPrimary = LattePrimary
val BrewPingPrimaryVariant = Color(0xFF7B4C2C)
val BrewPingGreen = LatteSuccess
val BrewPingGreenDim = LatteMuted
val BrewPingRed = LatteDestructive
val BrewPingAmber = LatteWarning
val BrewPingDivider = LatteBorder
val BrewPingSurfaceVariant = LatteCard
