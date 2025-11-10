import { Device, DeviceType } from '@/types/network'

export function createDevice(
  type: DeviceType,
  name: string,
  icon: string,
  x: number,
  y: number
): Device {
  const id = `${type}-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`

  const baseDevice: Device = {
    id,
    type,
    name: `${name}-${id.substr(-4)}`,
    icon,
    x,
    y,
    mac: generateMAC(),
  }

  // Add type-specific properties
  switch (type) {
    case 'router':
    case 'wifi-router':
      return {
        ...baseDevice,
        ports: 4,
        connectedPorts: [],
        routingTable: [],
        dhcpEnabled: false,
      }

    case 'switch':
      return {
        ...baseDevice,
        ports: 8,
        connectedPorts: [],
      }

    case 'hub':
      return {
        ...baseDevice,
        ports: 4,
        connectedPorts: [],
      }

    case 'firewall':
      return {
        ...baseDevice,
        ports: 2,
        connectedPorts: [],
      }

    default:
      return baseDevice
  }
}

function generateMAC(): string {
  const hex = '0123456789ABCDEF'
  let mac = ''
  for (let i = 0; i < 6; i++) {
    if (i > 0) mac += ':'
    mac += hex[Math.floor(Math.random() * 16)]
    mac += hex[Math.floor(Math.random() * 16)]
  }
  return mac
}

export function getDeviceColor(type: DeviceType): string {
  const colors: Record<string, string> = {
    router: '#1e40af',
    switch: '#059669',
    hub: '#dc2626',
    firewall: '#dc2626',
    'web-server': '#7c3aed',
    'db-server': '#7c3aed',
    pc: '#2563eb',
    laptop: '#2563eb',
    smartphone: '#ea580c',
    tablet: '#ea580c',
  }
  return colors[type] || '#6b7280'
}
