# Pac-Track Modern - macOS Setup Guide

## 🍎 macOS Optimization

This application is a **modern web app** optimized for macOS browsers. No code signing or notarization required!

## ✅ Prerequisites

- **macOS Version**: 10.15 (Catalina) or later
- **Node.js**: v18.0.0 or later
- **npm**: v9.0.0 or later
- **Browser**: Safari 14+, Chrome 90+, or Firefox 88+

## 🚀 Quick Start

### 1. Install Dependencies
```bash
cd electron-app
npm install
```

### 2. Run Development Server
```bash
npm run dev
```

The app will be available at:
- **Local**: http://localhost:5173/
- **Network**: http://[your-ip]:5173/ (accessible from other devices)

### 3. Build for Production
```bash
npm run build
```

Output will be in `dist/` folder.

## 🎹 Keyboard Shortcuts (macOS Optimized)

### Navigation
- `M` - Move mode
- `C` - Connect mode
- `D` - Delete mode
- `G` - Toggle snap to grid
- `S` - Toggle statistics panel
- `Space` - Toggle console
- `Escape` - Clear selection / Close dialogs

### Actions
- `⌘ + Z` or `Ctrl + Z` - Undo
- `⌘ + Shift + Z` or `Ctrl + Shift + Z` - Redo
- `⌘ + Y` or `Ctrl + Y` - Redo
- `⌘ + S` or `Ctrl + S` - Save topology
- `⌘ + O` or `Ctrl + O` - Load topology
- `⌘ + E` or `Ctrl + E` - Export as PNG
- `Delete` or `Backspace` - Delete selected devices

### Canvas
- `Mouse Wheel` - Zoom in/out (10% to 500%)
- `Middle Mouse Button` - Pan canvas
- `Shift + Click` - Multi-select devices

## 🎨 Features

### Core Functionality
- ✅ Professional network topology designer
- ✅ Drag & drop device placement
- ✅ Visual connection builder
- ✅ Real-time packet simulation
- ✅ DHCP server simulation

### Advanced Features
- ✅ **Undo/Redo** - Full history stack
- ✅ **Search & Filter** - Find devices instantly
- ✅ **Network Statistics** - Real-time metrics
- ✅ **Multi-Selection** - Select and manage multiple devices
- ✅ **Zoom & Pan** - Navigate large topologies

### Supported Devices
- 🖥️ **Computers**: PC, Laptop, Server
- 📱 **Mobile**: Smartphone, Tablet
- 🌐 **Networking**: Router, Switch, Access Point
- ☁️ **Cloud**: Cloud Server, Load Balancer
- 🔒 **Security**: Firewall
- 🖨️ **Peripherals**: Printer, IP Camera

### Network Protocols
- **ICMP** (Ping) - Green
- **TCP** (HTTP) - Blue
- **UDP** - Purple
- **ARP** - Orange
- **DNS** - Pink

## 🔧 Troubleshooting

### Port Already in Use
```bash
# Kill process on port 5173
lsof -ti:5173 | xargs kill -9

# Or use different port
npm run dev -- --port 3000
```

### Node Version Issues
```bash
# Check Node version
node --version

# Update if needed (using nvm)
nvm install 18
nvm use 18
```

### Build Errors
```bash
# Clean install
rm -rf node_modules package-lock.json
npm install
npm run build
```

## 🌐 Browser-Specific Notes

### Safari
- **Emoji Rendering**: Native macOS emojis look great!
- **Canvas Performance**: Excellent on Apple Silicon
- **File Download**: Works perfectly
- **Keyboard**: Cmd key supported

### Chrome
- **DevTools**: Best debugging experience
- **Performance**: Fastest rendering
- **Extensions**: Works with React DevTools

### Firefox
- **Privacy**: Best for privacy-conscious users
- **Compatibility**: 100% feature support

## 🚫 No Code Signing Required

This is a **web application**, not a native macOS app:
- ✅ No Gatekeeper issues
- ✅ No "unidentified developer" warnings
- ✅ No App Store submission needed
- ✅ No $99/year developer account required
- ✅ No notarization process
- ✅ Runs in any browser

## 📦 Deployment Options

### Option 1: Local Development
```bash
npm run dev
# Access at http://localhost:5173/
```

### Option 2: Static Build + Local Server
```bash
npm run build
npx serve dist
# Access at http://localhost:3000/
```

### Option 3: Cloud Deployment (Recommended)

#### Vercel (Free)
```bash
npm install -g vercel
vercel deploy
```

#### Netlify (Free)
```bash
npm install -g netlify-cli
netlify deploy --prod
```

#### GitHub Pages (Free)
```bash
# Add to package.json:
"homepage": "https://yourusername.github.io/pac-track"

# Deploy
npm run build
npx gh-pages -d dist
```

## 🔮 Future: Native macOS App (Optional)

If you want to convert to Electron later:

### 1. Install Electron
```bash
npm install --save-dev electron electron-builder vite-plugin-electron
```

### 2. Configure electron-builder (package.json)
```json
{
  "build": {
    "mac": {
      "category": "public.app-category.developer-tools",
      "hardenedRuntime": false,
      "gatekeeperAssess": false,
      "identity": null
    }
  }
}
```

### 3. Skip Code Signing (Development)
```json
{
  "build": {
    "mac": {
      "identity": null,
      "signIgnore": ".*"
    }
  }
}
```

## 📊 Performance on macOS

### Apple Silicon (M1/M2/M3)
- ✅ Native performance
- ✅ 60fps animations
- ✅ Low power consumption
- ✅ Instant cold start

### Intel Macs
- ✅ Full compatibility
- ✅ Smooth performance
- ✅ All features work

## 🎯 Best Practices

### For Best Performance
1. Use **Safari** on Apple Silicon for best battery life
2. Use **Chrome** for development (DevTools)
3. Close unused browser tabs
4. Zoom level affects rendering performance

### For Best Experience
1. Use **Cmd** shortcuts (macOS native)
2. Use **trackpad gestures** for zooming (if browser supports)
3. Enable **dark mode** in browser (app auto-detects)
4. Use **fullscreen mode** for large topologies

## 📧 Support

**Issues?** Check:
1. Node version: `node --version` (should be 18+)
2. Browser console: Press `⌘ + Option + I`
3. Network tab: Check for failed requests
4. Clear browser cache: `⌘ + Shift + R`

## 🏆 Production Ready

- ✅ Zero TypeScript errors
- ✅ Zero build warnings
- ✅ Clean code (ESLint ready)
- ✅ Optimized bundle size
- ✅ macOS tested and verified
- ✅ All features working

**Enjoy building network topologies!** 🚀
