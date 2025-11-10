import { Device, Connection } from '@/types/network'
import { BarChart3, Network, Cable, CheckCircle2, AlertCircle } from 'lucide-react'

interface NetworkStatsProps {
  devices: Device[]
  connections: Connection[]
}

export default function NetworkStats({ devices, connections }: NetworkStatsProps) {
  const configuredDevices = devices.filter((d) => d.ip).length
  const unconfiguredDevices = devices.length - configuredDevices
  const dhcpRouters = devices.filter((d) => d.dhcpEnabled).length

  const devicesByType = devices.reduce((acc, device) => {
    acc[device.type] = (acc[device.type] || 0) + 1
    return acc
  }, {} as Record<string, number>)

  const topDeviceTypes = Object.entries(devicesByType)
    .sort(([, a], [, b]) => b - a)
    .slice(0, 5)

  return (
    <div className="absolute top-4 left-4 w-72 bg-card/95 backdrop-blur-sm border border-border rounded-lg shadow-lg overflow-hidden">
      <div className="bg-primary/10 px-4 py-3 border-b border-border">
        <div className="flex items-center gap-2">
          <BarChart3 className="h-5 w-5 text-primary" />
          <h3 className="font-semibold">Network Statistics</h3>
        </div>
      </div>

      <div className="p-4 space-y-4">
        {/* Overview */}
        <div className="grid grid-cols-2 gap-3">
          <div className="bg-background rounded-md p-3">
            <div className="flex items-center gap-2 text-muted-foreground mb-1">
              <Network className="h-4 w-4" />
              <span className="text-xs">Devices</span>
            </div>
            <div className="text-2xl font-bold">{devices.length}</div>
          </div>

          <div className="bg-background rounded-md p-3">
            <div className="flex items-center gap-2 text-muted-foreground mb-1">
              <Cable className="h-4 w-4" />
              <span className="text-xs">Connections</span>
            </div>
            <div className="text-2xl font-bold">{connections.length}</div>
          </div>
        </div>

        {/* Configuration Status */}
        <div className="space-y-2">
          <div className="text-xs font-medium text-muted-foreground">Configuration</div>
          <div className="space-y-2">
            <div className="flex items-center justify-between text-sm">
              <div className="flex items-center gap-2">
                <CheckCircle2 className="h-4 w-4 text-green-500" />
                <span>Configured</span>
              </div>
              <span className="font-semibold">{configuredDevices}</span>
            </div>
            <div className="flex items-center justify-between text-sm">
              <div className="flex items-center gap-2">
                <AlertCircle className="h-4 w-4 text-yellow-500" />
                <span>Unconfigured</span>
              </div>
              <span className="font-semibold">{unconfiguredDevices}</span>
            </div>
            <div className="flex items-center justify-between text-sm">
              <div className="flex items-center gap-2">
                <span className="text-xs">📡</span>
                <span>DHCP Servers</span>
              </div>
              <span className="font-semibold">{dhcpRouters}</span>
            </div>
          </div>
        </div>

        {/* Top Device Types */}
        {topDeviceTypes.length > 0 && (
          <div className="space-y-2">
            <div className="text-xs font-medium text-muted-foreground">Top Device Types</div>
            <div className="space-y-1.5">
              {topDeviceTypes.map(([type, count]) => (
                <div key={type} className="flex items-center justify-between text-sm">
                  <span className="text-muted-foreground capitalize">
                    {type.replace('-', ' ')}
                  </span>
                  <span className="font-semibold">{count}</span>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Progress Bars */}
        {devices.length > 0 && (
          <div className="space-y-2">
            <div className="space-y-1">
              <div className="flex justify-between text-xs text-muted-foreground">
                <span>Network Coverage</span>
                <span>{Math.round((configuredDevices / devices.length) * 100)}%</span>
              </div>
              <div className="h-2 bg-background rounded-full overflow-hidden">
                <div
                  className="h-full bg-primary transition-all"
                  style={{ width: `${(configuredDevices / devices.length) * 100}%` }}
                />
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  )
}
