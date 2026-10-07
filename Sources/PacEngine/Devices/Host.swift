final class Host: IpNode {
    override init(sim: Sim, id: String) {
        super.init(sim: sim, id: id)
        addInterface("eth0")
    }
}
