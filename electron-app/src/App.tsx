import { useState, useRef, useEffect, useCallback } from 'react'
import Toolbar from './components/Toolbar'
import Sidebar from './components/Sidebar'
import Canvas from './components/Canvas'
import Console from './components/Console'
import DeviceConfigDialog from './components/DeviceConfigDialog'
import PacketSimulationDialog from './components/PacketSimulationDialog'
import { Device, Connection, ConsoleMessage, AnimatedPacket, HistoryEntry } from './types/network'
import { NetworkSimulator } from './lib/network-simulator'
import { createDevice } from './lib/device-factory'

const PROTOCOL_COLORS: Record<string, string> = {
  ICMP: '#22c55e',
  TCP: '#3b82f6',
  UDP: '#a855f7',
  ARP: '#f59e0b',
  DNS: '#ec4899',
}

function App() {
  // Mode & UI State
  const [mode, setMode] = useState<'move' | 'connect' | 'delete'>('move')
  const [consoleOpen, setConsoleOpen] = useState(true)
  const [snapToGrid, setSnapToGrid] = useState(false)

  // Network State
  const [devices, setDevices] = useState<Device[]>([])
  const [connections, setConnections] = useState<Connection[]>([])
  const [consoleMessages, setConsoleMessages] = useState<ConsoleMessage[]>([])

  // Dialogs
  const [selectedDevice, setSelectedDevice] = useState<Device | null>(null)
  const [configDialogOpen, setConfigDialogOpen] = useState(false)
  const [packetDialogOpen, setPacketDialogOpen] = useState(false)

  // Packet Animation
  const [animatedPackets, setAnimatedPackets] = useState<AnimatedPacket[]>([])

  // Continuous Traffic
  const [continuousTraffic, setContinuousTraffic] = useState(false)
  const trafficIntervalRef = useRef<NodeJS.Timeout | null>(null)

  // Undo/Redo
  const [history, setHistory] = useState<HistoryEntry[]>([])
  const [historyIndex, setHistoryIndex] = useState(-1)

  // Refs
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const simulatorRef = useRef<NetworkSimulator>(new NetworkSimulator())

  useEffect(() => {
    simulatorRef.current.setMessageCallback(addConsoleMessage)
  }, [])

  // Packet Animation Loop
  useEffect(() => {
    if (animatedPackets.length === 0) return

    const animationInterval = setInterval(() => {
      setAnimatedPackets((packets) => {
        return packets
          .map((packet) => {
            const newProgress = packet.progress + 0.02

            if (newProgress >= 1) {
              // Move to next segment
              if (packet.currentSegment < packet.path.length - 2) {
                return {
                  ...packet,
                  currentSegment: packet.currentSegment + 1,
                  progress: 0,
                }
              } else {
                // Packet completed
                return null
              }
            }

            return { ...packet, progress: newProgress }
          })
          .filter((p): p is AnimatedPacket => p !== null)
      })
    }, 16) // ~60fps

    return () => clearInterval(animationInterval)
  }, [animatedPackets])

  // Continuous Traffic Loop
  useEffect(() => {
    if (continuousTraffic && devices.length >= 2) {
      trafficIntervalRef.current = setInterval(() => {
        const configuredDevices = devices.filter((d) => d.ip)
        if (configuredDevices.length >= 2) {
          const source =
            configuredDevices[
              Math.floor(Math.random() * configuredDevices.length)
            ]
          let dest =
            configuredDevices[
              Math.floor(Math.random() * configuredDevices.length)
            ]

          // Ensure different devices
          let attempts = 0
          while (dest.id === source.id && attempts < 10) {
            dest =
              configuredDevices[
                Math.floor(Math.random() * configuredDevices.length)
              ]
            attempts++
          }

          if (dest.id !== source.id) {
            const protocols = ['ICMP', 'TCP', 'UDP', 'DNS']
            const protocol = protocols[Math.floor(Math.random() * protocols.length)]
            handleSendPacket(source.id, dest.id, protocol)
          }
        }
      }, 2000) // Every 2 seconds
    } else {
      if (trafficIntervalRef.current) {
        clearInterval(trafficIntervalRef.current)
        trafficIntervalRef.current = null
      }
    }

    return () => {
      if (trafficIntervalRef.current) {
        clearInterval(trafficIntervalRef.current)
      }
    }
  }, [continuousTraffic, devices])

  // Keyboard Shortcuts
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      // Ignore if typing in input
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) {
        return
      }

      switch (e.key.toLowerCase()) {
        case 'm':
          setMode('move')
          break
        case 'c':
          setMode('connect')
          break
        case 'd':
          setMode('delete')
          break
        case 'g':
          setSnapToGrid((prev) => !prev)
          break
        case ' ':
          e.preventDefault()
          setConsoleOpen((prev) => !prev)
          break
        case 'escape':
          // Cancel operations
          setConfigDialogOpen(false)
          setPacketDialogOpen(false)
          break
      }

      // Ctrl/Cmd shortcuts
      if (e.ctrlKey || e.metaKey) {
        switch (e.key.toLowerCase()) {
          case 's':
            e.preventDefault()
            handleSaveTopology()
            break
          case 'o':
            e.preventDefault()
            handleLoadTopology()
            break
          case 'e':
            e.preventDefault()
            handleExportPNG()
            break
          case 'z':
            e.preventDefault()
            if (e.shiftKey) {
              handleRedo()
            } else {
              handleUndo()
            }
            break
          case 'y':
            e.preventDefault()
            handleRedo()
            break
        }
      }
    }

    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [])

  const addConsoleMessage = useCallback((message: ConsoleMessage) => {
    setConsoleMessages((prev) => [...prev, { ...message, timestamp: new Date() }])
  }, [])

  const addToHistory = useCallback((entry: Omit<HistoryEntry, 'timestamp'>) => {
    const newEntry: HistoryEntry = { ...entry, timestamp: Date.now() }
    setHistory((prev) => [...prev.slice(0, historyIndex + 1), newEntry])
    setHistoryIndex((prev) => prev + 1)
  }, [historyIndex])

  const handleUndo = () => {
    if (historyIndex < 0) return

    const entry = history[historyIndex]
    // Implement undo logic based on entry type
    setHistoryIndex((prev) => prev - 1)
    addConsoleMessage({
      type: 'info',
      text: 'Undo: ' + entry.type,
      timestamp: new Date(),
    })
  }

  const handleRedo = () => {
    if (historyIndex >= history.length - 1) return

    const entry = history[historyIndex + 1]
    // Implement redo logic
    setHistoryIndex((prev) => prev + 1)
    addConsoleMessage({
      type: 'info',
      text: 'Redo: ' + entry.type,
      timestamp: new Date(),
    })
  }

  const handleAddDevice = (deviceType: any) => {
    const canvasCenter = { x: 400, y: 300 }
    const randomOffset = () => Math.random() * 200 - 100

    let x = canvasCenter.x + randomOffset()
    let y = canvasCenter.y + randomOffset()

    if (snapToGrid) {
      x = Math.round(x / 50) * 50
      y = Math.round(y / 50) * 50
    }

    const newDevice = createDevice(deviceType.id, deviceType.name, deviceType.icon, x, y)

    setDevices((prev) => [...prev, newDevice])
    simulatorRef.current.addDevice(newDevice)
    addToHistory({ type: 'add_device', data: newDevice })
    addConsoleMessage({
      type: 'success',
      text: `Added ${newDevice.name}`,
      timestamp: new Date(),
    })
  }

  const handleUpdateDevice = (device: Device) => {
    setDevices((prev) => prev.map((d) => (d.id === device.id ? device : d)))
    simulatorRef.current.addDevice(device)
    addToHistory({ type: 'update_device', data: { old: devices.find(d => d.id === device.id), new: device } })
    addConsoleMessage({
      type: 'info',
      text: `Updated ${device.name}`,
      timestamp: new Date(),
    })
  }

  const handleDeleteDevice = (deviceId: string) => {
    const device = devices.find((d) => d.id === deviceId)
    if (device) {
      setDevices((prev) => prev.filter((d) => d.id !== deviceId))
      setConnections((prev) =>
        prev.filter((c) => c.from !== deviceId && c.to !== deviceId)
      )
      simulatorRef.current.removeDevice(deviceId)
      addToHistory({ type: 'delete_device', data: device })
      addConsoleMessage({
        type: 'warning',
        text: `Deleted ${device.name}`,
        timestamp: new Date(),
      })
    }
  }

  const handleAddConnection = (from: string, to: string) => {
    const newConnection: Connection = {
      id: `conn-${Date.now()}`,
      from,
      to,
    }
    setConnections((prev) => [...prev, newConnection])
    simulatorRef.current.addConnection(newConnection)
    addToHistory({ type: 'add_connection', data: newConnection })
  }

  const handleDeleteConnection = (connectionId: string) => {
    const conn = connections.find(c => c.id === connectionId)
    setConnections((prev) => prev.filter((c) => c.id !== connectionId))
    simulatorRef.current.removeConnection(connectionId)
    addToHistory({ type: 'delete_connection', data: conn })
    addConsoleMessage({
      type: 'warning',
      text: 'Connection removed',
      timestamp: new Date(),
    })
  }

  const handleDeviceDoubleClick = (device: Device) => {
    setSelectedDevice(device)
    setConfigDialogOpen(true)
  }

  const handleSendPacket = (sourceId: string, destId: string, protocol: string) => {
    const path = simulatorRef.current.findPath(sourceId, destId)

    if (!path) {
      const source = devices.find(d => d.id === sourceId)
      const dest = devices.find(d => d.id === destId)
      addConsoleMessage({
        type: 'error',
        text: `No path found from ${source?.name} to ${dest?.name}`,
        timestamp: new Date(),
      })
      return
    }

    const source = devices.find(d => d.id === sourceId)
    const dest = devices.find(d => d.id === destId)

    const newPacket: AnimatedPacket = {
      id: `packet-${Date.now()}`,
      protocol: protocol as any,
      path,
      currentSegment: 0,
      progress: 0,
      color: PROTOCOL_COLORS[protocol] || '#fff',
    }

    setAnimatedPackets((prev) => [...prev, newPacket])

    addConsoleMessage({
      type: 'packet',
      text: `${protocol}: ${source?.name} → ${dest?.name} (${path.length - 1} hops)`,
      timestamp: new Date(),
    })
  }

  const handleAssignDHCPIPs = (routerId: string) => {
    const router = devices.find((d) => d.id === routerId)
    if (!router || !router.dhcpEnabled) return

    const connected = simulatorRef.current.getConnectedDevices(routerId)
    let assigned = 0

    connected.forEach((device) => {
      if (!device.ip) {
        const ip = simulatorRef.current.assignDHCPAddress(routerId, device.id)
        if (ip) {
          setDevices((prev) =>
            prev.map((d) => (d.id === device.id ? { ...d, ip, subnet: router.subnet, gateway: router.ip } : d))
          )
          assigned++
        }
      }
    })

    if (assigned > 0) {
      addConsoleMessage({
        type: 'success',
        text: `DHCP: Assigned ${assigned} IP address${assigned > 1 ? 'es' : ''}`,
        timestamp: new Date(),
      })
    }
  }

  const handleSaveTopology = () => {
    const json = simulatorRef.current.exportTopology()
    const blob = new Blob([json], { type: 'application/json' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = `topology-${Date.now()}.json`
    a.click()
    URL.revokeObjectURL(url)
    addConsoleMessage({
      type: 'success',
      text: 'Topology saved',
      timestamp: new Date(),
    })
  }

  const handleLoadTopology = () => {
    const input = document.createElement('input')
    input.type = 'file'
    input.accept = '.json'
    input.onchange = (e: any) => {
      const file = e.target.files[0]
      if (file) {
        const reader = new FileReader()
        reader.onload = (e: any) => {
          const json = e.target.result
          if (simulatorRef.current.importTopology(json)) {
            const topology = JSON.parse(json)
            setDevices(topology.devices)
            setConnections(topology.connections)
          }
        }
        reader.readAsText(file)
      }
    }
    input.click()
  }

  const handleExportPNG = () => {
    const canvas = canvasRef.current
    if (!canvas) return

    canvas.toBlob((blob) => {
      if (blob) {
        const url = URL.createObjectURL(blob)
        const a = document.createElement('a')
        a.href = url
        a.download = `topology-${Date.now()}.png`
        a.click()
        URL.revokeObjectURL(url)
        addConsoleMessage({
          type: 'success',
          text: 'Topology exported as PNG',
          timestamp: new Date(),
        })
      }
    })
  }

  return (
    <div className="h-screen w-screen flex flex-col bg-background dark">
      <Toolbar
        mode={mode}
        onModeChange={setMode}
        onConsoleToggle={() => setConsoleOpen(!consoleOpen)}
        snapToGrid={snapToGrid}
        onSnapToGridToggle={() => setSnapToGrid(!snapToGrid)}
        onSave={handleSaveTopology}
        onLoad={handleLoadTopology}
        onExport={handleExportPNG}
        onSendPacket={() => setPacketDialogOpen(true)}
        continuousTraffic={continuousTraffic}
        onToggleContinuousTraffic={() => setContinuousTraffic(!continuousTraffic)}
      />

      <div className="flex flex-1 overflow-hidden">
        <Sidebar onAddDevice={handleAddDevice} />

        <div className="flex flex-col flex-1">
          <Canvas
            ref={canvasRef}
            mode={mode}
            devices={devices}
            connections={connections}
            snapToGrid={snapToGrid}
            animatedPackets={animatedPackets}
            onDeviceMove={handleUpdateDevice}
            onDeviceDelete={handleDeleteDevice}
            onDeviceDoubleClick={handleDeviceDoubleClick}
            onConnectionAdd={handleAddConnection}
            onConnectionDelete={handleDeleteConnection}
            onMessage={addConsoleMessage}
          />

          {consoleOpen && (
            <Console messages={consoleMessages} onClear={() => setConsoleMessages([])} />
          )}
        </div>
      </div>

      <DeviceConfigDialog
        device={selectedDevice}
        open={configDialogOpen}
        onOpenChange={setConfigDialogOpen}
        onSave={handleUpdateDevice}
        onAssignDHCPIPs={selectedDevice && selectedDevice.dhcpEnabled ? () => handleAssignDHCPIPs(selectedDevice.id) : undefined}
      />

      <PacketSimulationDialog
        open={packetDialogOpen}
        onOpenChange={setPacketDialogOpen}
        devices={devices}
        onSendPacket={handleSendPacket}
      />
    </div>
  )
}

export default App
