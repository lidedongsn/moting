import CryptoKit
import Foundation

public enum ModelStoreError: Error, Equatable {
    case checksumMismatch(String)
    case allMirrorsFailed(String)
}

/// 模型的下载、校验、删除。每个模型一个目录：root/<model-id>/
public final class ModelStore: @unchecked Sendable {
    public let root: URL
    private let mirrors: [URL]

    public init(root: URL, mirrors: [URL] = [URL(string: "https://huggingface.co")!,
                                            URL(string: "https://hf-mirror.com")!]) {
        self.root = root
        self.mirrors = mirrors
    }

    public func directory(for m: StreamingModel) -> URL {
        root.appendingPathComponent(m.id, isDirectory: true)
    }

    /// 所有文件存在且大小一致（完整性在下载时已用 SHA-256 校验过）
    public func isInstalled(_ m: StreamingModel) -> Bool {
        m.files.allSatisfy { fileSize(directory(for: m).appendingPathComponent($0.name)) == $0.size }
    }

    /// 逐个文件下载到 .part，SHA-256 校验通过后改名；已存在且大小一致的文件跳过。
    /// 每个文件依次尝试各镜像：<mirror>/<repo>/resolve/main/<name>
    public func install(_ m: StreamingModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        let dir = directory(for: m)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let total = Double(max(m.totalSize, 1))
        var done: Int64 = 0
        for file in m.files {
            let target = dir.appendingPathComponent(file.name)
            if fileSize(target) == file.size {
                done += file.size
                progress(Double(done) / total)
                continue
            }
            let base = done
            try await download(file, repo: m.repo, to: target) { bytes in
                progress(Double(base + bytes) / total)
            }
            done += file.size
            progress(Double(done) / total)
        }
        progress(1.0)
    }

    public func remove(_ m: StreamingModel) throws {
        let dir = directory(for: m)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    public func diskUsage(_ m: StreamingModel) -> Int64 {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory(for: m).path) else { return 0 }
        return names.reduce(0) { $0 + (fileSize(directory(for: m).appendingPathComponent($1)) ?? 0) }
    }

    // MARK: - 内部

    private func download(_ file: ModelFile, repo: String, to target: URL,
                          progress: @escaping @Sendable (Int64) -> Void) async throws {
        let part = target.appendingPathExtension("part")
        defer { try? FileManager.default.removeItem(at: part) }
        for mirror in mirrors {
            let url = mirror.appendingPathComponent(repo).appendingPathComponent("resolve/main")
                .appendingPathComponent(file.name)
            do {
                let tmp = try await FileDownloader.download(url, progress: progress)
                try? FileManager.default.removeItem(at: part)
                try FileManager.default.moveItem(at: tmp, to: part)
            } catch {
                continue   // 换下一个镜像
            }
            guard try Self.sha256(of: part) == file.sha256 else {
                throw ModelStoreError.checksumMismatch(file.name)
            }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: part, to: target)
            return
        }
        throw ModelStoreError.allMirrorsFailed(file.name)
    }

    private func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
    }

    /// 按 1MB 分块流式计算，避免把大模型整体读进内存
    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 带字节进度的单文件下载，返回临时文件路径（调用方负责移走）
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private let progress: @Sendable (Int64) -> Void

    private init(progress: @escaping @Sendable (Int64) -> Void) {
        self.progress = progress
    }

    static func download(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let d = FileDownloader(progress: progress)
        let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            d.continuation = c
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation?.resume(throwing: URLError(.badServerResponse))
            continuation = nil
            return
        }
        // location 在回调返回后即被删除，先移到自己的临时位置
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("moting-dl-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: tmp)
            continuation?.resume(returning: tmp)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
