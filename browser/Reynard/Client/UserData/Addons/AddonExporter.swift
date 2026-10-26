//
//  AddonExporter.swift
//  Reynard
//
//  Created by Minh Ton on 20/10/26.
//

import Darwin
import Foundation
import GeckoView

enum AddonExporter {
    static func exportAddons(
        to fileURL: URL,
        cancellation: UserDataCancellation,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        guard fileURL.isFileURL else {
            completion(.failure(CocoaError(.fileWriteUnsupportedScheme)))
            return
        }

        guard !fileURL.path.contains("\0") else {
            completion(.failure(CocoaError(.fileWriteInvalidFileName)))
            return
        }

        do {
            try cancellation.checkCancellation()
        } catch {
            completion(.failure(error))
            return
        }

        AddonRuntime.shared.list { result in
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            case .success(let addons):
                DispatchQueue.global(qos: .userInitiated).async {
                    let count: Int
                    do {
                        var records: [String: AddonDataRecord] = [:]
                        for addon in addons where !addon.isBuiltIn {
                            guard AddonDataFile.isValidID(addon.id) else {
                                throw AddonDataError.invalidFile
                            }

                            let metadata = addon.metaData
                            records[addon.id] = AddonDataRecord(
                                name: metadata.name,
                                version: metadata.version,
                                disabledFlags: Array(Set(metadata.disabledFlags)).sorted(),
                                settings: AddonDataSettings(
                                    enabled: metadata.enabled,
                                    allowedInPrivateBrowsing: metadata.allowedInPrivateBrowsing,
                                    grantedOptionalPermissions: Array(Set(metadata.grantedOptionalPermissions)).sorted(),
                                    grantedOptionalOrigins: Array(Set(metadata.grantedOptionalOrigins)).sorted(),
                                    grantedOptionalDataCollectionPermissions: Array(Set(metadata.grantedOptionalDataCollectionPermissions)).sorted()
                                )
                            )
                        }

                        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                        let metadata = AddonDataMetadata(
                            browserName: "Safari",
                            browserVersion: "Reynard \(version)",
                            dataType: "extensions",
                            exportTimeUsec: Int64((Date().timeIntervalSince1970 * 1_000_000).rounded()),
                            schemaVersion: 1
                        )
                        let document = AddonExportDocument(metadata: metadata, extensions: records)

                        let hasAccess = fileURL.startAccessingSecurityScopedResource()
                        defer {
                            if hasAccess {
                                fileURL.stopAccessingSecurityScopedResource()
                            }
                        }

                        try cancellation.checkCancellation()
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        let data = try encoder.encode(document)
                        let temporaryURL = fileURL.deletingLastPathComponent()
                            .appendingPathComponent(".\(UUID().uuidString).json")
                        defer {
                            try? FileManager.default.removeItem(at: temporaryURL)
                        }

                        try data.write(to: temporaryURL)
                        try cancellation.checkCancellation()
                        guard rename(temporaryURL.path, fileURL.path) == 0 else {
                            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                        }

                        count = document.extensions.count
                    } catch {
                        DispatchQueue.main.async {
                            completion(.failure(error))
                        }
                        return
                    }

                    DispatchQueue.main.async {
                        completion(.success(count))
                    }
                }
            }
        }
    }
}

nonisolated private struct AddonExportDocument: Encodable, Sendable {
    let metadata: AddonDataMetadata
    let extensions: [String: AddonDataRecord]
}
