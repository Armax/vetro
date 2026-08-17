import SwiftUI
import VMKit

struct TransferPreviewSheet: View {
    private static let stateHeight: CGFloat = 300

    @Environment(AppSettings.self) private var settings
    @Environment(VMStore.self) private var vms
    @Environment(UIState.self) private var ui
    @Environment(\.dismiss) private var dismiss

    let project: Project
    let direction: TransferDirection

    @State private var preview: TransferPreview?
    @State private var expandedSections: Set<TransferPreviewSection> = [.deletes]
    @State private var isRunning = false
    @State private var didFinish = false
    @State private var didStartComparison = false
    @State private var ignoredPaths: Set<String> = []
    @State private var hideIgnored = false

    private var isExport: Bool { direction == .exportToMac }

    private var ignoredCount: Int {
        guard let preview else { return 0 }
        return (preview.adds + preview.updates + preview.deletes)
            .count { ignoredPaths.contains($0.path) }
    }

    private func filtered(_ preview: TransferPreview) -> TransferPreview {
        guard hideIgnored, !ignoredPaths.isEmpty else { return preview }
        return TransferPreview(
            adds: preview.adds.filter { !ignoredPaths.contains($0.path) },
            updates: preview.updates.filter { !ignoredPaths.contains($0.path) },
            deletes: preview.deletes.filter { !ignoredPaths.contains($0.path) }
        )
    }

    var body: some View {
        let theme = settings.theme

        VStack(alignment: .leading, spacing: 0) {
            Text("\(isExport ? "Export" : "Re-import") \(project.name)")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(theme.t1)

            Text(directionLine)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.t3)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 5)

            stateContent(theme: theme)

            actionArea(theme: theme)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(width: 460)
        .glassPanel(
            tint: theme.menu,
            enabled: !settings.reduceTransparency,
            fallback: theme.solidToolbar
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(theme.sideLine, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 40, y: 30)
        .onExitCommand { cancel() }
        .task { await compare() }
        .onDisappear { cancelPendingIfNeeded() }
    }

    private var directionLine: String {
        let vmPath = vms.attachment(for: project.id)?.guestPath ?? "VM"
        switch direction {
        case .exportToMac:
            return "VM \(vmPath) → Mac \(project.path)"
        case .importFromMac:
            return "Mac \(project.path) → VM \(vmPath)"
        }
    }

