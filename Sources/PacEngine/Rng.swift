/// Seeded PRNG (mulberry32), bit-identical to the TypeScript engine. All simulation randomness comes from here.
final class Rng {
    private var state: UInt32

    init(seed: UInt32) {
        state = seed
    }

    func next() -> Double {
        state &+= 0x6D2B_79F5
        var t = state
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }

    func int(_ maxExclusive: Int) -> Int {
        Int(next() * Double(maxExclusive))
    }

    func uint32() -> UInt32 {
        UInt32(next() * 4_294_967_296)
    }
}
