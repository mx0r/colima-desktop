import ColimaAppShell

// Thin app target: all code lives in the ColimaDesktopKit package.
MainActor.assumeIsolated {
    ColimaDesktopApplication.run()
}
