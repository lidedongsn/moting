import Foundation
import MotingCore

/// 数据目录布局：root/moting.sqlite、root/meetings/<id>/<mic|system>.pcm
public struct AppPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var `default`: AppPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(root: support.appendingPathComponent("Moting", isDirectory: true))
    }

    public var databaseURL: URL { root.appendingPathComponent("moting.sqlite") }

    public func meetingDirectory(_ id: UUID) -> URL {
        root.appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func trackURL(_ id: UUID, _ channel: AudioChannel) -> URL {
        meetingDirectory(id).appendingPathComponent("\(channel.rawValue).pcm")
    }

    /// 轨道文件相对 root 的路径，存进数据库，数据目录整体搬家后仍有效
    public func relativeTrackPath(_ id: UUID, _ channel: AudioChannel) -> String {
        "meetings/\(id.uuidString)/\(channel.rawValue).pcm"
    }

    public var meetingsRoot: URL { root.appendingPathComponent("meetings", isDirectory: true) }

    /// 用户声纹：root/voiceprint/me.f32
    public var voiceprintURL: URL { root.appendingPathComponent("voiceprint/me.f32") }

    /// 热词表：root/hotwords.txt，每行一个
    public var hotwordsURL: URL { root.appendingPathComponent("hotwords.txt") }

    /// 识别模型目录：root/models/<model-id>/
    public var modelsRoot: URL { root.appendingPathComponent("models", isDirectory: true) }

    /// 全部模型占用的字节数
    public func modelsDiskUsage() -> Int64 {
        Self.diskUsage(modelsRoot)
    }

    /// 全部录音占用的字节数
    public func meetingsDiskUsage() -> Int64 {
        Self.diskUsage(meetingsRoot)
    }

    /// 单场会议占用的字节数
    public func diskUsage(of id: UUID) -> Int64 {
        Self.diskUsage(meetingDirectory(id))
    }

    private static func diskUsage(_ dir: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.fileSize ?? 0)
        }
        return total
    }

    @discardableResult
    public func ensureMeetingDirectory(_ id: UUID) throws -> URL {
        let dir = meetingDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
