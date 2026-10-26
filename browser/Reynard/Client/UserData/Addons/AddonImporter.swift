//
//  AddonImporter.swift
//  Reynard
//
//  Created by Minh Ton on 20/10/26.
//

import Foundation
import GeckoView

enum AddonImporter {
    private static var isImporting = false
    private static var installingAddonID: String?
    private(set) static var importingAddonIDs = Set<String>()
    
    static func importAddons(
        from fileURL: URL,
        cancellation: UserDataCancellation,
        completion: @escaping (Result<AddonImportReport, Error>) -> Void
    ) {
        guard !isImporting else {
            completion(.failure(AddonDataError.operationInProgress))
            return
        }

        isImporting = true

        DispatchQueue.global(qos: .userInitiated).async {
            let document: AddonDataFile.Document
            do {
                document = try AddonDataFile.read(from: fileURL, cancellation: cancellation)
            } catch {
                isImporting = false
                importingAddonIDs.removeAll()
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }

            importingAddonIDs = Set(document.records.keys)

            do {
                try cancellation.checkCancellation()
            } catch {
                let report = AddonImportReport()
                finishImport(report: report, completion: completion)
                return
            }
            var report = AddonImportReport()
            report.issues = document.issues

            guard !document.records.isEmpty else {
                finishImport(report: report, completion: completion)
                return
            }

            let runtime = AddonRuntime.shared
            let engineVersion = GeckoRuntime.version
            runtime.list { result in
                switch result {
                case .failure(let error):
                    report.issues.append(AddonImportIssue(addonID: "", message: error.localizedDescription))
                    finishImport(report: report, completion: completion)
                case .success(let installed):
                    let records = document.records.sorted(by: { $0.key < $1.key })
                    importNext(
                        records: records, index: 0,
                        installed: installed, runtime: runtime,
                        engineVersion: engineVersion,
                        cancellation: cancellation, report: report,
                        completion: completion
                    )
                }
            }
        }
    }

    private static func finishImport(
        report: AddonImportReport,
        completion: @escaping (Result<AddonImportReport, Error>) -> Void
    ) {
        isImporting = false
        importingAddonIDs.removeAll()
        DispatchQueue.main.async {
            completion(.success(report))
        }
    }

    private static func importNext(
        records: [(key: String, value: AddonDataRecord)],
        index: Int,
        installed: [Addon],
        runtime: AddonRuntime,
        engineVersion: String,
        cancellation: UserDataCancellation,
        report: AddonImportReport,
        completion: @escaping (Result<AddonImportReport, Error>) -> Void
    ) {
        var report = report
        guard index < records.count else {
            finishImport(report: report, completion: completion)
            return
        }

        let (id, record) = records[index]
        let next = {
            importNext(
                records: records, index: index + 1,
                installed: installed, runtime: runtime,
                engineVersion: engineVersion,
                cancellation: cancellation, report: report,
                completion: completion
            )
        }

        do {
            try cancellation.checkCancellation()
        } catch {
            finishImport(report: report, completion: completion)
            return
        }

        resolveAddon(
            id: id, record: record,
            installed: installed, runtime: runtime,
            engineVersion: engineVersion, cancellation: cancellation
        ) { result in
            switch result {
            case .failure(let error):
                if error is UserDataCancelledError {
                    finishImport(report: report, completion: completion)
                } else {
                    report.issues.append(AddonImportIssue(addonID: id, message: error.localizedDescription))
                    next()
                }
            case .success(let addon):
                guard addon.id == id, !addon.isBuiltIn else {
                    report.issues.append(AddonImportIssue(addonID: id, message: "The package is built-in or has a different add-on ID. Its settings were not restored."))
                    next()
                    return
                }

                restore(record, on: addon, runtime: runtime, cancellation: cancellation) { issues in
                    var r = report
                    r.recordRestoration(
                        addonID: id, exportedVersion: record.version,
                        installedVersion: addon.metaData.version, issues: issues
                    )
                    report = r
                    next()
                }
            }
        }
    }

