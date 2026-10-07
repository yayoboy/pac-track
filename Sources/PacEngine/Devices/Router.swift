final class Router: IpNode {
    init(sim: Sim, id: String, ports: Int = 4) {
        super.init(sim: sim, id: id)
        forwarding = true
        defaultTtl = 255
        for i in 0..<ports { addInterface("Gi0/\(i)") }
    }
}
