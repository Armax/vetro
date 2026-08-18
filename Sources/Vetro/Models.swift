import Foundation

struct VMOrigin: Codable, Hashable {
    let vmID: UUID
    var guestPath: String
}

struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var path: String?
    var vmOrigin: VMOrigin?

    init(id: UUID = UUID(), name: String, path: String?, vmOrigin: VMOrigin? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.vmOrigin = vmOrigin
    }

    var url: URL? { path.map { URL(fileURLWithPath: $0) } }
    var isVMOnly: Bool { path == nil && vmOrigin != nil }
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
