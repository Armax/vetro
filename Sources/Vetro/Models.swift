import Foundation

struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var path: String

    init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }

    var url: URL { URL(fileURLWithPath: path) }
}

enum SessionTarget: Hashable {
    case project(UUID)
    case mac
    case vm(UUID)
}

/// A live terminal session. Sessions are runtime-only: a terminal process
/// can't be resurrected across launches, so they are not persisted.
struct Session: Identifiable, Hashable {
    let id: UUID
    var target: SessionTarget
    var title: String
    var pinned: Bool = false
    let createdAt: Date

    var projectID: UUID? { if case .project(let id) = target { id } else { nil } }
    var vmID: UUID? { if case .vm(let id) = target { id } else { nil } }

    init(id: UUID = UUID(), target: SessionTarget, title: String, createdAt: Date = .now) {
        self.id = id
        self.target = target
        self.title = title
        self.createdAt = createdAt
    }
}
