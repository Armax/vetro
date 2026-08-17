import Foundation
import Testing
@testable import VMKit

@Suite("Image checksum verification", .serialized)
struct ImageStoreTests {
    @Test("SHA512SUMS fixture is accepted only when the digest matches", arguments: [true, false])
    func checksumFixture(shouldMatch: Bool) async throws {
        let fileManager = FileManager()
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "ImageStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

        let stateDirectory = StateDirectory(
            rootURL: temporaryRoot,
            imagesDirectoryURL: temporaryRoot.appendingPathComponent(
                "vm-images",
                isDirectory: true
            )
        )
        let fixtureURL = temporaryRoot.appendingPathComponent("fixture.raw", isDirectory: false)
        let checksumsURL = temporaryRoot.appendingPathComponent("SHA512SUMS", isDirectory: false)
        try Data("abc".utf8).write(to: fixtureURL)

        let knownDigest = "ddaf35a193617abacc417349ae204131"
            + "12e6fa4e89a97ea20a9eeee64b55d39a"
            + "2192992a274fc1a836ba3c23a3feebbd"
            + "454d4423643ce80e2a9ac94fa54ca49f"
        let digest = shouldMatch ? knownDigest : String(repeating: "0", count: 128)
        try Data("\(digest)  fixture.raw\n".utf8).write(to: checksumsURL)

        let store = ImageStore(
            stateDirectory: stateDirectory,
            fileManager: FileManager(),
            session: URLSession(configuration: .ephemeral),
            checksumsRemoteURL: URL(string: "https://example.invalid/SHA512SUMS")!,
            baseImageRemoteURL: URL(string: "https://example.invalid/fixture.raw")!
        )
        let result = try await store.verifySHA512(
            fileURL: fixtureURL,
            checksumsURL: checksumsURL,
            expectedFileName: "fixture.raw"
        )
        #expect(result == shouldMatch)
    }

    @Test("shared cache transactions are serialized across image stores")
    func sharedCacheIsProcessWide() async throws {
        let fixture = ImageDownloadFixture.install(delaySeconds: 0.1)
        defer { ImageDownloadFixture.remove(host: fixture.host) }
        let fileManager = FileManager()
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "ImageStoreSharedCacheTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let imagesURL = temporaryRoot.appendingPathComponent("vm-images", isDirectory: true)
        let firstState = StateDirectory(
            rootURL: temporaryRoot.appendingPathComponent("first", isDirectory: true),
            imagesDirectoryURL: imagesURL
        )
        let secondState = StateDirectory(
            rootURL: temporaryRoot.appendingPathComponent("second", isDirectory: true),
            imagesDirectoryURL: imagesURL
        )
        let firstStages = LockedValue<[VMImagePreparationState]>([])
        let secondStages = LockedValue<[VMImagePreparationState]>([])
        let callbackOwners = LockedValue<[Int]>([])
        let firstStore = makeStore(stateDirectory: firstState, fixture: fixture)
        let secondStore = makeStore(stateDirectory: secondState, fixture: fixture)

        async let firstURL = firstStore.ensureBaseImage(
            stateUpdate: { stage in
                firstStages.mutate { $0.append(stage) }
                callbackOwners.mutate { $0.append(1) }
            }
        )
        async let secondURL = secondStore.ensureBaseImage(
            stateUpdate: { stage in
                secondStages.mutate { $0.append(stage) }
                callbackOwners.mutate { $0.append(2) }
            }
        )
        let resolvedURLs = try await [firstURL, secondURL]

        #expect(resolvedURLs == [firstState.baseImageURL, secondState.baseImageURL])
        #expect(ImageDownloadFixture.requestCount(host: fixture.host) == 2)
        let observedStages = [firstStages.value, secondStages.value]
        #expect(
            observedStages.contains([
                .checkingCache,
                .downloading,
                .verifying,
                .ready,
            ])
        )
        #expect(observedStages.contains([.checkingCache, .ready]))
        #expect(
            callbackOwners.value == [1, 1, 1, 1, 2, 2]
                || callbackOwners.value == [2, 2, 2, 2, 1, 1]
        )
    }

    @Test("a canceled cache waiter does not inherit the gate or emit stages")
    func canceledCacheWaiterIsRemoved() async throws {
        let fixture = ImageDownloadFixture.install(delaySeconds: 0.15)
        defer { ImageDownloadFixture.remove(host: fixture.host) }
        let fileManager = FileManager()
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "ImageStoreCancellationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let imagesURL = temporaryRoot.appendingPathComponent("vm-images", isDirectory: true)
        let firstStore = makeStore(
            stateDirectory: StateDirectory(
                rootURL: temporaryRoot.appendingPathComponent("first", isDirectory: true),
                imagesDirectoryURL: imagesURL
            ),
            fixture: fixture
        )
        let secondStages = LockedValue<[VMImagePreparationState]>([])
        let secondStore = makeStore(
            stateDirectory: StateDirectory(
                rootURL: temporaryRoot.appendingPathComponent("second", isDirectory: true),
                imagesDirectoryURL: imagesURL
            ),
            fixture: fixture
        )

        let firstTask = Task { try await firstStore.ensureBaseImage() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ImageDownloadFixture.requestCount(host: fixture.host) == 0,
              ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ImageDownloadFixture.requestCount(host: fixture.host) > 0)

        let canceledTask = Task {
            try await secondStore.ensureBaseImage(
                stateUpdate: { stage in secondStages.mutate { $0.append(stage) } }
            )
        }
        // The fixture keeps the first transaction in-flight long enough for
        // this task to suspend in the gate instead of being canceled pre-entry.
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))
        canceledTask.cancel()

        do {
            _ = try await canceledTask.value
            Issue.record("The canceled cache waiter unexpectedly prepared an image")
        } catch is CancellationError {
            // Expected: cancellation removes the waiter before it inherits the gate.
        } catch {
            Issue.record("The canceled cache waiter threw \(error) instead of CancellationError")
        }
        _ = try await firstTask.value

        #expect(secondStages.value.isEmpty)
        #expect(ImageDownloadFixture.requestCount(host: fixture.host) == 2)
    }

    private func makeStore(
        stateDirectory: StateDirectory,
        fixture: ImageDownloadFixture.Configuration
    ) -> ImageStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageDownloadFixture.self]
        return ImageStore(
            stateDirectory: stateDirectory,
            fileManager: FileManager(),
            session: URLSession(configuration: configuration),
            checksumsRemoteURL: fixture.checksumsURL,
            baseImageRemoteURL: fixture.imageURL
        )
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        self.storedValue = value
    }

    var value: Value {
        lock.withLock { storedValue }
    }

    func mutate(_ mutation: (inout Value) -> Void) {
        lock.withLock { mutation(&storedValue) }
    }
}

