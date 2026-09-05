import Foundation

let exitCode = BrewPingCLI.run(Array(CommandLine.arguments.dropFirst()))
exit(exitCode)
