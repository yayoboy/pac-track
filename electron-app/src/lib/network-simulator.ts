import { Device, Connection, Packet, ConsoleMessage } from '@/types/network'

export class NetworkSimulator {
  private devices: Map<string, Device>
  private connections: Connection[]
  private messageCallback?: (message: ConsoleMessage) => void

  constructor() {
    this.devices = new Map()
    this.connections = []
  }

  setMessageCallback(callback: (message: ConsoleMessage) => void) {
    this.messageCallback = callback
  }

  addDevice(device: Device) {
    this.devices.set(device.id, device)
    this.log('info', `Device ${device.name} added to network`)
  }

  removeDevice(deviceId: string) {
    const device = this.devices.get(deviceId)
    if (device) {
      this.devices.delete(deviceId)
      // Remove all connections to/from this device
      this.connections = this.connections.filter(
        (conn) => conn.from !== deviceId && conn.to !== deviceId
      )
      this.log('info', `Device ${device.name} removed from network`)
    }
  }

  addConnection(connection: Connection) {
    this.connections.push(connection)
    const from = this.devices.get(connection.from)
    const to = this.devices.get(connection.to)
    if (from && to) {
      this.log('success', `Connected ${from.name} to ${to.name}`)
    }
  }

  removeConnection(connectionId: string) {
    this.connections = this.connections.filter((conn) => conn.id !== connectionId)
  }

  getDevice(deviceId: string): Device | undefined {
    return this.devices.get(deviceId)
  }

  getAllDevices(): Device[] {
    return Array.from(this.devices.values())
  }

  getConnections(): Connection[] {
    return this.connections
  }

  getConnectedDevices(deviceId: string): Device[] {
    const connected: Device[] = []
    this.connections.forEach((conn) => {
      if (conn.from === deviceId) {
        const device = this.devices.get(conn.to)
        if (device) connected.push(device)
      } else if (conn.to === deviceId) {
        const device = this.devices.get(conn.from)
        if (device) connected.push(device)
      }
    })
    return connected
  }

  isInSameNetwork(ip1: string, ip2: string, subnet: string): boolean {
    const ip1Parts = ip1.split('.').map(Number)
    const ip2Parts = ip2.split('.').map(Number)
    const subnetParts = subnet.split('.').map(Number)

    for (let i = 0; i < 4; i++) {
      if ((ip1Parts[i] & subnetParts[i]) !== (ip2Parts[i] & subnetParts[i])) {
        return false
      }
    }
    return true
  }

  findPath(sourceId: string, destId: string): string[] | null {
    const visited = new Set<string>()
    const queue: { id: string; path: string[] }[] = [
      { id: sourceId, path: [sourceId] },
    ]

    while (queue.length > 0) {
      const current = queue.shift()!
      if (current.id === destId) {
        return current.path
      }

      if (visited.has(current.id)) continue
      visited.add(current.id)

      const connected = this.getConnectedDevices(current.id)
      connected.forEach((device) => {
        if (!visited.has(device.id)) {
          queue.push({
            id: device.id,
            path: [...current.path, device.id],
          })
        }
      })
    }

    return null
  }

  async sendPacket(packet: Packet): Promise<boolean> {
    const source = this.devices.get(packet.source)
    const destination = this.devices.get(packet.destination)

    if (!source || !destination) {
      this.log('error', 'Source or destination device not found')
      return false
    }

    if (!source.ip || !destination.ip) {
      this.log('error', 'Source or destination IP not configured')
      return false
    }

    this.log(
      'packet',
      `${packet.protocol}: ${source.name} → ${destination.name}`
    )

    const path = this.findPath(packet.source, packet.destination)
    if (!path) {
      this.log('error', `No path found from ${source.name} to ${destination.name}`)
      return false
    }

    packet.path = path
    this.log('info', `Path: ${path.map((id) => this.devices.get(id)?.name).join(' → ')}`)
    this.log('success', `Packet delivered successfully (${path.length - 1} hops)`)

    return true
  }

  assignDHCPAddress(routerId: string, deviceId: string): string | null {
    const router = this.devices.get(routerId)
    const device = this.devices.get(deviceId)

    if (!router || !device) return null
    if (!router.dhcpEnabled || !router.dhcpRange || !router.ip) return null

    // Simple DHCP: assign next available IP in range
    const rangeStart = router.dhcpRange.start.split('.').map(Number)
    const rangeEnd = router.dhcpRange.end.split('.').map(Number)

    const startNum = rangeStart[3]
    const endNum = rangeEnd[3]

    // Find an available IP
    for (let i = startNum; i <= endNum; i++) {
      const testIp = `${rangeStart[0]}.${rangeStart[1]}.${rangeStart[2]}.${i}`
      const alreadyUsed = Array.from(this.devices.values()).some(
        (d) => d.ip === testIp && d.id !== deviceId
      )
      if (!alreadyUsed) {
        device.ip = testIp
        device.subnet = router.subnet
        device.gateway = router.ip
        this.log('success', `DHCP: Assigned ${testIp} to ${device.name}`)
        return testIp
      }
    }

    this.log('error', `DHCP: No available IPs in range for ${device.name}`)
    return null
  }

  private log(type: ConsoleMessage['type'], text: string, deviceId?: string) {
    if (this.messageCallback) {
      this.messageCallback({
        type,
        text,
        timestamp: new Date(),
        deviceId,
      })
    }
  }

  exportTopology(): string {
    const topology = {
      name: 'Network Topology',
      devices: Array.from(this.devices.values()),
      connections: this.connections,
      createdAt: new Date(),
      modifiedAt: new Date(),
    }
    return JSON.stringify(topology, null, 2)
  }

  importTopology(json: string): boolean {
    try {
      const topology = JSON.parse(json)
      this.devices.clear()
      topology.devices.forEach((device: Device) => {
        this.devices.set(device.id, device)
      })
      this.connections = topology.connections
      this.log('success', 'Topology loaded successfully')
      return true
    } catch (error) {
      this.log('error', 'Failed to load topology')
      return false
    }
  }
}
