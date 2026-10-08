import Testing
@testable import PacEngine

/// H1 (10.0.0.1/24) cabled straight to SRV (10.0.0.2/24) at 10 Mb/s.
private func direct(sink: Bool = true) throws -> (sim: Sim, h1: Host, srv: Host) {
    let sim = Sim()
    let h1 = Host(sim: sim, id: "H1")
    let srv = Host(sim: sim, id: "SRV")
    _ = try Link(sim: sim, try h1.iface("eth0"), try srv.iface("eth0"), LinkOptions(bandwidthBps: 10e6))
    try h1.setIp("eth0", "10.0.0.1/24")
    try srv.setIp("eth0", "10.0.0.2/24")
    try srv.configureSink(sink)
    return (sim, h1, srv)
}

/// Runs to `seconds`, calling `sample` at every 100 ms boundary as the runtime does.
private func run(_ sim: Sim, seconds: Int, _ sample: (Int) -> Void) {
    var t = SAMPLE_NS
    while t <= seconds * S {
        sim.sched.runUntil(t)
        sample(t)
        t += SAMPLE_NS
    }
}

/// 10 Mb/s × 1460 / 1538: data bytes per wire byte of a full-sized segment.
private let GOODPUT_10MB = 9_492_848.0

@Suite struct TrafficTests {
    @Test func theSinkListensOnTcpAndUdpPort9UntilTurnedOff() throws {
        let (_, _, srv) = try direct()
        #expect(srv.sink && srv.tcp.listening == [9])
        expectError("UDP port 9 already in use") { try srv.bindUdp(9) { _, _, _ in } }
        try srv.configureSink(false)
        #expect(!srv.sink && srv.tcp.listening.isEmpty)
        try srv.bindUdp(9) { _, _, _ in }
    }

