import AppKit

if CommandLine.arguments.contains("--probe-window") {
    ProbeWindow.run()
}

#if DEBUG
if let index = CommandLine.arguments.firstIndex(of: "--snapshot-ui"), CommandLine.arguments.count > index + 1 {
    MainActor.assumeIsolated { UISnapshot.run(outputDirectory: CommandLine.arguments[index + 1]) }
}
#endif

StayWhereWindowsAreApp.main()
