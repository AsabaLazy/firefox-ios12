//
//  UserDataCancellation.swift
//  Reynard
//
//  Created by Minh Ton on 23/10/26.
//

import Foundation

// iOS 12 has no Swift Concurrency (and no CancellationError): cancellation
// surfaces as this plain error instead.
struct UserDataCancelledError: Error {}

nonisolated final class UserDataCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    
    var isCancelled: Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        
        return cancelled
    }
    
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
    
    func checkCancellation() throws {
        if isCancelled {
            throw UserDataCancelledError()
        }
    }
}
