import SwiftUI

struct FCPXPluginManagerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@main
struct Launcher {
    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        if let index = arguments.firstIndex(of: "--cli") {
            arguments.remove(at: index)
            exit(CLIRunner.run(arguments: arguments))
        }
        FCPXPluginManagerApp.main()
    }
}
