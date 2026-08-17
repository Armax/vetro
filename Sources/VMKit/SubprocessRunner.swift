public import Foundation

/// Runs bounded subprocesses while draining output through temporary files.
public struct SubprocessRunner: Sendable {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
        public let timedOut: Bool
    }

    public enum Failure: Error {
        case unableToCreateCaptureFile(URL)
    }

    private let temporaryDirectoryURL: URL

    public init(temporaryDirectoryURL: URL) {
        self.temporaryDirectoryURL = temporaryDirectoryURL
    }

    /// Executes one process without holding pipe buffers in the calling actor.
    public func run(
        executableURL: URL,
        arguments: [String],
        timeoutSeconds: Int
    ) async throws -> Result {
        let captureDirectory = temporaryDirectoryURL.appendingPathComponent(
            "vetro-process-\(UUID().uuidString)",
            isDirectory: true
        )

        return try await Task.detached(priority: nil) {
            let fileManager = FileManager()
            try fileManager.createDirectory(
                at: captureDirectory,
                withIntermediateDirectories: true
            )
            defer { try? fileManager.removeItem(at: captureDirectory) }

            let stdoutURL = captureDirectory.appendingPathComponent("stdout", isDirectory: false)
            let stderrURL = captureDirectory.appendingPathComponent("stderr", isDirectory: false)
            guard fileManager.createFile(atPath: stdoutURL.path, contents: nil) else {
                throw Failure.unableToCreateCaptureFile(stdoutURL)
            }
            guard fileManager.createFile(atPath: stderrURL.path, contents: nil) else {
                throw Failure.unableToCreateCaptureFile(stderrURL)
            }

            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle

            // waitUntilExit can miss the exit notification of a signalled
            // child (its run-loop race), wedging this group forever and
            // pinning a cooperative-pool thread. terminationHandler is the
            // reliable contract; install it before run() so a fast exit
            // cannot slip past, and buffer the event for the later await.
            let (terminationEvents, terminationContinuation) =
                AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            process.terminationHandler = { _ in
                terminationContinuation.yield()
                terminationContinuation.finish()
            }

            do {
                try process.run()
            } catch {
                try? stdoutHandle.close()
                try? stderrHandle.close()
                throw error
            }

            let timedOut = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await _ in terminationEvents { break }
                    return false
                }
                group.addTask {
                    do {
                        try await Task.sleep(for: .seconds(max(0, timeoutSeconds)))
                    } catch {
                        return false
                    }
                    guard process.isRunning else { return false }
                    process.terminate()
                    // Escalate: a process ignoring SIGTERM (or stuck in a
                    // half-dead ssh session) would otherwise hold the group's
                    // waitUntilExit child forever.
                    try? await Task.sleep(for: .seconds(5))
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                    return true
                }

                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }

            try stdoutHandle.close()
            try stderrHandle.close()
            let stdout = String(
                decoding: try Data(contentsOf: stdoutURL),
                as: UTF8.self
            )
            let stderr = String(
                decoding: try Data(contentsOf: stderrURL),
                as: UTF8.self
            )
            return Result(
                status: timedOut ? 124 : process.terminationStatus,
                stdout: stdout,
                stderr: stderr,
                timedOut: timedOut
            )
        }.value
    }
}
