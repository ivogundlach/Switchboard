import Foundation
import Observation

enum ManagedOperation: String, Equatable {
    case update
    case migration
    case restore
    case moduleTransition
    case privilegedHelperChange
}

@MainActor
@Observable
final class OperationCoordinator {
    private(set) var activeOperation: ManagedOperation?

    func perform<T>(
        _ operation: ManagedOperation,
        body: () async throws -> T
    ) async throws -> T {
        guard activeOperation == nil else {
            throw OperationCoordinatorError.busy(activeOperation!)
        }
        activeOperation = operation
        defer { activeOperation = nil }
        return try await body()
    }
}

enum OperationCoordinatorError: LocalizedError {
    case busy(ManagedOperation)

    var errorDescription: String? {
        switch self {
        case .busy(let operation):
            "Switchboard is already performing \(operation.rawValue)."
        }
    }
}
