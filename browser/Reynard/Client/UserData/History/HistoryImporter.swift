//
//  HistoryImporter.swift
//  Reynard
//
//  Created by Minh Ton on 20/10/26.
//

import Foundation

enum HistoryImporter {
    static func importHistory(
        from fileURL: URL,
        format: HistoryImportFormat,
        nearDuplicateToleranceSeconds: Int,
        decodeRecord: @escaping @Sendable (JSONDecoder, Data) throws -> HistoryImportRecord,
        cancellation: UserDataCancellation,
        completion: @escaping (Result<HistoryImportReport, Error>) -> Void
    ) {
        guard nearDuplicateToleranceSeconds >= 0 else {
            completion(.failure(HistoryDataError.invalidDeduplicationTolerance))
            return
        }

        let store = HistoryStore.shared
        let databaseURL: URL
        do {
            databaseURL = try HistoryDataStorage.databaseURL()
        } catch {
            completion(.failure(error))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let report: HistoryImportReport
            do {
                let hasAccess = fileURL.startAccessingSecurityScopedResource()
                defer {
                    if hasAccess {
                        fileURL.stopAccessingSecurityScopedResource()
                    }
                }

                try cancellation.checkCancellation()
                let stagedURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("History-\(UUID().uuidString).tmp")
                defer {
                    try? FileManager.default.removeItem(at: stagedURL)
                }

                let buffer = try HistoryImportBuffer(fileURL: stagedURL)
                let reader = try HistoryJSONReader(fileURL: fileURL, cancellation: cancellation)
                let decoder = JSONDecoder()
                var recordCount = 0
                var invalid = 0
                var discardedDetails = 0

                let detectedFormat = try reader.read { json, source in
                    guard source == format else {
                        throw HistoryDataError.unrecognizedFormat
                    }

                    let record: HistoryImportRecord
                    do {
                        record = try decodeRecord(decoder, json)
                    } catch is DecodingError {
                        invalid += 1
                        return
                    }

                    guard Int64(exactly: (record.timestamp * 1_000_000).rounded()) != nil else {
                        invalid += 1
                        return
                    }

                    if record.hasDiscardedDetails {
                        discardedDetails += 1
                    }

                    try buffer.append(record)
                    recordCount += 1
                }
                guard detectedFormat == format else {
                    throw HistoryDataError.unrecognizedFormat
                }

                try buffer.finish()

                var importResult: HistoryImportReport?
                var importError: Error?
                let group = DispatchGroup()
                group.enter()
                store.performHistoryImport({ [recordCount, invalid, discardedDetails] in
                    try cancellation.checkCancellation()
                    let storage = try HistoryDataStorage(databaseURL: databaseURL, cancellation: cancellation)
                    var committed = false
                    defer {
                        if !committed {
                            storage.rollbackImport()
                        }
                    }

                    try storage.beginImport()
                    var imported = 0
                    var duplicates = 0
                    try HistoryImportBuffer.enumerateRecords(from: stagedURL, cancellation: cancellation) { record in
                        if try storage.insert(record, toleranceSeconds: nearDuplicateToleranceSeconds) {
                            imported += 1
                        } else {
                            duplicates += 1
                        }
                    }

                    guard imported + duplicates == recordCount else {
                        throw CocoaError(.fileReadCorruptFile)
                    }

                    try storage.finishImport()
                    committed = true

                    return HistoryImportReport(
                        format: format,
                        importedRecordCount: imported,
                        duplicateRecordCount: duplicates,
                        invalidRecordCount: invalid,
                        recordsWithDiscardedDetails: discardedDetails
                    )
                }) { result in
                    switch result {
                    case .success(let report):
                        importResult = report
                    case .failure(let error):
                        importError = error
                    }
                    group.leave()
                }
                group.wait()
                if let importError {
                    throw importError
                }
                report = importResult!
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }

            if report.importedRecordCount > 0 {
                NotificationCenter.default.post(name: .historyStoreDidChange, object: store)
            }

            DispatchQueue.main.async {
                completion(.success(report))
            }
        }
    }
}
