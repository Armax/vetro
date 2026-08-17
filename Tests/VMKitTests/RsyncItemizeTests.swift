import Testing
@testable import VMKit

@Suite("Rsync itemize previews")
struct RsyncItemizeTests {
    @Test("empty and noise-only output is empty")
    func emptyAndNoise() {
        let preview = TransferPreview.parseItemizeOutput(
            """
            sending incremental file list
            cannot delete non-empty directory
            12% 1.2MB/s

            """
        )

        #expect(preview.isEmpty)
    }

    @Test("deletes preserve order and classify trailing directories")
    func deletes() {
        let preview = RsyncItemize.parse(
            """
            *deleting old-file.txt
              *deleting ./old directory/
            *deleting final-file
            """
        )

        #expect(preview.deletes == [
            TransferChange(path: "old-file.txt", kind: .file),
            TransferChange(path: "old directory", kind: .directory),
            TransferChange(path: "final-file", kind: .file),
        ])
    }

    @Test("adds classify files, directories, and symlinks")
    func adds() {
        let preview = RsyncItemize.parse(
            """
            >f+++++++++ file.txt
            <f+++++++++ ./received file.txt
            cd+++++++++ source/
            >d+++++++++ generated
            >L+++++++++ current
            """
        )

        #expect(preview.adds == [
            TransferChange(path: "file.txt", kind: .file),
            TransferChange(path: "received file.txt", kind: .file),
            TransferChange(path: "source", kind: .directory),
            TransferChange(path: "generated", kind: .directory),
            TransferChange(path: "current", kind: .symlink),
        ])
    }

    @Test("content changes are updates and attribute-only rows are ignored")
    func updatesAndIgnoredRows() {
        let preview = RsyncItemize.parse(
            """
            >f.st...... changed-time
            <f.st...... import-changed
            >fcst...... changed-all
            >f..t...... changed-lower-time
            >f..T...... changed-upper-time
            .f...p.... permissions-only
            .f......... unchanged
            .f...pog... attributes-only
            .f..t...... time-only-no-transfer
            .d..t...... keepdir/
            """
        )

        #expect(preview.updates == [
            TransferChange(path: "changed-time", kind: .file),
            TransferChange(path: "import-changed", kind: .file),
            TransferChange(path: "changed-all", kind: .file),
            TransferChange(path: "changed-lower-time", kind: .file),
            TransferChange(path: "changed-upper-time", kind: .file),
        ])
        #expect(preview.adds.isEmpty)
        #expect(preview.deletes.isEmpty)
    }

    @Test("openrsync 9-character itemize lines are classified")
    func openrsyncFlags() {
        let preview = RsyncItemize.parse(
            """
            >f+++++++ new-file
            cd+++++++ new-dir/
            cL+++++++ new-link
            >f.s..... resized
            .d..t.... keepdir/
            """
        )

        #expect(preview.adds == [
            TransferChange(path: "new-file", kind: .file),
            TransferChange(path: "new-dir", kind: .directory),
            TransferChange(path: "new-link", kind: .symlink),
        ])
        #expect(preview.updates == [
            TransferChange(path: "resized", kind: .file),
        ])
        #expect(preview.deletes.isEmpty)
    }

    @Test("mixed buckets, duplicate rows, and unknown types are handled")
    func mixedAndDeduplicated() {
        let preview = RsyncItemize.parse(
            """
            >f+++++++++ ./new file
            >f+++++++++ ./new file
            >f.st...... ./changed file
            >f.st...... ./changed file
            *deleting ./removed/
            *deleting ./removed/
            cd+++++++++ .
            .d..t...... .
            Df+++++++++ device
            >D+++++++++ device-two
            >S+++++++++ special
            >h+++++++++ hardlink
            sending incremental file list
            cannot delete non-empty directory ./removed
            """
        )

        #expect(preview.adds == [
            TransferChange(path: "new file", kind: .file),
        ])
        #expect(preview.updates == [
            TransferChange(path: "changed file", kind: .file),
        ])
        #expect(preview.deletes == [
            TransferChange(path: "removed", kind: .directory),
        ])
        #expect(!preview.isEmpty)
    }

    @Test("isEmpty is false for each non-empty bucket")
    func isEmpty() {
        #expect(!TransferPreview(adds: [TransferChange(path: "a", kind: .file)]).isEmpty)
        #expect(!TransferPreview(updates: [TransferChange(path: "u", kind: .file)]).isEmpty)
        #expect(!TransferPreview(deletes: [TransferChange(path: "d", kind: .file)]).isEmpty)
    }
}
