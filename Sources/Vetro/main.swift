import AppKit
import GhosttyKit

// Scrub agent-session markers so chats never look like child sessions of a
// harness that happened to launch Vetro (e.g. Claude Code's
// CLAUDE_CODE_CHILD_SESSION disables transcript saving). Login shells
// re-source the user's rc files, so intentional env vars come back anyway.
// Must happen before ghostty_init, which captures environ.
for (key, _) in ProcessInfo.processInfo.environment {
    if key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_")
        || key.hasPrefix("CODEX_") || key.hasPrefix("GROK_") {
        unsetenv(key)
    }
}

// libghostty must be initialized before AppKit starts.
guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
    FileHandle.standardError.write(Data("ghostty_init failed\n".utf8))
    exit(1)
}

VetroApp.main()
