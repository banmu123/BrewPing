package com.brewping.android

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * 命令接收器 (matches iOS CommandReceiver)
 */
class CommandReceiver {

    private val _lastCommandText = MutableStateFlow<String?>(null)
    val lastCommandText: StateFlow<String?> = _lastCommandText.asStateFlow()

    var onCommand: ((String) -> Unit)? = null

    fun receive(text: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        _lastCommandText.value = trimmed
        onCommand?.invoke(trimmed)
    }
}
