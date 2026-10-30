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

    @discardableResult
    public func ensureMeetingDirectory(_ id: UUID) throws -> URL {
        let dir = meetingDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
