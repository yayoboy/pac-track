import Testing
@testable import PacEngine

@Suite struct TracerouteTests {
    @Test func listsEveryHopUpToTheDestination() throws {
        let (sim, h1, _, _, _) = try twoRouters()
        let t = try Traceroute(node: h1, target: "10.0.2.10")
        sim.run(30 * S)
        #expect(t.result.done)
        #expect(t.result.reached)
        #expect(t.result.hops.map { $0.probes.map { $0.from ?? "*" } } == [
            ["10.0.1.1", "10.0.1.1", "10.0.1.1"],
            ["10.0.12.2", "10.0.12.2", "10.0.12.2"],
            ["10.0.2.10", "10.0.2.10", "10.0.2.10"],
        ])
        #expect(t.result.lines[0] == "traceroute to 10.0.2.10 (10.0.2.10), 30 hops max, 60 byte packets")
        #expect(t.result.lines[1].wholeMatch(of: /^ 1  10\.0\.1\.1 \(10\.0\.1\.1\)  \d+\.\d{3} ms  \d+\.\d{3} ms  \d+\.\d{3} ms$/) != nil)
    }

    @Test func marksUnreachableNetworksWithBangNAndStops() throws {
        let (sim, h1, _, _, _) = try twoRouters()
        let t = try Traceroute(node: h1, target: "10.0.9.9")
        sim.run(30 * S)
        #expect(t.result.hops.count == 2)
        #expect(t.result.reached)
        #expect(t.result.lines[2].firstMatch(of: /^ 2  10\.0\.1\.1 \(10\.0\.1\.1\)  \d+\.\d{3} ms !N/) != nil)
    }

    @Test func printsStarsForUnansweredProbesAndHonoursMaxHops() throws {
        let (sim, h1, _, _, _) = try twoRouters(lastLink: LinkOptions(lossRate: 1))
        let t = try Traceroute(node: h1, target: "10.0.2.10", options: TracerouteOptions(maxHops: 3, waitNs: 1 * S))
        sim.run(30 * S)
        #expect(t.result.done)
        #expect(!t.result.reached)
        #expect(t.result.lines[3] == " 3  * * *")
    }

    @Test func pingAcrossTwoRoutersSeesTtl62() throws {
        let (sim, h1, _, _, _) = try twoRouters()
        let p = try Ping(node: h1, target: "10.0.2.10", options: PingOptions(count: 1))
        sim.run(1 * S)
        #expect(p.result.replies.first?.ttl == 62)
    }

    @Test func keepsConcurrentTraceroutesFromTheSameNodeApart() throws {
        let (sim, h1, _, _, _) = try twoRouters()
        // Resolve the gateway first: 6 simultaneous probes would overflow the 3-packet ARP queue.
        _ = try Ping(node: h1, target: "10.0.1.1", options: PingOptions(count: 1))
        sim.run(1 * S)
        let good = try Traceroute(node: h1, target: "10.0.2.10")
        let bad = try Traceroute(node: h1, target: "10.0.9.9")
        sim.run(60 * S)
        #expect(good.result.hops.map { $0.probes[0].from } == ["10.0.1.1", "10.0.12.2", "10.0.2.10"])
        #expect(bad.result.hops.map { $0.probes[0].from } == ["10.0.1.1", "10.0.1.1"])
        #expect(bad.result.lines[2].contains("!N"))
    }

    @Test func rejectsInvalidOptionsSynchronously() throws {
        let (_, h1, _, _, _) = try twoRouters()
        let invalid = [TracerouteOptions(maxHops: 0), TracerouteOptions(maxHops: 256), TracerouteOptions(probes: 0),
                       TracerouteOptions(waitNs: 0), TracerouteOptions(firstPort: 70000)]
        for opts in invalid {
            expectError("Invalid traceroute option") { _ = try Traceroute(node: h1, target: "10.0.2.10", options: opts) }
        }
    }

    @Test func sameSeedAndTopologyProduceAnIdenticalEventLog() throws {
        func run(_ seed: UInt32) throws -> [String] {
            let net = try twoRouters(Sim(seed: seed))
            _ = try Ping(node: net.h1, target: "10.0.2.10", options: PingOptions(count: 3))
            _ = try Traceroute(node: net.h1, target: "10.0.2.10")
            net.sim.run(30 * S)
            return net.sim.log.all.map { "\($0.time) \($0.kind) \($0.node) \($0.iface ?? "") \($0.frame?.id ?? 0) \($0.reason?.rawValue ?? "")" }
        }
        let first = try run(5)
        #expect(first.count > 50)
        #expect(try run(5) == first)
    }
}
