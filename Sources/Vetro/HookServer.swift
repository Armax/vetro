import Foundation

/// Unix-socket listener for harness lifecycle hooks. Hook scripts send one
/// newline-terminated line: "<session-uuid or empty>\t<event>\t<payload-json>"
/// optionally followed by "\t<harness-name>\t<harness-pid>" (host scripts v2).
final class HookServer: @unchecked Sendable {
    static let shared = HookServer()

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vetro", isDirectory: true)
    }

    static var socketPath: String {
        supportDirectory.appendingPathComponent("hook.sock").path
    }

    /// Set once from the main actor before start().
    var onEvent: (@MainActor (UUID?, String, String, String?, pid_t?) -> Void)?

    /// Guest (vsock) events: no harness identity fields.
    func deliver(sessionID: UUID?, event: String, payload: String) {
        Task { @MainActor [onEvent] in
            onEvent?(sessionID, event, payload, nil, nil)
        }
    }

    private var fd: Int32 = -1
    private var acceptSource: (any DispatchSourceRead)?
    private let queue = DispatchQueue(label: "vetro.hook-server", qos: .utility)

    private init() {}

    func start() {
        guard fd < 0 else { return }
        let path = Self.socketPath
        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        unlink(path)

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = withUnsafeMutableBytes(of: &addr.sun_path) { buf -> Bool in
            let bytes = Array(path.utf8)
            guard bytes.count < buf.count else { return false }
            for (i, b) in bytes.enumerated() { buf[i] = b }
            return true
        }
        guard ok else { close(fd); fd = -1; return }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); fd = -1; return }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.resume()
        acceptSource = source
    }

    private func acceptClient() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count < 16384 {
            let n = read(client, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if data.contains(0x0A) { break }
        }

        guard let text = String(data: data, encoding: .utf8),
              let line = text.split(separator: "\n").first
        else { return }
        let parts = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return }

        let session = UUID(uuidString: String(parts[0]))
        let event = String(parts[1])
        let payload = parts.count >= 3 ? String(parts[2]) : ""
        let harnessName = parts.count >= 4 && !parts[3].isEmpty ? String(parts[3]) : nil
        let harnessPID = parts.count >= 5 ? pid_t(parts[4].trimmingCharacters(in: .whitespaces)) : nil
        Task { @MainActor [onEvent] in
            onEvent?(session, event, payload, harnessName, harnessPID)
        }
    }
}
