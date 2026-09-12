package com.brewping.android.model

// ─── 对话数据模型（契约对齐 iOS ConversationStore.swift / 桌面端 camelCase）──────
//
// 数据源 = 桌面端 `GET /api/conversations` / `GET /api/conversations/{id}`。
// 全部字段容错解析（老版本桌面端字段可能缺失），避免一条坏数据让整表解码失败。

/** 列表页摘要（元数据层：不含 messages）。 */
data class ConversationSummary(
    val id: String = "",
    val agentId: String = "",
    val title: String? = null,
    val titleSource: String? = null,
    val createdAtMs: Double = 0.0,
    val updatedAtMs: Double = 0.0,
    val archived: Boolean = false,
    val isPinned: Boolean = false,
    val modelOverride: String? = null,
    /** 与 [modelOverride] 配对的 providerId（同名模型可来自多个厂商）。 */
    val modelProviderOverride: String? = null,
    /** 绑定的工作目录；null = 未绑定（归入「未绑定目录」组）。 */
    val workdirOverride: String? = null,
    /** 对话级授权档位（safe / askAll / auto）；null = 未设置，回落全局默认。 */
    val approvalMode: String? = null,
    val latestCommandId: String? = null,
    val messageCount: Int = 0,
)

/** 转录条目（后端权威数据）。[uid] 由客户端补（后端 messages 不带 id）。 */
data class TranscriptEntry(
    /** "user" | "assistant" | "error" | "system" */
    val role: String,
    val text: String,
    val source: String? = null,
    val commandId: String? = null,
    val createdAtMs: Double = 0.0,
    val uid: String = "",
)

/** 完整对话（转录层）。 */
data class ConversationDetail(
    val id: String,
    val agentId: String,
    val title: String?,
    val modelOverride: String?,
    val modelProviderOverride: String?,
    val workdirOverride: String?,
    /** 对话级授权档位；null = 未设置（跟随桌面端全局默认）。 */
    val approvalMode: String?,
    val updatedAtMs: Double,
    val messages: List<TranscriptEntry>,
)

/** 目录分组（列表页按目录聚合，规则与 iOS / 桌面端侧栏一致）。 */
data class ConversationDirGroup(
    /** 目录路径；未绑定组为 null。 */
    val dir: String?,
    val items: List<ConversationSummary>,
) {
    val key: String get() = dir ?: "__unbound__"
}

/** `GET /api/conversations` 的解析结果：unsupported = 老版本桌面端没有该路由。 */
data class ConversationsResult(
    val conversations: List<ConversationSummary>?,
    val unsupported: Boolean = false,
    val error: String? = null,
)

/** `GET /api/conversations/{id}` 的解析结果。 */
data class ConversationResult(
    val detail: ConversationDetail?,
    val unsupported: Boolean = false,
    val error: String? = null,
)

// ─── 模型列表（契约对齐 iOS ModelStore / GET /api/agents/{id}/models）──────────

/** 一个可选模型。模型 id / 名称是**数据**（用户自己配置的），不做本地化。 */
data class ModelOption(
    val id: String,
    val name: String,
    /** 所属 provider 名，用于在重名时区分（如两个 provider 都有 gpt-4o）。 */
    val providerName: String,
    /** 所属 provider id —— 同名模型可来自多个 provider，选择时必须成对提交。 */
    val providerID: String,
    val available: Boolean = true,
) {
    /** `provider/model` 复合标识：同名模型在选择器里也各自独立。 */
    val compositeID: String get() = "$providerID/$id"
}

/** `GET /api/agents/{agentId}/models` 的解析结果。 */
data class AgentModelsResult(
    val models: List<ModelOption> = emptyList(),
    val activeModelID: String? = null,
    val preferredModelID: String? = null,
    val preferredProviderID: String? = null,
    /** 这台主机没有实现该接口（HTTP 404 / 501）：不是错误，只是没得选。 */
    val unsupported: Boolean = false,
    val error: String? = null,
)

// ─── 配对与目录浏览（契约对齐 iOS PairingURLHandler / FolderBrowserStore）──────

/** `POST /api/pair` 的结果：配对码换长期 token（码一次性、10 分钟有效）。 */
data class PairResult(
    val success: Boolean = false,
    val token: String = "",
    val deviceId: String = "",
    val deviceName: String = "",
    val error: String? = null,
)

/** `GET /api/folders/roots` 的结果（Windows 是盘符，Mac/Linux 是 home）。 */
data class FolderRoots(
    val platform: String = "",
    val pathSeparator: String = "/",
    val homeDir: String = "",
    val drives: List<String> = emptyList(),
)

/** 目录条目（name / absolutePath 是主机上的数据，不做本地化）。 */
data class FolderEntry(
    val name: String,
    val absolutePath: String,
    val isUnreadable: Boolean = false,
)

/** `GET /api/folders?path=` 的结果。 */
data class FolderBrowse(
    val path: String = "",
    val parentPath: String? = null,
    val entries: List<FolderEntry> = emptyList(),
)

/** 解析 `brewping://pair?host=&port=&deviceId=&name=&code=` 配对码内容。 */
data class PairPayload(
    val host: String,
    val port: String,
    val deviceId: String,
    val name: String,
    val code: String,
) {
    companion object {
        fun parse(raw: String): PairPayload? {
            val text = raw.trim()
            if (text.isEmpty()) return null
            // 纯 6 位数字：只有码，host/port 由表单提供
            if (text.matches(Regex("\\d{6}"))) {
                return PairPayload(host = "", port = "8787", deviceId = "", name = "", code = text)
            }
            if (!text.startsWith("brewping://pair")) return null
            val query = text.substringAfter("?", "")
            val params = query.split("&").mapNotNull {
                val idx = it.indexOf('=')
                if (idx <= 0) null else it.substring(0, idx) to it.substring(idx + 1)
            }.toMap()
            val host = params["host"]?.let { java.net.URLDecoder.decode(it, "UTF-8") } ?: ""
            if (host.isEmpty()) return null
            return PairPayload(
                host = host,
                port = params["port"]?.takeIf { it.isNotEmpty() } ?: "8787",
                deviceId = params["deviceId"] ?: "",
                name = params["name"]?.let { java.net.URLDecoder.decode(it, "UTF-8") } ?: "",
                code = params["code"] ?: "",
            )
        }
    }
}

// ─── 展示辅助（与 iOS bpPathLabel / bpTimeLabel 同规则）───────────────────────

/** 目录路径末段（`D:\study\workFlow` → `workFlow`）。 */
fun pathLabel(path: String): String {
    var trimmed = path.trimEnd('\\', '/')
    val idx = trimmed.lastIndexOfAny(charArrayOf('\\', '/'))
    return if (idx >= 0) trimmed.substring(idx + 1) else trimmed
}

/** 时间戳文案：今天只显示时间，其余显示「MM-dd HH:mm」（24 小时制，对齐桌面端）。 */
fun timeLabel(ms: Double): String {
    if (ms <= 0.0) return ""
    val calendar = java.util.Calendar.getInstance()
    calendar.timeInMillis = ms.toLong()
    val now = java.util.Calendar.getInstance()
    val sameDay = calendar.get(java.util.Calendar.YEAR) == now.get(java.util.Calendar.YEAR) &&
        calendar.get(java.util.Calendar.DAY_OF_YEAR) == now.get(java.util.Calendar.DAY_OF_YEAR)
    val fmt = java.text.SimpleDateFormat(if (sameDay) "HH:mm" else "MM-dd HH:mm", java.util.Locale.US)
    return fmt.format(calendar.time)
}
