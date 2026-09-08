package com.brewping.android

import android.app.Application
import com.brewping.android.api.DesktopApiClient
import com.brewping.android.discovery.DesktopDiscoveryManager
import com.brewping.android.repository.DesktopRepository
import com.brewping.android.store.DeviceStore

/**
 * Application class — provides singleton instances of Discovery, API, Repository, and DeviceStore.
 */
class BrewPingApp : Application() {

    lateinit var discoveryManager: DesktopDiscoveryManager
        private set

    lateinit var apiClient: DesktopApiClient
        private set

    lateinit var repository: DesktopRepository
        private set

    lateinit var deviceStore: DeviceStore
        private set

    override fun onCreate() {
        super.onCreate()
        instance = this

        deviceStore = DeviceStore(this)
        discoveryManager = DesktopDiscoveryManager(this)
        apiClient = DesktopApiClient()
        repository = DesktopRepository(discoveryManager, apiClient)
    }

    companion object {
        lateinit var instance: BrewPingApp
            private set
    }
}
