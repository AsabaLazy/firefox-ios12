//
//  ImportPreferencesViewController.swift
//  Reynard
//
//  Created by Minh Ton on 22/10/26.
//

import MobileCoreServices
import UIKit
import UniformTypeIdentifiers

final class ImportPreferencesViewController: SettingsTableViewController {
    private enum Section: Equatable {
        case introduction
        case file
        case data
        case actions
    }
    
    private enum ActionRow: CaseIterable {
        case chooseFile
        case importData
    }
    
    private var selectedFileURL: URL?
    private var selectedFileSize: Int64?
    private var importTypes: [UserDataType] = []
    private var hasStartedImport = false
    private var isImporting = false
    private var importSummary = ImportDataSummary()
    
    private var displayedSections: [Section] {
        var sections: [Section] = [.introduction]
        if !importTypes.isEmpty {
            sections.append(.data)
        } else if !hasStartedImport, selectedFileURL != nil {
            sections.append(.file)
        }
        
        sections.append(.actions)
        return sections
    }
    
    init() {
        super.init(style: .appGrouped)
        title = NSLocalizedString("Import Browsing Data", comment: "")
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(ImportFileCell.self, forCellReuseIdentifier: ImportFileCell.reuseIdentifier)
    }
    
    override func numberOfSections(in tableView: UITableView) -> Int {
        return displayedSections.count
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard displayedSections.indices.contains(section) else {
            return 0
        }
        
        switch displayedSections[section] {
        case .introduction, .file:
            return 1
        case .data:
            return importTypes.count
        case .actions:
            return ActionRow.allCases.count
        }
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard displayedSections.indices.contains(indexPath.section) else {
            return UITableViewCell()
        }
        
        switch displayedSections[indexPath.section] {
        case .introduction:
            let cell = ImportExportIntroductionCell(style: .default, reuseIdentifier: nil)
            cell.configure(
                iconName: "reynard.iphone.and.arrow.right.inward",
                title: NSLocalizedString("Import Browsing Data", comment: ""),
                description: NSLocalizedString("Import your bookmarks, history, and other browser data into Reynard.", comment: "")
            )
            return cell
        case .file:
            guard let fileURL = selectedFileURL else {
                return UITableViewCell()
            }
            let cell = tableView.dequeueReusableCell(withIdentifier: ImportFileCell.reuseIdentifier, for: indexPath) as! ImportFileCell
            cell.configure(fileURL: fileURL, byteCount: selectedFileSize)
            return cell
        case .data:
            guard importTypes.indices.contains(indexPath.row) else {
                return UITableViewCell()
            }
            let type = importTypes[indexPath.row]
            let cell = SettingsTableViewCell(style: .subtitle, reuseIdentifier: nil)
            cell.textLabel?.text = ImportExportViewUtils.title(for: type)
            cell.detailTextLabel?.numberOfLines = 0
            cell.imageView?.image = UIImage(named: ImportExportViewUtils.iconName(for: type))
            cell.imageView?.tintColor = view.tintColor
            cell.selectionStyle = .none
            if isImporting {
                let spinner: UIActivityIndicatorView = {
                    if #available(iOS 13.0, *) {
                        return UIActivityIndicatorView(style: .medium)
                    } else {
                        let indicator = UIActivityIndicatorView(style: .gray)
                        indicator.color = .gray
                        return indicator
                    }
                }()
                spinner.startAnimating()
                cell.accessoryView = spinner
            } else {
                cell.detailTextLabel?.text = importSummary.subtitle(for: type)
            }
            return cell
        case .actions:
            guard ActionRow.allCases.indices.contains(indexPath.row) else {
                return UITableViewCell()
            }
            
            let row = ActionRow.allCases[indexPath.row]
            let title: String
            switch row {
            case .chooseFile:
                title = selectedFileURL == nil
                ? NSLocalizedString("Choose File…", comment: "")
                : NSLocalizedString("Choose Other…", comment: "For choosing other file for import")
            case .importData:
                title = NSLocalizedString("Import", comment: "")
            }
            
            let canImport = selectedFileURL != nil && !hasStartedImport
            let isEnabled = !isImporting && (row == .chooseFile || canImport)
            let cell = SettingsViewUtils.actionCell(title: title, tintColor: isEnabled ? view.tintColor : .appTertiaryLabel)
            cell.textLabel?.textAlignment = .center
            cell.isUserInteractionEnabled = isEnabled
            if !isEnabled {
                cell.accessibilityTraits.insert(.notEnabled)
            }
            return cell
        }
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        
        guard !isImporting else {
            return
        }
        guard displayedSections.indices.contains(indexPath.section),
              displayedSections[indexPath.section] == .actions,
              ActionRow.allCases.indices.contains(indexPath.row) else {
            return
        }
        
