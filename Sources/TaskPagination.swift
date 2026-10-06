import Cocoa

enum TaskPagination {
    static func pageCount(_ tasks: Int) -> Int {
        // A full final page gets an additional page with four task-entry slots.
        let count = max(0, tasks)
        return max(1, (count + 3) / 4 + (count > 0 && count % 4 == 0 ? 1 : 0))
    }
}

struct WheelPageGate {
    private var accumulated: Double = 0
    private var flippedInGesture = false
    private var lastFlip = -Double.infinity
    mutating func consume(delta: Double, precise: Bool, phase: NSEvent.Phase, momentum: NSEvent.Phase, time: Double) -> Int {
        if phase.contains(.began) { accumulated = 0; flippedInGesture = false }
        if phase.contains(.ended) || phase.contains(.cancelled) { accumulated = 0; flippedInGesture = false; return 0 }
        guard momentum.isEmpty, delta != 0 else { return 0 }
        if precise && !phase.isEmpty {
            guard !flippedInGesture else { return 0 }
            accumulated += delta
            guard abs(accumulated) >= 30 else { return 0 }
            flippedInGesture = true
            return accumulated < 0 ? 1 : -1
        }
        guard time - lastFlip >= 0.25 else { return 0 }
        lastFlip = time
        return delta < 0 ? 1 : -1
    }
}
