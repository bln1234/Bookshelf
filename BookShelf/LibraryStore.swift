import Foundation
import SwiftUI
import Combine
import ReadiumShared

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var books: [Book] = []
    @Published private(set) var deletedBooks: [Book] = []
    @Published private(set) var collections: [BookCollection] = []
    @Published private(set) var marksRevision = 0
    @Published var isImporting = false
    @Published var errorMessage: String?
    @Published private(set) var importProgress: BookImportProgress?

    private let parser = EPUBParser()
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var marksByBook: [String: [ReaderMark]] = [:]
    private let storageDirectory: URL
    private var indexSaveTask: Task<Void, Never>?
    private var indexLoadFailed = false
    private var marksLoadFailed = false

    init(directory: URL? = nil) {
        storageDirectory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BookShelf", isDirectory: true)
        if directory == nil { removeLegacyKokoroData() }
        loadIndex()
        loadMarks()
        recoverPendingDeletions()
    }

    func importBook(from sourceURL: URL) async -> Book? {
        let report = await importBooks(from: [sourceURL])
        if let failure = report.failures.first { errorMessage = failure.message }
        return report.imported.first
    }

    func importBooks(from urls: [URL]) async -> BookImportReport {
        guard !isImporting else {
            return BookImportReport(imported: [], failures: urls.map {
                .init(fileName: $0.lastPathComponent, message: "另一批书籍仍在导入，请稍后重试。")
            })
        }
        isImporting = true
        defer { isImporting = false; importProgress = nil }
        var report = BookImportReport(imported: [], failures: [])
        for (index, url) in urls.enumerated() {
            importProgress = .init(completed: index, total: urls.count, fileName: url.lastPathComponent)
            await Task.yield()
            do { report.imported.append(try await importOne(from: url)) }
            catch { report.failures.append(.init(fileName: url.lastPathComponent, message: importErrorMessage(error))) }
        }
        return report
    }

    private func importErrorMessage(_ error: Error) -> String {
        if let epubError = error as? EPUBError, case .openFailed = epubError {
            return "无法解析书籍内容，请确认文件完整，或尝试其他版本后重新导入。"
        }
        return error.localizedDescription
    }

    private func importOne(from sourceURL: URL) async throws -> Book {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let destination = booksDirectory.appendingPathComponent("\(id.uuidString).epub")
        let coverDestination = coversDirectory.appendingPathComponent("\(id.uuidString).cover")
        do {
            try ensureDirectories()
            switch sourceURL.pathExtension.lowercased() {
            case "epub":
                try fileManager.copyItem(at: sourceURL, to: destination)
            case "txt":
                try await TXTImporter.convert(
                    sourceURL,
                    to: destination,
                    title: sourceURL.deletingPathExtension().lastPathComponent
                )
            default:
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            let document = try await parser.parse(url: destination)
            var coverName: String?
            if let cover = document.cover {
                let name = "\(id.uuidString).cover"
                try cover.write(to: coverDestination, options: .atomic)
                coverName = name
            }
            var title = document.title
            var author = document.author
            let fallback = sourceURL.deletingPathExtension().lastPathComponent
            if title.isEmpty || title == "未命名书籍" { title = fallback.components(separatedBy: "(").first?.trimmingCharacters(in: .whitespaces) ?? fallback }
            if author == "未知作者", let open = fallback.firstIndex(of: "("), let close = fallback[open...].firstIndex(of: ")") {
                let candidate = fallback[fallback.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty { author = candidate }
            }
            let book = Book(id: id, title: title, author: author, fileName: destination.lastPathComponent,
                            coverFileName: coverName, importedAt: Date(), locator: ReaderLocator(),
                            sourceFormat: sourceURL.pathExtension.uppercased())
            let updated = [book] + books
            try writeIndex(updated)
            books = updated
            return book
        } catch {
            try? fileManager.removeItem(at: destination)
            try? fileManager.removeItem(at: coverDestination)
            throw error
        }
    }

    func publication(for book: Book) async throws -> Publication {
        try await parser.openPublication(url: booksDirectory.appendingPathComponent(book.fileName))
    }

    func coverURL(for book: Book) -> URL? {
        guard let name = book.coverFileName else { return nil }
        let url = coversDirectory.appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func updateProgress(bookID: UUID, page: Int, total: Int) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].locator = ReaderLocator(page: page, totalPages: total)
        scheduleIndexSave()
    }

    func updateLocation(bookID: UUID, locatorJSON: String?, position: Int, total: Int, progression: Double? = nil) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        let location = ReaderLocator(page: max(0, position - 1), totalPages: total, locatorJSON: locatorJSON, progression: progression)
        guard books[index].locator != location else { return }
        books[index].locator = location
        scheduleIndexSave()
    }

    func recordOpened(bookID: UUID) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].lastOpenedAt = Date()
        scheduleIndexSave()
    }

    func toggleFavorite(_ book: Book) {
        updateBook(book.id) { $0.isFavorite.toggle() }
    }

    func toggleFinished(_ book: Book) {
        updateBook(book.id) { $0.isFinished.toggle() }
    }

    @discardableResult
    func editBook(bookID: UUID, title: String, author: String, isFavorite: Bool? = nil, isFinished: Bool? = nil) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        let author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        return updateBook(bookID) {
            $0.title = title
            $0.author = author.isEmpty ? "未知作者" : author
            if let isFavorite { $0.isFavorite = isFavorite }
            if let isFinished { $0.isFinished = isFinished }
        }
    }

    func fileSize(for book: Book) -> Int64? {
        (try? fileManager.attributesOfItem(atPath: booksDirectory.appendingPathComponent(book.fileName).path)[.size] as? NSNumber)?.int64Value
    }

    @discardableResult
    private func updateBook(_ id: UUID, edit: (inout Book) -> Void) -> Bool {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return false }
        var updated = books
        edit(&updated[index])
        do { try writeIndex(updated); books = updated; return true }
        catch { errorMessage = "无法保存书籍信息：\(error.localizedDescription)"; return false }
    }

    func flushPendingChanges() {
        guard indexSaveTask != nil else { return }
        saveIndex()
    }

    private func scheduleIndexSave() {
        indexSaveTask?.cancel()
        indexSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(750)) }
            catch { return }
            self?.saveIndex()
        }
    }

    func readerMarks(for bookID: UUID) -> [ReaderMark] {
        (marksByBook[bookID.uuidString] ?? []).filter { $0.kind == .highlight }
    }

    func saveReaderMark(_ mark: ReaderMark, for bookID: UUID) throws {
        guard books.contains(where: { $0.id == bookID }) else { throw CocoaError(.fileNoSuchFile) }
        var updated = marksByBook
        var marks = updated[bookID.uuidString] ?? []
        if let index = marks.firstIndex(where: { $0.id == mark.id }) {
            marks[index] = mark
        } else {
            marks.append(mark)
        }
        updated[bookID.uuidString] = marks
        try saveMarks(updated)
        marksByBook = updated
        marksRevision += 1
    }

    func removeReaderMark(id: UUID, for bookID: UUID) throws {
        var updated = marksByBook
        updated[bookID.uuidString]?.removeAll { $0.id == id }
        if updated[bookID.uuidString]?.isEmpty == true { updated.removeValue(forKey: bookID.uuidString) }
        try saveMarks(updated)
        marksByBook = updated
        marksRevision += 1
    }

    func delete(_ book: Book) {
        guard var current = books.first(where: { $0.id == book.id }) else { return }
        current.deletedAt = Date()
        let active = books.filter { $0.id != book.id }
        let trash = [current] + deletedBooks
        do {
            try writeIndex(active, deletedBooks: trash)
            books = active
            deletedBooks = trash
        } catch { errorMessage = "无法移到最近删除：\(error.localizedDescription)" }
    }

    @discardableResult
    func restore(_ book: Book) -> Bool {
        guard var current = deletedBooks.first(where: { $0.id == book.id }) else { return false }
        guard fileManager.fileExists(atPath: booksDirectory.appendingPathComponent(current.fileName).path) else {
            errorMessage = "书籍文件已不存在，无法恢复。"
            return false
        }
        current.deletedAt = nil
        let active = books + [current]
        let trash = deletedBooks.filter { $0.id != book.id }
        do {
            try writeIndex(active, deletedBooks: trash)
            books = active
            deletedBooks = trash
            return true
        } catch { errorMessage = "无法恢复书籍：\(error.localizedDescription)"; return false }
    }

    /// Stage files before committing the index, so an interrupted deletion can be recovered.
    @discardableResult
    func permanentlyDelete(_ book: Book) -> Bool {
        guard let current = deletedBooks.first(where: { $0.id == book.id }) else { return false }
        guard !indexLoadFailed, !marksLoadFailed else {
            errorMessage = "书架或笔记未能完整读取，暂不能永久删除，以免丢失数据。"
            return false
        }
        let staging = pendingDeletionDirectory.appendingPathComponent(book.id.uuidString, isDirectory: true)
        var moved: [(URL, URL)] = []
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            for source in fileURLs(for: current) where fileManager.fileExists(atPath: source.path) {
                let destination = staging.appendingPathComponent(source.lastPathComponent)
                try fileManager.moveItem(at: source, to: destination)
                moved.append((source, destination))
            }
            let trash = deletedBooks.filter { $0.id != book.id }
            try writeIndex(books, deletedBooks: trash)
            deletedBooks = trash
        } catch {
            for (source, destination) in moved.reversed() { try? fileManager.moveItem(at: destination, to: source) }
            errorMessage = "无法永久删除：\(error.localizedDescription)"
            return false
        }
        do {
            try removeMarksForDeletedBook(book.id)
            try fileManager.removeItem(at: staging)
        } catch { errorMessage = "书籍已删除，残留文件将在下次启动时清理：\(error.localizedDescription)" }
        return true
    }

    private func fileURLs(for book: Book) -> [URL] {
        [booksDirectory.appendingPathComponent(book.fileName)] + (book.coverFileName.map { [coversDirectory.appendingPathComponent($0)] } ?? [])
    }

    private func removeMarksForDeletedBook(_ id: UUID) throws {
        var updated = marksByBook
        updated.removeValue(forKey: id.uuidString)
        try saveMarks(updated)
        marksByBook = updated
        marksRevision += 1
    }

    private func recoverPendingDeletions() {
        guard !indexLoadFailed, !marksLoadFailed,
              let directories = try? fileManager.contentsOfDirectory(at: pendingDeletionDirectory, includingPropertiesForKeys: nil) else { return }
        for directory in directories {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            do {
                if let book = (books + deletedBooks).first(where: { $0.id == id }) {
                    for destination in fileURLs(for: book) {
                        let source = directory.appendingPathComponent(destination.lastPathComponent)
                        if fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: destination.path) {
                            try fileManager.moveItem(at: source, to: destination)
                        }
                    }
                } else { try removeMarksForDeletedBook(id) }
                try fileManager.removeItem(at: directory)
            } catch { errorMessage = "无法恢复删除操作：\(error.localizedDescription)" }
        }
    }

    @discardableResult
    func saveCollection(id: UUID? = nil, name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { errorMessage = "书单名称不能为空。"; return false }
        guard !collections.contains(where: { $0.id != id && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
            errorMessage = "已有同名书单，请换一个名称。"; return false
        }
        var updated = collections
        if let id {
            guard let index = updated.firstIndex(where: { $0.id == id }) else { return false }
            updated[index].name = name
        } else { updated.append(.init(id: UUID(), name: name, createdAt: Date())) }
        do { try writeIndex(books, collections: updated); collections = updated; return true }
        catch { errorMessage = "无法保存书单：\(error.localizedDescription)"; return false }
    }

    @discardableResult
    func deleteCollection(_ collection: BookCollection) -> Bool {
        let updated = collections.filter { $0.id != collection.id }
        let active = books.map { book in var book = book; book.collectionIDs.removeAll { $0 == collection.id }; return book }
        let trash = deletedBooks.map { book in var book = book; book.collectionIDs.removeAll { $0 == collection.id }; return book }
        do {
            try writeIndex(active, deletedBooks: trash, collections: updated)
            books = active; deletedBooks = trash; collections = updated
            return true
        } catch { errorMessage = "无法删除书单：\(error.localizedDescription)"; return false }
    }

    @discardableResult
    func setCollections(_ ids: Set<UUID>, for bookID: UUID) -> Bool {
        let valid = collections.filter { ids.contains($0.id) }.map(\.id)
        return updateBook(bookID) { $0.collectionIDs = valid }
    }

    private var applicationSupport: URL {
        storageDirectory
    }
    private var booksDirectory: URL { applicationSupport.appendingPathComponent("Books", isDirectory: true) }
    private var coversDirectory: URL { applicationSupport.appendingPathComponent("Covers", isDirectory: true) }
    private var indexURL: URL { applicationSupport.appendingPathComponent("library.json") }
    private var marksURL: URL { applicationSupport.appendingPathComponent("reader-marks.json") }
    private var pendingDeletionDirectory: URL { applicationSupport.appendingPathComponent("PendingDeletion", isDirectory: true) }

    /// Kokoro was removed from the app. Clear its large downloaded model and
    /// obsolete preferences once the updated app is launched.
    private func removeLegacyKokoroData() {
        let modelDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kokoro-v1.1-int8", isDirectory: true)
        if fileManager.fileExists(atPath: modelDirectory.path) {
            try? fileManager.removeItem(at: modelDirectory)
        }
        let defaults = UserDefaults.standard
        ["speech.engine", "speech.kokoroVoice", "speech.kokoroSpeed"].forEach(defaults.removeObject(forKey:))
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
    }
    private func loadIndex() {
        guard fileManager.fileExists(atPath: indexURL.path) else { return }
        do {
            let data = try Data(contentsOf: indexURL)
            let saved: [Book]
            if let snapshot = try? decoder.decode(LibrarySnapshot.self, from: data) {
                guard snapshot.version == 1 else { throw CocoaError(.coderReadCorrupt) }
                saved = snapshot.books
                collections = snapshot.collections
            } else { saved = try decoder.decode([Book].self, from: data) }
            books = saved.filter { $0.deletedAt == nil }.sorted { $0.importedAt > $1.importedAt }
            deletedBooks = saved.filter { $0.deletedAt != nil }.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        } catch {
            indexLoadFailed = true
            errorMessage = "无法读取书架，已保留原始文件以免覆盖：\(error.localizedDescription)"
        }
    }

    private func loadMarks() {
        guard fileManager.fileExists(atPath: marksURL.path) else { return }
        do {
            let data = try Data(contentsOf: marksURL)
            if let marks = try? decoder.decode([String: [ReaderMark]].self, from: data) {
                marksByBook = marks
            } else {
                let legacy = try decoder.decode([UUID: [ReaderMark]].self, from: data)
                marksByBook = Dictionary(uniqueKeysWithValues: legacy.map { ($0.key.uuidString, $0.value) })
            }
        } catch { marksLoadFailed = true; errorMessage = "无法读取划线与笔记：\(error.localizedDescription)" }
    }

    private func saveMarks(_ marks: [String: [ReaderMark]]) throws {
        guard !marksLoadFailed else { throw CocoaError(.fileReadCorruptFile) }
        try ensureDirectories()
        try encoder.encode(marks).write(to: marksURL, options: .atomic)
    }
    private func saveIndex() {
        do { try writeIndex(books) }
        catch { errorMessage = "无法保存书架：\(error.localizedDescription)" }
    }

    private func writeIndex(_ books: [Book], deletedBooks: [Book]? = nil, collections: [BookCollection]? = nil) throws {
        guard !indexLoadFailed else { throw CocoaError(.fileReadCorruptFile) }
        try ensureDirectories()
        let snapshot = LibrarySnapshot(books: books + (deletedBooks ?? self.deletedBooks), collections: collections ?? self.collections)
        try encoder.encode(snapshot).write(to: indexURL, options: .atomic)
        indexSaveTask?.cancel()
        indexSaveTask = nil
    }
}

struct BookImportProgress {
    let completed: Int
    let total: Int
    let fileName: String
}

struct BookImportReport: Identifiable {
    struct Failure: Identifiable {
        let id = UUID()
        let fileName: String
        let message: String
    }
    let id = UUID()
    var imported: [Book]
    var failures: [Failure]
}
