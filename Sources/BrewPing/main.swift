import Foundation
import BrewPingCore

let exitCode = BrewPingCLI.run(Array(CommandLine.arguments.dropFirst()))
exit(exitCode)
