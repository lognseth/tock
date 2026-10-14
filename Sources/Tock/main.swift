import AppKit

MainActor.assumeIsolated {
    if CommandLine.arguments.contains("--selftest") {
        exit(SelfTest.run())
    }
    if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > i + 1 {
        let variant = CommandLine.arguments.count > i + 2 ? CommandLine.arguments[i + 2] : "default"
        exit(Snapshot.run(path: CommandLine.arguments[i + 1], variant: variant))
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
