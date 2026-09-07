package com.brewping.android.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.brewping.android.model.DesktopDevice
import com.brewping.android.repository.ConnectionState
import com.brewping.android.repository.DesktopRepository
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn

/**
 * UI state for the Home screen.
 */
sealed interface HomeUiState {
    /** Initial state before any discovery attempt */
    data object Idle : HomeUiState

    /** Actively searching for BrewPing Desktop */
    data object Searching : HomeUiState

    /** Desktop found, connecting to its API */
    data object Connecting : HomeUiState

    /** Connected to Desktop, showing device and agent info */
    data class Connected(val device: DesktopDevice) : HomeUiState

    /** Desktop was found but is now unreachable */
    data class Disconnected(val device: DesktopDevice?) : HomeUiState

    /** An error occurred */
    data class Error(val message: String) : HomeUiState
}

class HomeViewModel(private val repository: DesktopRepository) : ViewModel() {

    val uiState: StateFlow<HomeUiState> = combine(
        repository.connectionState,
        repository.activeDevice,
    ) { connState, device ->
        when (connState) {
            ConnectionState.Idle -> HomeUiState.Idle
            ConnectionState.Searching -> HomeUiState.Searching
            ConnectionState.Connecting -> HomeUiState.Connecting
            ConnectionState.Connected -> {
                if (device != null) HomeUiState.Connected(device)
                else HomeUiState.Searching
            }
            ConnectionState.Disconnected -> HomeUiState.Disconnected(device)
            ConnectionState.Error -> HomeUiState.Error("Connection error")
        }
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5_000),
        initialValue = HomeUiState.Idle,
    )

    init {
        repository.startSearching()
        repository.start()
    }

    fun refresh() {
        repository.refresh()
    }

    override fun onCleared() {
        super.onCleared()
        repository.stop()
    }

    class Factory(private val repository: DesktopRepository) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T {
            return HomeViewModel(repository) as T
        }
    }
}
