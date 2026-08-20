import AppKit
import SwiftUI

@MainActor
final class WarmCornerIndicator {
    private let panel: NSPanel

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    func show(corner: WarmCorner, screen: NSScreen, duration: Double) {
        guard duration > 0 else {
            hide()
            return
        }
        let size = CGSize(width: 64, height: 64)
        let origin = Self.origin(corner: corner, screenFrame: screen.frame, size: size)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.contentView = NSHostingView(rootView: WarmCornerCountdownView(start: Date(), duration: duration))
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        panel.contentView = nil
    }

    static func origin(corner: WarmCorner, screenFrame: CGRect, size: CGSize, inset: CGFloat = 18) -> CGPoint {
        switch corner {
        case .topLeft:
            CGPoint(x: screenFrame.minX + inset, y: screenFrame.maxY - size.height - inset)
        case .topRight:
            CGPoint(x: screenFrame.maxX - size.width - inset, y: screenFrame.maxY - size.height - inset)
        case .bottomLeft:
            CGPoint(x: screenFrame.minX + inset, y: screenFrame.minY + inset)
        case .bottomRight:
            CGPoint(x: screenFrame.maxX - size.width - inset, y: screenFrame.minY + inset)
        }
    }
}

private struct WarmCornerCountdownView: View {
    let start: Date
    let duration: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let elapsed = context.date.timeIntervalSince(start)
            let progress = min(1, max(0, elapsed / duration))
            ZStack {
                Circle().fill(.black.opacity(0.66))
                Circle().stroke(.white.opacity(0.18), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        AngularGradient(colors: [.cyan, .blue], center: .center),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Image(systemName: "arrow.up.forward.app.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(6)
        }
        .frame(width: 64, height: 64)
    }
}
