import AppKit
import SwiftUI

/// The menu-bar glyph: the app icon's seven-blade iris, drawn at any opening, so the aperture is
/// open while the camera streams and closed while it is off. Template images, so the menu bar tints
/// them for light, dark and highlighted menu bars.
enum MenuBarSymbol {
    enum Badge: Equatable {
        case none, ellipsis, exclamation
    }

    struct Glyph: Equatable {
        /// 0 = closed, 1 = fully open.
        var opening: CGFloat
        /// A dot in the opening: the picture is going out to other apps.
        var lit: Bool
        var badge: Badge
    }

    private static let canvas = NSSize(width: 18, height: 18)
    private static let blades = 7
    private static let ringRadius: CGFloat = 8.1
    private static let ringWidth: CGFloat = 1.3
    private static let bladeRadius: CGFloat = 6.5
    private static let closedRadius: CGFloat = 0.55
    private static let openRadius: CGFloat = 4.1
    private static let seamWidth: CGFloat = 0.85
    private static let badgeDiameter: CGFloat = 8
    private static let gap: CGFloat = 1.3

    static func image(_ glyph: Glyph) -> NSImage {
        let image = NSImage(size: canvas, flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            drawIris(glyph, center: NSPoint(x: bounds.midX, y: bounds.midY), context: context)
            if glyph.badge != .none { drawBadge(glyph.badge, in: bounds, context: context) }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawIris(_ glyph: Glyph, center c: NSPoint, context: CGContext) {
        let opening = min(max(glyph.opening, 0), 1)
        NSColor.black.set()
        let ring = NSBezierPath(ovalIn: NSRect(x: c.x - ringRadius + ringWidth / 2, y: c.y - ringRadius + ringWidth / 2,
                                               width: 2 * ringRadius - ringWidth, height: 2 * ringRadius - ringWidth))
        ring.lineWidth = ringWidth
        ring.stroke()
        NSBezierPath(ovalIn: NSRect(x: c.x - bladeRadius, y: c.y - bladeRadius, width: 2 * bladeRadius, height: 2 * bladeRadius)).fill()

        // Opening: a heptagon that grows and turns as the blades swing out, like a real iris.
        let radius = closedRadius + (openRadius - closedRadius) * opening
        let rotation = -CGFloat.pi / 2 + opening * .pi / 9
        let vertices = (0..<blades).map { index -> NSPoint in
            let angle = rotation + 2 * .pi * CGFloat(index) / CGFloat(blades)
            return NSPoint(x: c.x + radius * cos(angle), y: c.y + radius * sin(angle))
        }
        context.setBlendMode(.clear)
        let hole = NSBezierPath()
        hole.move(to: vertices[0])
        vertices.dropFirst().forEach { hole.line(to: $0) }
        hole.close()
        hole.fill()

        // Seams: each blade edge continues past the opening, curving round to the barrel.
        for index in 0..<blades {
            let from = vertices[index], to = vertices[(index + 1) % blades]
            var dx = to.x - from.x, dy = to.y - from.y
            let length = max(hypot(dx, dy), 0.001)
            dx /= length
            dy /= length
            let reach = bladeRadius * 1.25
            let control = NSPoint(x: to.x + dx * reach * 0.55, y: to.y + dy * reach * 0.55)
            let endAngle = atan2(to.y + dy * reach - c.y, to.x + dx * reach - c.x) + .pi / 10
            let end = NSPoint(x: c.x + (bladeRadius + 0.5) * cos(endAngle), y: c.y + (bladeRadius + 0.5) * sin(endAngle))
            let seam = NSBezierPath()
            seam.move(to: to)
            seam.curve(to: end, controlPoint1: control, controlPoint2: control)
            seam.lineWidth = seamWidth
            seam.lineCapStyle = .round
            seam.stroke()
        }
        context.setBlendMode(.normal)

        if glyph.lit {
            let dot = radius * 0.5
            NSBezierPath(ovalIn: NSRect(x: c.x - dot, y: c.y - dot, width: 2 * dot, height: 2 * dot)).fill()
        }
    }

    private static func drawBadge(_ badge: Badge, in bounds: NSRect, context: CGContext) {
        let circle = NSRect(x: bounds.maxX - badgeDiameter, y: bounds.minY, width: badgeDiameter, height: badgeDiameter)
        context.setBlendMode(.clear)
        NSBezierPath(ovalIn: circle.insetBy(dx: -gap, dy: -gap)).fill()
        context.setBlendMode(.normal)
        NSColor.black.setFill()
        NSBezierPath(ovalIn: circle).fill()
        // The glyph is knocked out of the filled badge.
        context.setBlendMode(.clear)
        switch badge {
        case .ellipsis:
            let dot: CGFloat = 1.3
            for index in -1...1 {
                let x = circle.midX + CGFloat(index) * 2.2
                NSBezierPath(ovalIn: NSRect(x: x - dot / 2, y: circle.midY - dot / 2, width: dot, height: dot)).fill()
            }
        case .exclamation:
            let width: CGFloat = 1.4
            NSBezierPath(roundedRect: NSRect(x: circle.midX - width / 2, y: circle.midY - 0.5, width: width, height: 3),
                         xRadius: width / 2, yRadius: width / 2).fill()
            NSBezierPath(ovalIn: NSRect(x: circle.midX - width / 2, y: circle.minY + 1.3, width: width, height: width)).fill()
        case .none:
            break
        }
        context.setBlendMode(.normal)
    }
}

/// The status item's label. The iris swings to its new opening over about a third of a second when
/// the state changes (instantly with Reduce Motion) and draws nothing while the state holds.
struct MenuBarLabel: View {
    let glyph: MenuBarSymbol.Glyph

    @State private var opening: CGFloat?

    var body: some View {
        Image(nsImage: MenuBarSymbol.image(MenuBarSymbol.Glyph(opening: opening ?? glyph.opening, lit: glyph.lit, badge: glyph.badge)))
            .task(id: glyph.opening) {
                let target = glyph.opening
                guard let start = opening, start != target,
                      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                    opening = target
                    return
                }
                let frames = 12
                for frame in 1...frames {
                    try? await Task.sleep(for: .milliseconds(28))
                    if Task.isCancelled { return }
                    let t = CGFloat(frame) / CGFloat(frames)
                    let eased = 1 - pow(1 - t, 3)
                    opening = start + (target - start) * eased
                }
            }
    }
}
