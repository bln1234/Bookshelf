import Foundation

enum ShelfLayout: String, CaseIterable, Identifiable {
    case list, grid
    var id: String { rawValue }
    var name: String { self == .list ? "列表" : "封面网格" }
    var symbol: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

enum ShelfFilter: String, CaseIterable, Identifiable {
    case all, reading, unread, finished, favorites
    var id: String { rawValue }
    var name: String {
        switch self {
        case .all: "全部书籍"
        case .reading: "正在读"
        case .unread: "未开始"
        case .finished: "已读完"
        case .favorites: "收藏"
        }
    }
    var symbol: String {
        switch self {
        case .all: "books.vertical"
        case .reading: "book"
        case .unread: "book.closed"
        case .finished: "checkmark.circle"
        case .favorites: "star"
        }
    }

    func includes(_ book: Book) -> Bool {
        switch self {
        case .all: true
        case .reading: book.hasStartedReading && !book.isFinished
        case .unread: !book.hasStartedReading && !book.isFinished
        case .finished: book.isFinished
        case .favorites: book.isFavorite
        }
    }
}

enum ShelfSort: String, CaseIterable, Identifiable {
    case recent, imported, title, author, progress
    var id: String { rawValue }
    var name: String {
        switch self {
        case .recent: "最近阅读"
        case .imported: "最近导入"
        case .title: "书名"
        case .author: "作者"
        case .progress: "阅读进度"
        }
    }
}

enum LibraryOrganization {
    static func books(_ books: [Book], query: String, filter: ShelfFilter, sort: ShelfSort) -> [Book] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return books.filter {
            filter.includes($0) && (query.isEmpty || $0.title.localizedStandardContains(query) || $0.author.localizedStandardContains(query))
        }.sorted { lhs, rhs in
            switch sort {
            case .recent:
                let left = lhs.lastOpenedAt ?? .distantPast
                let right = rhs.lastOpenedAt ?? .distantPast
                if left != right { return left > right }
            case .imported:
                if lhs.importedAt != rhs.importedAt { return lhs.importedAt > rhs.importedAt }
            case .title:
                let comparison = lhs.title.localizedStandardCompare(rhs.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case .author:
                let comparison = lhs.author.localizedStandardCompare(rhs.author)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case .progress:
                let left = lhs.isFinished ? 1 : lhs.locator.fraction
                let right = rhs.isFinished ? 1 : rhs.locator.fraction
                if left != right { return left > right }
            }
            if lhs.importedAt != rhs.importedAt { return lhs.importedAt > rhs.importedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
