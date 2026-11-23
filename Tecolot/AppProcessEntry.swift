import Foundation
import Darwin
import SwiftUI

@main
enum AppProcessEntry {
    static func main() {
        let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())

        switch arguments {
        case ["--help"], ["-h"]:
            print("""
                Usage: tecolot [options]

                Options:
                  -h, --help       Show this help message
                  -v, --version    Show the application version
                """)

        case ["--version"], ["-v"]:
            let info = Bundle.main.infoDictionary
            let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
            print("Tecolot \(version)")

        case []:
            TecolotApp.main()

	case let args where args.count == 1 && args[0].hasPrefix("-psn_"):
            TecolotApp.main()

        default:
            fputs("tecolot: unsupported arguments\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
