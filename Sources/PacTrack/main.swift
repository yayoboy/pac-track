import AppKit

let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--selftest"), i + 1 < arguments.count {
    MainActor.assumeIsolated { SelfTest.run(output: arguments[i + 1]) }
} else {
    PacTrackApp.main()
}
