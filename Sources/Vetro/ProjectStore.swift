import Foundation
import Observation

@MainActor
@Observable
final class ProjectStore {
    private(set) var projects: [Project] = []

    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vetro", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("projects.json")
        load()
    }

    func addProject(at url: URL) -> Project {
        if let existing = projects.first(where: { $0.path == url.path }) {
            return existing
        }
        let project = Project(name: url.lastPathComponent, path: url.path)
        projects.append(project)
        save()
        return project
    }

    func addVMProject(name: String, vmID: UUID, guestPath: String) -> Project {
        if let existing = projects.first(where: {
            $0.vmOrigin?.vmID == vmID && $0.vmOrigin?.guestPath == guestPath
        }) {
            return existing
        }
        let project = Project(
            name: name,
            path: nil,
            vmOrigin: VMOrigin(vmID: vmID, guestPath: guestPath)
        )
        projects.append(project)
        save()
        return project
    }

    func removeProject(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        save()
    }

    func renameProject(_ project: Project, to name: String) {
        guard let i = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[i].name = name
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Project].self, from: data)
        else { return }
        projects = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
