import { useState, useEffect } from 'react'
import { Device } from '@/types/network'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from './ui/dialog'
import { Input } from './ui/input'
import { Label } from './ui/label'
import { Button } from './ui/button'
import { Switch } from './ui/switch'

interface DeviceConfigDialogProps {
  device: Device | null
  open: boolean
  onOpenChange: (open: boolean) => void
  onSave: (device: Device) => void
}

export default function DeviceConfigDialog({
  device,
  open,
  onOpenChange,
  onSave,
}: DeviceConfigDialogProps) {
  const [config, setConfig] = useState<Partial<Device>>({})

  useEffect(() => {
    if (device) {
      setConfig(device)
    }
  }, [device])

  if (!device) return null

  const handleSave = () => {
    onSave({ ...device, ...config })
    onOpenChange(false)
  }

  const isRouter = device.type === 'router' || device.type === 'wifi-router'

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-[500px]">
        <DialogHeader>
          <DialogTitle>
            Configure {device.icon} {device.name}
          </DialogTitle>
          <DialogDescription>
            Set network configuration for this device
          </DialogDescription>
        </DialogHeader>

        <div className="grid gap-4 py-4">
          <div className="grid gap-2">
            <Label htmlFor="name">Device Name</Label>
            <Input
              id="name"
              value={config.name || ''}
              onChange={(e) => setConfig({ ...config, name: e.target.value })}
            />
          </div>

          <div className="grid gap-2">
            <Label htmlFor="ip">IP Address</Label>
            <Input
              id="ip"
              placeholder="192.168.1.1"
              value={config.ip || ''}
              onChange={(e) => setConfig({ ...config, ip: e.target.value })}
            />
          </div>

          <div className="grid gap-2">
            <Label htmlFor="subnet">Subnet Mask</Label>
            <Input
              id="subnet"
              placeholder="255.255.255.0"
              value={config.subnet || ''}
              onChange={(e) => setConfig({ ...config, subnet: e.target.value })}
            />
          </div>

          <div className="grid gap-2">
            <Label htmlFor="gateway">Gateway</Label>
            <Input
              id="gateway"
              placeholder="192.168.1.1"
              value={config.gateway || ''}
              onChange={(e) => setConfig({ ...config, gateway: e.target.value })}
            />
          </div>

          <div className="grid gap-2">
            <Label htmlFor="mac">MAC Address</Label>
            <Input
              id="mac"
              placeholder="AA:BB:CC:DD:EE:FF"
              value={config.mac || ''}
              disabled
              className="opacity-60"
            />
          </div>

          {isRouter && (
            <>
              <div className="border-t pt-4 mt-2">
                <div className="flex items-center justify-between mb-4">
                  <Label htmlFor="dhcp">DHCP Server</Label>
                  <Switch
                    id="dhcp"
                    checked={config.dhcpEnabled || false}
                    onCheckedChange={(checked) =>
                      setConfig({ ...config, dhcpEnabled: checked })
                    }
                  />
                </div>

                {config.dhcpEnabled && (
                  <div className="grid gap-4 pl-4 border-l-2 border-primary/20">
                    <div className="grid gap-2">
                      <Label htmlFor="dhcp-start">DHCP Range Start</Label>
                      <Input
                        id="dhcp-start"
                        placeholder="192.168.1.100"
                        value={config.dhcpRange?.start || ''}
                        onChange={(e) =>
                          setConfig({
                            ...config,
                            dhcpRange: {
                              start: e.target.value,
                              end: config.dhcpRange?.end || '',
                            },
                          })
                        }
                      />
                    </div>

                    <div className="grid gap-2">
                      <Label htmlFor="dhcp-end">DHCP Range End</Label>
                      <Input
                        id="dhcp-end"
                        placeholder="192.168.1.200"
                        value={config.dhcpRange?.end || ''}
                        onChange={(e) =>
                          setConfig({
                            ...config,
                            dhcpRange: {
                              start: config.dhcpRange?.start || '',
                              end: e.target.value,
                            },
                          })
                        }
                      />
                    </div>
                  </div>
                )}
              </div>
            </>
          )}
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button onClick={handleSave}>Save Changes</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
