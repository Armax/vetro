import Foundation

/// Bridges URLSession's download byte counts to ImageStore's Sendable callback.
// URLSession owns and serializes this immutable delegate; its only stored value is a Sendable closure.
final class ImageDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64, Int64?) -> Void

    init(progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(
            totalBytesWritten,
            totalBytesExpectedToWrite == NSURLSessionTransferSizeUnknown
                ? nil
                : totalBytesExpectedToWrite
        )
    }
}
