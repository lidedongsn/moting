import Foundation
import GRDB

public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try AppDatabase(writer: DatabasePool(path: url.path))
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(writer: DatabaseQueue())
    }

    /// 只追加新迁移，不修改已发布的迁移
    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "meeting") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("endedAt", .datetime)
                t.column("status", .text).notNull().indexed()
            }
            try db.create(table: "audioTrack") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.column("channel", .text).notNull()
                t.column("relativePath", .text).notNull()
                t.column("sampleRate", .integer).notNull()
            }
            try db.create(table: "mark") { t in
                t.primaryKey("id", .text)
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.column("at", .double).notNull()
            }
            try db.create(table: "pause") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
            }
        }
        m.registerMigration("v2") { db in
            try db.create(table: "transcriptVersion") { t in
                t.primaryKey("id", .text)
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.column("kind", .text).notNull()
                t.column("engine", .text).notNull()
                t.column("model", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "segment") { t in
                t.primaryKey("id", .text)
                t.belongsTo("version", inTable: "transcriptVersion", onDelete: .cascade).notNull()
                t.column("channel", .text).notNull()
                t.column("speakerLabel", .text)
                t.column("start", .double).notNull()
                t.column("end", .double).notNull()
                t.column("text", .text).notNull()
            }
        }
        m.registerMigration("v3") { db in
            try db.create(table: "job") { t in
                t.primaryKey("id", .text)
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.column("status", .text).notNull().indexed()
                t.column("completedSteps", .text).notNull()
                t.column("progress", .double).notNull()
                t.column("error", .text)
                t.column("modelId", .text).notNull()
                t.column("versionId", .text)
                t.column("filterOutcome", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "speaker") { t in
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.column("label", .text).notNull()
                t.column("displayName", .text).notNull()
                t.primaryKey(["meetingId", "label"])
            }
            try db.alter(table: "transcriptVersion") { t in
                t.add(column: "completedAt", .datetime)
            }
        }
        return m
    }
}
