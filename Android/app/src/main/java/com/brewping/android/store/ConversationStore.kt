package com.brewping.android.store

import android.util.Log
import com.brewping.android.api.DesktopApiClient
import com.brewping.android.model.ConversationDetail
import com.brewping.android.model.ConversationDirGroup
import com.brewping.android.model.ConversationSummary
import com.brewping.android.model.DesktopDevice
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject

/**
 * 对话 Store：列表 + 详情（契约对齐 iOS `ConversationStore.swift`）。
 *
 * 三条约定与 iOS 一致：
 *  1. 一律走 [DesktopApiClient]，不另起 HTTP（超时/编码在那里统一）；
 *  2. 404/501 → `unsupported = true` 静默降级（老版本桌面端没有该路由）；
 *  3. 切设备必须 [invalidate]（否则会话数据会串到另一台机器上）。
 */
class ConversationStore(private val apiClient: DesktopApiClient) {

    companion object {
        private const val TAG = "BrewPingConvStore"
    }

    private val _conversations = MutableStateFlow<List<ConversationSummary>>(emptyList())
    val conversations: StateFlow<List<ConversationSummary>> = _conversations.asStateFlow()

    private val _loading = MutableStateFlow(false)
    val loading: StateFlow<Boolean> = _loading.asStateFlow()

    private val _loadError = MutableStateFlow<String?>(null)
    val loadError: StateFlow<String?> = _loadError.asStateFlow()

    /** 桌面端不认识该路由（404/501）：老版本桌面端 → 列表区静默降级。 */
    private val _unsupported = MutableStateFlow(false)
    val unsupported: StateFlow<Boolean> = _unsupported.asStateFlow()

    private val _detail = MutableStateFlow<ConversationDetail?>(null)
    val detail: StateFlow<ConversationDetail?> = _detail.asStateFlow()

    private val _detailLoading = MutableStateFlow(false)
    val detailLoading: StateFlow<Boolean> = _detailLoading.asStateFlow()

    private val _detailError = MutableStateFlow<String?>(null)
    val detailError: StateFlow<String?> = _detailError.asStateFlow()

    /** 缓存键 = deviceID：同设备已加载过就不重复打接口（`force = true` 强制刷新）。 */
    private var loadedKey: String? = null

    /** 切设备时清空（由 ViewModel 的 resetState 调用）。 */
    fun invalidate() {
        loadedKey = null
        _conversations.value = emptyList()
        _loadError.value = null
        _unsupported.value = false
        _detail.value = null
        _detailError.value = null
    }

    /** 按目录分组：组序按组内最新活动降序，未绑定组垫底（与桌面端侧栏一致）。 */
    val dirGroups: List<ConversationDirGroup>
        get() {
            val map = LinkedHashMap<String, MutableList<ConversationSummary>>()
            val unbound = mutableListOf<ConversationSummary>()
            for (conv in _conversations.value) {
                if (conv.archived) continue
                val dir = conv.workdirOverride
                if (dir.isNullOrEmpty()) {
                    unbound.add(conv)
                } else {
                    map.getOrPut(dir) { mutableListOf() }.add(conv)
                }
            }
            val groups = map.map { (dir, items) -> ConversationDirGroup(dir, items) }
                .sortedByDescending { it.items.firstOrNull()?.updatedAtMs ?: 0.0 }
            return if (unbound.isEmpty()) groups else groups + ConversationDirGroup(null, unbound)
        }

    /** 拉取对话列表。同设备且已有数据时不重复请求（列表页每次进入都会调用）。 */
    suspend fun refresh(device: DesktopDevice?, force: Boolean = false) {
        if (device == null) {
            invalidate()
            return
        }
        if (!force && loadedKey == device.id && _conversations.value.isNotEmpty()) return

        _loading.value = true
        try {
            val result = apiClient.fetchConversations(device) ?: run {
                _loadError.value = "Can't reach ${device.name}"
                return
            }
            when {
                result.unsupported -> {
                    _conversations.value = emptyList()
                    _loadError.value = null
                    _unsupported.value = true
                    loadedKey = device.id
                }
                result.error != null -> {
                    // 失败保留旧列表（网络抖动不该让列表消失）；换过设备则必须清空
                    if (loadedKey != device.id) _conversations.value = emptyList()
                    _loadError.value = result.error
                }
                else -> {
                    _conversations.value = result.conversations.orEmpty()
                    _unsupported.value = false
                    _loadError.value = null
                    loadedKey = device.id
                }
            }
        } finally {
            _loading.value = false
        }
    }

