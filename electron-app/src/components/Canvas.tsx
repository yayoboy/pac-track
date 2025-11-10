import { useRef, useEffect, useState } from 'react'

interface CanvasProps {
  mode: 'move' | 'connect' | 'delete'
  onMessage: (message: any) => void
}

export default function Canvas({ mode, onMessage }: CanvasProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const [devices, setDevices] = useState<any[]>([])
  const [connections, setConnections] = useState<any[]>([])

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return

    const ctx = canvas.getContext('2d')
    if (!ctx) return

    // Set canvas size
    const resizeCanvas = () => {
      const container = canvas.parentElement
      if (container) {
        canvas.width = container.clientWidth
        canvas.height = container.clientHeight
      }
    }

    resizeCanvas()
    window.addEventListener('resize', resizeCanvas)

    // Draw loop
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
          ctx.strokeStyle = '#666'
          ctx.lineWidth = 2
          ctx.beginPath()
          ctx.moveTo(from.x, from.y)
          ctx.lineTo(to.x, to.y)
          ctx.stroke()
        }
      })

      // Draw devices
      devices.forEach((device) => {
        // Device background
        ctx.fillStyle = '#1e40af'
        ctx.fillRect(device.x - 30, device.y - 30, 60, 60)

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
      })
    }

    draw()

    return () => {
      window.removeEventListener('resize', resizeCanvas)
    }
  }, [devices, connections])

  const handleCanvasClick = (e: React.MouseEvent<HTMLCanvasElement>) => {
    const canvas = canvasRef.current
    if (!canvas) return

    const rect = canvas.getBoundingClientRect()
    const x = e.clientX - rect.left
    const y = e.clientY - rect.top

    onMessage({ type: 'info', text: `Canvas clicked at (${x}, ${y})` })
  }

  return (
    <div className="flex-1 relative bg-background overflow-hidden">
      <canvas
        ref={canvasRef}
        className="absolute inset-0 cursor-crosshair"
        onClick={handleCanvasClick}
      />

      <div className="absolute top-4 right-4 bg-card/80 backdrop-blur-sm p-3 rounded-lg border border-border">
        <div className="text-sm">
          <div className="font-medium mb-1">Mode: {mode}</div>
          <div className="text-xs text-muted-foreground">
            Devices: {devices.length}
          </div>
          <div className="text-xs text-muted-foreground">
            Connections: {connections.length}
          </div>
        </div>
      </div>
    </div>
  )
}
