//
//  UserDataExporter.swift
//  Reynard
//
//  Created by Minh Ton on 21/10/26.
//

import Darwin
import Foundation
import ZIPFoundation

enum UserDataExporter {
    static func exportData(
        to fileURL: URL, types: Set<UserDataType> = Set(UserDataType.allCases),
        cancellation: UserDataCancellation,
        completion: @escaping (Result<UserDataExportReport, Error>) -> Void
    ) {
        guard fileURL.isFileURL else {
            completion(.failure(CocoaError(.fileWriteUnsupportedScheme)))
            return
        }

        guard !fileURL.path.contains("\0") else {
            completion(.failure(CocoaError(.fileWriteInvalidFileName)))
            return
        }

        let selectedTypes = UserDataType.allCases.filter { types.contains($0) }
        let fileExtension = fileURL.pathExtension.lowercased()
        let isArchive = fileExtension == "zip"
        guard !selectedTypes.isEmpty else {
            completion(.failure(UserDataError.invalidExportSelection))
            return
        }

        switch fileExtension {
        case "zip":
            break
        case "html" where types == [.bookmarks]:
            break
        case "json" where types == [.history] || types == [.extensions]:
            break
        default:
            completion(.failure(UserDataError.invalidExportSelection))
            return
        }

        let destinationURL = isArchive
        ? fileURL.deletingLastPathComponent().appendingPathComponent(archiveFileName)
        : fileURL

        DispatchQueue.global(qos: .userInitiated).async {
            let hasAccess = fileURL.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("UserData-\(UUID().uuidString)", isDirectory: true)
            if isArchive {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                } catch {
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                    return
                }
            }
            defer {
                if isArchive {
                    try? FileManager.default.removeItem(at: directory)
                }
            }

            let report = UserDataExportReport(fileURL: destinationURL)
            exportNext(
                selectedTypes, index: 0, isArchive: isArchive,
                directory: directory, destinationURL: destinationURL,
                cancellation: cancellation, report: report,
                completion: completion
            )
        }
    }

    private static func exportNext(
        _ types: [UserDataType], index: Int,
        isArchive: Bool, directory: URL, destinationURL: URL,
        cancellation: UserDataCancellation,
        report: UserDataExportReport,
        completion: @escaping (Result<UserDataExportReport, Error>) -> Void
    ) {
        var report = report
        guard index < types.count else {
            if isArchive {
                writeArchive(from: directory, types: types, to: destinationURL, cancellation: cancellation) { result in
                    switch result {
                    case .success:
                        DispatchQueue.main.async {
                            completion(.success(report))
                        }
                    case .failure(let error):
                        DispatchQueue.main.async {
                            completion(.failure(error))
                        }
                    }
                }
            } else {
                DispatchQueue.main.async {
                    completion(.success(report))
                }
            }
            return
        }

        let type = types[index]
        do {
            try cancellation.checkCancellation()
        } catch {
            DispatchQueue.main.async {
                completion(.failure(error))
            }
            return
        }

        let destination = isArchive ? directory.appendingPathComponent(type.fileName) : destinationURL
        let recordCount: (Int) -> Void = { count in
            report.recordCounts[type] = count
            exportNext(
                types, index: index + 1,
                isArchive: isArchive, directory: directory, destinationURL: destinationURL,
                cancellation: cancellation, report: report,
                completion: completion
            )
        }

        switch type {
        case .bookmarks:
            BookmarkExporter.exportBookmarks(to: destination, cancellation: cancellation) { result in
                switch result {
                case .success(let count):
                    recordCount(count)
                case .failure(let error):
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                }
            }
        case .history:
            SafariHistoryExporter.exportHistory(to: destination, cancellation: cancellation) { result in
                switch result {
                case .success(let count):
                    recordCount(count)
                case .failure(let error):
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                }
            }
        case .extensions:
            AddonExporter.exportAddons(to: destination, cancellation: cancellation) { result in
                switch result {
                case .success(let count):
                    recordCount(count)
                case .failure(let error):
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    static var archiveFileName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return "Reynard Export \(formatter.string(from: Date())).zip"
    }
    
    private static func writeArchive(
        from directory: URL, types: [UserDataType], to fileURL: URL,
        cancellation: UserDataCancellation,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let progress = Progress(totalUnitCount: 0)
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var result: Result<Void, Error> = .success(())

            coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinationError) { destination in
                result = Result {
                    try cancellation.checkCancellation()
                    let temporaryURL = destination.deletingLastPathComponent()
                        .appendingPathComponent(".\(UUID().uuidString).zip")
                    defer {
                        try? FileManager.default.removeItem(at: temporaryURL)
                    }

                    do {
                        let archive = try Archive(url: temporaryURL, accessMode: .create)
                        for type in types {
                            try cancellation.checkCancellation()
                            try archive.addEntry(
                                with: type.fileName, relativeTo: directory,
                                compressionMethod: .deflate, progress: progress
                            )
                        }
                    }

                    try cancellation.checkCancellation()
                    guard rename(temporaryURL.path, destination.path) == 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                }
            }

            if let coordinationError {
                DispatchQueue.main.async {
                    completion(.failure(coordinationError))
                }
                return
            }

            switch result {
            case .success:
                DispatchQueue.main.async {
                    completion(.success(()))
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
}
