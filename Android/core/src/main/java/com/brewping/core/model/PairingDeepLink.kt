package com.brewping.core.model

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * 处理从系统相机 / 微信扫桌面端二维码唤起 App 的 `brewping://pair?...` 深链。
 *
 * URL 契约与 iOS `PairingURLHandler` **逐字段一致**：
 *     brewping://pair?host=<ip-or-name>&port=<port>&deviceId=<host-deviceId>&osType=<mac|windows|linux>&code=<6digit>&name=<display>
 *
 * 设计（对齐 iOS）：
 *  - `MainActivity` 在 `onCreate`（冷启动）与 `onNewIntent`（热路径）里把 URL 交进来，
 *    **只做"解析 + 存进 pendingAction"**，不发网络请求 —— 网络与设备状态在 UI 上下文里最稳；
 *  - `HomeScreen` 通过 `LaunchedEffect` 观察 `pendingAction`，消费一次后立刻 `consume()`，
 *    这样冷启动与热路径共用同一条代码路径（iOS 用 `.onOpenURL` + `.onChange` 是同一思路）。
 *
 * 单例：Intent 的入口是 Activity，而 [ManagedDevice] 列表在 ViewModel/Compose 层，
 * 中间需要一个跨生命周期的传递点（与 iOS `@StateObject` 挂在 App 层等价）。
 */
object PairingDeepLink {

    private val _pendingAction = MutableStateFlow<PairPayload?>(null)
    val pendingAction: StateFlow<PairPayload?> = _pendingAction.asStateFlow()

    /**
     * 处理一个传入的 URL 字符串。空 / 非配对深链静默忽略，
     * 避免拉起失败影响正常启动路径（对齐 iOS `handle(_:)`）。
     */
    fun handle(rawUrl: String?) {
        val payload = PairPayload.parse(rawUrl ?: return) ?: return
        // 纯 6 位码（用户手动输入路径）不该走深链 —— 它没有 host，无法定位设备。
        if (payload.host.isEmpty()) return
        _pendingAction.value = payload
    }

    /** 视图消费后调用，避免重复处理同一 URL（对齐 iOS `consume()`）。 */
    fun consume() {
        _pendingAction.value = null
    }
}
