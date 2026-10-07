// Packet Tracer Application
class PacketTracer {
    constructor() {
        this.canvas = document.getElementById('canvas');
        this.ctx = this.canvas.getContext('2d');
        this.devices = [];
        this.connections = [];
        this.selectedDevice = null;
        this.mode = 'move'; // move, cable, delete
        this.cableStart = null;
        this.dragging = false;
        this.dragOffset = { x: 0, y: 0 };
        this.consoleMinimized = false;

        // Continuous simulation
        this.continuousSimulation = false;
        this.continuousSimInterval = null;
        this.simulationSpeed = 3000; // ms between packets

        // Verbose mode
        this.verboseMode = false;

        // Console resizing
        this.isResizingConsole = false;
        this.consoleStartHeight = 0;
        this.consoleStartY = 0;

        // Topology name
        this.topologyName = 'My Network';

        // Grid snapping
        this.snapToGrid = false;
        this.gridSize = 50;

        this.initCanvas();
        this.setupEventListeners();
        this.render();
        this.logConsole('info', 'Network Simulator initialized successfully');
    }

    initCanvas() {
        const mainContent = document.querySelector('.main-content');
        const workspace = document.querySelector('.workspace');
        this.canvas.width = workspace.clientWidth - 32;
        this.canvas.height = workspace.clientHeight - 32;
    }

    // Console logging system
    logConsole(type, message, deviceName = null) {
        const consoleContent = document.getElementById('console-content');
        const timestamp = new Date().toLocaleTimeString('it-IT', { hour12: false });

        const messageDiv = document.createElement('div');
        messageDiv.className = `console-message ${type}`;

        // Apply device color if available
        let messageContent = message;
        if (deviceName) {
            const device = this.devices.find(d => d.name === deviceName);
            if (device) {
                const deviceColor = this.getDeviceConsoleColor(device.type);
                messageContent = this.colorizeDeviceNames(message, deviceColor);
            }
        } else {
            // Colorize all device names in the message
            messageContent = this.colorizeAllDevices(message);
        }

        messageDiv.innerHTML = `
            <span class="timestamp">[${timestamp}]</span>
            <span class="message">${messageContent}</span>
        `;

        consoleContent.appendChild(messageDiv);
        consoleContent.scrollTop = consoleContent.scrollHeight;
    }

    getDeviceConsoleColor(type) {
        const colorMap = {
            // Network Devices
            'router': '#3498db',
            'switch': '#2ecc71',
            'hub': '#95a5a6',
            'modem': '#16a085',
            'access-point': '#27ae60',

            // Security
            'firewall': '#e74c3c',
            'ids': '#c0392b',

            // Servers
            'web-server': '#f39c12',
            'database-server': '#d35400',
            'mail-server': '#e67e22',
            'dns-server': '#f1c40f',
            'ftp-server': '#9b59b6',
            'proxy-server': '#8e44ad',

            // Storage
            'nas': '#34495e',
            'load-balancer': '#1abc9c',

            // Home & IoT
            'wifi-router': '#3498db',
            'mesh-node': '#5dade2',
            'smart-tv': '#e74c3c',
            'gaming-console': '#9b59b6',
            'smart-speaker': '#1abc9c',
            'security-camera': '#34495e',

            // WAN
            'internet': '#2980b9',
            'cloud': '#5dade2',

            // End Devices
            'pc': '#9b59b6',
            'laptop': '#8e44ad',
            'smartphone': '#3498db',
            'tablet': '#5dade2',
            'printer': '#7f8c8d'
        };

        return colorMap[type] || '#ecf0f1';
    }

    colorizeAllDevices(message) {
        let coloredMessage = message;

        this.devices.forEach(device => {
            const color = this.getDeviceConsoleColor(device.type);
            const regex = new RegExp(`\\b${device.name}\\b`, 'g');
            coloredMessage = coloredMessage.replace(
                regex,
                `<span style="color: ${color}; font-weight: bold;">${device.name}</span>`
            );
        });

        return coloredMessage;
    }

    colorizeDeviceNames(message, color) {
        // Colorize device names in the message
        this.devices.forEach(device => {
            const deviceColor = this.getDeviceConsoleColor(device.type);
            const regex = new RegExp(`\\b${device.name}\\b`, 'g');
            message = message.replace(
                regex,
                `<span style="color: ${deviceColor}; font-weight: bold;">${device.name}</span>`
            );
        });

        return message;
    }

    clearConsole() {
        const consoleContent = document.getElementById('console-content');
        consoleContent.innerHTML = '';
        this.logConsole('info', 'Console cleared');
    }

    toggleConsole() {
        const consoleContainer = document.getElementById('console-container');
        consoleContainer.classList.toggle('minimized');
        this.consoleMinimized = !this.consoleMinimized;

        // Adjust canvas size
        setTimeout(() => {
            this.initCanvas();
            this.render();
        }, 300);
    }

    toggleVerboseMode(button) {
        this.verboseMode = !this.verboseMode;

        if (this.verboseMode) {
            button.classList.add('active');
            button.style.background = '#3498db';
            button.style.color = 'white';
            this.logConsole('info', '📝 Verbose mode enabled - detailed network information will be shown');
        } else {
            button.classList.remove('active');
            button.style.background = '';
            button.style.color = '';
            this.logConsole('info', '📝 Verbose mode disabled - showing standard information');
        }
    }

    toggleSnapToGrid(button) {
        this.snapToGrid = !this.snapToGrid;

        if (this.snapToGrid) {
            button.classList.add('active');
            this.logConsole('info', '🔲 Snap to grid enabled - devices will align to grid (50px)');
        } else {
            button.classList.remove('active');
            this.logConsole('info', '🔲 Snap to grid disabled - free positioning');
        }
    }

    snapToGridPosition(x, y) {
        if (!this.snapToGrid) {
            return { x, y };
        }
        return {
            x: Math.round(x / this.gridSize) * this.gridSize,
            y: Math.round(y / this.gridSize) * this.gridSize
        };
    }

    startResizingConsole(e) {
        this.isResizingConsole = true;
        const consoleContainer = document.getElementById('console-container');
        this.consoleStartHeight = consoleContainer.offsetHeight;
        this.consoleStartY = e.clientY;
        document.body.style.cursor = 'ns-resize';
        document.body.style.userSelect = 'none';
        e.preventDefault();
    }

    resizeConsole(e) {
        if (!this.isResizingConsole) return;

        const consoleContainer = document.getElementById('console-container');
        const delta = this.consoleStartY - e.clientY;
        let newHeight = this.consoleStartHeight + delta;

        // Constraints
        const minHeight = 38;
        const maxHeight = window.innerHeight * 0.8;

        newHeight = Math.max(minHeight, Math.min(newHeight, maxHeight));
        consoleContainer.style.height = newHeight + 'px';

        // Adjust canvas
        this.initCanvas();
        this.render();
    }