    private static func resolveAddon(
        id: String, record: AddonDataRecord,
        installed: [Addon], runtime: AddonRuntime,
        engineVersion: String, cancellation: UserDataCancellation,
        completion: @escaping (Result<Addon, Error>) -> Void
    ) {
        if let addon = installed.first(where: { $0.id == id }) {
            completion(.success(addon))
            return
        }

        AddonCatalog.resolve(id: id, engineVersion: engineVersion, cancellation: cancellation) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let downloadURL):
                do {
                    try cancellation.checkCancellation()
                } catch {
                    completion(.failure(error))
                    return
                }
                runtime.list { result in
                    switch result {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let installed):
                        if let addon = installed.first(where: { $0.id == id }) {
                            completion(.success(addon))
                            return
                        }
                        do {
                            try cancellation.checkCancellation()
                        } catch {
                            completion(.failure(error))
                            return
                        }
                        installingAddonID = id
                        runtime.install(url: downloadURL.absoluteString, installMethod: .manager) { result in
                            installingAddonID = nil
                            completion(result)
                        }
                    }
                }
            }
        }
    }
    
    static func installationResponse(for prompt: AddonPermissionPrompt) -> AddonPermissionPromptResponse? {
        guard prompt.kind == .install, prompt.addon.id == installingAddonID else {
            return nil
        }
        
        return AddonPermissionPromptResponse(allow: true)
    }
    
    private static func restore(
        _ record: AddonDataRecord, on addon: Addon,
        runtime: AddonRuntime, cancellation: UserDataCancellation,
        completion: @escaping ([String]) -> Void
    ) {
        var current = addon
        var issues: [String] = []

        func apply(
            _ label: String,
            operation: @escaping (Addon, @escaping (Result<Addon, Error>) -> Void) -> Void,
            then next: @escaping () -> Void
        ) {
            do {
                try cancellation.checkCancellation()
            } catch {
                issues.append("\(label): \(error.localizedDescription)")
                next()
                return
            }
            operation(current) { result in
                switch result {
                case .success(let updated):
                    current = updated
                case .failure(let error):
                    issues.append("\(label): \(error.localizedDescription)")
                }
                next()
            }
        }

        let settings = record.settings
        let flags = record.disabledFlags
        let userDisabled = flags?.contains("userDisabled") ?? settings?.enabled.map { !$0 }
        let appDisabled = flags?.contains("appDisabled")

        func stepUserDisable(_ next: @escaping () -> Void) {
            if userDisabled == true, !current.metaData.disabledFlags.contains("userDisabled") {
                apply("Disable add-on", operation: { runtime.disable($0, source: .user, completion: $1) }, then: next)
            } else {
                next()
            }
        }

        func stepAppDisable(_ next: @escaping () -> Void) {
            if appDisabled == true, !current.metaData.disabledFlags.contains("appDisabled") {
                apply("Disable add-on for the app", operation: { runtime.disable($0, source: .app, completion: $1) }, then: next)
            } else {
                next()
            }
        }

        func stepPrivateBrowsing(_ next: @escaping () -> Void) {
            if let allowed = settings?.allowedInPrivateBrowsing,
               allowed != current.metaData.allowedInPrivateBrowsing {
                if allowed && current.metaData.incognito == .notAllowed {
                    issues.append("This version does not allow private browsing access.")
                    next()
                } else {
                    apply("Private browsing access", operation: { runtime.setAllowedInPrivateBrowsing($0, allowed: allowed, completion: $1) }, then: next)
                }
            } else {
                next()
            }
        }

        func stepKinds(_ kinds: [PermissionKind], _ next: @escaping () -> Void) {
            guard let kind = kinds.first else {
                next()
                return
            }
            stepKind(kind) {
                stepKinds(Array(kinds.dropFirst()), next)
            }
        }

        func stepKind(_ kind: PermissionKind, _ next: @escaping () -> Void) {
            guard let saved = kind.saved(in: settings) else {
                next()
                return
            }

            let desired = Set(saved)
            let granted = Set(kind.granted(in: current.metaData))
            let toRevoke = granted.subtracting(desired).sorted().filter { value in
                if kind == .permission, value == "<all_urls>" {
                    return false
                }
                // Required permissions belong to the installed package and cannot be revoked here.
                if kind.required(in: current.metaData).contains(value) {
                    issues.append("This version requires \(kind.rawValue): \(value). It could not be revoked.")
                    return false
                }
                return true
            }
            let toGrant = desired.sorted().filter { value in
                if kind.granted(in: current.metaData).contains(value) ||
                    kind.required(in: current.metaData).contains(value) {
                    return false
                }
                // <all_urls> is also returned as an API permission when its origin is granted.
                if kind == .permission, value == "<all_urls>" {
                    return false
                }
                if kind != .origin, !kind.available(in: current.metaData).contains(value) {
                    issues.append("This version no longer offers optional \(kind.rawValue): \(value)")
                    return false
                }
                return true
            }

            func revokeNext(_ values: [String], _ done: @escaping () -> Void) {
                guard let value = values.first else {
                    done()
                    return
                }
                apply("Remove \(kind.rawValue): \(value)", operation: {
                    runtime.removeOptionalPermissions(kind.request(value), from: $0, completion: $1)
                }) {
                    revokeNext(Array(values.dropFirst()), done)
                }
            }

            func grantNext(_ values: [String], _ done: @escaping () -> Void) {
                guard let value = values.first else {
                    done()
                    return
                }
                apply("Grant \(kind.rawValue): \(value)", operation: {
                    runtime.addOptionalPermissions(kind.request(value), to: $0, completion: $1)
                }) {
                    grantNext(Array(values.dropFirst()), done)
                }
            }

            revokeNext(toRevoke) {
                grantNext(toGrant, next)
            }
        }

        func stepAppEnable(_ next: @escaping () -> Void) {
            if appDisabled == false, current.metaData.disabledFlags.contains("appDisabled") {
                apply("Enable add-on for the app", operation: { runtime.enable($0, source: .app, completion: $1) }, then: next)
            } else {
                next()
            }
        }

        func stepUserEnable(_ next: @escaping () -> Void) {
            if userDisabled == false, current.metaData.disabledFlags.contains("userDisabled") {
                apply("Enable add-on", operation: { runtime.enable($0, source: .user, completion: $1) }, then: next)
            } else {
                next()
            }
        }

        func finish() {
            if settings?.enabled == true, !current.metaData.enabled {
                issues.append("The add-on is still inactive: \(current.metaData.disabledFlags.joined(separator: ", ")).")
            }

            do {
                try cancellation.checkCancellation()
            } catch {
                issues.append("Cancelled: \(error.localizedDescription)")
            }
            completion(issues)
        }

        stepUserDisable {
            stepAppDisable {
                stepPrivateBrowsing {
                    stepKinds(PermissionKind.allCases) {
                        stepAppEnable {
                            stepUserEnable {
                                finish()
                            }
                        }
                    }
                }
            }
        }
    }
    
    private enum PermissionKind: String, CaseIterable {
        case permission
        case origin
        case dataCollection = "data collection permission"
        
        func saved(in settings: AddonDataSettings?) -> [String]? {
            switch self {
            case .permission:
                return settings?.grantedOptionalPermissions
            case .origin:
                if let origins = settings?.grantedOptionalOrigins {
                    return origins
                }
                
                return settings?.grantedOptionalPermissions?.contains("<all_urls>") == true ? ["<all_urls>"] : nil
            case .dataCollection:
                return settings?.grantedOptionalDataCollectionPermissions
            }
        }
        
        func granted(in metadata: AddonMetaData) -> [String] {
            switch self {
            case .permission:
                return metadata.grantedOptionalPermissions
            case .origin:
                return metadata.grantedOptionalOrigins
            case .dataCollection:
                return metadata.grantedOptionalDataCollectionPermissions
            }
        }
        
        func available(in metadata: AddonMetaData) -> [String] {
            switch self {
            case .permission:
                return metadata.optionalPermissions
            case .origin:
                return metadata.optionalOrigins
            case .dataCollection:
                return metadata.optionalDataCollectionPermissions
            }
        }
        
        func required(in metadata: AddonMetaData) -> [String] {
            switch self {
            case .permission:
                return metadata.requiredPermissions
            case .origin:
                return metadata.requiredOrigins
            case .dataCollection:
                return metadata.requiredDataCollectionPermissions
            }
        }
        
        func request(_ value: String) -> AddonPermissionChangeRequest {
            switch self {
            case .permission:
                return AddonPermissionChangeRequest(permissions: [value])
            case .origin:
                return AddonPermissionChangeRequest(origins: [value])
            case .dataCollection:
                return AddonPermissionChangeRequest(dataCollectionPermissions: [value])
            }
        }
    }
}