    /** 拉取某个对话的完整转录。 */
    suspend fun open(id: String, device: DesktopDevice?) {
        if (device == null) return
        _detailLoading.value = true
        try {
            val result = apiClient.fetchConversation(device, id) ?: run {
                _detailError.value = "Can't reach ${device.name}"
                return
            }
            when {
                result.unsupported -> {
                    _detail.value = null
                    _detailError.value = null
                    _unsupported.value = true
                }
                result.error != null -> {
                    _detailError.value = result.error
                }
                else -> {
                    _detail.value = result.detail
                    _detailError.value = null
                }
            }
        } finally {
            _detailLoading.value = false
        }
    }

    // ─── 写操作（对话级 Agent / 模型 / 授权；与桌面端同一套存储语义）────────────

    /**
     * 创建对话（新对话草稿的物化入口）：`POST /api/conversations`。
     * Agent 与授权档位随创建固化（对话级，之后各对话互不影响）。
     * 成功返回新对话 id 并把详情写入 [detail]；失败返回 null（原因在 [detailError]）。
     */
    suspend fun createConversation(
        device: DesktopDevice?,
        agentId: String,
        approvalMode: String? = null,
    ): String? {
        if (device == null) return null
        _detailError.value = null
        val result = apiClient.createConversation(device, agentId, approvalMode)
        if (result == null) {
            _detailError.value = "Can't reach ${device.name}"
            return null
        }
        val detail = result.detail
        if (detail == null) {
            _detailError.value = result.error ?: "Create failed"
            return null
        }
        _detail.value = detail
        // 列表缓存作废：下一次 refresh(force) 会把新对话拉进来
        loadedKey = null
        Log.i(TAG, "[ConvStore] conversation created: ${detail.id}")
        return detail.id
    }

    /** `PATCH /api/conversations/{id}` 的统一小封装：失败时把原因写进 [detailError]。 */
    private suspend fun patch(device: DesktopDevice?, id: String, body: JSONObject): Boolean {
        if (device == null) return false
        val result = apiClient.patchConversation(device, id, body)
        if (result == null) {
            _detailError.value = "Can't reach ${device.name}"
            return false
        }
        if (result.detail == null) {
            _detailError.value = result.error ?: "Update failed"
            return false
        }
        return true
    }

    /** 切换对话绑定的 Agent（桌面端会自动清除该对话的模型覆盖）。 */
    suspend fun setAgent(device: DesktopDevice?, id: String, agentId: String): Boolean =
        patch(device, id, JSONObject().put("agentId", agentId))

    /** 设置 / 清除对话的授权档位（对话级，互不影响）。 */
    suspend fun setApprovalMode(device: DesktopDevice?, id: String, mode: String): Boolean =
        patch(device, id, JSONObject().put("approvalMode", mode))

    /** 设置 / 清除对话的模型覆盖（`modelId = null` = 清除，回落该 Agent 默认模型）。 */
    suspend fun setModel(
        device: DesktopDevice?,
        id: String,
        modelId: String?,
        providerId: String?,
    ): Boolean {
        val body = JSONObject().put("modelId", modelId ?: "")
        body.put("modelProviderId", providerId ?: "")
        return patch(device, id, body)
    }

    /** 置顶 / 取消置顶（侧栏与列表的置顶优先展示）。 */
    suspend fun setPinned(device: DesktopDevice?, id: String, pinned: Boolean): Boolean =
        patch(device, id, JSONObject().put("pinned", pinned))

    /** 归档 / 恢复（恢复时桌面端会校验绑定目录仍存在，缺失 → 409）。 */
    suspend fun setArchived(device: DesktopDevice?, id: String, archived: Boolean): Boolean =
        patch(device, id, JSONObject().put("archived", archived))

    /** 绑定 / 解绑对话的工作目录（空串 = 解绑；目录不存在 → 桌面端 400）。 */
    suspend fun setWorkdir(device: DesktopDevice?, id: String, workdir: String?): Boolean =
        patch(device, id, JSONObject().put("workdir", workdir ?: ""))
}