    @ViewBuilder
    private func stateContent(theme: Theme) -> some View {
        Group {
            if isRunning {
                TransferRunningState(
                    direction: direction,
                    progress: vms.attachment(for: project.id)?.importProgress,
                    theme: theme
                )
            } else if let preview {
                VStack(alignment: .leading, spacing: 8) {
                    if ignoredCount > 0 {
                        HStack {
                            Spacer()
                            Toggle(isOn: $hideIgnored) {
                                Text("Hide ignored (\(ignoredCount))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.t2)
                            }
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .tint(theme.accent)
                        }
                    }
                    TransferPreviewList(
                        preview: filtered(preview),
                        direction: direction,
                        expandedSections: $expandedSections
                    )
                }
            } else {
                TransferComparingState(theme: theme)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: Self.stateHeight,
            maxHeight: Self.stateHeight,
            alignment: .topLeading
        )
        .padding(.top, 14)
    }

    @ViewBuilder
    private func actionArea(theme: Theme) -> some View {
        if isRunning {
            Color.clear
                .frame(height: 28)
                .padding(.top, 16)
        } else {
            HStack(spacing: 10) {
                Spacer()
                sheetButton("Cancel", tint: theme.chip, foreground: theme.t1) {
                    cancel()
                }
                if let preview {
                    let changes = preview.adds.count + preview.updates.count + preview.deletes.count
                    let hasDeletes = !preview.deletes.isEmpty
                    sheetButton(
                        "\(isExport ? "Export" : "Import") (\(changes) changes)",
                        tint: hasDeletes
                            ? Color(hex: 0xff6358, alpha: 0.18)
                            : theme.accentChip,
                        foreground: hasDeletes ? theme.red : theme.accentTxt,
                        ring: hasDeletes ? Color(hex: 0xff6358, alpha: 0.30) : nil
                    ) {
                        confirm()
                    }
                }
            }
            .padding(.top, 16)
        }
    }

    private func sheetButton(
        _ title: String,
        tint: Color,
        foreground: Color,
        ring: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Hoverable { hovered in
            Button(action: action) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(foreground)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(
                        hovered ? tint : tint.opacity(0.92),
                        in: Capsule()
                    )
                    .overlay {
                        Capsule()
                            .strokeBorder(ring ?? settings.theme.sideLine, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
        }
    }

    private func compare() async {
        guard !didStartComparison else { return }
        didStartComparison = true

        do {
            let result: TransferPreview
            switch direction {
            case .exportToMac:
                result = try await vms.previewExport(project)
            case .importFromMac:
                result = try await vms.previewImport(project)
            }

            guard !Task.isCancelled, !didFinish else { return }
            if result.isEmpty {
                didFinish = true
                ui.showToast(isExport ? "Nothing to export" : "Nothing to import")
                closeSheet()
            } else {
                preview = result
                let paths = (result.adds + result.updates + result.deletes).map(\.path)
                ignoredPaths = await Self.gitIgnoredPaths(paths, repo: project.path)
            }
        } catch is CancellationError {
            // Cancelling the sheet invalidates the store's comparison token.
        } catch {
            guard !didFinish else { return }
            didFinish = true
            closeSheet()
        }
    }

    private func confirm() {
        guard let preview,
              !preview.isEmpty,
              !isRunning,
              vms.pendingTransfer?.projectID == project.id,
              vms.pendingTransfer?.phase == .awaitingConfirm
        else {
            cancel()
            return
        }

        isRunning = true
        Task { @MainActor in
            await vms.confirmPendingTransfer()
            guard !didFinish else { return }
            didFinish = true
            ui.showToast(isExport ? "Exported \(project.name)" : "Imported \(project.name)")
            closeSheet()
        }
    }

    private func cancel() {
        guard !isRunning else { return }
        vms.cancelPendingTransfer()
        didFinish = true
        closeSheet()
    }

    private func closeSheet() {
        ui.transferPreviewRequest = nil
        dismiss()
    }

    private func cancelPendingIfNeeded() {
        guard !didFinish, !isRunning else { return }
        if vms.pendingTransfer?.projectID == project.id {
            vms.cancelPendingTransfer()
        }
        didFinish = true
    }

    /// Which of `paths` are gitignored in `repo` (empty when not a git repo).
    private nonisolated static func gitIgnoredPaths(
        _ paths: [String],
        repo: String
    ) async -> Set<String> {
        guard !paths.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-C", repo, "check-ignore", "--stdin", "-z"]
                let stdin = Pipe()
                let stdout = Pipe()
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = Pipe()
                // waitUntilExit races fast exits; install the handler
                // before run() and wait on it instead.
                let done = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in done.signal() }
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: [])
                    return
                }
                // Write on a separate queue so a large ignore list can't
                // deadlock against the unread output pipe.
                DispatchQueue.global(qos: .userInitiated).async {
                    let input = paths.joined(separator: "\0") + "\0"
                    stdin.fileHandleForWriting.write(Data(input.utf8))
                    stdin.fileHandleForWriting.closeFile()
                }
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                done.wait()
                // 0 = matches found, 1 = none; anything else is not a repo.
                guard [0, 1].contains(process.terminationStatus) else {
                    continuation.resume(returning: [])
                    return
                }
                let output = String(decoding: data, as: UTF8.self)
                continuation.resume(
                    returning: Set(output.split(separator: "\0").map(String.init))
                )
            }
        }
    }
}

private enum TransferPreviewSection: String, CaseIterable, Hashable, Identifiable {
    case deletes
    case updates
    case adds

    var id: String { rawValue }

    func title(direction: TransferDirection) -> String {
        switch self {
        case .deletes:
            direction == .exportToMac ? "Delete on Mac" : "Delete in VM"
        case .updates:
            "Update"
        case .adds:
            "Add"
        }
    }
}

private struct TransferPreviewList: View {
    @Environment(AppSettings.self) private var settings

    let preview: TransferPreview
    let direction: TransferDirection
    @Binding var expandedSections: Set<TransferPreviewSection>

