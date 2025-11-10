import { useState } from 'react'
import { ScrollArea } from './ui/scroll-area'
import { Button } from './ui/button'
import { Separator } from './ui/separator'
import { Input } from './ui/input'
import { Search, X } from 'lucide-react'

const deviceCategories = [
  {
    name: 'Network Infrastructure',
    devices: [
      { id: 'router', name: 'Router', icon: '🔀' },
      { id: 'switch', name: 'Switch', icon: '🔲' },
      { id: 'hub', name: 'Hub', icon: '⬡' },
      { id: 'modem', name: 'Modem', icon: '📡' },
      { id: 'access-point', name: 'Access Point', icon: '📶' },
      { id: 'wan', name: 'Internet/WAN', icon: '🌐' },
      { id: 'cloud', name: 'Cloud', icon: '☁️' },
    ],
  },
  {
    name: 'Security',
    devices: [
      { id: 'firewall', name: 'Firewall', icon: '🔥' },
      { id: 'ids', name: 'IDS/IPS', icon: '🛡️' },
    ],
  },
  {
    name: 'Servers',
    devices: [
      { id: 'web-server', name: 'Web Server', icon: '🌐' },
      { id: 'db-server', name: 'Database', icon: '💾' },
      { id: 'mail-server', name: 'Mail Server', icon: '📧' },
      { id: 'dns-server', name: 'DNS Server', icon: '🔤' },
      { id: 'ftp-server', name: 'FTP Server', icon: '📁' },
      { id: 'proxy', name: 'Proxy', icon: '🔀' },
    ],
  },
  {
    name: 'End Devices',
    devices: [
      { id: 'pc', name: 'PC', icon: '💻' },
      { id: 'laptop', name: 'Laptop', icon: '💻' },
      { id: 'tablet', name: 'Tablet', icon: '📱' },
      { id: 'smartphone', name: 'Smartphone', icon: '📱' },
      { id: 'printer', name: 'Printer', icon: '🖨️' },
    ],
  },
  {
    name: 'IoT & Smart Home',
    devices: [
      { id: 'wifi-router', name: 'WiFi Router', icon: '📡' },
      { id: 'smart-tv', name: 'Smart TV', icon: '📺' },
      { id: 'game-console', name: 'Game Console', icon: '🎮' },
      { id: 'smart-speaker', name: 'Smart Speaker', icon: '🔊' },
      { id: 'camera', name: 'Security Camera', icon: '📷' },
      { id: 'thermostat', name: 'Thermostat', icon: '🌡️' },
      { id: 'smart-lock', name: 'Smart Lock', icon: '🔒' },
    ],
  },
]

interface SidebarProps {
  onAddDevice: (device: any) => void
}

export default function Sidebar({ onAddDevice }: SidebarProps) {
  const [searchQuery, setSearchQuery] = useState('')

  const filteredCategories = deviceCategories.map((category) => ({
    ...category,
    devices: category.devices.filter((device) =>
      device.name.toLowerCase().includes(searchQuery.toLowerCase())
    ),
  })).filter((category) => category.devices.length > 0)

  return (
    <div className="w-64 bg-card border-r border-border flex flex-col">
      <div className="p-4 border-b border-border">
        <h2 className="text-lg font-semibold mb-3">Devices</h2>
        <div className="relative">
          <Search className="absolute left-2 top-2.5 h-4 w-4 text-muted-foreground" />
          <Input
            placeholder="Search devices..."
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            className="pl-8 pr-8"
          />
          {searchQuery && (
            <button
              onClick={() => setSearchQuery('')}
              className="absolute right-2 top-2.5 text-muted-foreground hover:text-foreground"
            >
              <X className="h-4 w-4" />
            </button>
          )}
        </div>
      </div>

      <ScrollArea className="flex-1">
        <div className="p-4 space-y-4">
          {filteredCategories.length === 0 && (
            <div className="text-center text-sm text-muted-foreground py-8">
              No devices found
            </div>
          )}
          {filteredCategories.map((category) => (
            <div key={category.name}>
              <h3 className="text-sm font-medium text-muted-foreground mb-2">
                {category.name}
              </h3>
              <div className="grid grid-cols-2 gap-2">
                {category.devices.map((device) => (
                  <Button
                    key={device.id}
                    variant="outline"
                    className="h-auto flex flex-col items-center justify-center p-3 gap-1"
                    onClick={() => onAddDevice(device)}
                  >
                    <span className="text-2xl">{device.icon}</span>
                    <span className="text-xs text-center leading-tight">
                      {device.name}
                    </span>
                  </Button>
                ))}
              </div>
              {category !== filteredCategories[filteredCategories.length - 1] && (
                <Separator className="mt-4" />
              )}
            </div>
          ))}
        </div>
      </ScrollArea>
    </div>
  )
}
