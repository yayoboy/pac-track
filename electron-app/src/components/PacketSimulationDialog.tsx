import { useState } from 'react'
import { Device } from '@/types/network'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from './ui/dialog'
import { Button } from './ui/button'
import { Label } from './ui/label'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from './ui/select'

interface PacketSimulationDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  devices: Device[]
  onSendPacket: (sourceId: string, destId: string, protocol: string) => void
}

const protocols = [
  { value: 'ICMP', label: 'ICMP (Ping)', color: '#22c55e' },
  { value: 'TCP', label: 'TCP (HTTP)', color: '#3b82f6' },
  { value: 'UDP', label: 'UDP', color: '#a855f7' },
  { value: 'ARP', label: 'ARP', color: '#f59e0b' },
  { value: 'DNS', label: 'DNS', color: '#ec4899' },
]

export default function PacketSimulationDialog({
  open,
  onOpenChange,
  devices,
  onSendPacket,
}: PacketSimulationDialogProps) {
  const [sourceId, setSourceId] = useState('')
  const [destId, setDestId] = useState('')
  const [protocol, setProtocol] = useState('ICMP')

  const configuredDevices = devices.filter(d => d.ip)

  const handleSend = () => {
    if (sourceId && destId && sourceId !== destId) {
      onSendPacket(sourceId, destId, protocol)
      onOpenChange(false)
      // Reset
      setSourceId('')
      setDestId('')
      setProtocol('ICMP')
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-[500px]">
        <DialogHeader>
          <DialogTitle>Send Packet</DialogTitle>
          <DialogDescription>
            Simulate packet transmission between devices
          </DialogDescription>
        </DialogHeader>

        <div className="grid gap-4 py-4">
          <div className="grid gap-2">
            <Label htmlFor="source">Source Device</Label>
            <Select value={sourceId} onValueChange={setSourceId}>
              <SelectTrigger>
                <SelectValue placeholder="Select source device" />
              </SelectTrigger>
              <SelectContent>
                {configuredDevices.map((device) => (
                  <SelectItem key={device.id} value={device.id}>
                    {device.icon} {device.name} ({device.ip})
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="grid gap-2">
            <Label htmlFor="dest">Destination Device</Label>
            <Select value={destId} onValueChange={setDestId}>
              <SelectTrigger>
                <SelectValue placeholder="Select destination device" />
              </SelectTrigger>
              <SelectContent>
                {configuredDevices
                  .filter((d) => d.id !== sourceId)
                  .map((device) => (
                    <SelectItem key={device.id} value={device.id}>
                      {device.icon} {device.name} ({device.ip})
                    </SelectItem>
                  ))}
              </SelectContent>
            </Select>
          </div>

          <div className="grid gap-2">
            <Label htmlFor="protocol">Protocol</Label>
            <Select value={protocol} onValueChange={setProtocol}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {protocols.map((p) => (
                  <SelectItem key={p.value} value={p.value}>
                    <span
                      className="inline-block w-3 h-3 rounded-full mr-2"
                      style={{ backgroundColor: p.color }}
                    />
                    {p.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          {configuredDevices.length === 0 && (
            <div className="text-sm text-muted-foreground p-4 bg-muted rounded-md">
              No devices with IP addresses configured. Please configure device
              IPs first.
            </div>
          )}

          {sourceId && destId && sourceId === destId && (
            <div className="text-sm text-destructive p-4 bg-destructive/10 rounded-md">
              Source and destination must be different devices
            </div>
          )}
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button
            onClick={handleSend}
            disabled={!sourceId || !destId || sourceId === destId}
          >
            Send Packet
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
