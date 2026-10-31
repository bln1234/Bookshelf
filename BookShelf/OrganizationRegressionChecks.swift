#if DEBUG && targetEnvironment(simulator)
import Foundation
import ReadiumShared

enum OrganizationRegressionChecks {
    static func run(directory: URL, source: URL) async throws -> [String] {
        let manager = FileManager.default
        let root = directory.appendingPathComponent("Organization", isDirectory: true)
        let initial = LibraryStore(directory: root)
        guard let imported = await initial.importBook(from: source) else { throw failure("fixture import") }
        let indexURL = root.appendingPathComponent("library.json")
        let fileURL = root.appendingPathComponent("Books/\(imported.fileName)")
        let marksURL = root.appendingPathComponent("reader-marks.json")
        var results: [String] = []

        // Simulate an actual old, plain-array index, not just a single Book decoder.
        let legacyData = try JSONEncoder().encode([imported])
        var legacyJSON = try JSONSerialization.jsonObject(with: legacyData) as! [[String: Any]]
        for key in ["collectionIDs", "deletedAt", "isFavorite", "isFinished", "lastOpenedAt", "sourceFormat"] { legacyJSON[0].removeValue(forKey: key) }
        try JSONSerialization.data(withJSONObject: legacyJSON).write(to: indexURL, options: .atomic)
        let store = LibraryStore(directory: root)
        try require(store.books.count == 1 && store.books[0].collectionIDs.isEmpty && store.collections.isEmpty, "legacy index load")
        try require(store.saveCollection(name: "  我的书单  "), "create collection")
        let first = store.collections[0]
        try require(!store.saveCollection(name: "我的书单") && !store.saveCollection(name: " \n "), "invalid collection names")
        store.errorMessage = nil
        try require(store.saveCollection(name: "待读"), "second collection")
        let second = store.collections[1]
        try require(store.setCollections([first.id, second.id, UUID()], for: imported.id), "multiple memberships")
        try require(store.saveCollection(id: first.id, name: "诗词与散文"), "rename collection")
        var reloaded = LibraryStore(directory: root)
        try require(reloaded.collections[0].name == "诗词与散文" && Set(reloaded.books[0].collectionIDs) == [first.id, second.id], "collection persistence")
        let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: indexURL))
        try require(snapshot.version == 1, "index migrated on write")
        results.append("PASS: plain-array library migrates; collections create, rename, validate and persist multiple memberships")

        let publication = try await reloaded.publication(for: imported)
        let positions = try await publication.positions().get()
        guard let locator = positions.first else { throw failure("fixture positions") }
        let locatorJSON = try locator.jsonString()
        let mark = ReaderMark(id: UUID(), kind: .highlight, locatorJSON: locatorJSON, chapter: "第一章 [月光]", excerpt: "江畔何人初见月？\n江月何年初照人。", note: "一条 *笔记*\n下一行 <内容>", color: .yellow, createdAt: Date())
        try reloaded.saveReaderMark(mark, for: imported.id)
        let legacyBookmark = ReaderMark(id: UUID(), kind: .bookmark, locatorJSON: locatorJSON, chapter: "旧书签", excerpt: "不应导出", note: "", color: .yellow, createdAt: Date())
        let md = ReaderAnnotationExporter.make(books: reloaded.books, marks: { _ in [legacyBookmark, mark] }, format: .markdown, date: Date())
        let txt = ReaderAnnotationExporter.make(books: reloaded.books, marks: reloaded.readerMarks, format: .text, date: Date())
        try require(md.markCount == 1 && md.bookCount == 1 && !md.text.contains("不应导出"), "export scope")
        try require(md.text.contains("> 江畔何人初见月？\n> 江月何年初照人。") && md.text.contains("\\*笔记\\*") && md.text.contains("\\[月光\\]"), "Markdown escaping and multiline")
        try require(txt.text.contains(mark.excerpt) && txt.text.contains(mark.note), "plain text preservation")
        var laterLocator = locator
        laterLocator.locations.position = (locator.locations.position ?? 1) + 10
        let later = ReaderMark(id: UUID(), kind: .highlight, locatorJSON: try laterLocator.jsonString(), chapter: "第二章", excerpt: "后面的段落", note: "", color: .blue, createdAt: mark.createdAt.addingTimeInterval(-60))
        let sorted = ReaderAnnotationExporter.make(books: reloaded.books, marks: { _ in [later, mark] }, format: .text, date: Date())
        try require(sorted.markCount == 2 && sorted.text.range(of: mark.excerpt)!.lowerBound < sorted.text.range(of: later.excerpt)!.lowerBound, "export follows reading order, not creation order")
        let document = AnnotationDocument(text: md.text)
        try require(!document.text.isEmpty && Data(document.text.utf8).count > document.text.count, "UTF8 export")
        results.append("PASS: Markdown / TXT export preserve Chinese multiline highlights and notes; legacy bookmarks excluded")

        reloaded.updateLocation(bookID: imported.id, locatorJSON: locatorJSON, position: 1, total: positions.count, progression: 0.42)
        reloaded.recordOpened(bookID: imported.id)
        reloaded.delete(imported)
        reloaded.delete(imported)
        try require(reloaded.books.isEmpty && reloaded.deletedBooks.count == 1 && manager.fileExists(atPath: fileURL.path), "soft delete keeps file and ignores repeat")
        reloaded = LibraryStore(directory: root)
        try require(reloaded.deletedBooks[0].locator.fraction == 0.42 && reloaded.readerMarks(for: imported.id).count == 1, "trash persistence")
        try require(reloaded.restore(imported), "restore")
        try require(reloaded.books[0].collectionIDs.count == 2 && reloaded.books[0].deletedAt == nil && reloaded.books[0].lastOpenedAt != nil, "restore metadata")
        try require(!reloaded.permanentlyDelete(imported), "active book purge guard")
        results.append("PASS: deletion preserves file, notes, memberships, reading history and latest progress; restore survives reload")

        reloaded.delete(imported)
        try require(reloaded.deleteCollection(second), "delete collection with trashed member")
        try require(reloaded.deletedBooks[0].collectionIDs == [first.id], "trash membership removed")
        try require(reloaded.restore(imported) && reloaded.books.count == 1, "collection deletion keeps books")
        results.append("PASS: deleting a collection keeps books and removes membership from recently deleted books too")

        reloaded.delete(imported)
        let staging = root.appendingPathComponent("PendingDeletion/\(imported.id.uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        try manager.moveItem(at: fileURL, to: staging.appendingPathComponent(imported.fileName))
        reloaded = LibraryStore(directory: root)
        try require(manager.fileExists(atPath: fileURL.path) && !manager.fileExists(atPath: staging.path), "interrupted purge recovery")
        let backup = try Data(contentsOf: indexURL)
        try manager.removeItem(at: indexURL)
        try manager.createDirectory(at: indexURL, withIntermediateDirectories: true)
        try require(!reloaded.permanentlyDelete(imported) && manager.fileExists(atPath: fileURL.path) && reloaded.deletedBooks.count == 1, "purge rollback when index write fails")
        try manager.removeItem(at: indexURL)
        try backup.write(to: indexURL, options: .atomic)
        reloaded.errorMessage = nil
        try require(reloaded.permanentlyDelete(imported), "permanent deletion")
        reloaded = LibraryStore(directory: root)
        try require(reloaded.books.isEmpty && reloaded.deletedBooks.isEmpty && !manager.fileExists(atPath: fileURL.path) && reloaded.readerMarks(for: imported.id).isEmpty, "permanent deletion persisted")
        // Simulate interruption after committing the deletion but before mark/file cleanup.
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("staged fixture".utf8).write(to: staging.appendingPathComponent(imported.fileName))
        try JSONEncoder().encode([imported.id.uuidString: [mark]]).write(to: marksURL, options: .atomic)
        reloaded = LibraryStore(directory: root)
        try require(!manager.fileExists(atPath: staging.path) && reloaded.readerMarks(for: imported.id).isEmpty, "post-commit cleanup recovery")
        results.append("PASS: interrupted permanent deletion recovers on either side of commit; failed index write rolls files back; purge removes files and marks")

        let corruptRoot = directory.appendingPathComponent("CorruptIndex", isDirectory: true)
        try manager.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        let corruptIndex = corruptRoot.appendingPathComponent("library.json")
        let invalid = Data("invalid JSON, keep me".utf8)
        try invalid.write(to: corruptIndex)
        let corruptStore = LibraryStore(directory: corruptRoot)
        try require(corruptStore.errorMessage != nil && !corruptStore.saveCollection(name: "新书单"), "corrupt index guard")
        try require(try Data(contentsOf: corruptIndex) == invalid, "corrupt index retained")
        results.append("PASS: corrupt index cannot be silently overwritten")
        return results
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        if try !condition() { throw failure(name) }
    }
    private static func failure(_ name: String) -> NSError { NSError(domain: "OrganizationRegression: \(name)", code: 1) }
}
#endif