    private var sections: [TransferPreviewSection] {
        TransferPreviewSection.allCases.filter { count(for: $0) > 0 }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 6) {
                ForEach(sections) { section in
                    TransferSectionCard(
                        section: section,
                        title: section.title(direction: direction),
                        changes: changes(for: section),
                        isDanger: section == .deletes,
                        isExpanded: expandedSections.contains(section),
                        onToggle: {
                            withAnimation(.easeOut(duration: 0.15)) {
                                if expandedSections.contains(section) {
                                    expandedSections.remove(section)
                                } else {
                                    expandedSections.insert(section)
                                }
                            }
                        },
                        theme: settings.theme
                    )
                }
            }
            .padding(.horizontal, 1)
        }
        .scrollIndicators(.automatic)
    }

    private func changes(for section: TransferPreviewSection) -> [TransferChange] {
        switch section {
        case .deletes: preview.deletes
        case .updates: preview.updates
        case .adds: preview.adds
        }
    }

    private func count(for section: TransferPreviewSection) -> Int {
        changes(for: section).count
    }
}

private struct TransferSectionCard: View {
    let section: TransferPreviewSection
    let title: String
    let changes: [TransferChange]
    let isDanger: Bool
    let isExpanded: Bool
    let onToggle: () -> Void
    let theme: Theme

    var body: some View {
        VStack(spacing: 0) {
            Hoverable { hovered in
                Button(action: onToggle) {
                    HStack(spacing: 8) {
                        Text(isExpanded ? "⌄" : "›")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(theme.t3)
                            .frame(width: 10)
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isDanger ? theme.red : theme.t2)
                        Spacer(minLength: 4)
                        Text("\(changes.count)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(isDanger ? theme.red : theme.t2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                            .background(
                                isDanger ? Color(hex: 0xff6358, alpha: 0.14) : theme.chip,
                                in: Capsule()
                            )
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(hovered ? theme.hover : .clear, in: Rectangle())
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                VStack(spacing: 2) {
                    ForEach(changes) { change in
                        TransferChangeRow(
                            change: change,
                            section: section,
                            isDanger: isDanger,
                            theme: theme
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
        .background(theme.field, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(theme.sideLine, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct TransferChangeRow: View {
    let change: TransferChange
    let section: TransferPreviewSection
    let isDanger: Bool
    let theme: Theme

    var body: some View {
        HStack(spacing: 9) {
            Text(glyph)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(isDanger ? theme.red : theme.t2)
                .frame(width: 12)

            Text(relativePath)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(isDanger ? theme.red.opacity(0.92) : theme.t1)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            isDanger ? Color(hex: 0xff6358, alpha: 0.08) : .clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    private var glyph: String {
        switch section {
        case .deletes: "−"
        case .updates: "~"
        case .adds: "+"
        }
    }

    private var relativePath: String {
        change.path + (change.kind == .directory ? "/" : "")
    }
}

private struct TransferComparingState: View {
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                TransferSpinner(theme: theme)
                Text("Comparing…")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.t1)
            }

            IndeterminateTransferBar(theme: theme)
                .padding(.top, 10)
        }
        .padding(.top, 4)
    }
}

private struct TransferRunningState: View {
    let direction: TransferDirection
    let progress: Double?
    let theme: Theme

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Text(direction == .exportToMac ? "Exporting…" : "Importing…")
                Spacer(minLength: 4)
                if direction == .importFromMac {
                    Text("\(Int(clampedProgress.rounded()))%")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.t3)

            if direction == .exportToMac {
                IndeterminateTransferBar(theme: theme)
            } else {
                TransferProgressBar(progress: clampedProgress / 100, theme: theme)
            }
        }
        .padding(.top, 4)
    }

    private var clampedProgress: Double {
        min(max(progress ?? 0, 0), 100)
    }
}

private struct TransferProgressBar: View {
    let progress: Double
    let theme: Theme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.field)
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.accent)
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 3)
        .animation(.easeOut(duration: 0.2), value: progress)
    }
}

private struct IndeterminateTransferBar: View {
    let theme: Theme
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let segmentWidth = proxy.size.width * 0.35
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.field)
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.accent)
                    .frame(width: segmentWidth)
                    .offset(x: (proxy.size.width + segmentWidth) * phase - segmentWidth)
            }
        }
        .frame(height: 3)
        .clipped()
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

private struct TransferSpinner: View {
    let theme: Theme
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(theme.accent.opacity(0.25), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(theme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(.linear(duration: 0.7).repeatForever(autoreverses: false), value: spinning)
        }
        .frame(width: 11, height: 11)
        .onAppear { spinning = true }
    }
}
