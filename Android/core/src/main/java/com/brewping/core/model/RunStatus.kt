package com.brewping.core.model

import org.json.JSONObject

/**
 * 服务端**权威**执行阶段（协议 DTO）。
 *
 * 来源：桌面端在 `GET /api/message/{commandId}` 响应里新增的 `run` 对象 ——
 * 由桌面端从命令状态（queued / working / completed / failed）+ 输出活跃时刻推导，
 * 阈值与 macOS `Sources/App/ConversationRun.swift` 的 `RunTiming` 一致
 * （stalled = 30s 无新增量）。**客户端只展示，绝不自己按时间猜 stalled。**
 *
 * 阶段取值（与 `ConversationRun.RunPhase` 的真实状态机对齐，未凭空发明）：
 *   queued / thinking / streaming / stalled / completed / failed
 * （submitting 与 stopping 是纯客户端阶段，服务端不产生，见 ConversationRun 注释。）
 */
data class CommandRunStatus(
    val commandId: String = "",
    val phase: String = "",
    /** 命令创建时刻（epoch ms）。 */
    val startedAtMs: Long? = null,
    /** 最后一次收到输出的时刻（epoch ms）；尚无输出为 null。 */
    val lastOutputAtMs: Long? = null,
    /** 服务端生成该快照的时刻（epoch ms），客户端可据此计算本地显示耗时。 */
    val updatedAtMs: Long? = null,
) {

    /** 是否处于「命令在飞」阶段（决定是否继续轮询）。 */
    val isActive: Boolean get() = phase in ACTIVE_PHASES

    /** 是否终态。 */
    val isTerminal: Boolean get() = phase == PHASE_COMPLETED || phase == PHASE_FAILED

    companion object {
        const val PHASE_QUEUED = "queued"
        const val PHASE_THINKING = "thinking"
        const val PHASE_STREAMING = "streaming"
        const val PHASE_STALLED = "stalled"
        const val PHASE_COMPLETED = "completed"
        const val PHASE_FAILED = "failed"

        val ACTIVE_PHASES = setOf(PHASE_QUEUED, PHASE_THINKING, PHASE_STREAMING, PHASE_STALLED)

        fun fromJson(obj: JSONObject): CommandRunStatus = CommandRunStatus(
            commandId = obj.optString("commandId", ""),
            phase = obj.optString("phase", ""),
            startedAtMs = obj.optLongOrNull("startedAtMs"),
            lastOutputAtMs = obj.optLongOrNull("lastOutputAtMs"),
            updatedAtMs = obj.optLongOrNull("updatedAtMs"),
        )

        private fun JSONObject.optLongOrNull(key: String): Long? =
            if (has(key) && !isNull(key)) optLong(key) else null
    }
}