        switch ActionRow.allCases[indexPath.row] {
        case .chooseFile:
            chooseFile()
        case .importData:
            guard !hasStartedImport, let selectedFileURL else {
                return
            }
            
            isImporting = true
            importData(from: selectedFileURL)
        }
    }
    
    private func updateSections(_ changes: @escaping () -> Void, completion: (() -> Void)? = nil) {
        tableView.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            let previousSections = self.displayedSections
            let previousImportTypes = self.importTypes
            self.tableView.performBatchUpdates {
                changes()
                let updatedSections = self.displayedSections
                let deletedSections = previousSections.indices.filter { !updatedSections.contains(previousSections[$0]) }
                let insertedSections = updatedSections.indices.filter { !previousSections.contains(updatedSections[$0]) }
                self.tableView.deleteSections(IndexSet(deletedSections), with: .fade)
                self.tableView.insertSections(IndexSet(insertedSections), with: .fade)

                if previousSections.contains(.data),
                   let section = updatedSections.firstIndex(of: .data) {
                    let insertedRows = self.importTypes.enumerated().compactMap { index, type in
                        return previousImportTypes.contains(type) ? nil : IndexPath(row: index, section: section)
                    }
                    self.tableView.insertRows(at: insertedRows, with: .automatic)
                }
            } completion: { _ in
                self.tableView.reloadData()
                self.tableView.isUserInteractionEnabled = true
                completion?()
            }
        }
    }

    private func showImportType(_ type: UserDataType) {
        guard !importTypes.contains(type) else {
            return
        }

        updateSections {
            self.importTypes = UserDataType.allCases.filter { self.importTypes.contains($0) || $0 == type }
        }
    }

    private func importData(from fileURL: URL) {
        let cancellation = UserDataCancellation()
        ImportExportProgressAlert.run(
            from: self,
            message: NSLocalizedString("Importing in progress…", comment: "")
        ) { done in
            self.updateSections({
                self.hasStartedImport = true
            }) {
                UserDataImporter.importData(from: fileURL, onTypeDetected: { type in
                    self.showImportType(type)
                }, cancellation: cancellation) { result in
                    switch result {
                    case .success(let report):
                        var summary = ImportDataSummary()
                        for result in report.results {
                            summary.record(result)
                        }
                        done(.success(summary))
                    case .failure(let error):
                        done(.failure(error))
                    }
                }
            }
        } completion: { [weak self] result in
            guard let self else {
                return
            }

            let summary: ImportDataSummary
            let failureMessage: String?
            switch result {
            case .success(let imported):
                summary = imported
                failureMessage = summary.issues.isEmpty ? nil : summary.issues.joined(separator: "\n\n")
            case .failure(let error):
                summary = ImportDataSummary()
                failureMessage = error.localizedDescription
            }

            self.updateSections({
                self.importSummary = summary
                self.isImporting = false
            }) {
                if let failureMessage {
                    AlertPresenter.show(title: NSLocalizedString("Import Failed", comment: ""), message: failureMessage)
                } else {
                    AlertPresenter.show(
                        title: NSLocalizedString("Import Complete", comment: ""),
                        message: summary.hasImportedData
                        ? NSLocalizedString("Your data has been imported.", comment: "")
                        : NSLocalizedString("No data was imported.", comment: "")
                    )
                }
            }
        }
    }
    
    private func chooseFile() {
        let picker: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .html, .zip], asCopy: true)
        } else {
            picker = UIDocumentPickerViewController(
                documentTypes: [kUTTypeJSON as String, kUTTypeHTML as String, kUTTypeZipArchive as String],
                in: .import
            )
        }
        picker.delegate = self
        picker.allowsMultipleSelection = false
        if #available(iOS 13.0, *) {
            picker.shouldShowFileExtensions = true
        }
        present(picker, animated: true)
    }
}

extension ImportPreferencesViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !isImporting, let fileURL = urls.first else {
            return
        }
        
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        updateSections {
            self.selectedFileURL = fileURL
            self.selectedFileSize = size.map(Int64.init)
            self.importTypes = []
            self.hasStartedImport = false
            self.importSummary = ImportDataSummary()
        }
    }
}