    generateMAC() {
        const hex = '0123456789ABCDEF';
        let mac = '';
        for (let i = 0; i < 6; i++) {
            mac += hex[Math.floor(Math.random() * 16)];
            mac += hex[Math.floor(Math.random() * 16)];
            if (i < 5) mac += ':';
        }
        return mac;
    }

    setupEventListeners() {
        // Device creation buttons
        document.querySelectorAll('.device-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                const type = e.currentTarget.dataset.type;
                this.addDevice(type);
            });
        });

        // Tool buttons
        document.getElementById('move-mode').addEventListener('click', (e) => {
            this.setMode('move', e.currentTarget);
            this.logConsole('info', 'Mode: Move - Drag devices to reposition');
        });

        document.getElementById('cable-mode').addEventListener('click', (e) => {
            this.setMode('cable', e.currentTarget);
            this.logConsole('info', 'Mode: Cable - Click two devices to connect');
        });

        document.getElementById('delete-mode').addEventListener('click', (e) => {
            this.setMode('delete', e.currentTarget);
            this.logConsole('warning', 'Mode: Delete - Click a device or connection to delete');
        });

        document.getElementById('simulate-btn').addEventListener('click', () => {
            this.openSimulationModal();
        });

        document.getElementById('clear-btn').addEventListener('click', () => {
            this.clearAll();
        });

        document.getElementById('continuous-sim-btn').addEventListener('click', (e) => {
            this.toggleContinuousSimulation(e.currentTarget);
        });

        // Console controls
        document.getElementById('toggle-console').addEventListener('click', () => {
            this.toggleConsole();
        });

        document.getElementById('minimize-console').addEventListener('click', () => {
            this.toggleConsole();
        });

        document.getElementById('clear-console').addEventListener('click', () => {
            this.clearConsole();
        });

        document.getElementById('verbose-toggle').addEventListener('click', (e) => {
            this.toggleVerboseMode(e.currentTarget);
        });

        // Snap to grid toggle
        document.getElementById('snap-to-grid').addEventListener('click', (e) => {
            this.toggleSnapToGrid(e.currentTarget);
        });

        // Console resize handle
        const resizeHandle = document.getElementById('console-resize-handle');
        resizeHandle.addEventListener('mousedown', (e) => {
            this.startResizingConsole(e);
        });

        document.addEventListener('mousemove', (e) => {
            if (this.isResizingConsole) {
                this.resizeConsole(e);
            }
        });

        document.addEventListener('mouseup', () => {
            this.isResizingConsole = false;
            document.body.style.cursor = '';
            document.body.style.userSelect = '';
        });

        // Topology name input
        document.getElementById('topology-name').addEventListener('input', (e) => {
            this.topologyName = e.target.value || 'My Network';
        });

        // Toolbar buttons
        document.getElementById('save-topology')?.addEventListener('click', () => {
            this.saveTopology();
        });

        document.getElementById('load-topology')?.addEventListener('click', () => {
            this.loadTopology();
        });

        document.getElementById('export-image')?.addEventListener('click', () => {
            this.exportAsImage();
        });

        // Canvas events
        this.canvas.addEventListener('mousedown', (e) => this.handleMouseDown(e));
        this.canvas.addEventListener('mousemove', (e) => this.handleMouseMove(e));
        this.canvas.addEventListener('mouseup', (e) => this.handleMouseUp(e));
        this.canvas.addEventListener('dblclick', (e) => this.handleDoubleClick(e));

        // Modal events
        document.querySelector('.close').addEventListener('click', () => {
            document.getElementById('config-modal').style.display = 'none';
        });

        document.getElementById('close-sim').addEventListener('click', () => {
            document.getElementById('simulation-modal').style.display = 'none';
        });

        document.getElementById('save-config').addEventListener('click', () => {
            this.saveDeviceConfig();
        });

        document.getElementById('add-route').addEventListener('click', () => {
            this.addRoute();
        });

        document.getElementById('start-simulation').addEventListener('click', () => {
            this.startSimulation();
        });

        // DHCP controls
        document.getElementById('dhcp-enabled').addEventListener('change', (e) => {
            const dhcpSettings = document.getElementById('dhcp-settings');
            dhcpSettings.style.display = e.target.checked ? 'block' : 'none';
        });

        document.getElementById('assign-dhcp').addEventListener('click', () => {
            this.assignDHCPAddresses();
        });

        // Window resize
        window.addEventListener('resize', () => {
            this.initCanvas();
            this.render();
        });
    }

    setMode(mode, button) {
        this.mode = mode;
        // Remove active class from all toolbar buttons
        document.querySelectorAll('.toolbar-btn').forEach(btn => btn.classList.remove('active'));
        // Add active class to the clicked button
        if (button) {
            button.classList.add('active');
        }
        this.cableStart = null;
    }

    addDevice(type) {
        const portCount = this.getPortsForType(type);
        const ports = [];

        for (let i = 0; i < portCount; i++) {
            ports.push({
                id: i,
                name: type === 'switch' ? `Fa0/${i}` : `Gig0/${i}`,
                status: 'up',
                connectedTo: null
            });
        }

        // Generate random position
        let x = Math.random() * (this.canvas.width - 100) + 50;
        let y = Math.random() * (this.canvas.height - 100) + 50;

        // Apply grid snapping if enabled
        const snappedPos = this.snapToGridPosition(x, y);

        const device = {
            id: Date.now(),
            type: type,
            x: snappedPos.x,
            y: snappedPos.y,
            name: `${type.toUpperCase()}-${this.devices.length + 1}`,
            mac: this.generateMAC(),
            ip: '',
            subnet: '255.255.255.0',
            gateway: '',
            ports: ports,
            routingTable: type === 'router' ? [] : null,
            arpTable: [],
            // DHCP configuration
            dhcpEnabled: false,
            dhcpRange: {
                start: '',
                end: '',
                subnet: '255.255.255.0',
                gateway: ''
            },
            dhcpLeases: [] // Track assigned IPs
        };

        this.devices.push(device);
        this.render();
        this.logConsole('success', `Added ${type.toUpperCase().replace('-', ' ')}: ${device.name}`);
    }

    getPortsForType(type) {
        switch(type) {
            // Network Devices
            case 'router': return 4;
            case 'switch': return 24;
            case 'hub': return 8;
            case 'modem': return 2;
            case 'access-point': return 1;

            // Security
            case 'firewall': return 6;
            case 'ids': return 4;

            // Servers
            case 'web-server': return 2;
            case 'database-server': return 2;
            case 'mail-server': return 2;
            case 'dns-server': return 2;
            case 'ftp-server': return 2;
            case 'proxy-server': return 2;

            // Storage & Others
            case 'nas': return 2;
            case 'load-balancer': return 8;

            // Home & IoT
            case 'wifi-router': return 5;
            case 'mesh-node': return 3;
            case 'range-extender': return 1;
            case 'smart-tv': return 1;
            case 'gaming-console': return 1;
            case 'smart-speaker': return 1;
            case 'security-camera': return 1;
            case 'smart-thermostat': return 1;
            case 'smart-lock': return 1;
            case 'iot-sensor': return 1;
            case 'smart-plug': return 1;
            case 'home-hub': return 2;

            // WAN/Internet
            case 'internet': return 1;
            case 'cloud': return 4;

            // End Devices
            case 'pc': return 1;
            case 'laptop': return 1;
            case 'smartphone': return 1;
            case 'tablet': return 1;
            case 'printer': return 1;

            default: return 1;
        }
    }

    getDeviceCategory(type) {
        const categories = {
            'router': 'network',
            'switch': 'network',
            'hub': 'network',
            'modem': 'network',
            'access-point': 'network',
            'firewall': 'security',
            'ids': 'security',
            'web-server': 'server',
            'database-server': 'server',
            'mail-server': 'server',
            'dns-server': 'server',
            'ftp-server': 'server',
            'proxy-server': 'server',
            'nas': 'storage',
            'load-balancer': 'network',
            'wifi-router': 'home-iot',
            'mesh-node': 'home-iot',
            'range-extender': 'home-iot',
            'smart-tv': 'home-iot',
            'gaming-console': 'home-iot',
            'smart-speaker': 'home-iot',
            'security-camera': 'home-iot',
            'smart-thermostat': 'home-iot',
            'smart-lock': 'home-iot',
            'iot-sensor': 'home-iot',
            'smart-plug': 'home-iot',
            'home-hub': 'home-iot',
            'internet': 'wan',
            'cloud': 'wan',
            'pc': 'end-device',
            'laptop': 'end-device',
            'smartphone': 'end-device',
            'tablet': 'end-device',
            'printer': 'end-device'
        };
        return categories[type] || 'unknown';
    }

    handleMouseDown(e) {
        const rect = this.canvas.getBoundingClientRect();
        const x = e.clientX - rect.left;
        const y = e.clientY - rect.top;

        const device = this.getDeviceAtPosition(x, y);

        if (this.mode === 'cable') {
            if (device) {
                if (!this.cableStart) {
                    this.cableStart = device;
                    this.logConsole('info', `Cable started from ${device.name}. Click another device to complete connection.`);
                } else {
                    this.createConnection(this.cableStart, device);
                    this.cableStart = null;
                }
            }
        } else if (this.mode === 'delete') {
            if (device) {
                this.deleteDevice(device);
            } else {
                const connection = this.getConnectionAtPosition(x, y);
                if (connection) {
                    this.deleteConnection(connection);
                }
            }
        } else if (this.mode === 'move') {
            if (device) {
                this.selectedDevice = device;
                this.dragging = true;
                this.dragOffset = { x: x - device.x, y: y - device.y };
            }
        }
    }

    handleMouseMove(e) {
        if (this.dragging && this.selectedDevice && this.mode === 'move') {
            const rect = this.canvas.getBoundingClientRect();
            let x = e.clientX - rect.left - this.dragOffset.x;
            let y = e.clientY - rect.top - this.dragOffset.y;

            // Apply grid snapping if enabled
            const snappedPos = this.snapToGridPosition(x, y);
            this.selectedDevice.x = snappedPos.x;
            this.selectedDevice.y = snappedPos.y;

            this.render();
        }
    }

    handleMouseUp(e) {
        this.dragging = false;
    }

    handleDoubleClick(e) {
        const rect = this.canvas.getBoundingClientRect();
        const x = e.clientX - rect.left;
        const y = e.clientY - rect.top;

        const device = this.getDeviceAtPosition(x, y);
        if (device) {
            this.openConfigModal(device);
        }
    }

    getDeviceAtPosition(x, y) {
        for (let i = this.devices.length - 1; i >= 0; i--) {
            const device = this.devices[i];
            const size = 40;
            if (x >= device.x - size/2 && x <= device.x + size/2 &&
                y >= device.y - size/2 && y <= device.y + size/2) {
                return device;
            }
        }
        return null;
    }

    getConnectionAtPosition(x, y) {
        for (let connection of this.connections) {
            const dist = this.pointToLineDistance(
                x, y,
                connection.from.x, connection.from.y,
                connection.to.x, connection.to.y
            );
            if (dist < 5) {
                return connection;
            }
        }
        return null;
    }

    pointToLineDistance(px, py, x1, y1, x2, y2) {
        const A = px - x1;
        const B = py - y1;
        const C = x2 - x1;
        const D = y2 - y1;

        const dot = A * C + B * D;
        const lenSq = C * C + D * D;
        let param = -1;
        if (lenSq !== 0) param = dot / lenSq;

        let xx, yy;

        if (param < 0) {
            xx = x1;
            yy = y1;
        } else if (param > 1) {
            xx = x2;
            yy = y2;
        } else {
            xx = x1 + param * C;
            yy = y1 + param * D;
        }

        const dx = px - xx;
        const dy = py - yy;
        return Math.sqrt(dx * dx + dy * dy);
    }

    createConnection(from, to) {
        if (from === to) {
            this.logConsole('error', 'Cannot connect device to itself');
            return;
        }

        // Check if connection already exists
        const exists = this.connections.some(c =>
            (c.from === from && c.to === to) || (c.from === to && c.to === from)
        );

        if (exists) {
            this.logConsole('warning', 'Connection already exists between these devices');
            return;
        }

        // Find available ports
        const fromPort = from.ports.find(p => !p.connectedTo);
        const toPort = to.ports.find(p => !p.connectedTo);

        if (!fromPort || !toPort) {
            this.logConsole('error', 'No available ports on one or both devices');
            return;
        }

        // Create connection
        const connection = {
            from,
            to,
            fromPort: fromPort.id,
            toPort: toPort.id
        };

        fromPort.connectedTo = { device: to, port: toPort.id };
        toPort.connectedTo = { device: from, port: fromPort.id };

        this.connections.push(connection);
        this.render();
        this.logConsole('success', `Connected ${from.name}:${fromPort.name} ↔ ${to.name}:${toPort.name}`);
    }

    deleteDevice(device) {
        // Free up ports on connected devices
        this.connections.forEach(c => {
            if (c.from === device) {
                const port = c.to.ports[c.toPort];
                if (port) port.connectedTo = null;
            }
            if (c.to === device) {
                const port = c.from.ports[c.fromPort];
                if (port) port.connectedTo = null;
            }
        });

        this.devices = this.devices.filter(d => d !== device);
        this.connections = this.connections.filter(c =>
            c.from !== device && c.to !== device
        );
        this.render();
        this.logConsole('warning', `Deleted device: ${device.name}`);
    }

    deleteConnection(connection) {
        // Free up ports
        const fromPort = connection.from.ports[connection.fromPort];
        const toPort = connection.to.ports[connection.toPort];
        if (fromPort) fromPort.connectedTo = null;
        if (toPort) toPort.connectedTo = null;

        this.connections = this.connections.filter(c => c !== connection);
        this.render();
        this.logConsole('warning', 'Connection deleted');
    }

    openConfigModal(device) {
        this.selectedDevice = device;
        document.getElementById('device-name').value = device.name;
        document.getElementById('device-mac').value = device.mac;
        document.getElementById('device-ip').value = device.ip;
        document.getElementById('device-subnet').value = device.subnet;
        document.getElementById('device-gateway').value = device.gateway || '';

        // Populate IP suggestions
        this.populateIPSuggestions();

        // Show/hide router config
        const routerConfig = document.getElementById('router-config');
        if (device.type === 'router') {
            routerConfig.style.display = 'block';
            this.renderRoutingTable();
        } else {
            routerConfig.style.display = 'none';
        }

        // Show/hide DHCP config for routers and wifi-routers
        const dhcpConfig = document.getElementById('dhcp-config');
        if (device.type === 'router' || device.type === 'wifi-router') {
            dhcpConfig.style.display = 'block';
            this.renderDHCPConfig();
        } else {
            dhcpConfig.style.display = 'none';
        }

        // Render ports
        this.renderPorts();

        document.getElementById('config-modal').style.display = 'block';
    }

    populateIPSuggestions() {
        // Get all existing IPs and networks
        const existingIPs = this.devices
            .filter(d => d.ip)
            .map(d => d.ip);

        // Extract network prefixes
        const networks = new Set();
        existingIPs.forEach(ip => {
            const parts = ip.split('.');
            if (parts.length === 4) {
                networks.add(`${parts[0]}.${parts[1]}.${parts[2]}`);
            }
        });

        // Generate IP suggestions
        const ipSuggestions = document.getElementById('ip-suggestions');
        ipSuggestions.innerHTML = '';

        // If no networks exist, suggest common ones
        if (networks.size === 0) {
            ['192.168.1', '192.168.0', '10.0.0', '172.16.0'].forEach(prefix => {
                for (let i = 1; i <= 10; i++) {
                    const option = document.createElement('option');
                    option.value = `${prefix}.${i}`;
                    ipSuggestions.appendChild(option);
                }
            });
        } else {
            // Suggest IPs in existing networks
            networks.forEach(prefix => {
                for (let i = 1; i <= 254; i++) {
                    const suggestedIP = `${prefix}.${i}`;
                    if (!existingIPs.includes(suggestedIP)) {
                        const option = document.createElement('option');
                        option.value = suggestedIP;
                        ipSuggestions.appendChild(option);
                    }
                }
            });
        }

        // Gateway suggestions (routers/gateways in the network)
        const gatewaySuggestions = document.getElementById('gateway-suggestions');
        gatewaySuggestions.innerHTML = '';

        this.devices.forEach(d => {
            if ((d.type === 'router' || d.type === 'wifi-router') && d.ip) {
                const option = document.createElement('option');
                option.value = d.ip;
                option.label = `${d.name} (${d.ip})`;
                gatewaySuggestions.appendChild(option);
            }
        });

        // DHCP suggestions
        if (this.selectedDevice && (this.selectedDevice.type === 'router' || this.selectedDevice.type === 'wifi-router')) {
            const deviceIP = this.selectedDevice.ip;
            if (deviceIP) {
                const parts = deviceIP.split('.');
                if (parts.length === 4) {
                    const prefix = `${parts[0]}.${parts[1]}.${parts[2]}`;

                    // DHCP start suggestions
                    const dhcpStartSuggestions = document.getElementById('dhcp-start-suggestions');
                    dhcpStartSuggestions.innerHTML = '';
                    [100, 150, 200].forEach(start => {
                        const option = document.createElement('option');
                        option.value = `${prefix}.${start}`;
                        dhcpStartSuggestions.appendChild(option);
                    });

                    // DHCP end suggestions
                    const dhcpEndSuggestions = document.getElementById('dhcp-end-suggestions');
                    dhcpEndSuggestions.innerHTML = '';
                    [150, 200, 250].forEach(end => {
                        const option = document.createElement('option');
                        option.value = `${prefix}.${end}`;
                        dhcpEndSuggestions.appendChild(option);
                    });

                    // DHCP gateway suggestion (router itself)
                    const dhcpGatewaySuggestions = document.getElementById('dhcp-gateway-suggestions');
                    dhcpGatewaySuggestions.innerHTML = '';
                    const option = document.createElement('option');
                    option.value = deviceIP;
                    option.label = `This router (${deviceIP})`;
                    dhcpGatewaySuggestions.appendChild(option);
                }
            }
        }
    }

    renderDHCPConfig() {
        if (!this.selectedDevice) return;

        const dhcpEnabled = document.getElementById('dhcp-enabled');
        const dhcpSettings = document.getElementById('dhcp-settings');
        const dhcpStart = document.getElementById('dhcp-start');
        const dhcpEnd = document.getElementById('dhcp-end');
        const dhcpSubnet = document.getElementById('dhcp-subnet');
        const dhcpGateway = document.getElementById('dhcp-gateway');

        dhcpEnabled.checked = this.selectedDevice.dhcpEnabled || false;
        dhcpSettings.style.display = dhcpEnabled.checked ? 'block' : 'none';

        dhcpStart.value = this.selectedDevice.dhcpRange.start || '';
        dhcpEnd.value = this.selectedDevice.dhcpRange.end || '';
        dhcpSubnet.value = this.selectedDevice.dhcpRange.subnet || '255.255.255.0';
        dhcpGateway.value = this.selectedDevice.dhcpRange.gateway || this.selectedDevice.ip || '';

        // Update DHCP suggestions when showing config
        this.populateIPSuggestions();

        this.renderDHCPLeases();
    }

    renderDHCPLeases() {
        const leasesList = document.getElementById('leases-list');
        if (!this.selectedDevice || !this.selectedDevice.dhcpLeases || this.selectedDevice.dhcpLeases.length === 0) {
            leasesList.innerHTML = '<em style="color: #999;">No active leases</em>';
            return;
        }

        let html = '<table style="width:100%; border-collapse: collapse; margin-top: 0.5rem;">';
        html += '<tr style="background: #f8f9fa;"><th style="padding: 0.3rem; text-align: left; border: 1px solid #ddd;">Device</th><th style="padding: 0.3rem; text-align: left; border: 1px solid #ddd;">IP Address</th><th style="padding: 0.3rem; text-align: left; border: 1px solid #ddd;">MAC</th></tr>';

        this.selectedDevice.dhcpLeases.forEach(lease => {
            html += `<tr>
                <td style="padding: 0.3rem; border: 1px solid #ddd;">${lease.deviceName}</td>
                <td style="padding: 0.3rem; border: 1px solid #ddd;">${lease.ip}</td>
                <td style="padding: 0.3rem; border: 1px solid #ddd; font-size: 0.75rem;">${lease.mac}</td>
            </tr>`;
        });

        html += '</table>';
        leasesList.innerHTML = html;
    }

    renderRoutingTable() {
        const table = document.getElementById('routing-table');
        if (!this.selectedDevice.routingTable) return;

        let html = '<table style="width:100%; margin:10px 0;"><tr><th>Network</th><th>Netmask</th><th>Gateway</th><th>Interface</th><th></th></tr>';

        this.selectedDevice.routingTable.forEach((route, idx) => {
            html += `<tr>
                <td>${route.network}</td>
                <td>${route.netmask}</td>
                <td>${route.gateway}</td>
                <td>${route.interface}</td>
                <td><button onclick="app.deleteRoute(${idx})">Delete</button></td>
            </tr>`;
        });

        html += '</table>';
        table.innerHTML = html;
    }

    renderPorts() {
        const portsList = document.getElementById('ports-list');
        if (!this.selectedDevice) return;

        let html = '<table style="width:100%; margin:10px 0;"><tr><th>Port</th><th>Status</th><th>Connected To</th></tr>';

        this.selectedDevice.ports.forEach(port => {
            const connectedInfo = port.connectedTo
                ? `${port.connectedTo.device.name}:${port.connectedTo.device.ports[port.connectedTo.port].name}`
                : 'Not connected';

            html += `<tr>
                <td>${port.name}</td>
                <td style="color:${port.status === 'up' ? 'green' : 'red'}">${port.status}</td>
                <td>${connectedInfo}</td>
            </tr>`;
        });

        html += '</table>';
        portsList.innerHTML = html;
    }

    addRoute() {
        const network = prompt('Enter network address (e.g., 192.168.2.0):');
        const netmask = prompt('Enter netmask (e.g., 255.255.255.0):');
        const gateway = prompt('Enter gateway (e.g., 192.168.1.1):');
        const iface = prompt('Enter interface (e.g., Gig0/0):');

        if (network && netmask && gateway && iface) {
            if (!this.selectedDevice.routingTable) {
                this.selectedDevice.routingTable = [];
            }
            this.selectedDevice.routingTable.push({ network, netmask, gateway, interface: iface });
            this.renderRoutingTable();
        }
    }

    deleteRoute(index) {
        if (this.selectedDevice && this.selectedDevice.routingTable) {
            this.selectedDevice.routingTable.splice(index, 1);
            this.renderRoutingTable();
        }
    }

    saveDeviceConfig() {
        if (this.selectedDevice) {
            this.selectedDevice.name = document.getElementById('device-name').value;
            this.selectedDevice.ip = document.getElementById('device-ip').value;
            this.selectedDevice.subnet = document.getElementById('device-subnet').value;
            this.selectedDevice.gateway = document.getElementById('device-gateway').value;

            // Save DHCP configuration if applicable
            if (this.selectedDevice.type === 'router' || this.selectedDevice.type === 'wifi-router') {
                this.selectedDevice.dhcpEnabled = document.getElementById('dhcp-enabled').checked;
                this.selectedDevice.dhcpRange.start = document.getElementById('dhcp-start').value;
                this.selectedDevice.dhcpRange.end = document.getElementById('dhcp-end').value;
                this.selectedDevice.dhcpRange.subnet = document.getElementById('dhcp-subnet').value;
                this.selectedDevice.dhcpRange.gateway = document.getElementById('dhcp-gateway').value;
            }

            document.getElementById('config-modal').style.display = 'none';
            this.render();
            this.logConsole('success', `Configuration saved for ${this.selectedDevice.name}`);
        }
    }

    assignDHCPAddresses() {
        if (!this.selectedDevice) return;

        const startIP = document.getElementById('dhcp-start').value;
        const endIP = document.getElementById('dhcp-end').value;
        const subnet = document.getElementById('dhcp-subnet').value;
        const gateway = document.getElementById('dhcp-gateway').value;

        if (!startIP || !endIP) {
            this.logConsole('error', 'Please configure DHCP start and end IP addresses');
            alert('Please configure DHCP start and end IP addresses first');
            return;
        }

        // Get connected devices
        const connectedDevices = this.getConnectedDevices(this.selectedDevice);

        if (connectedDevices.length === 0) {
            this.logConsole('warning', 'No devices connected to this router');
            alert('No devices connected to this router');
            return;
        }

        // Convert IP to number for incrementing
        const ipToNum = (ip) => {
            const parts = ip.split('.');
            return (parseInt(parts[0]) << 24) + (parseInt(parts[1]) << 16) +
                   (parseInt(parts[2]) << 8) + parseInt(parts[3]);
        };

        const numToIP = (num) => {
            return [
                (num >>> 24) & 0xFF,
                (num >>> 16) & 0xFF,
                (num >>> 8) & 0xFF,
                num & 0xFF
            ].join('.');
        };

        let currentIP = ipToNum(startIP);
        const endIPNum = ipToNum(endIP);

        this.selectedDevice.dhcpLeases = [];
        let assignedCount = 0;

        connectedDevices.forEach(device => {
            // Skip if device already has an IP or if we've run out of addresses
            if (currentIP > endIPNum) {
                this.logConsole('warning', `Not enough IP addresses in pool for ${device.name}`);
                return;
            }

            const assignedIP = numToIP(currentIP);
            device.ip = assignedIP;
            device.subnet = subnet;
            device.gateway = gateway;

            // Record the lease
            this.selectedDevice.dhcpLeases.push({
                deviceName: device.name,
                ip: assignedIP,
                mac: device.mac
            });

            this.logConsole('success', `DHCP assigned ${assignedIP} to ${device.name}`);
            assignedCount++;
            currentIP++;
        });

        this.renderDHCPLeases();
        this.render();
        this.logConsole('success', `DHCP: Assigned ${assignedCount} IP addresses to connected devices`);
        alert(`Successfully assigned ${assignedCount} IP addresses to connected devices`);
    }

    getConnectedDevices(routerDevice) {
        const connected = new Set();
        const visited = new Set();

        const explore = (device) => {
            if (visited.has(device)) return;
            visited.add(device);

            this.connections.forEach(conn => {
                if (conn.from === device && conn.to !== routerDevice) {
                    connected.add(conn.to);
                    explore(conn.to);
                } else if (conn.to === device && conn.from !== routerDevice) {
                    connected.add(conn.from);
                    explore(conn.from);
                }
            });
        };

        explore(routerDevice);
        return Array.from(connected);
    }

    openSimulationModal() {
        if (this.devices.length < 2) {
            this.logConsole('warning', 'Need at least 2 devices to simulate packet transmission');
            return;
        }

        // Populate device dropdowns
        const sourceSelect = document.getElementById('source-device');
        const destSelect = document.getElementById('dest-device');

        sourceSelect.innerHTML = '';
        destSelect.innerHTML = '';

        this.devices.forEach(device => {
            if (device.ip) {
                sourceSelect.innerHTML += `<option value="${device.id}">${device.name} (${device.ip})</option>`;
                destSelect.innerHTML += `<option value="${device.id}">${device.name} (${device.ip})</option>`;
            }
        });

        // Populate IP suggestions for simulation
        const simIPSuggestions = document.getElementById('sim-ip-suggestions');
        simIPSuggestions.innerHTML = '';

        this.devices.forEach(device => {
            if (device.ip) {
                const option = document.createElement('option');
                option.value = device.ip;
                option.label = `${device.name} (${device.ip})`;
                simIPSuggestions.appendChild(option);
            }
        });

        document.getElementById('simulation-modal').style.display = 'block';
    }

    startSimulation() {
        const sourceId = parseInt(document.getElementById('source-device').value);
        const destId = parseInt(document.getElementById('dest-device').value);
        const destIP = document.getElementById('dest-ip').value ||
                       this.devices.find(d => d.id === destId)?.ip;
        const packetType = document.getElementById('packet-type').value;

        const source = this.devices.find(d => d.id === sourceId);
        const dest = this.devices.find(d => d.id === destId);

        if (!source || !dest) {
            this.logSimulation('Error: Invalid source or destination device');
            return;
        }

        if (!source.ip || !destIP) {
            this.logSimulation('Error: Source or destination IP not configured');
            return;
        }

        document.getElementById('simulation-log').innerHTML = '';
        this.logSimulation(`Starting ${packetType.toUpperCase()} simulation from ${source.name} (${source.ip}) to ${destIP}`);

        // Check if devices are on same network
        if (this.isSameNetwork(source.ip, destIP, source.subnet)) {
            this.logSimulation(`Devices on same network - using ARP`);
            this.simulateDirectPath(source, dest, packetType);
        } else {
            this.logSimulation(`Devices on different networks - routing required`);
            this.simulateRoutedPath(source, dest, destIP, packetType);
        }
    }

    isSameNetwork(ip1, ip2, subnet) {
        const ipToInt = (ip) => ip.split('.').reduce((acc, octet) => (acc << 8) + parseInt(octet), 0);
        const subnetInt = ipToInt(subnet);
        return (ipToInt(ip1) & subnetInt) === (ipToInt(ip2) & subnetInt);
    }

    simulateDirectPath(source, dest, packetType) {
        const path = this.findPath(source, dest);

        if (path.length === 0) {
            this.logSimulation('Error: No physical path found between devices');
            return;
        }

        this.logSimulation(`Path found: ${path.map(d => d.name).join(' -> ')}`);
        this.animatePacket(path, packetType);
    }

    simulateRoutedPath(source, dest, destIP, packetType) {
        // Check if source has gateway
        if (!source.gateway) {
            this.logSimulation(`Error: ${source.name} has no default gateway configured`);
            return;
        }

        // Find gateway device
        const gateway = this.devices.find(d => d.ip === source.gateway);
        if (!gateway) {
            this.logSimulation(`Error: Gateway ${source.gateway} not found`);
            return;
        }

        this.logSimulation(`Sending packet to gateway ${gateway.name} (${gateway.ip})`);

        // Find path to gateway, then to destination
        const pathToGateway = this.findPath(source, gateway);
        const pathToDest = this.findPath(gateway, dest);

        if (pathToGateway.length === 0 || pathToDest.length === 0) {
            this.logSimulation('Error: No complete path found');
            return;
        }

        // Combine paths (remove duplicate gateway)
        const fullPath = [...pathToGateway, ...pathToDest.slice(1)];
        this.logSimulation(`Full path: ${fullPath.map(d => d.name).join(' -> ')}`);
        this.animatePacket(fullPath, packetType);
    }

    logSimulation(message) {
        const log = document.getElementById('simulation-log');
        log.innerHTML += `<div style="padding:5px; border-bottom:1px solid #eee;">${message}</div>`;
        log.scrollTop = log.scrollHeight;

        // Also log to main console
        this.logConsole('packet', message);
    }

    findPath(start, end, visited = new Set()) {
        if (start === end) return [start];

        visited.add(start);

        const neighbors = this.connections
            .filter(c => c.from === start || c.to === start)
            .map(c => c.from === start ? c.to : c.from)
            .filter(n => !visited.has(n));

        for (let neighbor of neighbors) {
            const path = this.findPath(neighbor, end, new Set(visited));
            if (path.length > 0) {
                return [start, ...path];
            }
        }

        return [];
    }

    animatePacket(path, packetType) {
        let index = 0;
        const colors = {
            icmp: '#3498db',
            tcp: '#2ecc71',
            udp: '#e74c3c'
        };

        const animate = () => {
            if (index < path.length - 1) {
                this.render();
                this.drawPacket(path[index], path[index + 1], 0.5, colors[packetType] || '#ff6b6b');
                this.logSimulation(`Packet at ${path[index].name}`);
                index++;
                setTimeout(animate, 800);
            } else {
                this.render();
                this.logSimulation(`✓ Packet delivered to ${path[path.length - 1].name}`);
            }
        };

        animate();
    }

    drawPacket(from, to, progress, color) {
        const x = from.x + (to.x - from.x) * progress;
        const y = from.y + (to.y - from.y) * progress;

        this.ctx.fillStyle = color;
        this.ctx.beginPath();
        this.ctx.arc(x, y, 8, 0, Math.PI * 2);
        this.ctx.fill();

        this.ctx.strokeStyle = '#fff';
        this.ctx.lineWidth = 2;
        this.ctx.stroke();
    }

    clearAll() {
        if (confirm('Clear all devices and connections?')) {
            const deviceCount = this.devices.length;
            const connectionCount = this.connections.length;
            this.devices = [];
            this.connections = [];
            this.render();
            this.logConsole('warning', `Workspace cleared: ${deviceCount} devices and ${connectionCount} connections removed`);
        }
    }

    render() {
        // Clear canvas
        this.ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);

        // Draw grid
        this.drawGrid();

        // Draw connections
        this.connections.forEach(conn => {
            this.ctx.strokeStyle = '#34495e';
            this.ctx.lineWidth = 2;
            this.ctx.beginPath();
            this.ctx.moveTo(conn.from.x, conn.from.y);
            this.ctx.lineTo(conn.to.x, conn.to.y);
            this.ctx.stroke();
        });

        // Draw devices
        this.devices.forEach(device => {
            this.drawDevice(device);
        });
    }

    drawGrid() {
        this.ctx.strokeStyle = '#ecf0f1';
        this.ctx.lineWidth = 0.5;

        for (let x = 0; x < this.canvas.width; x += 50) {
            this.ctx.beginPath();
            this.ctx.moveTo(x, 0);
            this.ctx.lineTo(x, this.canvas.height);
            this.ctx.stroke();
        }

        for (let y = 0; y < this.canvas.height; y += 50) {
            this.ctx.beginPath();
            this.ctx.moveTo(0, y);
            this.ctx.lineTo(this.canvas.width, y);
            this.ctx.stroke();
        }
    }

    drawDevice(device) {
        const size = 45;
        const colors = {
            // Network Devices
            'router': '#3498db',
            'switch': '#2ecc71',
            'hub': '#95a5a6',
            'modem': '#16a085',
            'access-point': '#27ae60',

            // Security
            'firewall': '#e74c3c',
            'ids': '#c0392b',

            // Servers
            'web-server': '#f39c12',
            'database-server': '#d35400',
            'mail-server': '#e67e22',
            'dns-server': '#f1c40f',
            'ftp-server': '#9b59b6',
            'proxy-server': '#8e44ad',

            // Storage & Others
            'nas': '#34495e',
            'load-balancer': '#1abc9c',

            // Home & IoT
            'wifi-router': '#3498db',
            'mesh-node': '#5dade2',
            'range-extender': '#85c1e9',
            'smart-tv': '#e74c3c',
            'gaming-console': '#9b59b6',
            'smart-speaker': '#1abc9c',
            'security-camera': '#34495e',
            'smart-thermostat': '#e67e22',
            'smart-lock': '#f39c12',
            'iot-sensor': '#16a085',
            'smart-plug': '#27ae60',
            'home-hub': '#2c3e50',

            // WAN/Internet
            'internet': '#2980b9',
            'cloud': '#5dade2',

            // End Devices
            'pc': '#9b59b6',
            'laptop': '#8e44ad',
            'smartphone': '#3498db',
            'tablet': '#5dade2',
            'printer': '#7f8c8d'
        };

        const icons = {
            // Network Devices
            'router': '🔀',
            'switch': '⚡',
            'hub': '🔘',
            'modem': '📡',
            'access-point': '📶',

            // Security
            'firewall': '🔥',
            'ids': '🛡️',

            // Servers
            'web-server': '🌐',
            'database-server': '🗄️',
            'mail-server': '📧',
            'dns-server': '🔤',
            'ftp-server': '📁',
            'proxy-server': '🔄',

            // Storage & Others
            'nas': '💾',
            'load-balancer': '⚖️',

            // Home & IoT
            'wifi-router': '📡',
            'mesh-node': '🔗',
            'range-extender': '📶',
            'smart-tv': '📺',
            'gaming-console': '🎮',
            'smart-speaker': '🔊',
            'security-camera': '📹',
            'smart-thermostat': '🌡️',
            'smart-lock': '🔐',
            'iot-sensor': '📡',
            'smart-plug': '🔌',
            'home-hub': '🏠',

            // WAN/Internet
            'internet': '🌍',
            'cloud': '☁️',

            // End Devices
            'pc': '💻',
            'laptop': '💻',
            'smartphone': '📱',
            'tablet': '📱',
            'printer': '🖨️'
        };

        // Draw device box with rounded corners
        this.ctx.fillStyle = colors[device.type] || '#95a5a6';
        this.roundRect(device.x - size/2, device.y - size/2, size, size, 5);
        this.ctx.fill();

        // Draw border
        this.ctx.strokeStyle = device === this.selectedDevice ? '#f39c12' : '#2c3e50';
        this.ctx.lineWidth = device === this.selectedDevice ? 3 : 2;
        this.roundRect(device.x - size/2, device.y - size/2, size, size, 5);
        this.ctx.stroke();

        // Draw icon
        this.ctx.font = '26px Arial';
        this.ctx.textAlign = 'center';
        this.ctx.textBaseline = 'middle';
        this.ctx.fillText(icons[device.type] || '❓', device.x, device.y);

        // Draw name with background
        this.ctx.fillStyle = 'rgba(255, 255, 255, 0.9)';
        const nameWidth = this.ctx.measureText(device.name).width + 8;
        this.roundRect(device.x - nameWidth/2, device.y + size/2 + 5, nameWidth, 18, 3);
        this.ctx.fill();

        this.ctx.fillStyle = '#2c3e50';
        this.ctx.font = 'bold 11px Arial';
        this.ctx.fillText(device.name, device.x, device.y + size/2 + 14);

        // Draw IP if configured
        if (device.ip) {
            this.ctx.fillStyle = 'rgba(255, 255, 255, 0.9)';
            const ipWidth = this.ctx.measureText(device.ip).width + 8;
            this.roundRect(device.x - ipWidth/2, device.y + size/2 + 25, ipWidth, 16, 3);
            this.ctx.fill();

            this.ctx.fillStyle = '#7f8c8d';
            this.ctx.font = '10px Arial';
            this.ctx.fillText(device.ip, device.x, device.y + size/2 + 33);
        }
    }

    roundRect(x, y, width, height, radius) {
        this.ctx.beginPath();
        this.ctx.moveTo(x + radius, y);
        this.ctx.lineTo(x + width - radius, y);
        this.ctx.quadraticCurveTo(x + width, y, x + width, y + radius);
        this.ctx.lineTo(x + width, y + height - radius);
        this.ctx.quadraticCurveTo(x + width, y + height, x + width - radius, y + height);
        this.ctx.lineTo(x + radius, y + height);
        this.ctx.quadraticCurveTo(x, y + height, x, y + height - radius);
        this.ctx.lineTo(x, y + radius);
        this.ctx.quadraticCurveTo(x, y, x + radius, y);
        this.ctx.closePath();
    }

    // Save and Load Topology
    saveTopology() {
        try {
            const topologyName = this.topologyName || 'My Network';
            const fileName = topologyName.toLowerCase().replace(/[^a-z0-9]+/g, '_');

            // Create a clean copy of devices without circular references
            const devicesClean = this.devices.map(device => {
                const cleanDevice = {
                    id: device.id,
                    type: device.type,
                    x: device.x,
                    y: device.y,
                    name: device.name,
                    mac: device.mac,
                    ip: device.ip,
                    subnet: device.subnet,
                    gateway: device.gateway,
                    ports: device.ports.map(port => ({
                        id: port.id,
                        name: port.name,
                        status: port.status,
                        connectedTo: port.connectedTo ? {
                            deviceId: port.connectedTo.device.id,
                            port: port.connectedTo.port
                        } : null
                    })),
                    routingTable: device.routingTable,
                    arpTable: device.arpTable,
                    dhcpEnabled: device.dhcpEnabled,
                    dhcpRange: device.dhcpRange,
                    dhcpLeases: device.dhcpLeases
                };
                return cleanDevice;
            });

            const topology = {
                name: topologyName,
                version: '2.0.0',
                created: new Date().toISOString(),
                devices: devicesClean,
                connections: this.connections.map(conn => ({
                    fromId: conn.from.id,
                    toId: conn.to.id,
                    fromPort: conn.fromPort,
                    toPort: conn.toPort
                }))
            };

            const dataStr = JSON.stringify(topology, null, 2);
            const dataBlob = new Blob([dataStr], { type: 'application/json' });
            const url = URL.createObjectURL(dataBlob);

            const link = document.createElement('a');
            link.href = url;
            link.download = `${fileName}_${new Date().toISOString().slice(0,10)}.json`;
            link.click();

            URL.revokeObjectURL(url);
            this.logConsole('success', `Topology saved: ${this.devices.length} devices, ${this.connections.length} connections`);
        } catch (error) {
            this.logConsole('error', `Failed to save topology: ${error.message}`);
        }
    }

    loadTopology() {
        const input = document.createElement('input');
        input.type = 'file';
        input.accept = '.json';

        input.onchange = (e) => {
            const file = e.target.files[0];
            if (!file) return;

            const reader = new FileReader();
            reader.onload = (event) => {
                try {
                    const topology = JSON.parse(event.target.result);

                    // Set topology name
                    if (topology.name) {
                        this.topologyName = topology.name;
                        document.getElementById('topology-name').value = topology.name;
                    }

                    // Restore devices
                    this.devices = topology.devices;

                    // Rebuild port connections with device references
                    this.devices.forEach(device => {
                        device.ports.forEach(port => {
                            if (port.connectedTo) {
                                const connectedDevice = this.devices.find(d => d.id === port.connectedTo.deviceId);
                                if (connectedDevice) {
                                    port.connectedTo.device = connectedDevice;
                                }
                            }
                        });
                    });

                    // Rebuild connections with device object references
                    this.connections = [];
                    topology.connections.forEach(conn => {
                        const fromDevice = this.devices.find(d => d.id === conn.fromId);
                        const toDevice = this.devices.find(d => d.id === conn.toId);

                        if (fromDevice && toDevice) {
                            this.connections.push({
                                from: fromDevice,
                                to: toDevice,
                                fromPort: conn.fromPort,
                                toPort: conn.toPort
                            });
                        }
                    });

                    this.render();
                    this.logConsole('success', `✅ Topology loaded: ${this.devices.length} devices, ${this.connections.length} connections`);
                } catch (error) {
                    this.logConsole('error', `Failed to load topology: ${error.message}`);
                    alert(`Error loading topology: ${error.message}`);
                }
            };

            reader.readAsText(file);
        };

        input.click();
    }

    exportAsImage() {
        const link = document.createElement('a');
        link.download = `network_topology_${new Date().toISOString().slice(0,10)}.png`;
        link.href = this.canvas.toDataURL();
        link.click();
        this.logConsole('success', 'Topology exported as image');
    }

    updateStatus(message) {
        // Compatibility method - redirects to console
        this.logConsole('info', message);
    }

    // Continuous Simulation
    toggleContinuousSimulation(button) {
        this.continuousSimulation = !this.continuousSimulation;

        if (this.continuousSimulation) {
            button.classList.add('active');
            button.style.background = '#27ae60';
            this.startContinuousSimulation();
            this.logConsole('success', '🔄 Continuous simulation started - simulating network traffic');
        } else {
            button.classList.remove('active');
            button.style.background = '';
            this.stopContinuousSimulation();
            this.logConsole('info', '⏸️ Continuous simulation stopped');
        }
    }

    startContinuousSimulation() {
        if (this.devices.length < 2) {
            this.logConsole('warning', 'Need at least 2 devices for continuous simulation');
            return;
        }

        this.continuousSimInterval = setInterval(() => {
            this.simulateRandomTraffic();
        }, this.simulationSpeed);
    }

    stopContinuousSimulation() {
        if (this.continuousSimInterval) {
            clearInterval(this.continuousSimInterval);
            this.continuousSimInterval = null;
        }
    }

    simulateRandomTraffic() {
        // Get devices with IPs
        const devicesWithIP = this.devices.filter(d => d.ip);

        if (devicesWithIP.length < 2) {
            return;
        }

        // Pick random source and destination
        const source = devicesWithIP[Math.floor(Math.random() * devicesWithIP.length)];
        let dest = devicesWithIP[Math.floor(Math.random() * devicesWithIP.length)];

        // Ensure source and dest are different
        let attempts = 0;
        while (dest === source && attempts < 10) {
            dest = devicesWithIP[Math.floor(Math.random() * devicesWithIP.length)];
            attempts++;
        }

        if (dest === source) return;

        // Random protocol
        const protocols = [
            { type: 'arp', name: 'ARP', desc: 'ARP request' },
            { type: 'icmp', name: 'ICMP', desc: 'Ping' },
            { type: 'tcp', name: 'HTTP', desc: 'Web request' },
            { type: 'udp', name: 'UDP', desc: 'Data transfer' },
            { type: 'dns', name: 'DNS', desc: 'Domain lookup' }
        ];

        const protocol = protocols[Math.floor(Math.random() * protocols.length)];

        // Simulate the traffic
        this.simulateTrafficBetween(source, dest, protocol);
    }

    simulateTrafficBetween(source, dest, protocol) {
        const path = this.findPath(source, dest);

        if (path.length === 0) {
            return; // No path, silently skip
        }

        // Log to console
        const protocolIcon = {
            'arp': '🔍',
            'icmp': '🏓',
            'tcp': '🌐',
            'udp': '📦',
            'dns': '🔤'
        };

        const icon = protocolIcon[protocol.type] || '📡';

        // Basic log
        let message = `${icon} ${protocol.name}: ${source.name} (${source.ip}) → ${dest.name} (${dest.ip}) - ${protocol.desc}`;

        // Verbose mode: Add detailed information
        if (this.verboseMode) {
            message += `\n    ↳ Path: ${path.map(d => d.name).join(' → ')}`;
            message += `\n    ↳ Hops: ${path.length - 1}`;
            message += `\n    ↳ Source MAC: ${source.mac}`;
            message += `\n    ↳ Dest MAC: ${dest.mac}`;

            // Protocol-specific details
            if (protocol.type === 'tcp') {
                message += `\n    ↳ TCP Flags: SYN, ACK | Port: 80 (HTTP)`;
                message += `\n    ↳ Sequence: ${Math.floor(Math.random() * 10000)}`;
            } else if (protocol.type === 'udp') {
                message += `\n    ↳ UDP Port: ${Math.floor(Math.random() * 10000 + 50000)}`;
                message += `\n    ↳ Packet Size: ${Math.floor(Math.random() * 1000 + 500)} bytes`;
            } else if (protocol.type === 'dns') {
                const domains = ['google.com', 'facebook.com', 'amazon.com', 'netflix.com', 'microsoft.com'];
                message += `\n    ↳ Query: ${domains[Math.floor(Math.random() * domains.length)]}`;
                message += `\n    ↳ Query Type: A (IPv4 address)`;
            } else if (protocol.type === 'arp') {
                message += `\n    ↳ ARP Type: Request`;
                message += `\n    ↳ Who has ${dest.ip}? Tell ${source.ip}`;
            } else if (protocol.type === 'icmp') {
                message += `\n    ↳ ICMP Type: Echo Request`;
                message += `\n    ↳ TTL: ${64 - (path.length - 1)}`;
            }

            // Network layer info
            if (source.subnet) {
                message += `\n    ↳ Subnet: ${source.subnet}`;
            }
        }

        this.logConsole('packet', message);

        // Animate packet
        this.animatePacketContinuous(path, protocol.type);
    }

    animatePacketContinuous(path, packetType) {
        let index = 0;
        const colors = {
            icmp: '#3498db',
            tcp: '#2ecc71',
            udp: '#e74c3c',
            arp: '#f39c12',
            dns: '#9b59b6'
        };

        const color = colors[packetType] || '#95a5a6';

        const animate = () => {
            if (index < path.length - 1 && this.continuousSimulation) {
                this.render();

                // Draw all active packets
                const progress = 0.5;
                this.drawPacket(path[index], path[index + 1], progress, color);

                index++;
                setTimeout(animate, 400);
            } else {
                this.render();
            }
        };

        animate();
    }
}

// Initialize application
const app = new PacketTracer();
