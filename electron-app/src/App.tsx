import { useState } from 'react'
import Toolbar from './components/Toolbar'
import Sidebar from './components/Sidebar'
import Canvas from './components/Canvas'
import Console from './components/Console'

function App() {
  const [mode, setMode] = useState<'move' | 'connect' | 'delete'>('move')
  const [consoleOpen, setConsoleOpen] = useState(true)
  const [consoleMessages, setConsoleMessages] = useState<any[]>([])

  const addConsoleMessage = (message: any) => {
    setConsoleMessages(prev => [...prev, { ...message, timestamp: new Date() }])
  }

  return (
    <div className="h-screen w-screen flex flex-col bg-background dark">
      <Toolbar
        mode={mode}
        onModeChange={setMode}
        onConsoleToggle={() => setConsoleOpen(!consoleOpen)}
      />

      <div className="flex flex-1 overflow-hidden">
        <Sidebar onAddDevice={(device) => addConsoleMessage({
          type: 'info',
          text: `Added ${device.type}`
        })} />

        <div className="flex flex-col flex-1">
          <Canvas
            mode={mode}
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
    </div>
  )
}

export default App