private final class ImageDownloadFixture: URLProtocol, @unchecked Sendable {
    struct Configuration: Sendable {
        let host: String
        let checksumsURL: URL
        let imageURL: URL
    }

    private struct Fixture: Sendable {
        let checksumData: Data
        let imageData: Data
        let delaySeconds: TimeInterval
        var requestCount: Int
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: Fixture] = [:]

    static func install(delaySeconds: TimeInterval) -> Configuration {
        let host = "\(UUID().uuidString.lowercased()).vetro.test"
        let imageName = "debian-13-genericcloud-arm64.raw"
        let imageData = Data("abc".utf8)
        let digest = "ddaf35a193617abacc417349ae204131"
            + "12e6fa4e89a97ea20a9eeee64b55d39a"
            + "2192992a274fc1a836ba3c23a3feebbd"
            + "454d4423643ce80e2a9ac94fa54ca49f"
        let checksumData = Data("\(digest)  \(imageName)\n".utf8)
        lock.withLock {
            fixtures[host] = Fixture(
                checksumData: checksumData,
                imageData: imageData,
                delaySeconds: delaySeconds,
                requestCount: 0
            )
        }
        return Configuration(
            host: host,
            checksumsURL: URL(string: "https://\(host)/SHA512SUMS")!,
            imageURL: URL(string: "https://\(host)/\(imageName)")!
        )
    }

    static func remove(host: String) {
        _ = lock.withLock { fixtures.removeValue(forKey: host) }
    }

    static func requestCount(host: String) -> Int {
        lock.withLock { fixtures[host]?.requestCount ?? 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { fixtures[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let fixture = Self.fixtureAndRecordRequest(host: url.host)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        Thread.sleep(forTimeInterval: fixture.delaySeconds)
        let data = url.lastPathComponent == "SHA512SUMS"
            ? fixture.checksumData
            : fixture.imageData
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(data.count)]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func fixtureAndRecordRequest(host: String?) -> Fixture? {
        guard let host else { return nil }
        return lock.withLock {
            guard var fixture = fixtures[host] else { return nil }
            fixture.requestCount += 1
            fixtures[host] = fixture
            return fixture
        }
    }
}
