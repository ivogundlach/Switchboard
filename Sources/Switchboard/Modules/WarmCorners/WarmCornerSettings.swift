import Foundation
import Observation

@MainActor
@Observable
final class WarmCornerSettings {
    private static let storeKey = "switchboard.warm-corners.config"
    private let defaults: UserDefaults

    private var store: WarmCornerSettingsPayload {
        didSet { save() }
    }
    var onPauseChanged: ((Bool) -> Void)?

    convenience init() {
        self.init(defaults: .standard)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storeKey),
           let decoded = WarmCornerSettingsCodec.decode(data) {
            store = decoded
        } else {
            store = WarmCornerSettingsPayload()
        }
    }

    var hasAnyCornerSet: Bool {
        WarmCorner.allCases.contains { action(for: $0).isActive }
    }

    var hasStoredConfiguration: Bool {
        defaults.data(forKey: Self.storeKey) != nil
    }

    func encodedData() -> Data? {
        try? JSONEncoder().encode(store)
    }

    func applyImportedPayload(_ payload: WarmCornerSettingsPayload) {
        store = payload
    }

    func clearStoredConfiguration() {
        store = WarmCornerSettingsPayload()
        defaults.removeObject(forKey: Self.storeKey)
    }

    func action(for corner: WarmCorner) -> WarmCornerAction {
        store.actions[corner.rawValue] ?? WarmCornerAction(appPath: nil)
    }

    func setAction(_ action: WarmCornerAction, for corner: WarmCorner) {
        store.actions[corner.rawValue] = action
    }

    var showIndicator: Bool {
        get { store.showIndicator }
        set { store.showIndicator = newValue }
    }

    var isPaused: Bool {
        get { store.isPaused }
        set {
            store.isPaused = newValue
            onPauseChanged?(newValue)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        defaults.set(data, forKey: Self.storeKey)
    }
}

struct WarmCornerSettingsPayload: Codable, Equatable {
    var actions: [String: WarmCornerAction] = [:]
    var showIndicator = true
    var isPaused = false

    private enum CodingKeys: String, CodingKey {
        case actions, showIndicator, isPaused
    }

    init(
        actions: [String: WarmCornerAction] = [:],
        showIndicator: Bool = true,
        isPaused: Bool = false
    ) {
        self.actions = actions
        self.showIndicator = showIndicator
        self.isPaused = isPaused
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        actions = try container.decodeIfPresent([String: WarmCornerAction].self, forKey: .actions) ?? [:]
        showIndicator = try container.decodeIfPresent(Bool.self, forKey: .showIndicator) ?? true
        isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
    }
}

enum WarmCornerSettingsCodec {
    enum Source: Equatable {
        case current
        case legacy
        case defaults
    }

    static func decode(_ data: Data) -> WarmCornerSettingsPayload? {
        try? JSONDecoder().decode(WarmCornerSettingsPayload.self, from: data)
    }

    static func select(currentData: Data?, legacyData: Data?) -> (WarmCornerSettingsPayload, Source) {
        if let currentData, let current = decode(currentData) {
            return (current, .current)
        }
        if let legacyData, let legacy = decode(legacyData) {
            return (legacy, .legacy)
        }
        return (WarmCornerSettingsPayload(), .defaults)
    }
}
