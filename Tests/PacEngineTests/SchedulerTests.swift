import Testing
@testable import PacEngine

@Suite struct SchedulerTests {
    @Test func runsEventsInTimeOrderAndAdvancesNow() {
        let s = Scheduler()
        var seen: [String] = []
        s.at(30) { seen.append("c@\(s.now)") }
        s.at(10) { seen.append("a@\(s.now)") }
        s.at(20) { seen.append("b@\(s.now)") }
        s.runUntil(100)
        #expect(seen == ["a@10", "b@20", "c@30"])
        #expect(s.now == 100)
    }

    @Test func keepsFifoOrderForEventsAtTheSameTime() {
        let s = Scheduler()
        var seen: [Int] = []
        for i in 0..<5 { s.at(10) { seen.append(i) } }
        s.runUntil(10)
        #expect(seen == [0, 1, 2, 3, 4])
    }

    @Test func runsEventsScheduledDuringExecutionInTheSameWindow() {
        let s = Scheduler()
        var seen: [Int] = []
        s.at(5) { s.after(0) { seen.append(s.now) } }
        s.runUntil(5)
        #expect(seen == [5])
    }

    @Test func doesNotRunEventsBeyondTheTarget() {
        let s = Scheduler()
        var ran = false
        s.at(11) { ran = true }
        s.runUntil(10)
        #expect(!ran)
        #expect(s.now == 10)
    }

    @Test func cancelledTimersNeverFireAndDoNotBlockLaterEvents() {
        let s = Scheduler()
        var seen: [String] = []
        let t = s.at(5) { seen.append("cancelled") }
        s.at(20) { seen.append("late") }
        t.cancel()
        s.runUntil(10)
        #expect(seen.isEmpty)
        #expect(s.now == 10)
        s.runUntil(20)
        #expect(seen == ["late"])
    }

    @Test func schedulingInThePastIsAProgrammingError() async {
        await #expect(processExitsWith: .failure) {
            let s = Scheduler()
            s.runUntil(50)
            s.at(10) {}
        }
    }

    @Test func stepReturnsFalseWhenIdle() {
        #expect(!Scheduler().step())
    }

    @Test func runUntilStopsAtTheEventBudgetWithoutJumpingAhead() {
        let s = Scheduler()
        var fired = 0
        for t in 1...10 { s.at(t) { fired += 1 } }
        s.runUntil(100, maxEvents: 4)
        #expect(fired == 4 && s.now == 4)
        s.runUntil(100)
        #expect(fired == 10 && s.now == 100)
    }
}
