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
    private let lock = NSLock()
    private var _proxy: URL?
    /// 正在安装的模型：同一模型同时只装一次，后来的等前一个的结果（共用 .part 文件会互相删）
    private var inFlight: [String: Task<Void, Error>] = [:]
    /// 下载代理，可在运行中修改（设置页）
    public var proxy: URL? {
        get { lock.withLock { _proxy } }
        set { lock.withLock { _proxy = newValue } }
    }

    /// 默认 hf-mirror 优先：国内直连 huggingface.co 常超时，hf-mirror 可达。
    /// proxy 形如 http://127.0.0.1:7897；系统代理关闭但本机有代理时用它
    public init(root: URL, mirrors: [URL] = [URL(string: "https://hf-mirror.com")!,
                                            URL(string: "https://huggingface.co")!],
                proxy: URL? = nil) {
        self.root = root
        self.mirrors = mirrors
        _proxy = proxy
    }

    public func directory(for m: some DownloadableModel) -> URL {
        root.appendingPathComponent(m.id, isDirectory: true)
    }

    /// 所有文件存在且大小一致（完整性在下载时已用 SHA-256 校验过）
    public func isInstalled(_ m: some DownloadableModel) -> Bool {
        m.files.allSatisfy { fileSize(directory(for: m).appendingPathComponent($0.name)) == $0.size }
    }

    /// HuggingFace / 直链：逐个文件下载到 .part，SHA-256 校验通过后改名；已存在且大小一致的文件跳过。
    /// HuggingFace 每个文件依次尝试各镜像：<mirror>/<repo>/resolve/main/<name>。
    /// GitHub 压缩包：整包校验后只解出列出的文件
    public func install(_ m: some DownloadableModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        let id = m.id
        let (task, isOwner): (Task<Void, Error>, Bool) = lock.withLock {
            if let t = inFlight[id] { return (t, false) }
            let t = Task { try await self.performInstall(m, progress: progress) }
            inFlight[id] = t
            return (t, true)
        }
        defer { if isOwner { lock.withLock { inFlight[id] = nil } } }
        // 发起方被取消（如暂停精准转写）时取消下载，不必等下完
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            if isOwner { task.cancel() }
        }
        if !isOwner { progress(1) }
    }

    private func performInstall(_ m: some DownloadableModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        let dir = directory(for: m)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if case .githubArchive(let url, let sha, let size, let prefix) = m.source {
            if !isInstalled(m) {
                try await installArchive(m, url: url, sha256: sha, size: size, prefix: prefix, into: dir, progress: progress)
            }
            progress(1.0)
            return
        }
        let total = Double(max(m.totalSize, 1))
        var done: Int64 = 0
        for file in m.files {
            let target = dir.appendingPathComponent(file.name)
            if fileSize(target) == file.size {
                done += file.size
                progress(Double(done) / total)
                continue
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = done
            let urls: [URL]
            switch m.source {
            case .huggingFace(let repo):
                urls = mirrors.map { $0.appendingPathComponent(repo).appendingPathComponent("resolve/main").appendingPathComponent(file.name) }
            case .direct(let baseURL):
                urls = [baseURL.appendingPathComponent(file.name)]
            case .githubArchive:
                urls = []
            }
            try await download(file, from: urls, to: target) { bytes in
                progress(Double(base + bytes) / total)
            }
            done += file.size
            progress(Double(done) / total)
        }
        progress(1.0)
    }

    public func remove(_ m: some DownloadableModel) throws {
        let dir = directory(for: m)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    public func diskUsage(_ m: some DownloadableModel) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: directory(for: m), includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.fileSize ?? 0)
        }
        return total
    }

    // MARK: - 内部

    private func download(_ file: ModelFile, from urls: [URL], to target: URL,
                          progress: @escaping @Sendable (Int64) -> Void) async throws {
        let part = target.appendingPathExtension("part")
        defer { try? FileManager.default.removeItem(at: part) }
        for url in urls {
            var tmp: URL?
            do {
                tmp = try await FileDownloader.download(url, proxy: proxy, progress: progress)
                try? FileManager.default.removeItem(at: part)
                try FileManager.default.moveItem(at: tmp!, to: part)
            } catch {
                // 下载到一半或移动失败：删掉系统临时目录里的残留（可能上百 MB），换下一个镜像
                if let tmp { try? FileManager.default.removeItem(at: tmp) }
                continue
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

    /// 下载压缩包 → 整包 SHA-256 → 只解出列出的文件 → 逐个核对大小后移入模型目录；临时文件全部清理
    private func installArchive(_ m: some DownloadableModel, url: URL, sha256: String, size: Int64, prefix: String,
                                into dir: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("moting-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let tmp = try await FileDownloader.download(url, proxy: proxy) { bytes in progress(Double(bytes) / Double(max(size, 1)) * 0.9) }
        let archive = work.appendingPathComponent(url.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.moveItem(at: tmp, to: archive)
        guard try Self.sha256(of: archive) == sha256 else {
            throw ModelStoreError.checksumMismatch(url.lastPathComponent)
        }
        let out = work.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xjf", archive.path, "-C", out.path] + m.files.map { "\(prefix)/\($0.name)" }
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw ModelStoreError.allMirrorsFailed(url.lastPathComponent) }
        for file in m.files {
            let src = out.appendingPathComponent(prefix).appendingPathComponent(file.name)
            guard fileSize(src) == file.size else { throw ModelStoreError.checksumMismatch(file.name) }
            let target = dir.appendingPathComponent(file.name)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: src, to: target)
        }
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

    static func download(_ url: URL, proxy: URL?, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let d = FileDownloader(progress: progress)
        let config = URLSessionConfiguration.default
        // 30 秒没有数据就放弃，尽快换下一个来源
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 6 * 3600
        // 不写系统网络缓存（~/Library/Caches/<bundle id>），不在 app 目录之外留文件
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let proxy, let host = proxy.host {
            let port = proxy.port ?? 80
            config.connectionProxyDictionary = [
                "HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
                "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port,
            ]
        }
        let session = URLSession(configuration: config, delegate: d, delegateQueue: nil)
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
