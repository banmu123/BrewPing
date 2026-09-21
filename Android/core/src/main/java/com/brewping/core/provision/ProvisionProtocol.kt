package com.brewping.core.provision

/**
 * 手机 → 手表 provisioning 协议常量（:app 发送方与 :wear 接收方共用，防两处漂移）。
 *
 * payload（JSON，UTF-8，经 Wearable Data Layer 的 MessageClient 传输）：
 * ```json
 * {
 *   "deviceId": "...",   // 桌面端身份（token 的归属键）
 *   "deviceName": "...",
 *   "host": "192.168.1.10",
 *   "port": 8787,
 *   "token": "...",      // ⚠️ 手表端必须加密持久化（PairingStore），绝不普通落盘
 *   "langMode": "system" // 可选：手机端语言偏好，手表跟随
 * }
 * ```
 */
object ProvisionProtocol {
    const val MESSAGE_PATH = "/brewping/provision"
}
