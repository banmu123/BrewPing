package com.brewping.android.store

import android.content.Context
import android.content.SharedPreferences
import com.brewping.android.api.DesktopApiClient
import com.brewping.android.model.DesktopDevice
import com.brewping.android.model.ModelOption
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * 当前 Agent 的可切换模型列表 + 当前生效模型（契约对齐 iOS `ModelStore`）。
 *
 * 数据来源唯一：桌面端 `GET /api/agents/{id}/models`（Provider → Models 两层，
 * 这里已拍平）。切换走 `POST /api/agents/models/default`，providerId 成对提交。
 */
class ModelStore(
    private val apiClient: DesktopApiClient,
    private val scope: CoroutineScope,
    context: Context,
) {

    private val appContext: Context = context.applicationContext

    private val prefs: SharedPreferences =
        context.getSharedPreferences("brewping_models", Context.MODE_PRIVATE)

    private val _models = MutableStateFlow<List<ModelOption>>(emptyList())
    val models: StateFlow<List<ModelOption>> = _models.asStateFlow()

    private val _activeModelID = MutableStateFlow<String?>(null)
    val activeModelID: StateFlow<String?> = _activeModelID.asStateFlow()

    /** 拉取失败时的提示。失败不清空 models，保留上次可用的列表。 */
    private val _loadError = MutableStateFlow<String?>(null)
    val loadError: StateFlow<String?> = _loadError.asStateFlow()

    /** 这台主机没有实现模型接口（HTTP 404 / 501）：不是错误，只是没得选。 */
    private val _unsupported = MutableStateFlow(false)
    val unsupported: StateFlow<Boolean> = _unsupported.asStateFlow()

    /** 切换失败时的提示。 */
    private val _notice = MutableStateFlow<String?>(null)
    val notice: StateFlow<String?> = _notice.asStateFlow()

    private var currentDevice: DesktopDevice? = null
    private var currentAgentID: String = ""
    /** 已加载过的 "deviceID/agentID"，避免状态轮询重复拉模型列表。 */
    private var loadedKey: String? = null
    /**
     * 最近一次**成功响应**里的配置指纹（失败不更新，下次轮询再试）。
     * 用于判断主机侧厂商配置是否变过 —— 变了才更新 UI 状态，否则每 5 秒
     * 轮询都会重写 `_models` 触发 Compose 重组（列表闪）。
     */
    private var loadedConfigVersion: String? = null

    /**
     * 是否值得展示切换入口：只要**有模型**就显示（单模型时只读展示当前模型）。
     *
     * ⚠️ 早先是 `size > 1` —— 只配了 1 个厂商 1 个模型时整个入口被隐藏，
     * 用户「明明配好了却说没得选」。iOS 侧已改为 `!isEmpty`，此处对齐。
     */
    val canSwitch: Boolean get() = !_unsupported.value && _models.value.isNotEmpty()

    /** 当前生效模型的展示名；列表里没有时直接显示 id。 */
    val activeModelName: String?
        get() = _activeModelID.value?.let { id ->
            _models.value.firstOrNull { it.id == id }?.name ?: id
        }

    /**
     * 拉取指定设备上某个 Agent 的模型列表。
     *
     * 去重语义（对齐 iOS `ModelCatalog.refresh` 修复后的实现）：
     *  - **照发探测请求** —— 指纹只能从响应里拿，本地无从预判主机配置变没变；
     *    请求本身很轻（一个 GET、几十字节），不值得为省它而漏掉变更。
     *  - 目标（设备/Agent）变了 → 先清空再拉，防新主机短暂显示旧主机的模型。
     *  - 拿到响应后：指纹与上次一致且非 force → **直接返回，不动 state**
     *    （否则 5 秒轮询每次都重写列表，Compose 重组 + 闪烁）。
     */
    suspend fun refresh(device: DesktopDevice?, agentId: String, force: Boolean = false) {
        currentDevice = device
        currentAgentID = agentId

        if (device == null) {
            clearModels()
            _unsupported.value = false
            _loadError.value = null
            loadedKey = null
            loadedConfigVersion = null
            return
        }

        val key = "${device.id}/$agentId"
        val targetChanged = loadedKey != key
        // 换目标（设备/Agent）：先清空，避免短暂显示上一个目标的模型
        if (targetChanged) clearModels()

        val result = apiClient.fetchAgentModels(device, agentId)
        if (result == null) {
            // 同一主机上失败不清空已有列表（一次网络抖动不该让选项消失）
            if (targetChanged) clearModels()
            _unsupported.value = false
            _loadError.value = appContext.getString(com.brewping.android.R.string.cant_load_models)
            return
        }
        when {
            result.unsupported -> {
                clearModels()
                _loadError.value = null
                _unsupported.value = true
                loadedKey = key
                loadedConfigVersion = null
            }
            result.error != null -> {
                if (targetChanged) clearModels()
                _unsupported.value = false
                _loadError.value = result.error
            }
            else -> {
                // 指纹没变且非强制 → 不动 state（避免轮询导致的无谓重组）
                val incoming = result.configVersion
                if (!force && !targetChanged && incoming != null && incoming == loadedConfigVersion) {
                    _loadError.value = null
                    return
                }
                _models.value = result.models
                _activeModelID.value = resolveActive(result, result.models, localSelection(device.id, agentId))
                _loadError.value = null
                _unsupported.value = false
                loadedKey = key
                loadedConfigVersion = incoming
            }
        }
    }

    /**
     * 设备或 Agent 变了 —— 下次必须重新拉，否则会沿用上一个 Agent 的模型。
     * 指纹一并清掉：它描述的是旧目标那次响应，留着会误判"配置没变"。
     */
    fun invalidate() {
        loadedKey = null
        loadedConfigVersion = null
    }

    /**
     * 切换模型（乐观更新：先高亮，失败回滚）。
     * providerId 与 modelId 成对提交：同名模型可来自多个 provider，
     * 缺了它 opencode 会拼出错误的 `provider/model`。
     */
    fun select(modelId: String, providerId: String? = null) {
        val device = currentDevice ?: return
        val agentId = currentAgentID
        if (agentId.isEmpty()) return
        val previous = _activeModelID.value
        _activeModelID.value = modelId
        saveLocalSelection(modelId, device.id, agentId)
        _notice.value = null

        scope.launch {
            val error = apiClient.setDefaultModel(device, agentId, modelId, providerId)
            if (error == null) {
                // 拉一次确认服务端已生效（也顺带刷新默认标记）
                refresh(device, agentId, force = true)
            } else {
                _activeModelID.value = previous
                _notice.value = error
            }
        }
    }

    // ─── 当前生效模型判定（顺序对齐 iOS resolveActive）─────────────────────────

    private fun resolveActive(
        result: com.brewping.android.model.AgentModelsResult,
        models: List<ModelOption>,
        localFallback: String?,
    ): String? {
        result.preferredModelID?.takeIf { it.isNotEmpty() && models.any { m -> m.id == it } }?.let { return it }
        localFallback?.takeIf { models.any { m -> m.id == it } }?.let { return it }
        result.activeModelID?.takeIf { it.isNotEmpty() && models.any { m -> m.id == it } }?.let { return it }
        return models.firstOrNull()?.id
    }

    // ─── 本地持久化：按「设备 + Agent」分别记 ──────────────────────────────────

    private fun storageKey(deviceId: String, agentId: String) = "BrewPing.Model.$deviceId.$agentId"

    private fun localSelection(deviceId: String, agentId: String): String? =
        prefs.getString(storageKey(deviceId, agentId), null)

    private fun saveLocalSelection(modelId: String, deviceId: String, agentId: String) {
        prefs.edit().putString(storageKey(deviceId, agentId), modelId).apply()
    }

    private fun clearModels() {
        _models.value = emptyList()
        _activeModelID.value = null
    }
}