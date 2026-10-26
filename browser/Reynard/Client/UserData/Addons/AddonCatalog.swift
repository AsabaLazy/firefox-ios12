//
//  AddonCatalog.swift
//  Reynard
//
//  Created by Minh Ton on 20/10/26.
//

import Foundation

nonisolated enum AddonCatalog {
    static func resolve(
        id: String,
        engineVersion: String,
        cancellation: UserDataCancellation,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "addons.mozilla.org"
        components.path = "/api/v5/addons/addon/\(id)/"
        guard let url = components.url else {
            completion(.failure(AddonDataError.invalidFile))
            return
        }

        fetch(Detail.self, from: url, cancellation: cancellation) { result in
            switch result {
            case .failure(let error as AddonDataError):
                if case .catalogHTTP(404) = error {
                    completion(.failure(AddonDataError.catalog("The add-on is no longer available from Mozilla.")))
                } else {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            case .success(let detail):
                guard detail.guid == id, detail.type == "extension", !detail.isDisabled else {
                    completion(.failure(AddonDataError.catalog("Mozilla returned invalid add-on information.")))
                    return
                }

                if let version = detail.currentVersion, version.supports(engineVersion) {
                    do {
                        completion(.success(try downloadURL(for: version)))
                    } catch {
                        completion(.failure(error))
                    }
                    return
                }

                fetchVersionPages(url: url, engineVersion: engineVersion, cancellation: cancellation, completion: completion)
            }
        }
    }

    private static func fetchVersionPages(
        url: URL,
        engineVersion: String,
        cancellation: UserDataCancellation,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let versionsURL = url.appendingPathComponent("versions/")
        var visited = Set<URL>()
        var selected: Version?

        func fetchNext(_ pageURL: URL?) {
            guard let currentURL = pageURL else {
                if let selected {
                    do {
                        completion(.success(try downloadURL(for: selected)))
                    } catch {
                        completion(.failure(error))
                    }
                } else {
                    completion(.failure(AddonDataError.catalog("No public Firefox Mobile version of the add-on supports the current engine.")))
                }
                return
            }

            do {
                try cancellation.checkCancellation()
            } catch {
                completion(.failure(error))
                return
            }
            guard currentURL.scheme == "https",
                  currentURL.host == url.host,
                  currentURL.path == versionsURL.path,
                  visited.insert(currentURL).inserted else {
                completion(.failure(AddonDataError.catalog("Mozilla returned invalid add-on information.")))
                return
            }

            fetch(Page.self, from: currentURL, cancellation: cancellation) { result in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let page):
                    for version in page.results where version.supports(engineVersion) {
                        if let selected, AddonVersionOrder.compare(version.version, selected.version) <= 0 {
                            continue
                        }

                        selected = version
                    }

                    fetchNext(page.next)
                }
            }
        }

        fetchNext(versionsURL)
    }
    
    private static func downloadURL(for version: Version) throws -> URL {
        let location = version.file.url
        guard !location.contains("\0"),
              let url = URL(string: location),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              url.user == nil, url.password == nil else {
            throw AddonDataError.catalog("Mozilla returned invalid add-on information.")
        }
        
        return url
    }
    
    private static func fetch<Value: Decodable & Sendable>(
        _ type: Value.Type, from url: URL,
        cancellation: UserDataCancellation,
        completion: @escaping (Result<Value, Error>) -> Void
    ) {
        do {
            try cancellation.checkCancellation()
        } catch {
            completion(.failure(error))
            return
        }

        let request = AddonCatalogRequest()
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            let result: Result<Value, Error>
            do {
                if let error {
                    throw error
                } else if let response = response as? HTTPURLResponse, response.statusCode != 200 {
                    throw AddonDataError.catalogHTTP(response.statusCode)
                } else if let data, response is HTTPURLResponse {
                    try cancellation.checkCancellation()
                    result = .success(try JSONDecoder().decode(type, from: data))
                } else {
                    throw URLError(.badServerResponse)
                }
            } catch {
                result = .failure(error)
            }
            completion(result)
        }
        request.start(task)
    }
    
    private struct Detail: Decodable, Sendable {
        let guid: String
        let type: String
        let isDisabled: Bool
        let currentVersion: Version?
        
        enum CodingKeys: String, CodingKey {
            case guid, type
            case isDisabled = "is_disabled"
            case currentVersion = "current_version"
        }
    }
    
    private struct Page: Decodable, Sendable {
        let next: URL?
        let results: [Version]
    }
    
    private struct Version: Decodable, Sendable {
        struct Bounds: Decodable, Sendable {
            let min: String
            let max: String
        }
        
        struct File: Decodable, Sendable {
            let status: String
            let url: String
        }
        
        let version: String
        let compatibility: [String: Bounds]
        let isStrictCompatibilityEnabled: Bool
        let file: File
        
        enum CodingKeys: String, CodingKey {
            case version, compatibility, file
            case isStrictCompatibilityEnabled = "is_strict_compatibility_enabled"
        }
        
        func supports(_ engineVersion: String) -> Bool {
            guard file.status == "public",
                  compatibility["android"] != nil else {
                return false
            }
            
            for bounds in [compatibility["android"], compatibility["firefox"]].compactMap({ $0 }) {
                if AddonVersionOrder.compare(engineVersion, bounds.min) < 0 {
                    return false
                }
                
                if isStrictCompatibilityEnabled,
                   AddonVersionOrder.compare(engineVersion, bounds.max) > 0 {
                    return false
                }
            }
            
            return true
        }
    }
}

nonisolated private final class AddonCatalogRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var isCancelled = false
    
    func start(_ task: URLSessionDataTask) {
        lock.lock()
        self.task = task
        let cancelled = isCancelled
        lock.unlock()
        
        if cancelled {
            task.cancel()
        }
        task.resume()
    }
    
    func cancel() {
        lock.lock()
        isCancelled = true
        let task = task
        lock.unlock()
        
        task?.cancel()
    }
}
