import { useState, useRef, useEffect } from 'react'
import Toolbar from './components/Toolbar'
import Sidebar from './components/Sidebar'
import Canvas from './components/Canvas'
import Console from './components/Console'
import DeviceConfigDialog from './components/DeviceConfigDialog'
import { Device, Connection, ConsoleMessage } from './types/network'
import { NetworkSimulator } from './lib/network-simulator'
import { createDevice } from './lib/device-factory'

function App() {
  const [mode, setMode] = useState<'move' | 'connect' | 'delete'>('move')
  const [consoleOpen, setConsoleOpen] = useState(true)
  const [consoleMessages, setConsoleMessages] = useState<ConsoleMessage[]>([])
  const [devices, setDevices] = useState<Device[]>([])
  const [connections, setConnections] = useState<Connection[]>([])
  const [selectedDevice, setSelectedDevice] = useState<Device | null>(null)
  const [configDialogOpen, setConfigDialogOpen] = useState(false)
  const [snapToGrid, setSnapToGrid] = useState(false)
  const canvasRef = useRef<HTMLCanvasElement>(null)

  const simulatorRef = useRef<NetworkSimulator>(new NetworkSimulator())

  useEffect(() => {
    simulatorRef.current.setMessageCallback(addConsoleMessage)
  }, [])

  const addConsoleMessage = (message: ConsoleMessage) => {
    setConsoleMessages(prev => [...prev, { ...message, timestamp: new Date() }])
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

    const newDevice = createDevice(
      deviceType.id,
      deviceType.name,
      deviceType.icon,
      x,
      y
    )

    setDevices(prev => [...prev, newDevice])
    simulatorRef.current.addDevice(newDevice)
    addConsoleMessage({
      type: 'success',
      text: `Added ${newDevice.name}`,
      timestamp: new Date(),
    })
  }

  const handleUpdateDevice = (device: Device) => {
    setDevices(prev => prev.map(d => d.id === device.id ? device : d))
    simulatorRef.current.addDevice(device) // Update in simulator
    addConsoleMessage({
      type: 'info',
      text: `Updated ${device.name}`,
      timestamp: new Date(),
    })
  }

  const handleDeleteDevice = (deviceId: string) => {
    const device = devices.find(d => d.id === deviceId)
    if (device) {
      setDevices(prev => prev.filter(d => d.id !== deviceId))
      setConnections(prev => prev.filter(c => c.from !== deviceId && c.to !== deviceId))
      simulatorRef.current.removeDevice(deviceId)
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
    setConnections(prev => [...prev, newConnection])
    simulatorRef.current.addConnection(newConnection)
  }

  const handleDeleteConnection = (connectionId: string) => {
    setConnections(prev => prev.filter(c => c.id !== connectionId))
    simulatorRef.current.removeConnection(connectionId)
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
            onDeviceMove={handleUpdateDevice}
            onDeviceDelete={handleDeleteDevice}
            onDeviceDoubleClick={handleDeviceDoubleClick}
            onConnectionAdd={handleAddConnection}
            onConnectionDelete={handleDeleteConnection}
            onMessage={addConsoleMessage}
          />

          {consoleOpen && (
            <Console
              messages={consoleMessages}
              onClear={() => setConsoleMessages([])}
            />
          )}
        </div>
      </div>

      <DeviceConfigDialog
        device={selectedDevice}
        open={configDialogOpen}
        onOpenChange={setConfigDialogOpen}
        onSave={handleUpdateDevice}
      />
    </div>
  )
}

export default App
