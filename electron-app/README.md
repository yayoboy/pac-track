# Pac-Track Modern - Network Simulator

<div align="center">

![Version](https://img.shields.io/badge/version-2.0.0-blue.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)
![React](https://img.shields.io/badge/React-18.2-blue?logo=react)
![TypeScript](https://img.shields.io/badge/TypeScript-5.3-blue?logo=typescript)
![Vite](https://img.shields.io/badge/Vite-5.0-blue?logo=vite)

**Professional network topology simulator built with React, TypeScript, Vite, and shadcn/ui**

*Ready to be packaged as an Electron desktop app*

</div>

---

## ✨ Features

### 🎨 Modern UI
- **shadcn/ui Components** - Beautiful, accessible components built with Radix UI
- **Dark Mode** - Eye-friendly dark interface
- **Responsive Layout** - Flexible sidebar, canvas, and console panels
- **Smooth Animations** - Fluid transitions and interactions

### 🔧 Core Functionality
- **38+ Network Devices** - Routers, switches, servers, IoT devices, and more
- **Visual Topology Builder** - Drag-and-drop interface with grid snapping
- **Network Simulation** - DHCP, packet routing, protocol simulation
- **Device Configuration** - IP addressing, routing tables, DHCP server
- **Real-time Console** - Monitor network events and traffic
- **Save/Load Topologies** - JSON-based topology persistence
- **Export to PNG** - Save network diagrams as images

### 🚀 Modern Web App
- **Fast Development** - Vite-powered with instant HMR
- **Modern Stack** - React 18 + TypeScript 5
- **Beautiful UI** - shadcn/ui components with Tailwind CSS
- **Electron Ready** - Easy to package as desktop app (see below)

---

## 📦 Installation

### Prerequisites
- Node.js 18+ (with npm)
- Git (optional, for cloning)

### Setup

```bash
# Clone or navigate to the electron-app directory
cd electron-app

# Install dependencies
npm install

# Start development server
npm run dev
```

The application will open in your default browser at `http://localhost:5173` with hot-reload enabled.

---

## 🛠️ Development

### Available Scripts

```bash
# Development mode (with hot reload)
npm run dev

# Build for production
npm run build

# Preview production build
npm run preview
```

### Converting to Electron Desktop App

To package this as an Electron desktop application:

1. Install Electron dependencies:
```bash
npm install -D electron electron-builder vite-plugin-electron vite-plugin-electron-renderer concurrently wait-on
```

2. The Electron main and preload scripts are already included in the `electron/` folder

3. Update `package.json` scripts to include Electron commands

4. Run with Electron:
```bash
npm run electron:dev
```

### Project Structure

```
electron-app/
├── electron/              # Electron main and preload scripts
│   ├── main.ts           # Main process
│   └── preload.ts        # Preload script
├── src/
│   ├── components/       # React components
│   │   ├── ui/          # shadcn/ui components
│   │   ├── Canvas.tsx   # Network topology canvas
│   │   ├── Console.tsx  # Log console
│   │   ├── Sidebar.tsx  # Device palette
│   │   └── Toolbar.tsx  # Main toolbar
│   ├── lib/             # Utilities and core logic
│   │   ├── network-simulator.ts  # Network simulation engine
│   │   ├── device-factory.ts    # Device creation
│   │   └── utils.ts     # Helper functions
│   ├── types/           # TypeScript type definitions
│   │   └── network.ts   # Network types
│   ├── App.tsx          # Main app component
│   ├── main.tsx         # React entry point
│   └── index.css        # Global styles
├── index.html           # HTML entry point
├── package.json         # Dependencies and scripts
├── tsconfig.json        # TypeScript configuration
├── vite.config.ts       # Vite configuration
├── tailwind.config.js   # Tailwind CSS configuration
└── README.md           # This file
```

---

## 🎮 Usage

### Basic Workflow

1. **Add Devices**
   - Click device buttons in the left sidebar
   - Devices appear on the canvas

2. **Connect Devices**
   - Click the "Connect" button (🔌) in toolbar
   - Click first device, then second device
   - Connection appears as a line

3. **Configure Devices**
   - Double-click any device (future feature)
   - Set IP address, subnet, gateway
   - Enable DHCP for routers

4. **Move Devices**
   - Click "Move" button (📍)
   - Drag devices to reposition

5. **Delete Items**
   - Click "Delete" button (🗑️)
   - Click device or connection to remove

6. **View Console**
   - Click "Console" button (💻) to toggle
   - See network events and messages

---

## 🎨 Technology Stack

- **Frontend**: React 18 + TypeScript 5
- **Build Tool**: Vite 5
- **UI Components**: shadcn/ui (Radix UI)
- **Styling**: Tailwind CSS 3
- **Icons**: Lucide React
- **Canvas**: HTML5 Canvas API

---

## 🔮 Roadmap

- [ ] Device configuration dialogs
- [ ] Interactive packet sending
- [ ] Continuous traffic simulation
- [ ] DHCP server implementation
- [ ] Routing table management
- [ ] VLAN support
- [ ] Network latency simulation
- [ ] Packet capture (PCAP)
- [ ] Custom device types
- [ ] Multi-tab topology management

---

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

---

## 📝 License

This project is licensed under the MIT License.

---

## 🙏 Acknowledgments

- Original Pac-Track web app
- shadcn/ui for the beautiful component library
- Electron for making desktop apps easy
- Radix UI for accessible primitives

---

<div align="center">

**Made with ❤️ for the networking community**

⭐ Star this repo if you find it useful!

</div>
