//
//  BookmarkImporter.swift
//  Reynard
//
//  Created by Minh Ton on 20/10/26.
//

import Foundation

enum BookmarkImporter {
    static func importBookmarks(
        from fileURL: URL,
        cancellation: UserDataCancellation,
        completion: @escaping (Result<BookmarkImportReport, Error>) -> Void
    ) {
        guard fileURL.isFileURL else {
            completion(.failure(CocoaError(.fileReadUnsupportedScheme)))
            return
        }

        guard !fileURL.path.contains("\0") else {
            completion(.failure(CocoaError(.fileReadInvalidFileName)))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let document: BookmarkHTMLDocument
            do {
                let hasAccess = fileURL.startAccessingSecurityScopedResource()
                defer {
                    if hasAccess {
                        fileURL.stopAccessingSecurityScopedResource()
                    }
                }

                try cancellation.checkCancellation()
                document = try BookmarkHTMLParser.parse(fileURL: fileURL, cancellation: cancellation)
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }

            importBookmarks(document, cancellation: cancellation, completion: completion)
        }
    }

    static func importBookmarks(
        _ document: BookmarkHTMLDocument,
        cancellation: UserDataCancellation,
        completion: @escaping (Result<BookmarkImportReport, Error>) -> Void
    ) {
        let store = BookmarkStore.shared
        store.performBookmarkDataOperation({ database in
            let storage = BookmarkDataStorage(database: database)
            return try storage.importDocument(document, cancellation: cancellation)
        }) { result in
            switch result {
            case .success(let report):
                if report.importedBookmarkCount > 0 || report.importedFolderCount > 0 {
                    NotificationCenter.default.post(name: .bookmarkStoreDidChange, object: store)
                }
                DispatchQueue.main.async {
                    completion(.success(report))
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
}
