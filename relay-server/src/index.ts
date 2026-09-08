/**
 * BrewPing Relay Server - Entry Point
 *
 * Bootstraps and starts the relay server.
 */

import { RelayServer } from './server'

const server = new RelayServer()

server.start().then(() => {
  console.log('✅ BrewPing Relay Server is ready')
})

// Graceful shutdown
process.on('SIGINT', async () => {
  console.log('\n⏹ Shutting down...')
  await server.stop()
  process.exit(0)
})

process.on('SIGTERM', async () => {
  await server.stop()
  process.exit(0)
})
