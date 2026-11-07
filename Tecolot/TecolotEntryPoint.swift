import ArgumentParser
import Foundation
import SwiftUI

/// Runs the `teco` command-line tool when the executable is started with
/// that name. Otherwise starts the app.
@main
enum TecolotEntryPoint {
    static func main() {
        let name = URL(fileURLWithPath: CommandLine.arguments.first ?? "").lastPathComponent
        if name == "teco" {
            TecoCommand.main(Array(CommandLine.arguments.dropFirst()))
        } else {
            TecolotApp.main()
        }
    }
}