    @Test func tcpFlowSendsItsBytesToTheSinkAndReportsLikeIperf3() throws {
        let (sim, h1, srv) = try direct()
        let flow = try TcpFlow(node: h1, target: "10.0.0.2", bytes: 1_000_000)
        run(sim, seconds: 2) { flow.sample(at: $0) }
        let lines = flow.result.lines
        #expect(lines.count == 4 && flow.result.done)
        #expect(lines[0] == "Connecting to host 10.0.0.2, port 9")
        #expect(lines[1].hasPrefix("[  1] local 10.0.0.1 port ") && lines[1].hasSuffix(" connected to 10.0.0.2 port 9"))
        // ≈ 0.843 s for 685 segments on the wire at 10 Mb/s
        #expect(lines[2].hasPrefix("[  1]   0.00-0.84 sec  1000000 bytes  9.4") && lines[2].hasSuffix(" Mbits/sec  0 retr"))
        #expect(lines[3] == "iperf Done.")
        let samples = flow.result.samples
        #expect(samples.count == 9) // 100 … 900 ms: the flow ends (TIME_WAIT) at ~843 ms; 900 ms holds its last bytes
        #expect(samples.last!.timeNs == 900 * MS && samples.last!.bitsPerSecond > 0)
        for s in samples[1...6] { #expect(abs(s.bitsPerSecond - GOODPUT_10MB) / GOODPUT_10MB < 0.05) }
        #expect(samples.allSatisfy { $0.jitterNs == nil && $0.lossPct == 0 && $0.delayNs != nil })
        #expect(srv.tcp.connections.isEmpty)
    }

    @Test func tcpFlowToAHostWithoutTheSinkIsRefused() throws {
        let (sim, h1, _) = try direct(sink: false)
        let flow = try TcpFlow(node: h1, target: "10.0.0.2", bytes: 1000)
        sim.run(10 * MS)
        #expect(flow.result.lines == ["Connecting to host 10.0.0.2, port 9", "iperf3: error - unable to connect to server: Connection refused"])
        #expect(flow.result.done && flow.result.samples.isEmpty)
    }

    @Test func stoppingATcpFlowResetsTheConnection() throws {
        let (sim, h1, srv) = try direct()
        let flow = try TcpFlow(node: h1, target: "10.0.0.2", bytes: 100_000_000)
        sim.run(50 * MS)
        #expect(srv.tcp.connections.map(\.state) == [.established])
        flow.stop()
        sim.run(200 * MS) // the RST waits behind the data already queued on the cable
        #expect(flow.result.lines.last == "iperf3: interrupt - the client has terminated" && flow.result.done)
        #expect(srv.tcp.connections.isEmpty && h1.tcp.connections.isEmpty)
    }

    @Test func udpFlowSendsAConstantBitrateAndMeasuresWhatTheSinkReceived() throws {
        let (sim, h1, _) = try direct()
        let flow = try UdpFlow(node: h1, target: "10.0.0.2", bitsPerSecond: 1e6, seconds: 1)
        run(sim, seconds: 3) { flow.sample(at: $0) }
        let lines = flow.result.lines
        #expect(lines.count == 4 && flow.result.done)
        #expect(lines[1].hasPrefix("[  1] local 10.0.0.1 port "))
        // 86 datagrams of 1470 B, one every 11.76 ms; only the first waited for ARP (135.4 µs), so the jitter decays to ~37 ns
        #expect(lines[2] == "[  1]   0.00-1.00 sec  126420 bytes  1.01 Mbits/sec  0.000 ms  0/86 (0%)")
        #expect(lines[3] == "iperf Done.")
        let samples = flow.result.samples
        #expect(samples.count == 19) // 100 … 1900 ms: the report at 2 s ends the flow
        #expect(samples[1].delayNs == 1_229_300) // 1536 wire bytes at 10 Mb/s + 500 ns of cable
        #expect(samples.allSatisfy { $0.lossPct == 0 && $0.jitterNs != nil })
        #expect(samples[11...].allSatisfy { $0.bitsPerSecond == 0 }) // nothing arrives after 1.1 s
    }

    @Test func aStoppedUdpFlowStillSamplesItsLastPartialInterval() throws {
        let (sim, h1, _) = try direct()
        let flow = try UdpFlow(node: h1, target: "10.0.0.2", bitsPerSecond: 1e6, seconds: 1)
        run(sim, seconds: 1) {
            flow.sample(at: $0)
            if $0 == 500 * MS {
                sim.sched.runUntil(550 * MS)
                flow.stop()
            }
        }
        let samples = flow.result.samples
        #expect(samples.map(\.timeNs) == (1...6).map { $0 * 100 * MS }) // 600 ms holds 500–550 ms, then nothing
        #expect(samples.last!.bitsPerSecond > 0)
    }

    @Test func udpFlowToAHostWithoutTheSinkLosesEverything() throws {
        let (sim, h1, _) = try direct(sink: false)
        let flow = try UdpFlow(node: h1, target: "10.0.0.2", bitsPerSecond: 1e6, seconds: 1)
        sim.run(3 * S)
        #expect(flow.result.lines[2] == "[  1]   0.00-1.00 sec  0 bytes  0.00 Mbits/sec  0.000 ms  86/86 (100%)")
        #expect(sim.log.all.contains { $0.kind == .tx && $0.node == "SRV" && eventView($0).info.contains("Destination unreachable (port)") })
    }

    @Test func rejectsOutOfRangeSettingsBeforeSendingAnything() throws {
        let (sim, h1, _) = try direct()
        expectError("Bytes must be between 1 and 1000000000") { _ = try TcpFlow(node: h1, target: "10.0.0.2", bytes: 0) }
        expectError("Bitrate must be between 1 kb/s and 1 Gb/s") { _ = try UdpFlow(node: h1, target: "10.0.0.2", bitsPerSecond: 999, seconds: 1) }
        expectError("Duration must be between 1 and 3600 s") { _ = try UdpFlow(node: h1, target: "10.0.0.2", bitsPerSecond: 1e6, seconds: 3601) }
        expectError("Invalid address or host name") { _ = try UdpFlow(node: h1, target: "a b", bitsPerSecond: 1e6, seconds: 1) }
        #expect(sim.log.all.isEmpty)
    }
}
