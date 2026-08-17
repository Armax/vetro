<h1 align="center">Vetro</h1>

<p align="center">
  Native macOS terminal sessions for projects and isolated Linux agent environments.
</p>

<p align="center">
  <img alt="Platform: macOS 26+" src="https://img.shields.io/badge/platform-macOS%2026%2B-111827?logo=apple&logoColor=white">
  <img alt="Swift: 6.1" src="https://img.shields.io/badge/Swift-6.1-F05138?logo=swift&logoColor=white">
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-2ea44f">
</p>

Vetro combines a libghostty-powered terminal with a project sidebar and a
Virtualization.framework-based Linux layer. Projects can run local terminal
sessions or launch agent sessions inside persistent, isolated VMs through
`VMKit`.

## ✨ Features

- **Project sidebar** — add project folders, search and pin sessions, and start
  one or more terminal sessions per project. Project folders persist between
  launches; live terminal sessions are runtime-only.
- **Native terminal rendering** — `GhosttyKit.xcframework` provides libghostty
  surfaces rendered through Metal, with AppKit input, focus, scaling, clipboard,
  title, bell, and notification handling.
- **Liquid Glass interface** — SwiftUI and AppKit views use macOS 26 Liquid
  Glass styling with dark/light appearance, wallpapers, and a solid fallback
  when Reduce Transparency is enabled.
- **Agent activity** — chat rows show a spinner while Claude Code, Codex, or
  Grok is working and a green unread indicator when a turn finishes. Lifecycle
  hooks are authoritative when enabled; terminal-title and process/CPU
  heuristics provide fallback detection. macOS notifications can focus the
  relevant chat.
- **VM-backed projects** — attach a project to a Linux VM, preview and transfer
  project files with `rsync`, and launch a terminal or agent session in the
  guest workspace.
- **VMKit runtime** — persistent VM lifecycle management, cloud-init
  provisioning, vsock SSH forwarding, guest port discovery, host port
  forwarding, golden-image capture and reuse, optional idle auto-stop, and idle
  memory reclaim.

## ⚡ Why a VM?

Isolation is the obvious reason: agents run with full autonomy inside a
disposable Linux guest, not on your Mac. The less obvious one is speed — agent
workloads are *faster* inside the VM than on the host, because ext4 skips the
two things that slow agentic coding down on macOS:

- **APFS metadata tax** — agent workloads are metadata-heavy: package installs
  and git operations create, stat, and unlink hundreds of thousands of small
  files. APFS handles this far more slowly than ext4, so the same
  `node_modules` churn that crawls on macOS is quick in the guest.
- **Gatekeeper (`syspolicyd`) per-spawn checks** — macOS assesses newly spawned
  executables through `syspolicyd`, adding latency to every process launch.
  Agents spawn thousands of short-lived processes (compilers, linters, git,
  node); inside Linux none of those checks exist.

Benchmarks on the same Apple silicon machine, guest vs host:

| Workload                     | VM (ext4) | macOS (APFS) | Result        |
|------------------------------|-----------|--------------|---------------|
| `pnpm install` — TS monorepo | 13.61s    | 30.10s       | VM 2.2× faster |
| `git clean` — `node_modules` | 2.87s     | 25.73s       | VM 9× faster  |
| 2,825 Jest tests — CPU-bound | 35.55s    | 35.40s       | no VM tax     |

CPU-bound work runs at native speed under Virtualization.framework, so the VM
costs nothing where the filesystem isn't involved and wins big where it is.

## 🧰 Requirements

- macOS 26 or later.
- An Apple silicon Mac. The bundled GhosttyKit slice and the VM base image are
  `arm64`.
