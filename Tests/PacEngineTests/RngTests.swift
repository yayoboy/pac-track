import Testing
@testable import PacEngine

@Suite struct RngTests {
    @Test func isDeterministicForAGivenSeed() {
        let a = Rng(seed: 42)
        let b = Rng(seed: 42)
        #expect((0..<5).map { _ in a.next() } == (0..<5).map { _ in b.next() })
    }

    @Test func matchesTheTypeScriptReferenceBitForBit() {
        let r = Rng(seed: 42)
        #expect([r.next(), r.next(), r.next()] == [0.6011037519201636, 0.44829055899754167, 0.8524657934904099])
        let q = Rng(seed: 1)
        #expect((0..<5).map { _ in q.int(65536) } == [41095, 179, 34566, 64294, 63463])
    }

    @Test func differsAcrossSeedsAndStaysInUnitRange() {
        #expect(Rng(seed: 1).next() != Rng(seed: 2).next())
        let r = Rng(seed: 7)
        for _ in 0..<1000 {
            let v = r.next()
            #expect(v >= 0 && v < 1)
        }
    }

    @Test func intStaysBelowTheBound() {
        let r = Rng(seed: 3)
        for _ in 0..<1000 {
            #expect((0..<10).contains(r.int(10)))
        }
    }
}
