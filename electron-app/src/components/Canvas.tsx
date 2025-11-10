import { useRef, useEffect, useState, useCallback, forwardRef, useImperativeHandle } from 'react'
import { Device, Connection, ConsoleMessage, AnimatedPacket } from '@/types/network'
import { getDeviceColor } from '@/lib/device-factory'

interface CanvasProps {
  mode: 'move' | 'connect' | 'delete'
  devices: Device[]
  connections: Connection[]
  snapToGrid: boolean
  animatedPackets?: AnimatedPacket[]
  onDeviceMove: (device: Device) => void
  onDeviceDelete: (deviceId: string) => void
  onDeviceDoubleClick: (device: Device) => void
  onConnectionAdd: (from: string, to: string) => void
  onConnectionDelete: (connectionId: string) => void
  onMessage: (message: ConsoleMessage) => void
}

const Canvas = forwardRef<HTMLCanvasElement, CanvasProps>(({
  mode,
  devices,
  connections,
  snapToGrid,
  animatedPackets = [],
  onDeviceMove,
  onDeviceDelete,
  onDeviceDoubleClick,
  onConnectionAdd,
  onConnectionDelete,
}, ref) => {
  const canvasRef = useRef<HTMLCanvasElement>(null)

  useImperativeHandle(ref, () => canvasRef.current!)
  const [draggedDevice, setDraggedDevice] = useState<Device | null>(null)
  const [dragOffset, setDragOffset] = useState({ x: 0, y: 0 })
  const [connectFrom, setConnectFrom] = useState<string | null>(null)
  const [hoveredDevice, setHoveredDevice] = useState<string | null>(null)
  const [hoveredConnection, setHoveredConnection] = useState<string | null>(null)
  const lastClickTime = useRef(0)
  const lastClickedDevice = useRef<string | null>(null)

  const getDeviceAtPosition = useCallback(
    (x: number, y: number): Device | null => {
      for (let i = devices.length - 1; i >= 0; i--) {
        const device = devices[i]
        const dx = x - device.x
        const dy = y - device.y
        if (Math.abs(dx) < 30 && Math.abs(dy) < 30) {
          return device
        }
      }
      return null
    },
    [devices]
  )

  const getConnectionAtPosition = useCallback(
    (x: number, y: number): Connection | null => {
      for (const conn of connections) {
        const from = devices.find((d) => d.id === conn.from)
        const to = devices.find((d) => d.id === conn.to)
        if (from && to) {
          const dist = distanceToLine(x, y, from.x, from.y, to.x, to.y)
          if (dist < 10) {
            return conn
          }
        }
      }
      return null
    },
    [connections, devices]
  )

  const distanceToLine = (
    px: number,
    py: number,
    x1: number,
    y1: number,
    x2: number,
    y2: number
  ): number => {
    const A = px - x1
    const B = py - y1
    const C = x2 - x1
    const D = y2 - y1

    const dot = A * C + B * D
    const lenSq = C * C + D * D
    let param = -1

    if (lenSq !== 0) param = dot / lenSq

    let xx, yy

    if (param < 0) {
      xx = x1
      yy = y1
    } else if (param > 1) {
      xx = x2
      yy = y2
    } else {
      xx = x1 + param * C
      yy = y1 + param * D
    }

    const dx = px - xx
    const dy = py - yy
    return Math.sqrt(dx * dx + dy * dy)
  }

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return

    const ctx = canvas.getContext('2d')
    if (!ctx) return

    const resizeCanvas = () => {
      const container = canvas.parentElement
      if (container) {
        canvas.width = container.clientWidth
        canvas.height = container.clientHeight
      }
    }

    resizeCanvas()
    window.addEventListener('resize', resizeCanvas)

    const draw = () => {
      ctx.clearRect(0, 0, canvas.width, canvas.height)

      // Draw grid
      ctx.strokeStyle = '#2a2a2a'
      ctx.lineWidth = 1
      for (let x = 0; x < canvas.width; x += 50) {
        ctx.beginPath()
        ctx.moveTo(x, 0)
        ctx.lineTo(x, canvas.height)
        ctx.stroke()
      }
      for (let y = 0; y < canvas.height; y += 50) {
        ctx.beginPath()
        ctx.moveTo(0, y)
        ctx.lineTo(canvas.width, y)
        ctx.stroke()
      }

      // Draw connections
      connections.forEach((conn) => {
        const from = devices.find((d) => d.id === conn.from)
        const to = devices.find((d) => d.id === conn.to)
        if (from && to) {
          const isHovered = hoveredConnection === conn.id
          ctx.strokeStyle = isHovered ? '#3b82f6' : '#666'
          ctx.lineWidth = isHovered ? 3 : 2
          ctx.beginPath()
          ctx.moveTo(from.x, from.y)
          ctx.lineTo(to.x, to.y)
          ctx.stroke()
        }
      })

      // Draw connection preview in connect mode
      if (mode === 'connect' && connectFrom && hoveredDevice !== connectFrom) {
        const from = devices.find((d) => d.id === connectFrom)
        const mousePos = hoveredDevice
          ? devices.find((d) => d.id === hoveredDevice)
          : null

        if (from) {
          ctx.strokeStyle = '#3b82f6'
          ctx.lineWidth = 2
          ctx.setLineDash([5, 5])
          ctx.beginPath()
          ctx.moveTo(from.x, from.y)
          if (mousePos) {
            ctx.lineTo(mousePos.x, mousePos.y)
          }
          ctx.stroke()
          ctx.setLineDash([])
        }
      }

      // Draw devices
      devices.forEach((device) => {
        const isHovered = hoveredDevice === device.id
        const isConnectFrom = connectFrom === device.id

        // Device background
        ctx.fillStyle = isConnectFrom
          ? '#3b82f6'
          : isHovered
          ? getDeviceColor(device.type)
          : getDeviceColor(device.type)
        ctx.shadowColor = isHovered || isConnectFrom ? '#3b82f6' : 'transparent'
        ctx.shadowBlur = isHovered || isConnectFrom ? 10 : 0

        ctx.fillRect(device.x - 30, device.y - 30, 60, 60)
        ctx.shadowBlur = 0

        // Device border
        if (isHovered || isConnectFrom) {
          ctx.strokeStyle = '#3b82f6'
          ctx.lineWidth = 2
          ctx.strokeRect(device.x - 30, device.y - 30, 60, 60)
        }

        // Device icon (emoji)
        ctx.font = '32px Arial'
        ctx.textAlign = 'center'
        ctx.textBaseline = 'middle'
        ctx.fillStyle = '#fff'
        ctx.fillText(device.icon, device.x, device.y)

        // Device label
        ctx.font = '12px Arial'
        ctx.fillStyle = '#fff'
        ctx.fillText(device.name, device.x, device.y + 45)

        // IP label
        if (device.ip) {
          ctx.font = '10px monospace'
          ctx.fillStyle = '#aaa'
          ctx.fillText(device.ip, device.x, device.y + 58)
        }
      })

      // Draw animated packets
      animatedPackets.forEach((packet) => {
        if (packet.currentSegment >= packet.path.length - 1) return

        const fromId = packet.path[packet.currentSegment]
        const toId = packet.path[packet.currentSegment + 1]
        const from = devices.find((d) => d.id === fromId)
        const to = devices.find((d) => d.id === toId)

        if (from && to) {
          const x = from.x + (to.x - from.x) * packet.progress
          const y = from.y + (to.y - from.y) * packet.progress

          // Draw packet circle
          ctx.fillStyle = packet.color
          ctx.shadowColor = packet.color
          ctx.shadowBlur = 10
          ctx.beginPath()
          ctx.arc(x, y, 8, 0, Math.PI * 2)
          ctx.fill()
          ctx.shadowBlur = 0

          // Draw protocol label
          ctx.font = 'bold 10px Arial'
          ctx.fillStyle = '#fff'
          ctx.textAlign = 'center'
          ctx.textBaseline = 'middle'
          ctx.fillText(packet.protocol, x, y)
        }
      })

      // Draw mode indicator
      const modeText = mode.toUpperCase()
      const modeColor =
        mode === 'delete' ? '#ef4444' : mode === 'connect' ? '#3b82f6' : '#22c55e'
      ctx.font = 'bold 14px Arial'
      ctx.fillStyle = modeColor
      ctx.textAlign = 'right'
      ctx.textBaseline = 'top'
      ctx.fillText(`Mode: ${modeText}`, canvas.width - 20, 20)
    }

    draw()

    return () => {
      window.removeEventListener('resize', resizeCanvas)
    }
  }, [devices, connections, hoveredDevice, hoveredConnection, connectFrom, mode, animatedPackets])

  const handleMouseDown = (e: React.MouseEvent<HTMLCanvasElement>) => {
    const canvas = canvasRef.current
    if (!canvas) return

    const rect = canvas.getBoundingClientRect()
    const x = e.clientX - rect.left
    const y = e.clientY - rect.top

    const device = getDeviceAtPosition(x, y)

    if (mode === 'move' && device) {
      setDraggedDevice(device)
      setDragOffset({ x: x - device.x, y: y - device.y })
    } else if (mode === 'connect' && device) {
      if (connectFrom === null) {
        setConnectFrom(device.id)
      } else if (connectFrom !== device.id) {
        onConnectionAdd(connectFrom, device.id)
        setConnectFrom(null)
      }
    } else if (mode === 'delete') {
      if (device) {
        onDeviceDelete(device.id)
      } else {
        const conn = getConnectionAtPosition(x, y)
        if (conn) {
          onConnectionDelete(conn.id)
        }
      }
    }
  }

  const handleMouseMove = (e: React.MouseEvent<HTMLCanvasElement>) => {
    const canvas = canvasRef.current
    if (!canvas) return

    const rect = canvas.getBoundingClientRect()
    const x = e.clientX - rect.left
    const y = e.clientY - rect.top

    // Update hovered device
    const device = getDeviceAtPosition(x, y)
    setHoveredDevice(device?.id || null)

    // Update hovered connection
    if (!device) {
      const conn = getConnectionAtPosition(x, y)
      setHoveredConnection(conn?.id || null)
    } else {
      setHoveredConnection(null)
    }

    // Handle dragging
    if (draggedDevice && mode === 'move') {
      let newX = x - dragOffset.x
      let newY = y - dragOffset.y

      if (snapToGrid) {
        newX = Math.round(newX / 50) * 50
        newY = Math.round(newY / 50) * 50
      }

      onDeviceMove({ ...draggedDevice, x: newX, y: newY })
    }
  }

  const handleMouseUp = () => {
    setDraggedDevice(null)
  }

  const handleDoubleClick = (e: React.MouseEvent<HTMLCanvasElement>) => {
    const canvas = canvasRef.current
    if (!canvas) return

    const rect = canvas.getBoundingClientRect()
    const x = e.clientX - rect.left
    const y = e.clientY - rect.top

    const device = getDeviceAtPosition(x, y)
    if (device) {
      onDeviceDoubleClick(device)
    }
  }

  const handleClick = (e: React.MouseEvent<HTMLCanvasElement>) => {
    const canvas = canvasRef.current
    if (!canvas) return

    const rect = canvas.getBoundingClientRect()
    const x = e.clientX - rect.left
    const y = e.clientY - rect.top

    const device = getDeviceAtPosition(x, y)

    // Detect double click
    const now = Date.now()
    if (
      device &&
      lastClickedDevice.current === device.id &&
      now - lastClickTime.current < 300
    ) {
      handleDoubleClick(e)
      lastClickTime.current = 0
      lastClickedDevice.current = null
      return
    }

    lastClickTime.current = now
    lastClickedDevice.current = device?.id || null
  }

  return (
    <div className="flex-1 relative bg-background overflow-hidden">
      <canvas
        ref={canvasRef}
        className={`absolute inset-0 ${
          mode === 'move'
            ? 'cursor-move'
            : mode === 'connect'
            ? 'cursor-crosshair'
            : 'cursor-not-allowed'
        }`}
        onMouseDown={handleMouseDown}
        onMouseMove={handleMouseMove}
        onMouseUp={handleMouseUp}
        onMouseLeave={handleMouseUp}
        onClick={handleClick}
      />

      <div className="absolute top-4 right-4 bg-card/80 backdrop-blur-sm p-3 rounded-lg border border-border">
        <div className="text-sm">
          <div className="font-medium mb-1">
            Mode: <span className="text-primary">{mode}</span>
          </div>
          <div className="text-xs text-muted-foreground">
            Devices: {devices.length}
          </div>
          <div className="text-xs text-muted-foreground">
            Connections: {connections.length}
          </div>
          {snapToGrid && (
            <div className="text-xs text-primary mt-1">Grid: ON</div>
          )}
        </div>
      </div>

      {mode === 'connect' && connectFrom && (
        <div className="absolute bottom-4 left-1/2 transform -translate-x-1/2 bg-primary/90 backdrop-blur-sm px-4 py-2 rounded-lg">
          <div className="text-sm text-white">
            Click on another device to connect
          </div>
        </div>
      )}
    </div>
  )
})

Canvas.displayName = 'Canvas'

export default Canvas
