import SwiftUI
import AppKit
import VMKit

// MARK: - Right rail

/// The 44pt rail on the right edge of the terminal view: git changes
/// (with count badge) and git history toggles.
struct GitRail: View {
    let git: GitPanelModel
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let theme = settings.theme
        VStack(spacing: 6) {
            railButton(theme, active: git.isOpen && git.tab == .changes) {
                git.toggle(tab: .changes)
            } label: {
                Text("±")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
            }
            .overlay(alignment: .topTrailing) {
                if git.files.count > 0 {
                    Text("\(git.files.count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(hex: 0x0b1020))
                        .padding(.horizontal, 3)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(theme.accent, in: Capsule())
                        .offset(x: 2, y: -2)
                }
            }
            railButton(theme, active: git.isOpen && git.tab == .history) {
                git.toggle(tab: .history)
            } label: {
                Image(systemName: "clock")
                    .font(.system(size: 13))
            }
        }
        .padding(.vertical, 12)
        .frame(width: 44)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(settings.reduceTransparency ? theme.solidToolbar : theme.toolbar)
        .overlay(alignment: .leading) { theme.sideLine.frame(width: 1) }
    }

    private func railButton(
        _ theme: Theme,
        active: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> some View
    ) -> some View {
        let label = label()
        return Hoverable { hovered in
            Button(action: action) {
                label
                    .foregroundStyle(active ? theme.t1 : theme.t3)
                    .frame(width: 30, height: 30)
                    .background(
                        active ? theme.sel : (hovered ? theme.hover : .clear),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Side panel

struct GitSidePanel: View {
    let git: GitPanelModel
    @Environment(AppSettings.self) private var settings
    @Environment(UIState.self) private var ui

    var body: some View {
        let theme = settings.theme
        VStack(spacing: 0) {
            header(theme)
            if !git.hasRepo {
                emptyState(theme, "No repository")
            } else if git.tab == .changes {
                changesTab(theme)
            } else {
                HistoryList(git: git, theme: theme)
            }
        }
        .frame(maxHeight: .infinity)
        .background(settings.reduceTransparency ? theme.solidSide : theme.term)
        .overlay(alignment: .leading) { theme.sideLine.frame(width: 1) }
    }

    private func header(_ theme: Theme) -> some View {
        HStack(spacing: 9) {
            Text(git.tab == .history ? "History" : "Changes")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(theme.t1)
            if let branch = git.branch {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.trianglehead.branch")
                        .font(.system(size: 9))
                    Text(branch)
                        .lineLimit(1)
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.t3)
            }
            Spacer(minLength: 0)
            iconButton(theme, systemName: "arrow.clockwise", help: "Refresh") {
                Task {
                    await git.refreshChanges()
                    await git.refreshHistory()
                    if git.files.isEmpty {
                        ui.showToast("Working tree refreshed — no new changes")
                    }
                }
            }
            iconButton(theme, systemName: "xmark", help: "Close") { git.close() }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .overlay(alignment: .bottom) { theme.sideLine.frame(height: 1) }
    }

    private func iconButton(
        _ theme: Theme,
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Hoverable { hovered in
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.t2)
                    .frame(width: 24, height: 24)
                    .background(hovered ? theme.hover : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
        }
    }

    private func changesTab(_ theme: Theme) -> some View {
        VStack(spacing: 0) {
            SummarizeSection(git: git, theme: theme)
            if git.files.isEmpty {
                emptyState(theme, "Working tree clean")
            } else {
                ChangedFilesList(git: git, theme: theme)
                DiffPane(git: git, theme: theme)
            }
        }
    }

    private func emptyState(_ theme: Theme, _ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(theme.t3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Summarize

private struct SummarizeSection: View {
    let git: GitPanelModel
    let theme: Theme
    @Environment(UIState.self) private var ui
    @State private var pickerOpen = false

    private func color(of provider: GitProvider) -> Color {
        provider == .grok ? theme.providerGrok : theme.providerChatGPT
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                summarizeButton
                Spacer(minLength: 0)
                pickerChip
            }
            switch git.summary {
            case .idle:
                EmptyView()
            case .running(let provider, let model):
                runningCard(provider: provider, model: model)
            case .done(let summary, let provider, let model):
                doneCard(summary, provider: provider, model: model)
            case .error(let message):
                errorCard(message)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { theme.sideLine.frame(height: 1) }
    }

    private var summarizeButton: some View {
        Hoverable { hovered in
            Button {
                if git.files.isEmpty {
                    ui.showToast("No changes to summarize")
                } else {
                    Task { await git.summarize() }
                }
            } label: {
                HStack(spacing: 7) {
                    Text("✦").font(.system(size: 11))
                    Text("Summarize")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
                .foregroundStyle(theme.accentTxt)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(theme.accentChip, in: Capsule())
                .overlay { Capsule().strokeBorder(theme.cardLine, lineWidth: 1) }
                .brightness(hovered ? 0.06 : 0)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var pickerChip: some View {
        Button {
            pickerOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(git.provider.glyph)
                    .font(.system(size: 10))
                    .foregroundStyle(color(of: git.provider))
                Text("\(git.provider.displayName) · \(git.selectedModel)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.t1)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(theme.t3)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .overlay { Capsule().strokeBorder(theme.sideLine, lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $pickerOpen, arrowEdge: .bottom) {
            pickerMenu
        }
    }

    private var pickerMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(GitProvider.allCases, id: \.self) { provider in
                HStack(spacing: 6) {
                    Text(provider.glyph)
                        .font(.system(size: 9))
                        .foregroundStyle(color(of: provider))
                    Text(provider.displayName.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .kerning(0.5)
                        .foregroundStyle(theme.t3)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)
                ForEach(GitProvider.models[provider] ?? [], id: \.self) { model in
                    let current = provider == git.provider && model == git.selectedModel
                    Hoverable { hovered in
                        Button {
                            git.pick(provider: provider, model: model)
                            pickerOpen = false
                        } label: {
                            HStack(spacing: 10) {
                                Text(model)
                                    .font(.system(size: 13))
                                    .foregroundStyle(theme.t1)
                                Spacer(minLength: 0)
                                if current {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(theme.t1)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(hovered ? theme.hover : .clear, in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(6)
        .frame(minWidth: 196, alignment: .leading)
        .glassEffect(
            .regular.tint(theme.menu),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.sideLine, lineWidth: 1)
        }
    }

    private func card(@ViewBuilder content: () -> some View) -> some View {
        content()
            .background(theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(theme.cardLine, lineWidth: 1)
            }
    }

    private func runningCard(provider: GitProvider, model: String) -> some View {
        card {
            HStack(spacing: 9) {
                TintedSpinner(color: color(of: provider))
                Text("\(model) is reading \(git.files.count) changed files…")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.t2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func doneCard(_ summary: GitSummary, provider: GitProvider, model: String) -> some View {
        card {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Text(provider.glyph)
                        .font(.system(size: 11))
                        .foregroundStyle(color(of: provider))
                    Text("Summarized by \(model) · \(git.countLabel)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.t2)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Copy") {
                        if let text = git.summaryPlainText {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                            ui.showToast("Summary copied to clipboard")
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    Button {
                        Task { await git.summarize() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.t2)
                    }
                    .buttonStyle(.plain)
                    .help("Regenerate")
                    Button {
                        git.clearSummary()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.t2)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) { theme.sideLine.frame(height: 1) }

                VStack(alignment: .leading, spacing: 7) {
                    if let raw = summary.rawFallback {
                        Text(raw)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.t2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(summary.headline)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(theme.t1)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(summary.bullets, id: \.self) { bullet in
                            HStack(alignment: .top, spacing: 8) {
                                Text("•")
                                    .foregroundStyle(color(of: provider))
                                (Text(bullet.path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(theme.t1)
                                + Text(" — \(bullet.text)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.t2))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: 12))
                        }
                        if let note = summary.note, !note.isEmpty {
                            Text(note)
                                .font(.system(size: 11.5))
                                .foregroundStyle(theme.t3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .textSelection(.enabled)
    }

    private func errorCard(_ message: String) -> some View {
        card {
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.red)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.t2)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button("Retry") {
                    Task { await git.summarize() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
}

/// The design's provider-tinted 10px spinner ring.
private struct TintedSpinner: View {
    let color: Color
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(.linear(duration: 0.7).repeatForever(autoreverses: false), value: spinning)
        }
        .frame(width: 10, height: 10)
        .onAppear { spinning = true }
    }
}

// MARK: - Changed files

private struct ChangedFilesList: View {
    let git: GitPanelModel
    let theme: Theme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("CHANGED FILES")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(theme.t3)
                Spacer(minLength: 0)
                Text(git.countLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.t3)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(git.files) { file in
                        row(file)
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(maxHeight: 166)
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { theme.sideLine.frame(height: 1) }
    }

    private func row(_ file: GitFileChange) -> some View {
        let selected = file.path == git.selectedPath
        return Hoverable { hovered in
            Button {
                git.select(path: file.path)
            } label: {
                HStack(spacing: 8) {
                    Text(displayLetter(file.status))
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(statusColor(file.status, theme))
                        .frame(width: 12)
                    Text(file.path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.t1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if file.added > 0 {
                        Text("+\(file.added)")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(theme.greenBright)
                    }
                    if file.deleted > 0 {
                        Text("−\(file.deleted)")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(theme.red)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    selected ? theme.sel : (hovered ? theme.hover : .clear),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

func displayLetter(_ status: GitFileStatus) -> String {
    status == .untracked ? "A" : status.rawValue
}

func statusColor(_ status: GitFileStatus, _ theme: Theme) -> Color {
    switch status {
    case .added, .untracked: theme.greenBright
    case .deleted: theme.red
    case .modified, .renamed: theme.amber
    }
}

// MARK: - Diff pane

private struct DiffPane: View {
    let git: GitPanelModel
    let theme: Theme

    var body: some View {
        VStack(spacing: 0) {
            if let file = git.selectedFile {
                HStack(spacing: 8) {
                    Text(displayLetter(file.status))
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(statusColor(file.status, theme))
                    Text(file.path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.t1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if file.added > 0 {
                        Text("+\(file.added)")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(theme.greenBright)
                    }
                    if file.deleted > 0 {
                        Text("−\(file.deleted)")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(theme.red)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .overlay(alignment: .bottom) { theme.sideLine.frame(height: 1) }
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(git.diffRows.enumerated()), id: \.offset) { _, row in
                        diffRow(row)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.code)
        }
    }

    private func diffRow(_ row: DiffRow) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(row.oldLine.map(String.init) ?? "")
                .foregroundStyle(gutterColor(row.kind))
                .frame(width: 32, alignment: .trailing)
                .padding(.trailing, 7)
            Text(row.newLine.map(String.init) ?? "")
                .foregroundStyle(gutterColor(row.kind))
                .frame(width: 32, alignment: .trailing)
                .padding(.trailing, 10)
            Text(row.mark.map(String.init) ?? "")
                .fontWeight(.bold)
                .foregroundStyle(markColor(row.kind))
                .frame(width: 13, alignment: .leading)
            Text(row.text.isEmpty ? " " : row.text)
                .foregroundStyle(textColor(row.kind))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 14)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 1.5)
        .background(rowBackground(row.kind))
    }

    private func rowBackground(_ kind: DiffRow.Kind) -> Color {
        switch kind {
        case .hunk: theme.accent.opacity(0.08)
        case .add: theme.greenBright.opacity(0.09)
        case .del: theme.red.opacity(0.09)
        case .ctx: .clear
        }
    }

    private func textColor(_ kind: DiffRow.Kind) -> Color {
        switch kind {
        case .hunk: theme.diffHunk
        case .add: theme.diffAdd
        case .del: theme.diffDel
        case .ctx: theme.diffCtx
        }
    }

    private func gutterColor(_ kind: DiffRow.Kind) -> Color {
        switch kind {
        case .hunk: .clear
        case .add: theme.diffAddGutter
        case .del: theme.diffDelGutter
        case .ctx: theme.diffGutter
        }
    }

    private func markColor(_ kind: DiffRow.Kind) -> Color {
        switch kind {
        case .add: theme.greenBright
        case .del: theme.red
        case .hunk, .ctx: .clear
        }
    }
}

// MARK: - History

private struct HistoryList: View {
    let git: GitPanelModel
    let theme: Theme

    var body: some View {
        if git.commits.isEmpty {
            Text("No commits")
                .font(.system(size: 12))
                .foregroundStyle(theme.t3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(git.commits.enumerated()), id: \.element.id) { index, commit in
                        row(commit, isHead: index == 0)
                    }
                }
                .padding(8)
            }
        }
    }

    private func row(_ commit: GitCommit, isHead: Bool) -> some View {
        Hoverable { hovered in
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(isHead ? theme.amber : theme.chipHi)
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(commit.message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.t1)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(commit.shortHash)
                            .font(.system(size: 11, design: .monospaced))
                        Text("\(commit.relativeAge) · \(commit.author)")
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if commit.added > 0 {
                            Text("+\(commit.added)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(theme.greenBright)
                        }
                        if commit.deleted > 0 {
                            Text("−\(commit.deleted)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(theme.red)
                        }
                    }
                    .foregroundStyle(theme.t3)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered ? theme.hover : .clear, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
