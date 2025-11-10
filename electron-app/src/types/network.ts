export type DeviceType =
  | 'router'
  | 'switch'
  | 'hub'
  | 'modem'
  | 'access-point'
  | 'wan'
  | 'cloud'
  | 'firewall'
  | 'ids'
  | 'web-server'
  | 'db-server'
  | 'mail-server'
  | 'dns-server'
  | 'ftp-server'
  | 'proxy'
  | 'pc'
  | 'laptop'
  | 'tablet'
  | 'smartphone'
  | 'printer'
  | 'wifi-router'
  | 'smart-tv'
  | 'game-console'
  | 'smart-speaker'
  | 'camera'
  | 'thermostat'
  | 'smart-lock'

export interface Device {
  id: string
  type: DeviceType
  name: string
  icon: string
  x: number
  y: number
  ip?: string
  subnet?: string
  gateway?: string
  mac?: string
  dhcpEnabled?: boolean
  dhcpRange?: {
    start: string
    end: string
  }
  routingTable?: RoutingEntry[]
  ports?: number
  connectedPorts?: number[]
}

export interface RoutingEntry {
  network: string
  subnet: string
  gateway: string
  interface: string
}

export interface Connection {
  id: string
  from: string
  to: string
  fromPort?: number
  toPort?: number
}

export interface Packet {
  id: string
  protocol: 'ARP' | 'ICMP' | 'TCP' | 'UDP' | 'DNS'
  source: string
  destination: string
  data?: any
  path?: string[]
  ttl: number
}

export interface NetworkTopology {
  name: string
  devices: Device[]
  connections: Connection[]
  createdAt: Date
  modifiedAt: Date
}

export interface ConsoleMessage {
  type: 'info' | 'success' | 'warning' | 'error' | 'packet'
  text: string
  timestamp: Date
  deviceId?: string
}