- Swift 6.1 with the macOS 26 SDK.
- Command Line Tools for macOS. The build script borrows the SwiftUI macros
  plugin from Xcode-beta; see [Build](#-build).
- Zig, only when rebuilding `GhosttyKit`.

## 🔨 Build

From the repository root:

```sh
./Support/build-app.sh release   # or debug
open build/Vetro.app
```

`Support/build-app.sh` builds the SwiftPM executable, packages VMKit and
Ghostty runtime resources, and signs `build/Vetro.app` with an Apple Development
identity when one is available. It uses the macOS 26+ SDK. Because the Command
Line Tools do not ship the SwiftUI macros plugin, the script borrows it from
Xcode-beta, which it expects at `/Applications/Xcode-beta.app` by default. Set
`DEVELOPER_DIR` before running the script when Xcode-beta is installed
elsewhere.

The script looks for Ghostty resources in `../ghostty-src` by default. Set
`GHOSTTY_SRC` to use a different checkout.

## ⌨️ Usage

- Add a project folder from the sidebar, then start a chat to open a shell in
  that directory.
- Set `VETRO_OPEN=/path/to/dir` before launch to add that directory and start a
  session automatically.
- Use `⌘N` or `⌘T` for a new chat, `⌘W` to close the selected chat, and `⌘K` to
  search chats.

## 🏗️ Architecture & layout

`Vetro` is a SwiftPM package containing the macOS executable, the reusable
`VMKit` library, a VM smoke-test executable, and VMKit tests.

```text
.
├── Package.swift
├── Frameworks/
│   └── GhosttyKit.xcframework
├── Sources/
│   ├── Vetro/
│   │   ├── VetroApp.swift              # SwiftUI scene and app wiring
│   │   ├── ContentView.swift           # Sidebar and terminal/settings panes
│   │   ├── GhosttyRuntime.swift        # libghostty runtime callbacks
│   │   ├── TerminalSurface.swift       # Ghostty surface and AppKit input view
│   │   ├── SessionManager.swift        # Live project sessions
│   │   └── VMStore.swift               # VM and project orchestration
│   ├── VMKit/
│   │   ├── VMController.swift          # VM lifecycle and provisioning
│   │   ├── VZVirtualMachineRuntime.swift
│   │   ├── CloudInitSeed.swift
│   │   ├── ImageStore.swift
│   │   ├── GoldenImageStore.swift
│   │   ├── SSHClient.swift
│   │   ├── VsockSSHForwarder.swift
│   │   └── Resources/Guest/
│   └── VetroVMSmoke/
├── Support/
│   ├── Info.plist
│   ├── Vetro.entitlements
│   └── build-app.sh
└── Tests/
    └── VMKitTests/
```

The app calls `ghostty_init` before AppKit starts. `GhosttyRuntime` owns the
libghostty app instance, while each `TerminalSurface` connects a Ghostty
surface to an AppKit view for input, sizing, focus, and Metal rendering.
`VMStore` coordinates project attachments and session launches with the
actor-based services in `VMKit`.

## 🧱 Rebuilding GhosttyKit

The checked-in `GhosttyKit.xcframework` is built from a sibling Ghostty
checkout:

```sh
cd ../ghostty-src
zig build -Demit-xcframework -Dxcframework-target=native -Doptimize=ReleaseFast -Demit-macos-app=false
```

The Ghostty tree carries two local patches so the build works without Apple's
Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain` was not
installed):

- `src/build/SharedDeps.zig` embeds the raw `shaders.metal` source instead of a
  compiled metallib.
- `src/renderer/metal/shaders.zig` compiles that source at runtime with
  `newLibraryWithSource:`.

The final `xcodebuild -create-xcframework` step also requires a licensed Xcode.
Without it, the xcframework in `Frameworks/` is assembled by hand from
`libghostty-internal.a` and headers in `.zig-cache`; see
`Frameworks/GhosttyKit.xcframework/Info.plist`.

## 📄 License

Vetro is MIT-licensed. See [LICENSE](LICENSE).

This repository bundles Ghostty (`GhosttyKit`), which is also MIT-licensed. The
included Ghostty license notice is in [LICENSE](LICENSE).
