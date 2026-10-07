/// Handle for a scheduled event.
final class SimTimer {
    fileprivate let time: Int
    fileprivate let seq: Int
    fileprivate let fn: () -> Void
    fileprivate var cancelled = false

    fileprivate init(time: Int, seq: Int, fn: @escaping () -> Void) {
        self.time = time
        self.seq = seq
        self.fn = fn
    }

    func cancel() {
        cancelled = true
    }
}

/// Min-heap of events ordered by (time, insertion seq) for deterministic ties.
final class Scheduler {
    private(set) var now = 0
    private var heap: [SimTimer] = []
    private var seq = 0

    @discardableResult
    func at(_ time: Int, _ fn: @escaping () -> Void) -> SimTimer {
        precondition(time >= now, "Cannot schedule in the past (\(time) < \(now))")
        let timer = SimTimer(time: time, seq: seq, fn: fn)
        seq += 1
        push(timer)
        return timer
    }

    @discardableResult
    func after(_ delay: Int, _ fn: @escaping () -> Void) -> SimTimer {
        at(now + delay, fn)
    }

    /// Runs the next live event. Returns false when nothing is pending.
    @discardableResult
    func step() -> Bool {
        guard let timer = peek() else { return false }
        pop()
        now = timer.time
        timer.fn()
        return true
    }

    /// Runs events up to `time`. With a budget, stops after `maxEvents` and leaves `now` at the last event run.
    func runUntil(_ time: Int, maxEvents: Int = .max) {
        var count = 0
        while count < maxEvents, let timer = peek(), timer.time <= time {
            step()
            count += 1
        }
        if count < maxEvents, time > now { now = time }
    }

    private func peek() -> SimTimer? {
        while let first = heap.first, first.cancelled { pop() }
        return heap.first
    }

    private func less(_ a: SimTimer, _ b: SimTimer) -> Bool {
        a.time < b.time || (a.time == b.time && a.seq < b.seq)
    }

    private func push(_ timer: SimTimer) {
        heap.append(timer)
        var i = heap.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard less(heap[i], heap[parent]) else { break }
            heap.swapAt(i, parent)
            i = parent
        }
    }

    @discardableResult
    private func pop() -> SimTimer? {
        guard !heap.isEmpty else { return nil }
        let top = heap[0]
        let last = heap.removeLast()
        if !heap.isEmpty {
            heap[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1
                let r = l + 1
                var m = i
                if l < heap.count && less(heap[l], heap[m]) { m = l }
                if r < heap.count && less(heap[r], heap[m]) { m = r }
                if m == i { break }
                heap.swapAt(i, m)
                i = m
            }
        }
        return top
    }
}
