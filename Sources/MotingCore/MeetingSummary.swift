import Foundation

/// AI 纪要（spec 5.5）：概要、按议题的主要内容、决策、待办
public struct MeetingSummary: Codable, Equatable, Sendable {
    public struct Topic: Codable, Equatable, Sendable {
        public var title: String
        public var points: [String]

        public init(title: String, points: [String]) {
            self.title = title
            self.points = points
        }
    }

    public struct Todo: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var task: String
        /// 负责人（能识别时）
        public var owner: String?
        /// 截止时间（会上提到时），按原话保存，如"周三"
        public var due: String?
        public var done: Bool

        public init(id: UUID = UUID(), task: String, owner: String? = nil, due: String? = nil, done: Bool = false) {
            self.id = id
            self.task = task
            self.owner = owner
            self.due = due
            self.done = done
        }
    }

    public var overview: String
    public var topics: [Topic]
    public var decisions: [String]
    public var todos: [Todo]

    public init(overview: String, topics: [Topic] = [], decisions: [String] = [], todos: [Todo] = []) {
        self.overview = overview
        self.topics = topics
        self.decisions = decisions
        self.todos = todos
    }
}
