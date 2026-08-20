import AppKit
import Foundation

enum WarmCorner: String, CaseIterable, Identifiable, Codable {
    case topLeft, topRight, bottomLeft, bottomRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }

    func contains(_ location: CGPoint, on screen: NSScreen, size: CGFloat) -> Bool {
        let frame = screen.frame
        let point: CGPoint = switch self {
        case .topLeft: CGPoint(x: frame.minX, y: frame.maxY)
        case .topRight: CGPoint(x: frame.maxX, y: frame.maxY)
        case .bottomLeft: CGPoint(x: frame.minX, y: frame.minY)
        case .bottomRight: CGPoint(x: frame.maxX, y: frame.minY)
        }
        return abs(location.x - point.x) <= size && abs(location.y - point.y) <= size
    }
}

struct WarmCornerAction: Codable, Equatable {
    var appPath: String?
    var delay: Double = 0.5

    private enum CodingKeys: String, CodingKey {
        case appPath, delay
    }

    init(appPath: String?, delay: Double = 0.5) {
        self.appPath = appPath
        self.delay = delay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appPath = try container.decodeIfPresent(String.self, forKey: .appPath)
        delay = try container.decodeIfPresent(Double.self, forKey: .delay) ?? 0.5
    }

    var isActive: Bool { appPath != nil }
    var appURL: URL? { appPath.map(URL.init(fileURLWithPath:)) }
    var appName: String? {
        guard let appPath else { return nil }
        return FileManager.default.displayName(atPath: appPath)
            .replacingOccurrences(of: ".app", with: "")
    }
}
