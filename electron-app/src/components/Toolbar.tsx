import { Button } from './ui/button'
import { Separator } from './ui/separator'
import {
  Move,
  Cable,
  Trash2,
  Play,
  RotateCw,
  Save,
  FolderOpen,
  Download,
  Terminal,
  Grid3x3,
  BarChart3,
} from 'lucide-react'
import { TooltipProvider, Tooltip, TooltipTrigger, TooltipContent } from './ui/tooltip'

interface ToolbarProps {
  mode: 'move' | 'connect' | 'delete'
  onModeChange: (mode: 'move' | 'connect' | 'delete') => void
  onConsoleToggle: () => void
  onStatsToggle: () => void
  statsOpen: boolean
  snapToGrid: boolean
  onSnapToGridToggle: () => void
  onSave: () => void
  onLoad: () => void
  onExport: () => void
  onSendPacket?: () => void
  continuousTraffic?: boolean
  onToggleContinuousTraffic?: () => void
}

export default function Toolbar({
  mode,
  onModeChange,
  onConsoleToggle,
  onStatsToggle,
  statsOpen,
  snapToGrid,
  onSnapToGridToggle,
  onSave,
  onLoad,
  onExport,
  onSendPacket,
  continuousTraffic = false,
  onToggleContinuousTraffic,
}: ToolbarProps) {
  return (
    <TooltipProvider>
      <div className="h-14 bg-card border-b border-border flex items-center px-4 gap-2">
        <div className="text-lg font-bold text-primary">Pac-Track</div>

        <Separator orientation="vertical" className="h-8 mx-2" />

        <div className="flex gap-1">
          <Tooltip>
            <TooltipTrigger asChild>
              <Button
                variant={mode === 'move' ? 'default' : 'ghost'}
                size="icon"
                onClick={() => onModeChange('move')}
              >
                <Move className="h-4 w-4" />
              </Button>
            </TooltipTrigger>
            <TooltipContent>Move Mode</TooltipContent>
          </Tooltip>

          <Tooltip>
            <TooltipTrigger asChild>
              <Button
                variant={mode === 'connect' ? 'default' : 'ghost'}
                size="icon"
                onClick={() => onModeChange('connect')}
              >
                <Cable className="h-4 w-4" />
              </Button>
            </TooltipTrigger>
            <TooltipContent>Connect Mode</TooltipContent>
          </Tooltip>

          <Tooltip>
            <TooltipTrigger asChild>
              <Button
                variant={mode === 'delete' ? 'default' : 'ghost'}
                size="icon"
                onClick={() => onModeChange('delete')}
              >
                <Trash2 className="h-4 w-4" />
              </Button>
            </TooltipTrigger>
            <TooltipContent>Delete Mode</TooltipContent>
          </Tooltip>
        </div>

        <Separator orientation="vertical" className="h-8 mx-2" />

        <div className="flex gap-1">
          <Tooltip>
            <TooltipTrigger asChild>
              <Button variant="ghost" size="icon" onClick={onSendPacket}>
                <Play className="h-4 w-4" />
              </Button>
            </TooltipTrigger>
            <TooltipContent>Send Packet</TooltipContent>
          </Tooltip>

          <Tooltip>
            <TooltipTrigger asChild>
              <Button
                variant={continuousTraffic ? 'default' : 'ghost'}
                size="icon"
                onClick={onToggleContinuousTraffic}
              >
                <RotateCw className="h-4 w-4" />
              </Button>
            </TooltipTrigger>
            <TooltipContent>
              {continuousTraffic ? 'Stop' : 'Start'} Continuous Simulation
            </TooltipContent>
          </Tooltip>

          <Tooltip>
            <TooltipTrigger asChild>
              <Button
                variant={snapToGrid ? 'default' : 'ghost'}
                size="icon"
                onClick={onSnapToGridToggle}
              >
                <Grid3x3 className="h-4 w-4" />
              </Button>
            </TooltipTrigger>
            <TooltipContent>Snap to Grid</TooltipContent>
          </Tooltip>
        </div>

        <Separator orientation="vertical" className="h-8 mx-2" />

        <div className="flex gap-1">
          <Tooltip>
            <TooltipTrigger asChild>
              <Button variant="ghost" size="icon" onClick={onLoad}>
                <FolderOpen className="h-4 w-4" />
              </Button>
            </TooltipTrigger>
            <TooltipContent>Open Topology</TooltipContent>
          </Tooltip>

          <Tooltip>
            <TooltipTrigger asChild>
              <Button variant="ghost" size="icon" onClick={onSave}>
                <Save className="h-4 w-4" />
              </Button>
            </TooltipTrigger>
            <TooltipContent>Save Topology</TooltipContent>
          </Tooltip>

          <Tooltip>
            <TooltipTrigger asChild>
              <Button variant="ghost" size="icon" onClick={onExport}>
                <Download className="h-4 w-4" />
              </Button>
            </TooltipTrigger>
            <TooltipContent>Export as PNG</TooltipContent>
          </Tooltip>
        </div>

        <div className="flex-1" />

        <Tooltip>
          <TooltipTrigger asChild>
            <Button variant={statsOpen ? 'default' : 'ghost'} size="icon" onClick={onStatsToggle}>
              <BarChart3 className="h-4 w-4" />
            </Button>
          </TooltipTrigger>
          <TooltipContent>Toggle Statistics</TooltipContent>
        </Tooltip>

        <Tooltip>
          <TooltipTrigger asChild>
            <Button variant="ghost" size="icon" onClick={onConsoleToggle}>
              <Terminal className="h-4 w-4" />
            </Button>
          </TooltipTrigger>
          <TooltipContent>Toggle Console</TooltipContent>
        </Tooltip>
      </div>
    </TooltipProvider>
  )
}
