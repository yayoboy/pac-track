import { useRef, useEffect } from 'react'
import { ScrollArea } from './ui/scroll-area'
import { Button } from './ui/button'
import { Trash2 } from 'lucide-react'

interface ConsoleMessage {
  type: 'info' | 'success' | 'warning' | 'error' | 'packet'
  text: string
  timestamp: Date
}

interface ConsoleProps {
  messages: ConsoleMessage[]
  onClear: () => void
}

export default function Console({ messages, onClear }: ConsoleProps) {
  const scrollRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight
    }
  }, [messages])

  const getMessageColor = (type: string) => {
    switch (type) {
      case 'success':
        return 'text-green-400'
      case 'warning':
        return 'text-yellow-400'
      case 'error':
        return 'text-red-400'
      case 'packet':
        return 'text-blue-400'
      default:
        return 'text-muted-foreground'
    }
  }

  const formatTime = (date: Date) => {
    return date.toLocaleTimeString('it-IT', {
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
    })
  }

  return (
    <div className="h-64 border-t border-border bg-card flex flex-col">
      <div className="flex items-center justify-between px-4 py-2 border-b border-border">
        <h3 className="font-semibold text-sm">Console</h3>
        <div className="flex gap-2">
          <Button
            variant="ghost"
            size="sm"
            onClick={onClear}
            className="h-7 gap-1"
          >
            <Trash2 className="h-3 w-3" />
            Clear
          </Button>
        </div>
      </div>

      <ScrollArea className="flex-1">
        <div ref={scrollRef} className="p-4 space-y-1 font-mono text-xs">
          {messages.length === 0 ? (
            <div className="text-muted-foreground text-center py-8">
              Console output will appear here...
            </div>
          ) : (
            messages.map((msg, idx) => (
              <div key={idx} className="flex gap-2">
                <span className="text-muted-foreground shrink-0">
                  [{formatTime(msg.timestamp)}]
                </span>
                <span className={getMessageColor(msg.type)}>{msg.text}</span>
              </div>
            ))
          )}
        </div>
      </ScrollArea>
    </div>
  )
}
