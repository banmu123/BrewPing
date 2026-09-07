package com.brewping.android

import android.app.Application
import com.brewping.android.api.DesktopApiClient
import com.brewping.android.discovery.DesktopDiscoveryManager
import com.brewping.android.repository.DesktopRepository

/**
 * Application class — provides singleton instances of Discovery, API, and Repository.
 */
class BrewPingApp : Application() {

    lateinit var discoveryManager: DesktopDiscoveryManager
        private set

    lateinit var apiClient: DesktopApiClient
        private set

    lateinit var repository: DesktopRepository
        private set

    override fun onCreate() {
        super.onCreate()
        instance = this

        discoveryManager = DesktopDiscoveryManager(this)
        apiClient = DesktopApiClient()
        repository = DesktopRepository(discoveryManager, apiClient)
    }

    companion object {
        lateinit var instance: BrewPingApp
            private set
    }
}
