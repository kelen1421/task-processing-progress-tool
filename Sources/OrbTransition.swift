import Cocoa
import QuartzCore

struct PanelDockEdge: OptionSet {
    let rawValue: Int
    static let left = Self(rawValue: 1), right = Self(rawValue: 2), top = Self(rawValue: 4), bottom = Self(rawValue: 8)
    static func touching(_ frame: NSRect, screen: NSRect) -> Self {
        var edges: Self = []
        if frame.minX <= screen.minX + 8 { edges.insert(.left) }
        if frame.maxX >= screen.maxX - 8 { edges.insert(.right) }
        if frame.maxY >= screen.maxY - 8 { edges.insert(.top) }
        if frame.minY <= screen.minY + 8 { edges.insert(.bottom) }
        return edges
    }
    func orbFrame(_ panel: NSRect, screen: NSRect) -> NSRect {
        var x = min(screen.maxX - 68, max(screen.minX + 4, panel.midX - 32))
        var y = min(screen.maxY - 68, max(screen.minY + 4, panel.midY - 32))
        if contains(.left) { x = screen.minX + 4 } else if contains(.right) { x = screen.maxX - 68 }
        if contains(.top) { y = screen.maxY - 68 } else if contains(.bottom) { y = screen.minY + 4 }
        return NSRect(x: x, y: y, width: 64, height: 64)
    }
}

enum OrbCollapseTransition {
    // Animate a snapshot of our own panel so the live task layout does not jump
    // between sizes while its contents rotate and gather at the orb's position.
    static func animate(panel: NSPanel, destination: CGPoint? = nil, completion: @escaping () -> Void) -> Bool {
        guard panel.isVisible, let content = panel.contentView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return false }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return false }
        let bounds = content.bounds
        let overlay = NSView(frame: bounds)
        overlay.wantsLayer = true
        guard let layer = overlay.layer else { return false }
        layer.contents = image; layer.contentsGravity = .resize
        let container = NSView(frame: bounds)
        container.addSubview(overlay)
        panel.contentView = container
        let destination = destination ?? CGPoint(x: bounds.maxX - 32, y: bounds.maxY - 32)
        let movement = CABasicAnimation(keyPath: "position")
        movement.fromValue = NSValue(point: CGPoint(x: bounds.midX, y: bounds.midY))
        movement.toValue = NSValue(point: destination)
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0; rotation.toValue = -Double.pi * 1.25
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1; scale.toValue = 52 / max(bounds.width, bounds.height)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 0.9, 0]; fade.keyTimes = [0, 0.65, 1]
        let animation = CAAnimationGroup()
        animation.animations = [movement, rotation, scale, fade]
        animation.duration = 0.42; animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.fillMode = .forwards; animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "gatherIntoOrb")
        DispatchQueue.main.asyncAfter(deadline: .now() + animation.duration) {
            panel.contentView = content
            completion()
        }
        return true
    }
}
