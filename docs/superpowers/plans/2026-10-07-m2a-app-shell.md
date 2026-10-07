# M2a — Electron app: build, configure and test a network (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A desktop app in which you drag devices onto a canvas, cable them, set IP addresses and routes in an inspector, run ping/traceroute and read the output and live ARP/MAC/routing tables — with undo/redo and save/open of `.ptk` files.

**Architecture:** The M1 engine runs inside a Web Worker behind a `Runtime` that turns typed `Command`s into engine calls and emits full `Snapshot`s (on every reply and every 50 ms tick). The React UI keeps only presentation state (positions, selection, menu, history) in a Zustand store; all edits go through `actions.ts`, which is unit-tested in Node against a real `Runtime`. Electron's main process only opens windows, owns the menu and reads/writes files via IPC.

**Tech Stack:** Electron 44, Vite 8, React 19, @xyflow/react 12, Zustand 5, Tailwind CSS 4, lucide-react, Vitest 4, Playwright (Electron mode), TypeScript 7.

**Spec:** `docs/superpowers/specs/2026-10-07-pac-track-rewrite-design.md` (§4, §6, §7, §8, §9 — milestone M2, first half)

**Milestone split (ruling):** spec M2 is split in two plans so each produces working software:
- **M2a (this plan):** shell, worker, canvas editing, inspector (Interfacce/Routing/Tabelle/App), output panel, context menus, undo/redo, save/open.
- **M2b (next plan):** Realtime/Simulation switch with step, event list + PDU inspector, packet animation on links, link properties editor, power on/off, duplicate/copy/paste, palette search, resizable bottom panel, L2-loop warning.

**Deviations from the spec, chosen for simplicity (review these):**
1. **Undo/redo uses topology snapshots** (memento) instead of per-command inverses (§8). Undoing a *network* change reloads the network: clock, ARP/MAC caches and running apps restart. Undoing a *move* only restores positions.
2. **The worker sends full snapshots** at 20 Hz instead of deltas (§6). Fine for the small/medium networks the app targets; switch to deltas if profiling says so.
3. **Plain Tailwind + lucide icons** instead of Radix/shadcn (§2) — six small primitives cover M2a.
4. **Engine error messages stay in English** in the Italian UI (e.g. `Invalid CIDR: "x"`).
5. **No CSP meta tag**: the renderer loads only local files, runs sandboxed with context isolation and no Node.

## Global Constraints

- `src/engine/**`, `src/shared/**` and `src/worker/runtime.ts` stay DOM-free: they are type-checked by `tsconfig.json` (lib `ES2022` only). UI code is type-checked by `tsconfig.ui.json` (adds DOM + JSX).
- Renderer runs with `contextIsolation: true`, `nodeIntegration: false`, `sandbox: true`; the only bridge is `window.pac` (`openFile`, `saveFile`, `onMenu`).
- Every network change goes through `edit()` (one undo step per user action); non-topology commands (ping, traceroute, play/pause, speed) go through `run()`.
- User-facing copy is Italian; code, comments, test names and commits are English.
- Colors only from the theme tokens in `src/ui/theme.css` (spec §7.3).
- `npm install` must use `--cache "$TMPDIR/npm-cache"` (the sandbox blocks `~/.npm`).
- Every commit message ends with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01FbFogmKCbqCctTUt5TujDV
  ```

## Review Focus

1. **Two edits in quick succession** (second command sent before the first snapshot lands) → the second undo step must contain the first change. Pinned by design: the worker sends the snapshot in the same message as the reply, and the client applies it before resolving (Task 4); `actions.test.ts` drives consecutive awaited edits (Task 3).
2. **Opening a corrupt or foreign `.ptk`** → clear error in the toolbar, open project untouched. Pinned in Task 3 (`rejects a corrupt file…`) and Task 2 (`loads a topology atomically`).
3. **Deleting a node that has cables** → one undo step restores node *and* cables. Pinned in Task 3.
4. **Machine sleeps / window hidden for minutes** → simulation must not try to catch up hours at once. Pinned in Task 2 (wall time clamped to 100 ms per tick).
5. **Connecting a device whose ports are all used** → readable error, no cable. Pinned in Task 3 (`connects through the first free ports…`).

## File Structure

```
index.html                    Vite entry (renderer)
vite.config.ts                renderer build (base './', react, tailwind)
vitest.config.ts              unit tests: src/**/*.test.ts only
playwright.config.ts          e2e against the built app
tsconfig.json                 engine + shared + runtime (no DOM)
tsconfig.ui.json              everything in src with DOM + JSX
scripts/dev.mjs               vite dev server + electron
electron/main.mjs             window, menu, file IPC
electron/preload.cjs          window.pac bridge
src/engine/index.ts           public engine API (new)
src/shared/protocol.ts        Command / Snapshot / Topology types
src/worker/runtime.ts         Command → engine, Snapshot builder, clock
src/worker/engine.worker.ts   postMessage adapter + 50 ms tick
src/ui/main.tsx               React root, worker connection
src/ui/theme.css              Tailwind + design tokens
src/ui/store.ts               Zustand store (presentation state)
src/ui/topology.ts            pure helpers (names, ports, topology <-> snapshot)
src/ui/actions.ts             all user actions, undo/redo, project text
src/ui/engine-client.ts       Worker-backed EngineClient
src/ui/files.ts               open/save through window.pac
src/ui/shortcuts.ts           menu commands + Space/Escape
src/ui/ui.tsx                 ToolButton, Button, Field, ErrorText, Tabs
src/ui/icons.tsx              DeviceIcon
src/ui/App.tsx                layout
src/ui/Toolbar.tsx            file, history, clock controls
src/ui/Palette.tsx            draggable device list
src/ui/DeviceNode.tsx         React Flow node
src/ui/Canvas.tsx             React Flow canvas
src/ui/Inspector.tsx          node/link inspector with tabs
src/ui/OutputPanel.tsx        app output
src/ui/ContextMenu.tsx        pane/node/link menus
e2e/helpers.ts                launch + gestures
e2e/*.spec.ts                 end-to-end tests
```

---

### Task 1: Engine views, removal and public API

**Files:**
- Modify: `src/engine/link.ts`, `src/engine/l3/routing.ts`, `src/engine/l3/arp.ts`, `src/engine/devices/switch.ts`
- Create: `src/engine/index.ts`
- Test: `src/engine/link.test.ts`, `src/engine/l3/routing.test.ts`, `src/engine/l3/ip.test.ts`, `src/engine/devices/l2.test.ts`

**Interfaces:**
- Produces: `Link.disconnect(): void`; `RoutingTable.removeStatic(cidr: string): void`; `interface RouteView { kind: 'connected' | 'static'; network: number; prefix: number; nextHop?: number; iface: string }`; `RoutingTable.view(): RouteView[]`; `interface ArpEntry { ip: number; mac: Mac; iface: string; expiresAt: number }`; `Arp.entries(): ArpEntry[]`; `Switch.macTable(): { mac: Mac; iface: string; ageNs: number }[]`; `src/engine/index.ts` re-exporting the engine.

- [ ] **Step 1: Write the failing tests**

Append inside `describe('Link', …)` in `src/engine/link.test.ts`:

```ts
  it('disconnect frees both interfaces and later frames find no cable', () => {
    const { sim, a, b, link } = pair()
    link.disconnect()
    expect(a.iface('eth0').link).toBeUndefined()
    expect(b.iface('eth0').link).toBeUndefined()
    a.sendRaw()
    sim.run(MS)
    expect(drops(sim, 'no-link')).toBe(1)
    const c = new Probe(sim, 'C')
    expect(() => new Link(sim, a.iface('eth0'), c.iface('eth0'))).not.toThrow()
  })

  it('frames on the wire or queued when the cable is pulled never arrive', () => {
    const { sim, a, b, link } = pair()
    a.sendRaw()
    a.sendRaw()
    link.disconnect()
    sim.run(MS)
    expect(b.got).toHaveLength(0)
    expect(sim.log.all().filter((e) => e.kind === 'tx')).toHaveLength(1)
  })
```

Append inside `describe('RoutingTable', …)` in `src/engine/l3/routing.test.ts`:

```ts
  it('lists and removes static routes', () => {
    const { rt } = setup()
    rt.addStatic('10.0.2.0/24', '10.0.12.2')
    const rows = () =>
      rt.view().map((r) => `${r.kind} ${formatIp(r.network)}/${r.prefix} ${r.nextHop === undefined ? '-' : formatIp(r.nextHop)} ${r.iface}`)
    expect(rows()).toEqual([
      'connected 10.0.1.0/24 - eth0',
      'connected 10.0.12.0/30 - eth1',
      'static 10.0.2.0/24 10.0.12.2 eth1',
    ])
    rt.removeStatic('10.0.2.7/24')
    expect(hop(rt, '10.0.2.1')).toBeUndefined()
    expect(rows()).toHaveLength(2)
  })
```

Append inside `describe('ARP + ICMP on a LAN', …)` in `src/engine/l3/ip.test.ts`:

```ts
  it('lists live ARP entries until they expire', () => {
    const { sim, a, b } = lan()
    a.sendPacket(parseIp('10.0.0.2'), echo())
    sim.run(MS)
    expect(a.arp.entries()).toEqual([
      { ip: parseIp('10.0.0.2'), mac: b.iface('eth0').mac, iface: 'eth0', expiresAt: expect.any(Number) },
    ])
    sim.run(301 * S)
    expect(a.arp.entries()).toEqual([])
  })
```

Append inside `describe('Switch', …)` in `src/engine/devices/l2.test.ts`:

```ts
  it('lists the MAC table without aged entries', () => {
    const sim = new Sim()
    const sw = new Switch(sim, 'SW1')
    const [a] = star(sim, sw, ['A', 'B'])
    a.sendRaw()
    sim.run(MS)
    expect(sw.macTable()).toEqual([{ mac: a.iface('eth0').mac, iface: 'Gi0/1', ageNs: expect.any(Number) }])
    sim.run(301 * S)
    expect(sw.macTable()).toEqual([])
  })
```

- [ ] **Step 2: Run them to verify they fail**

Run: `npx vitest run src/engine`
Expected: FAIL — `link.disconnect is not a function`, `rt.view is not a function`, `a.arp.entries is not a function`, `sw.macTable is not a function`.

- [ ] **Step 3: Implement**

In `src/engine/link.ts`, add this method after `peer(...)`:

```ts
  /** Pulls the cable: both interfaces become free, frames in flight are lost. */
  disconnect(): void {
    this.up = false
    this.a.link = undefined
    this.b.link = undefined
  }
```

and in `startTx`, replace

```ts
      const next = dir.queue.shift()
      if (next) this.startTx(from, dir, next)
      else dir.busy = false
```

with

```ts
      const next = this.up ? dir.queue.shift() : undefined
      if (next) this.startTx(from, dir, next)
      else {
        dir.busy = false
        dir.queue.length = 0
      }
```

In `src/engine/l3/routing.ts`, add after the `NextHop` interface:

```ts
export interface RouteView {
  kind: 'connected' | 'static'
  network: number
  prefix: number
  nextHop?: number
  iface: string
}
```

and add these methods after `addStatic(...)`:

```ts
  removeStatic(cidr: string): void {
    const { addr, prefix } = parseCidr(cidr)
    const network = networkOf(addr, prefix)
    this.statics = this.statics.filter((r) => !(r.network === network && r.prefix === prefix))
  }

  view(): RouteView[] {
    const connected: RouteView[] = this.interfaces()
      .filter((i) => i.up && i.ipv4)
      .map((i) => ({ kind: 'connected', network: networkOf(i.ipv4!.addr, i.ipv4!.prefix), prefix: i.ipv4!.prefix, iface: i.name }))
    const statics: RouteView[] = this.statics.map((r) => ({
      kind: 'static',
      network: r.network,
      prefix: r.prefix,
      nextHop: r.nextHop,
      iface: this.connectedFor(r.nextHop)?.iface.name ?? '-',
    }))
    return [...connected, ...statics]
  }
```

In `src/engine/l3/arp.ts`, add after the `Pending` interface:

```ts
export interface ArpEntry {
  ip: number
  mac: Mac
  iface: string
  expiresAt: number
}
```

and after `lookup(...)`:

```ts
  entries(): ArpEntry[] {
    return [...this.cache]
      .filter(([, e]) => this.node.sim.now < e.expiresAt)
      .map(([ip, e]) => ({ ip, mac: e.mac, iface: e.iface.name, expiresAt: e.expiresAt }))
  }
```

In `src/engine/devices/switch.ts`, add after `lookup(...)`:

```ts
  macTable(): { mac: Mac; iface: string; ageNs: number }[] {
    return [...this.table]
      .filter(([mac]) => this.lookup(mac))
      .map(([mac, e]) => ({ mac, iface: e.iface.name, ageNs: this.sim.now - e.seen }))
  }
```

Create `src/engine/index.ts`:

```ts
export * from './time'
export * from './rng'
export * from './scheduler'
export * from './addr'
export * from './pdu'
export * from './events'
export * from './sim'
export * from './node'
export * from './link'
export * from './devices/hub'
export * from './devices/switch'
export * from './devices/host'
export * from './devices/router'
export * from './l3/routing'
export * from './l3/arp'
export * from './l3/ip-node'
export * from './apps/ping'
export * from './apps/traceroute'
```

- [ ] **Step 4: Run tests**

Run: `npm test && npm run typecheck`
Expected: all PASS (74 tests), typecheck exits 0.

- [ ] **Step 5: Commit**

```bash
git add src/engine
git commit -m "feat(engine): add table views, route removal, cable disconnect and public index"
```

---

### Task 2: Shared protocol and worker Runtime

**Files:**
- Create: `src/shared/protocol.ts`, `src/worker/runtime.ts`
- Modify: `tsconfig.json` (`include`)
- Test: `src/worker/runtime.test.ts`

**Interfaces:**
- Consumes: engine public API from `src/engine/index.ts` (Task 1)
- Produces:
  - `type DeviceKind = 'pc' | 'laptop' | 'server' | 'router' | 'switch' | 'hub'`; `IfaceRef { node; iface }`; `Pos { x; y }`
  - `type Command` (union: `addNode`, `removeNode`, `rename`, `connect`, `disconnect`, `setIp`, `addRoute`, `removeRoute`, `ping`, `traceroute`, `setRunning`, `setSpeed`, `load`); `type Request = Command & { reqId: number }`; `type Reply`
  - `IfaceView`, `RouteRow`, `ArpRow`, `MacRow`, `NodeView`, `LinkView`, `AppView`, `Snapshot`, `TopologyNode`, `Topology`, `WorkerMessage`, `SPEEDS`
  - `class Runtime { constructor(seed = 1); running: boolean; speed: number; handle(cmd: Command): void /* throws Error */; advance(wallMs: number): void; snapshot(): Snapshot }`

- [ ] **Step 1: Point the no-DOM typecheck at the new folders**

In `tsconfig.json` replace `"include": ["src"]` with:

```json
  "include": ["src/engine", "src/shared", "src/worker/runtime.ts", "src/worker/runtime.test.ts"]
```

- [ ] **Step 2: Write the protocol types**

`src/shared/protocol.ts`:

```ts
export type DeviceKind = 'pc' | 'laptop' | 'server' | 'router' | 'switch' | 'hub'

export interface IfaceRef {
  node: string
  iface: string
}

export interface Pos {
  x: number
  y: number
}

export type Command =
  | { type: 'addNode'; id: string; kind: DeviceKind; name: string }
  | { type: 'removeNode'; id: string }
  | { type: 'rename'; id: string; name: string }
  | { type: 'connect'; id: string; a: IfaceRef; b: IfaceRef }
  | { type: 'disconnect'; id: string }
  | { type: 'setIp'; node: string; iface: string; cidr: string | null }
  | { type: 'addRoute'; node: string; cidr: string; nextHop: string }
  | { type: 'removeRoute'; node: string; cidr: string }
  | { type: 'ping'; node: string; target: string }
  | { type: 'traceroute'; node: string; target: string }
  | { type: 'setRunning'; running: boolean }
  | { type: 'setSpeed'; speed: number }
  | { type: 'load'; topology: Topology }

export type Request = Command & { reqId: number }
export type Reply = { reqId: number; ok: true } | { reqId: number; ok: false; error: string }

export interface IfaceView {
  name: string
  mac: string
  cidr: string | null
  linked: boolean
}

export interface RouteRow {
  kind: 'connected' | 'static'
  dest: string
  nextHop: string | null
  iface: string
}

export interface ArpRow {
  ip: string
  mac: string
  iface: string
  ttlS: number
}

export interface MacRow {
  mac: string
  iface: string
  ageS: number
}

export interface NodeView {
  id: string
  kind: DeviceKind
  name: string
  ifaces: IfaceView[]
  routes: RouteRow[]
  arp: ArpRow[]
  mac: MacRow[]
}

export interface LinkView {
  id: string
  a: IfaceRef
  b: IfaceRef
}

export interface AppView {
  id: number
  node: string
  title: string
  lines: string[]
  done: boolean
}

export interface Snapshot {
  seed: number
  timeNs: number
  running: boolean
  speed: number
  nodes: NodeView[]
  links: LinkView[]
  apps: AppView[]
}

export interface TopologyNode {
  id: string
  kind: DeviceKind
  name: string
  pos: Pos
  ifaces: { name: string; cidr: string | null }[]
  routes: { cidr: string; nextHop: string }[]
}

/** Project file format (`.ptk`). */
export interface Topology {
  version: 1
  seed: number
  nodes: TopologyNode[]
  links: LinkView[]
}

export type WorkerMessage =
  | { type: 'reply'; reply: Reply; snapshot: Snapshot }
  | { type: 'tick'; snapshot: Snapshot }

export const SPEEDS = [0.1, 0.5, 1, 2, 5, 10, 100]
```

- [ ] **Step 3: Write the failing test**

`src/worker/runtime.test.ts`:

```ts
import { describe, expect, it } from 'vitest'
import type { Topology } from '../shared/protocol'
import { Runtime } from './runtime'

function lan() {
  const rt = new Runtime()
  rt.handle({ type: 'addNode', id: 'a', kind: 'pc', name: 'PC1' })
  rt.handle({ type: 'addNode', id: 'b', kind: 'pc', name: 'PC2' })
  rt.handle({ type: 'addNode', id: 's', kind: 'switch', name: 'SW1' })
  rt.handle({ type: 'connect', id: 'l1', a: { node: 'a', iface: 'eth0' }, b: { node: 's', iface: 'Gi0/1' } })
  rt.handle({ type: 'connect', id: 'l2', a: { node: 'b', iface: 'eth0' }, b: { node: 's', iface: 'Gi0/2' } })
  rt.handle({ type: 'setIp', node: 'a', iface: 'eth0', cidr: '10.0.0.1/24' })
  rt.handle({ type: 'setIp', node: 'b', iface: 'eth0', cidr: '10.0.0.2/24' })
  return rt
}

const runFor = (rt: Runtime, wallMs: number) => {
  for (let t = 0; t < wallMs; t += 100) rt.advance(100)
}

describe('Runtime', () => {
  it('builds a network from commands and reports it in the snapshot', () => {
    const s = lan().snapshot()
    expect(s.nodes.map((n) => `${n.name}:${n.kind}`)).toEqual(['PC1:pc', 'PC2:pc', 'SW1:switch'])
    expect(s.nodes[0].ifaces).toEqual([{ name: 'eth0', mac: expect.any(String), cidr: '10.0.0.1/24', linked: true }])
    expect(s.nodes[0].routes).toEqual([{ kind: 'connected', dest: '10.0.0.0/24', nextHop: null, iface: 'eth0' }])
    expect(s.links).toEqual([
      { id: 'l1', a: { node: 'a', iface: 'eth0' }, b: { node: 's', iface: 'Gi0/1' } },
      { id: 'l2', a: { node: 'b', iface: 'eth0' }, b: { node: 's', iface: 'Gi0/2' } },
    ])
  })

  it('runs ping as an app and fills ARP and MAC tables', () => {
    const rt = lan()
    rt.handle({ type: 'ping', node: 'a', target: '10.0.0.2' })
    runFor(rt, 15_000)
    const s = rt.snapshot()
    expect(s.apps).toHaveLength(1)
    expect(s.apps[0]).toMatchObject({ node: 'a', title: 'ping 10.0.0.2', done: true })
    expect(s.apps[0].lines).toContain('4 packets transmitted, 4 received, 0% packet loss')
    expect(s.nodes[0].arp.map((r) => r.ip)).toEqual(['10.0.0.2'])
    expect(s.nodes[2].mac).toHaveLength(2)
  })

  it('advances simulated time by wall time × speed, clamped, and only while running', () => {
    const rt = new Runtime()
    rt.advance(50)
    expect(rt.snapshot().timeNs).toBe(50_000_000)
    rt.handle({ type: 'setSpeed', speed: 10 })
    rt.advance(50)
    expect(rt.snapshot().timeNs).toBe(550_000_000)
    rt.advance(600_000) // ten minutes asleep: only 100 ms of wall time count
    expect(rt.snapshot().timeNs).toBe(1_550_000_000)
    rt.handle({ type: 'setRunning', running: false })
    rt.advance(50)
    expect(rt.snapshot().timeNs).toBe(1_550_000_000)
    expect(() => rt.handle({ type: 'setSpeed', speed: 0 })).toThrow(/Invalid speed/)
  })

  it('rejects invalid commands with clear errors and no side effects', () => {
    const rt = lan()
    expect(() => rt.handle({ type: 'setIp', node: 'a', iface: 'eth0', cidr: '10.0.0.300/24' })).toThrow(/Invalid IPv4/)
    expect(() => rt.handle({ type: 'addNode', id: 'a', kind: 'pc', name: 'X' })).toThrow(/already exists/)
    expect(() =>
      rt.handle({ type: 'connect', id: 'l3', a: { node: 'a', iface: 'eth0' }, b: { node: 's', iface: 'Gi0/3' } }),
    ).toThrow(/already connected/)
    expect(() => rt.handle({ type: 'ping', node: 's', target: '10.0.0.1' })).toThrow(/no IP stack/)
    expect(() => rt.handle({ type: 'removeNode', id: 'zz' })).toThrow(/Unknown node/)
    expect(() => rt.handle({ type: 'rename', id: 'a', name: '  ' })).toThrow(/empty/)
    expect(rt.snapshot().nodes[0].ifaces[0].cidr).toBe('10.0.0.1/24')
    expect(rt.snapshot().links).toHaveLength(2)
  })

  it('removing a node removes its cables and stops its apps', () => {
    const rt = lan()
    rt.handle({ type: 'ping', node: 'a', target: '10.0.0.2' })
    rt.handle({ type: 'removeNode', id: 's' })
    rt.handle({ type: 'removeNode', id: 'a' })
    const s = rt.snapshot()
    expect(s.links).toEqual([])
    expect(s.nodes.map((n) => n.ifaces[0].linked)).toEqual([false])
    expect(s.apps[0].done).toBe(true)
  })

  it('clears an address and manages static routes', () => {
    const rt = lan()
    rt.handle({ type: 'addRoute', node: 'a', cidr: '0.0.0.0/0', nextHop: '10.0.0.254' })
    expect(rt.snapshot().nodes[0].routes.at(-1)).toEqual({ kind: 'static', dest: '0.0.0.0/0', nextHop: '10.0.0.254', iface: 'eth0' })
    rt.handle({ type: 'removeRoute', node: 'a', cidr: '0.0.0.0/0' })
    rt.handle({ type: 'setIp', node: 'a', iface: 'eth0', cidr: null })
    expect(rt.snapshot().nodes[0].routes).toEqual([])
    expect(rt.snapshot().nodes[0].ifaces[0].cidr).toBeNull()
  })

  it('loads a topology atomically', () => {
    const rt = lan()
    const t: Topology = {
      version: 1,
      seed: 7,
      nodes: [
        {
          id: 'r',
          kind: 'router',
          name: 'R1',
          pos: { x: 0, y: 0 },
          ifaces: [
            { name: 'Gi0/0', cidr: '10.0.1.1/24' },
            { name: 'Gi0/1', cidr: null },
            { name: 'Gi0/2', cidr: null },
            { name: 'Gi0/3', cidr: null },
          ],
          routes: [],
        },
        {
          id: 'h',
          kind: 'pc',
          name: 'H1',
          pos: { x: 0, y: 0 },
          ifaces: [{ name: 'eth0', cidr: '10.0.1.10/24' }],
          routes: [{ cidr: '0.0.0.0/0', nextHop: '10.0.1.1' }],
        },
      ],
      links: [{ id: 'x', a: { node: 'h', iface: 'eth0' }, b: { node: 'r', iface: 'Gi0/0' } }],
    }
    rt.advance(50)
    rt.handle({ type: 'load', topology: t })
    const s = rt.snapshot()
    expect(s.seed).toBe(7)
    expect(s.timeNs).toBe(0)
    expect(s.nodes.map((n) => n.name)).toEqual(['R1', 'H1'])
    expect(s.nodes[1].routes.at(-1)?.nextHop).toBe('10.0.1.1')

    const badLink = { ...t, links: [{ id: 'y', a: { node: 'h', iface: 'eth9' }, b: { node: 'r', iface: 'Gi0/1' } }] }
    expect(() => rt.handle({ type: 'load', topology: badLink })).toThrow(/no interface eth9/)
    const badKind = { ...t, nodes: [{ ...t.nodes[1], kind: 'toaster' }] } as unknown as Topology
    expect(() => rt.handle({ type: 'load', topology: badKind })).toThrow(/Unknown device kind/)
    expect(() => rt.handle({ type: 'load', topology: { version: 2 } as unknown as Topology })).toThrow(/Unsupported or corrupt/)
    expect(rt.snapshot().nodes.map((n) => n.name)).toEqual(['R1', 'H1'])
  })
})
```

- [ ] **Step 4: Run it to verify it fails**

Run: `npx vitest run src/worker/runtime.test.ts`
Expected: FAIL — cannot resolve `./runtime`.

- [ ] **Step 5: Implement**

`src/worker/runtime.ts`:

```ts
import { Host, Hub, IpNode, Link, MS, Router, S, Sim, Switch, formatIp, ping, traceroute, type Node } from '../engine'
import type { AppView, Command, DeviceKind, NodeView, Snapshot, Topology } from '../shared/protocol'

const MAX_APPS = 20
/** Longest wall-clock gap simulated in one tick; longer gaps (sleep, hidden window) are dropped. */
const MAX_STEP_MS = 100

interface App {
  id: number
  node: string
  title: string
  result: { lines: string[]; done: boolean }
  stop(): void
}

function create(sim: Sim, id: string, kind: DeviceKind): Node {
  switch (kind) {
    case 'pc':
    case 'laptop':
    case 'server':
      return new Host(sim, id)
    case 'router':
      return new Router(sim, id)
    case 'switch':
      return new Switch(sim, id)
    case 'hub':
      return new Hub(sim, id)
    default:
      throw new Error(`Unknown device kind: ${String(kind)}`)
  }
}

/** Owns one simulation and translates protocol commands into engine calls. */
export class Runtime {
  running = true
  speed = 1
  private sim: Sim
  private seed: number
  private nodes = new Map<string, { node: Node; kind: DeviceKind }>()
  private links = new Map<string, Link>()
  private apps: App[] = []
  private appId = 0

  constructor(seed = 1) {
    this.seed = seed
    this.sim = new Sim({ seed })
  }

  handle(cmd: Command): void {
    switch (cmd.type) {
      case 'addNode': {
        if (this.nodes.has(cmd.id)) throw new Error(`Node ${cmd.id} already exists`)
        const node = create(this.sim, cmd.id, cmd.kind)
        node.name = cmd.name
        this.nodes.set(cmd.id, { node, kind: cmd.kind })
        return
      }
      case 'removeNode': {
        const node = this.get(cmd.id)
        for (const [id, link] of this.links) {
          if (link.a.node === node || link.b.node === node) {
            link.disconnect()
            this.links.delete(id)
          }
        }
        for (const app of this.apps) if (app.node === cmd.id) app.stop()
        this.nodes.delete(cmd.id)
        return
      }
      case 'rename': {
        const name = cmd.name.trim()
        if (!name) throw new Error('Name cannot be empty')
        this.get(cmd.id).name = name
        return
      }
      case 'connect': {
        if (this.links.has(cmd.id)) throw new Error(`Link ${cmd.id} already exists`)
        const a = this.get(cmd.a.node).iface(cmd.a.iface)
        const b = this.get(cmd.b.node).iface(cmd.b.iface)
        this.links.set(cmd.id, new Link(this.sim, a, b))
        return
      }
      case 'disconnect': {
        const link = this.links.get(cmd.id)
        if (!link) throw new Error(`Unknown link ${cmd.id}`)
        link.disconnect()
        this.links.delete(cmd.id)
        return
      }
      case 'setIp': {
        const node = this.ip(cmd.node)
        const cidr = cmd.cidr?.trim()
        if (cidr) node.setIp(cmd.iface, cidr)
        else node.iface(cmd.iface).ipv4 = undefined
        return
      }
      case 'addRoute':
        this.ip(cmd.node).routes.addStatic(cmd.cidr.trim(), cmd.nextHop.trim())
        return
      case 'removeRoute':
        this.ip(cmd.node).routes.removeStatic(cmd.cidr)
        return
      case 'ping':
        this.startApp(cmd.node, `ping ${cmd.target.trim()}`, (n) => ping(n, cmd.target.trim()))
        return
      case 'traceroute':
        this.startApp(cmd.node, `traceroute ${cmd.target.trim()}`, (n) => traceroute(n, cmd.target.trim()))
        return
      case 'setRunning':
        this.running = cmd.running
        return
      case 'setSpeed':
        if (!(cmd.speed > 0 && cmd.speed <= 1000)) throw new Error(`Invalid speed: ${cmd.speed}`)
        this.speed = cmd.speed
        return
      case 'load':
        this.load(cmd.topology)
        return
    }
  }

  advance(wallMs: number): void {
    if (!this.running) return
    this.sim.run(Math.round(Math.min(wallMs, MAX_STEP_MS) * MS * this.speed))
  }

  snapshot(): Snapshot {
    const now = this.sim.now
    const nodes: NodeView[] = [...this.nodes].map(([id, { node, kind }]) => ({
      id,
      kind,
      name: node.name,
      ifaces: node.interfaces.map((i) => ({
        name: i.name,
        mac: i.mac,
        cidr: i.ipv4 ? `${formatIp(i.ipv4.addr)}/${i.ipv4.prefix}` : null,
        linked: i.link !== undefined,
      })),
      routes:
        node instanceof IpNode
          ? node.routes.view().map((r) => ({
              kind: r.kind,
              dest: `${formatIp(r.network)}/${r.prefix}`,
              nextHop: r.nextHop === undefined ? null : formatIp(r.nextHop),
              iface: r.iface,
            }))
          : [],
      arp:
        node instanceof IpNode
          ? node.arp.entries().map((e) => ({ ip: formatIp(e.ip), mac: e.mac, iface: e.iface, ttlS: Math.ceil((e.expiresAt - now) / S) }))
          : [],
      mac: node instanceof Switch ? node.macTable().map((e) => ({ mac: e.mac, iface: e.iface, ageS: Math.floor(e.ageNs / S) })) : [],
    }))
    const apps: AppView[] = this.apps.map((a) => ({ id: a.id, node: a.node, title: a.title, lines: [...a.result.lines], done: a.result.done }))
    return {
      seed: this.seed,
      timeNs: now,
      running: this.running,
      speed: this.speed,
      nodes,
      links: [...this.links].map(([id, l]) => ({ id, a: { node: l.a.node.id, iface: l.a.name }, b: { node: l.b.node.id, iface: l.b.name } })),
      apps,
    }
  }

  private get(id: string): Node {
    const entry = this.nodes.get(id)
    if (!entry) throw new Error(`Unknown node ${id}`)
    return entry.node
  }

  private ip(id: string): IpNode {
    const node = this.get(id)
    if (!(node instanceof IpNode)) throw new Error(`${node.name} has no IP stack`)
    return node
  }

  private startApp(nodeId: string, title: string, start: (n: IpNode) => Omit<App, 'id' | 'node' | 'title'>): void {
    const handle = start(this.ip(nodeId))
    this.apps.push({ id: ++this.appId, node: nodeId, title, result: handle.result, stop: handle.stop })
    if (this.apps.length > MAX_APPS) this.apps.shift()?.stop()
  }

  /** Builds the new network aside and swaps it in only if every step succeeds. */
  private load(t: Topology): void {
    if (t?.version !== 1 || !Array.isArray(t.nodes) || !Array.isArray(t.links)) {
      throw new Error('Unsupported or corrupt project file')
    }
    const next = new Runtime(t.seed ?? 1)
    for (const n of t.nodes) {
      next.handle({ type: 'addNode', id: n.id, kind: n.kind, name: n.name })
      for (const i of n.ifaces ?? []) if (i.cidr) next.handle({ type: 'setIp', node: n.id, iface: i.name, cidr: i.cidr })
    }
    for (const l of t.links) next.handle({ type: 'connect', id: l.id, a: l.a, b: l.b })
    for (const n of t.nodes) {
      for (const r of n.routes ?? []) next.handle({ type: 'addRoute', node: n.id, cidr: r.cidr, nextHop: r.nextHop })
    }
    for (const app of this.apps) app.stop()
    this.sim = next.sim
    this.seed = next.seed
    this.nodes = next.nodes
    this.links = next.links
    this.apps = []
  }
}
```

- [ ] **Step 6: Run tests**

Run: `npx vitest run src/worker && npm run typecheck`
Expected: 7 tests PASS, typecheck exits 0.

- [ ] **Step 7: Commit**

```bash
git add tsconfig.json src/shared src/worker
git commit -m "feat(worker): add command protocol and simulation runtime"
```

---

### Task 3: UI state, actions, undo/redo and project files (Node-tested)

**Files:**
- Create: `tsconfig.ui.json`, `src/ui/store.ts`, `src/ui/topology.ts`, `src/ui/actions.ts`
- Modify: `package.json` (`typecheck` script, dependencies)
- Test: `src/ui/topology.test.ts`, `src/ui/actions.test.ts`

**Interfaces:**
- Consumes: protocol types and `Runtime` (Task 2)
- Produces:
  - store: `type Selection`, `type Menu`, `interface AppState`, `initialState()`, `useApp`
  - topology: `ALL_KINDS`, `KIND_LABEL`, `IP_KINDS`, `EMPTY_SNAPSHOT`, `EMPTY_TOPOLOGY`, `defaultName(kind, nodes)`, `firstFreeIface(node)`, `firstIp(node)`, `gatewayOf(node)`, `toTopology(snapshot, positions)`, `positionsOf(t)`, `sameNetwork(a, b)`, `parseProject(text)`, `newId()`
  - actions: `interface EngineClient { send(cmd: Command): Promise<void> }`, `setClient`, `run(cmd, key?)`, `edit(cmds, key?)`, `addDevice(kind, pos)`, `connect(a, b)`, `removeElements(nodeIds, linkIds)`, `remove(sel)`, `select(sel)`, `setPosition(id, pos)`, `openMenu(menu)`, `moveStart()`, `moveEnd()`, `undo()`, `redo()`, `newProject()`, `openProject(text, path)`, `projectText()`

- [ ] **Step 1: Install state deps and add the UI typecheck**

Run: `npm install zustand react react-dom --cache "$TMPDIR/npm-cache" && npm install -D @types/react @types/react-dom --cache "$TMPDIR/npm-cache"`
Expected: packages added.

Create `tsconfig.ui.json`:

```json
{
  "extends": "./tsconfig.json",
  "compilerOptions": {
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "jsx": "react-jsx",
    "types": ["vite/client"]
  },
  "include": ["src"]
}
```

In `package.json` replace the `typecheck` script with:

```json
    "typecheck": "tsc --noEmit && tsc --noEmit -p tsconfig.ui.json"
```

- [ ] **Step 2: Write the failing tests**

`src/ui/topology.test.ts`:

```ts
import { describe, expect, it } from 'vitest'
import type { NodeView } from '../shared/protocol'
import { defaultName, firstFreeIface, firstIp, gatewayOf, sameNetwork, EMPTY_TOPOLOGY } from './topology'

const view = (over: Partial<NodeView>): NodeView => ({ id: 'x', kind: 'pc', name: 'PC1', ifaces: [], routes: [], arp: [], mac: [], ...over })

describe('topology helpers', () => {
  it('picks the lowest free default name per kind', () => {
    const nodes = [view({ name: 'PC1' }), view({ name: 'PC3' }), view({ name: 'R1', kind: 'router' })]
    expect(defaultName('pc', nodes)).toBe('PC2')
    expect(defaultName('router', nodes)).toBe('R2')
    expect(defaultName('switch', nodes)).toBe('SW1')
  })

  it('finds free ports, first IP and gateway', () => {
    const n = view({
      ifaces: [
        { name: 'Gi0/0', mac: 'm', cidr: null, linked: true },
        { name: 'Gi0/1', mac: 'm', cidr: '10.0.0.1/24', linked: false },
      ],
      routes: [{ kind: 'static', dest: '0.0.0.0/0', nextHop: '10.0.0.254', iface: 'Gi0/1' }],
    })
    expect(firstFreeIface(n)).toBe('Gi0/1')
    expect(firstIp(n)).toBe('10.0.0.1')
    expect(gatewayOf(n)).toBe('10.0.0.254')
    expect(firstFreeIface(view({ ifaces: [{ name: 'eth0', mac: 'm', cidr: null, linked: true }] }))).toBeUndefined()
  })

  it('compares topologies ignoring positions', () => {
    const a = { ...EMPTY_TOPOLOGY, nodes: [{ id: 'a', kind: 'pc' as const, name: 'PC1', pos: { x: 0, y: 0 }, ifaces: [], routes: [] }] }
    const moved = { ...a, nodes: [{ ...a.nodes[0], pos: { x: 9, y: 9 } }] }
    const renamed = { ...a, nodes: [{ ...a.nodes[0], name: 'PC9' }] }
    expect(sameNetwork(a, moved)).toBe(true)
    expect(sameNetwork(a, renamed)).toBe(false)
  })
})
```

`src/ui/actions.test.ts`:

```ts
import { beforeEach, describe, expect, it } from 'vitest'
import type { Command } from '../shared/protocol'
import { Runtime } from '../worker/runtime'
import {
  addDevice,
  connect,
  edit,
  moveEnd,
  moveStart,
  newProject,
  openProject,
  projectText,
  redo,
  removeElements,
  setClient,
  setPosition,
  undo,
} from './actions'
import { initialState, useApp } from './store'

let rt: Runtime
let sent: Command[]

beforeEach(() => {
  useApp.setState(initialState(), true)
  rt = new Runtime()
  sent = []
  setClient({
    async send(cmd) {
      sent.push(cmd)
      rt.handle(cmd)
      useApp.setState({ snapshot: rt.snapshot() })
    },
  })
})

const names = () => useApp.getState().snapshot.nodes.map((n) => n.name)
const node = (name: string) => useApp.getState().snapshot.nodes.find((n) => n.name === name)!
const origin = { x: 0, y: 0 }

describe('editing', () => {
  it('adds devices with default names, positions and selection', async () => {
    await addDevice('pc', { x: 10, y: 20 })
    await addDevice('pc', { x: 30, y: 20 })
    await addDevice('router', origin)
    expect(names()).toEqual(['PC1', 'PC2', 'R1'])
    const s = useApp.getState()
    expect(s.positions[node('PC2').id]).toEqual({ x: 30, y: 20 })
    expect(s.selected).toEqual({ kind: 'node', id: node('R1').id })
    expect(s.past).toHaveLength(3)
  })

  it('connects through the first free ports and reports full devices', async () => {
    await addDevice('pc', origin)
    await addDevice('switch', origin)
    await addDevice('pc', origin)
    await connect(node('PC1').id, node('SW1').id)
    expect(useApp.getState().snapshot.links[0]).toMatchObject({ a: { iface: 'eth0' }, b: { iface: 'Gi0/1' } })
    await connect(node('PC1').id, node('PC2').id)
    expect(useApp.getState().error).toEqual({ key: 'connect', message: 'PC1 has no free port' })
    expect(useApp.getState().snapshot.links).toHaveLength(1)
  })

  it('a failed edit shows its error and adds no history', async () => {
    await addDevice('pc', origin)
    const before = useApp.getState().past.length
    expect(await edit({ type: 'setIp', node: node('PC1').id, iface: 'eth0', cidr: 'nope' }, 'ip')).toBe(false)
    expect(useApp.getState().error).toEqual({ key: 'ip', message: 'Invalid CIDR: "nope"' })
    expect(useApp.getState().past).toHaveLength(before)
  })
})

describe('undo / redo', () => {
  it('undoes and redoes adding a device, keeping id and position', async () => {
    await addDevice('pc', { x: 5, y: 6 })
    const id = node('PC1').id
    await undo()
    expect(names()).toEqual([])
    await redo()
    expect(node('PC1').id).toBe(id)
    expect(useApp.getState().positions[id]).toEqual({ x: 5, y: 6 })
  })

  it('deleting a node with cables is one step and undo restores everything', async () => {
    await addDevice('switch', origin)
    await addDevice('pc', origin)
    await addDevice('pc', origin)
    await connect(node('PC1').id, node('SW1').id)
    await connect(node('PC2').id, node('SW1').id)
    const links = useApp.getState().snapshot.links
    const steps = useApp.getState().past.length
    await removeElements([node('SW1').id], links.map((l) => l.id))
    expect(names()).toEqual(['PC1', 'PC2'])
    expect(useApp.getState().snapshot.links).toEqual([])
    expect(useApp.getState().past).toHaveLength(steps + 1)
    await undo()
    expect(names()).toEqual(['SW1', 'PC1', 'PC2'])
    expect(useApp.getState().snapshot.links).toEqual(links)
  })

  it('undoing a move restores positions without reloading the network', async () => {
    await addDevice('pc', origin)
    const id = node('PC1').id
    moveStart()
    setPosition(id, { x: 100, y: 50 })
    moveEnd()
    sent = []
    await undo()
    expect(useApp.getState().positions[id]).toEqual(origin)
    expect(sent).toEqual([])
  })

  it('a click without movement adds no history; a new edit clears redo', async () => {
    await addDevice('pc', origin)
    const steps = useApp.getState().past.length
    moveStart()
    moveEnd()
    expect(useApp.getState().past).toHaveLength(steps)
    await undo()
    expect(useApp.getState().future).toHaveLength(1)
    await addDevice('hub', origin)
    expect(useApp.getState().future).toHaveLength(0)
  })
})

describe('project files', () => {
  it('round-trips through text and clears history on open', async () => {
    await addDevice('router', { x: 1, y: 2 })
    await addDevice('pc', { x: 3, y: 4 })
    await edit({ type: 'setIp', node: node('R1').id, iface: 'Gi0/0', cidr: '10.0.1.1/24' })
    await edit({ type: 'setIp', node: node('PC1').id, iface: 'eth0', cidr: '10.0.1.10/24' })
    await edit({ type: 'addRoute', node: node('PC1').id, cidr: '0.0.0.0/0', nextHop: '10.0.1.1' })
    await connect(node('PC1').id, node('R1').id)
    const text = projectText()
    await newProject()
    expect(names()).toEqual([])
    expect(useApp.getState().past).toEqual([])
    await openProject(text, '/tmp/x.ptk')
    expect(projectText()).toBe(text)
    expect(useApp.getState()).toMatchObject({ filePath: '/tmp/x.ptk', past: [], future: [], error: null })
  })

  it('rejects a corrupt file and leaves the project untouched', async () => {
    await addDevice('pc', origin)
    await openProject('{ not json', '/tmp/bad.ptk')
    expect(useApp.getState().error).toEqual({ key: 'file', message: 'Not a Pac-Track project file' })
    await openProject('{"version": 9}', '/tmp/bad.ptk')
    expect(useApp.getState().error?.message).toMatch(/Unsupported or corrupt/)
    expect(names()).toEqual(['PC1'])
    expect(useApp.getState().filePath).toBeNull()
  })
})
```

- [ ] **Step 3: Run them to verify they fail**

Run: `npx vitest run src/ui`
Expected: FAIL — cannot resolve `./topology`, `./actions`, `./store`.

- [ ] **Step 4: Implement**

`src/ui/store.ts`:

```ts
import { create } from 'zustand'
import type { Pos, Snapshot, Topology } from '../shared/protocol'
import { EMPTY_SNAPSHOT } from './topology'

export type Selection = { kind: 'node' | 'link'; id: string } | null

export type Menu =
  | { kind: 'pane'; x: number; y: number; pos: Pos }
  | { kind: 'node'; x: number; y: number; id: string }
  | { kind: 'link'; x: number; y: number; id: string }
  | null

/** Presentation state only; the network itself lives in the worker and arrives as `snapshot`. */
export interface AppState {
  snapshot: Snapshot
  positions: Record<string, Pos>
  selected: Selection
  menu: Menu
  /** Last failed action; `key` tells which field or panel shows it. */
  error: { key: string; message: string } | null
  past: Topology[]
  future: Topology[]
  filePath: string | null
}

export const initialState = (): AppState => ({
  snapshot: EMPTY_SNAPSHOT,
  positions: {},
  selected: null,
  menu: null,
  error: null,
  past: [],
  future: [],
  filePath: null,
})

export const useApp = create<AppState>()(initialState)
```

`src/ui/topology.ts`:

```ts
import type { DeviceKind, NodeView, Pos, Snapshot, Topology } from '../shared/protocol'

export const ALL_KINDS: DeviceKind[] = ['router', 'switch', 'hub', 'pc', 'laptop', 'server']

export const KIND_LABEL: Record<DeviceKind, string> = {
  pc: 'PC',
  laptop: 'Laptop',
  server: 'Server',
  router: 'Router',
  switch: 'Switch',
  hub: 'Hub',
}

const NAME_PREFIX: Record<DeviceKind, string> = { pc: 'PC', laptop: 'LAPTOP', server: 'SRV', router: 'R', switch: 'SW', hub: 'HUB' }

export const IP_KINDS = new Set<DeviceKind>(['pc', 'laptop', 'server', 'router'])

export const EMPTY_SNAPSHOT: Snapshot = { seed: 1, timeNs: 0, running: true, speed: 1, nodes: [], links: [], apps: [] }
export const EMPTY_TOPOLOGY: Topology = { version: 1, seed: 1, nodes: [], links: [] }

export function defaultName(kind: DeviceKind, nodes: NodeView[]): string {
  const taken = new Set(nodes.map((n) => n.name))
  for (let i = 1; ; i++) {
    const name = `${NAME_PREFIX[kind]}${i}`
    if (!taken.has(name)) return name
  }
}

export const firstFreeIface = (node: NodeView) => node.ifaces.find((i) => !i.linked)?.name

export const firstIp = (node: NodeView) => node.ifaces.find((i) => i.cidr)?.cidr?.split('/')[0]

export const gatewayOf = (node: NodeView) =>
  node.routes.find((r) => r.kind === 'static' && r.dest === '0.0.0.0/0')?.nextHop ?? undefined

export function toTopology(s: Snapshot, positions: Record<string, Pos>): Topology {
  return {
    version: 1,
    seed: s.seed,
    nodes: s.nodes.map((n) => ({
      id: n.id,
      kind: n.kind,
      name: n.name,
      pos: positions[n.id] ?? { x: 0, y: 0 },
      ifaces: n.ifaces.map((i) => ({ name: i.name, cidr: i.cidr })),
      routes: n.routes.filter((r) => r.kind === 'static').map((r) => ({ cidr: r.dest, nextHop: r.nextHop ?? '' })),
    })),
    links: s.links.map((l) => ({ id: l.id, a: l.a, b: l.b })),
  }
}

export const positionsOf = (t: Topology): Record<string, Pos> => Object.fromEntries(t.nodes.map((n) => [n.id, n.pos]))

/** True when two topologies differ at most in node positions. */
export function sameNetwork(a: Topology, b: Topology): boolean {
  const strip = (t: Topology) => JSON.stringify({ ...t, nodes: t.nodes.map(({ pos: _pos, ...rest }) => rest) })
  return strip(a) === strip(b)
}

/** Parses JSON only; structure is validated by the runtime's atomic `load`. */
export function parseProject(text: string): Topology {
  try {
    return JSON.parse(text) as Topology
  } catch {
    throw new Error('Not a Pac-Track project file')
  }
}

export const newId = () => crypto.randomUUID().slice(0, 8)
```

`src/ui/actions.ts`:

```ts
import type { Command, DeviceKind, Pos, Topology } from '../shared/protocol'
import { useApp, type Menu, type Selection } from './store'
import {
  EMPTY_TOPOLOGY,
  defaultName,
  firstFreeIface,
  newId,
  parseProject,
  positionsOf,
  sameNetwork,
  toTopology,
} from './topology'

export interface EngineClient {
  /** Resolves once the command is applied and the new snapshot is in the store; rejects with the engine's error. */
  send(cmd: Command): Promise<void>
}

const HISTORY_LIMIT = 100
let client: EngineClient
let pendingMove: Topology | null = null

export function setClient(c: EngineClient): void {
  client = c
}

const current = (): Topology => {
  const s = useApp.getState()
  return toTopology(s.snapshot, s.positions)
}

function remember(before: Topology): void {
  useApp.setState((s) => ({ past: [...s.past, before].slice(-HISTORY_LIMIT), future: [] }))
}

const fail = (key: string, e: unknown) => useApp.setState({ error: { key, message: e instanceof Error ? e.message : String(e) } })

/** Sends a command that does not change the topology (apps, clock). */
export async function run(cmd: Command, key: string = cmd.type): Promise<boolean> {
  try {
    await client.send(cmd)
    useApp.setState({ error: null })
    return true
  } catch (e) {
    fail(key, e)
    return false
  }
}

/** Sends one or more topology changes as a single undo step. */
export async function edit(cmds: Command | Command[], key?: string): Promise<boolean> {
  const list = Array.isArray(cmds) ? cmds : [cmds]
  const before = current()
  for (const [i, cmd] of list.entries()) {
    if (!(await run(cmd, key ?? cmd.type))) {
      if (i > 0) remember(before)
      return false
    }
  }
  remember(before)
  return true
}

export const select = (selected: Selection) => useApp.setState({ selected, menu: null })
export const openMenu = (menu: Menu) => useApp.setState({ menu })
export const setPosition = (id: string, pos: Pos) => useApp.setState((s) => ({ positions: { ...s.positions, [id]: pos } }))

export async function addDevice(kind: DeviceKind, pos: Pos): Promise<void> {
  const id = newId()
  setPosition(id, pos)
  const name = defaultName(kind, useApp.getState().snapshot.nodes)
  if (await edit({ type: 'addNode', id, kind, name })) select({ kind: 'node', id })
}

export async function connect(aId: string, bId: string): Promise<void> {
  const nodes = useApp.getState().snapshot.nodes
  const a = nodes.find((n) => n.id === aId)
  const b = nodes.find((n) => n.id === bId)
  if (!a || !b || a === b) return
  const ia = firstFreeIface(a)
  const ib = firstFreeIface(b)
  if (!ia || !ib) {
    fail('connect', new Error(`${!ia ? a.name : b.name} has no free port`))
    return
  }
  await edit({ type: 'connect', id: newId(), a: { node: aId, iface: ia }, b: { node: bId, iface: ib } }, 'connect')
}

/** Deletes nodes and cables in one undo step (cables of deleted nodes go with them). */
export async function removeElements(nodeIds: string[], linkIds: string[]): Promise<void> {
  const gone = new Set(nodeIds)
  const links = useApp.getState().snapshot.links
  const cmds: Command[] = [
    ...linkIds
      .filter((id) => links.some((l) => l.id === id && !gone.has(l.a.node) && !gone.has(l.b.node)))
      .map((id): Command => ({ type: 'disconnect', id })),
    ...nodeIds.map((id): Command => ({ type: 'removeNode', id })),
  ]
  if (cmds.length > 0) await edit(cmds)
  select(null)
}

export const remove = (sel: NonNullable<Selection>) =>
  removeElements(sel.kind === 'node' ? [sel.id] : [], sel.kind === 'link' ? [sel.id] : [])

export function moveStart(): void {
  pendingMove = current()
}

export function moveEnd(): void {
  if (pendingMove && JSON.stringify(pendingMove) !== JSON.stringify(current())) remember(pendingMove)
  pendingMove = null
}

async function restore(t: Topology): Promise<void> {
  if (!sameNetwork(t, current())) await client.send({ type: 'load', topology: t })
  useApp.setState({ positions: positionsOf(t), selected: null, error: null })
}

export async function undo(): Promise<void> {
  const prev = useApp.getState().past.at(-1)
  if (!prev) return
  const now = current()
  await restore(prev)
  useApp.setState((s) => ({ past: s.past.slice(0, -1), future: [now, ...s.future] }))
}

export async function redo(): Promise<void> {
  const next = useApp.getState().future[0]
  if (!next) return
  const now = current()
  await restore(next)
  useApp.setState((s) => ({ past: [...s.past, now], future: s.future.slice(1) }))
}

export async function newProject(): Promise<void> {
  await client.send({ type: 'load', topology: EMPTY_TOPOLOGY })
  useApp.setState({ positions: {}, past: [], future: [], filePath: null, selected: null, error: null })
}

export async function openProject(text: string, path: string): Promise<void> {
  try {
    const t = parseProject(text)
    await client.send({ type: 'load', topology: t })
    useApp.setState({ positions: positionsOf(t), past: [], future: [], filePath: path, selected: null, error: null })
  } catch (e) {
    fail('file', e)
  }
}

export const projectText = () => JSON.stringify(current(), null, 2)
```

- [ ] **Step 5: Run tests**

Run: `npm test && npm run typecheck`
Expected: all PASS (74 + 7 + 3 + 9 = 93), both typechecks exit 0.

- [ ] **Step 6: Commit**

```bash
git add package.json package-lock.json tsconfig.ui.json src/ui
git commit -m "feat(ui): add store, editing actions, snapshot undo/redo and project files"
```

---

### Task 4: Electron shell, worker client, toolbar and menu

**Files:**
- Create: `index.html`, `vite.config.ts`, `vitest.config.ts`, `playwright.config.ts`, `scripts/dev.mjs`, `electron/main.mjs`, `electron/preload.cjs`, `src/worker/engine.worker.ts`, `src/ui/engine-client.ts`, `src/ui/files.ts`, `src/ui/shortcuts.ts`, `src/ui/theme.css`, `src/ui/ui.tsx`, `src/ui/main.tsx`, `src/ui/App.tsx`, `src/ui/Toolbar.tsx`, `e2e/helpers.ts`, `e2e/app.spec.ts`
- Modify: `package.json` (main, scripts, deps), `.gitignore`

**Interfaces:**
- Consumes: `actions.ts`, `store.ts` (Task 3), `Runtime` (Task 2)
- Produces: `window.pac: { openFile(): Promise<{ path; text } | null>; saveFile(text, path | null): Promise<string | null>; onMenu(cb: (cmd: string) => void): void }`; menu commands `new | open | save | saveAs | undo | redo`; `openFile()`, `saveFile(saveAs?)`; UI primitives `ToolButton`, `Button`, `ErrorText`, `Field`, `Tabs`, `inputClass`; `launch()` e2e helper; `data-testid="clock"`

- [ ] **Step 1: Install the app toolchain**

Run:

```bash
npm install @xyflow/react lucide-react --cache "$TMPDIR/npm-cache"
npm install -D electron vite @vitejs/plugin-react tailwindcss @tailwindcss/vite @playwright/test --cache "$TMPDIR/npm-cache"
```

Expected: packages added; Electron's postinstall downloads its binary (needs network access to GitHub).

In `package.json` add `"main": "electron/main.mjs",` after `"description"`, and replace `"scripts"` with:

```json
  "scripts": {
    "dev": "node scripts/dev.mjs",
    "build": "vite build",
    "start": "vite build && electron .",
    "test": "vitest run",
    "test:watch": "vitest",
    "e2e": "vite build && playwright test",
    "typecheck": "tsc --noEmit && tsc --noEmit -p tsconfig.ui.json"
  },
```

Append to `.gitignore`:

```
# Playwright
test-results/
playwright-report/
```

- [ ] **Step 2: Write the failing e2e smoke test**

`playwright.config.ts`:

```ts
import { defineConfig } from '@playwright/test'

export default defineConfig({ testDir: 'e2e', timeout: 60_000, workers: 1 })
```

`vitest.config.ts`:

```ts
import { defineConfig } from 'vitest/config'

export default defineConfig({ test: { include: ['src/**/*.test.ts'] } })
```

`e2e/helpers.ts`:

```ts
import { _electron as electron, type ElectronApplication, type Page } from '@playwright/test'

export async function launch(): Promise<{ app: ElectronApplication; page: Page }> {
  const app = await electron.launch({ args: ['.'] })
  const page = await app.firstWindow()
  await page.getByTestId('clock').waitFor()
  return { app, page }
}
```

`e2e/app.spec.ts`:

```ts
import { expect, test, type ElectronApplication, type Page } from '@playwright/test'
import { launch } from './helpers'

let app: ElectronApplication
let page: Page

test.beforeEach(async () => ({ app, page } = await launch()))
test.afterEach(async () => app.close())

test('opens the main window and runs the simulation clock', async () => {
  await expect(page).toHaveTitle('Pac-Track')
  await expect(page.getByTestId('clock')).not.toHaveText('t = 0.000 s')
})

test('pause stops the clock', async () => {
  await page.getByRole('button', { name: /Pausa/ }).click()
  const frozen = await page.getByTestId('clock').textContent()
  await page.waitForTimeout(300)
  await expect(page.getByTestId('clock')).toHaveText(frozen!)
  await expect(page.getByRole('button', { name: /Avvia/ })).toBeVisible()
})
```

Run: `npm run e2e`
Expected: FAIL — `vite build` cannot find `index.html` (no renderer yet).

- [ ] **Step 3: Implement the main process and preload**

`electron/main.mjs`:

```js
import { app, BrowserWindow, dialog, ipcMain, Menu } from 'electron'
import { readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const dir = path.dirname(fileURLToPath(import.meta.url))
const FILTERS = [{ name: 'Progetto Pac-Track', extensions: ['ptk'] }]

function createWindow() {
  const win = new BrowserWindow({
    width: 1440,
    height: 900,
    backgroundColor: '#1e1f22',
    title: 'Pac-Track',
    webPreferences: { preload: path.join(dir, 'preload.cjs'), contextIsolation: true, nodeIntegration: false, sandbox: true },
  })
  if (process.env.PAC_DEV_URL) win.loadURL(process.env.PAC_DEV_URL)
  else win.loadFile(path.join(dir, '../dist/index.html'))
}

const send = (cmd) => BrowserWindow.getFocusedWindow()?.webContents.send('menu', cmd)
const isMac = process.platform === 'darwin'

Menu.setApplicationMenu(
  Menu.buildFromTemplate([
    ...(isMac ? [{ role: 'appMenu' }] : []),
    {
      label: 'File',
      submenu: [
        { label: 'Nuovo', accelerator: 'CmdOrCtrl+N', click: () => send('new') },
        { label: 'Apri…', accelerator: 'CmdOrCtrl+O', click: () => send('open') },
        { label: 'Salva', accelerator: 'CmdOrCtrl+S', click: () => send('save') },
        { label: 'Salva con nome…', accelerator: 'Shift+CmdOrCtrl+S', click: () => send('saveAs') },
        { type: 'separator' },
        isMac ? { role: 'close' } : { role: 'quit' },
      ],
    },
    {
      label: 'Modifica',
      submenu: [
        { label: 'Annulla', accelerator: 'CmdOrCtrl+Z', click: () => send('undo') },
        { label: 'Ripeti', accelerator: 'Shift+CmdOrCtrl+Z', click: () => send('redo') },
        { type: 'separator' },
        { role: 'cut' },
        { role: 'copy' },
        { role: 'paste' },
        { role: 'selectAll' },
      ],
    },
    { label: 'Vista', submenu: [{ role: 'reload' }, { role: 'toggleDevTools' }, { type: 'separator' }, { role: 'togglefullscreen' }] },
  ]),
)

ipcMain.handle('file:open', async (event) => {
  const result = await dialog.showOpenDialog(BrowserWindow.fromWebContents(event.sender), { filters: FILTERS, properties: ['openFile'] })
  const file = result.filePaths[0]
  if (result.canceled || !file) return null
  return { path: file, text: await readFile(file, 'utf8') }
})

ipcMain.handle('file:save', async (event, text, current) => {
  let file = current
  if (!file) {
    const result = await dialog.showSaveDialog(BrowserWindow.fromWebContents(event.sender), { filters: FILTERS, defaultPath: 'rete.ptk' })
    if (result.canceled || !result.filePath) return null
    file = result.filePath
  }
  await writeFile(file, text, 'utf8')
  return file
})

app.whenReady().then(createWindow)
app.on('window-all-closed', () => {
  if (!isMac) app.quit()
})
app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow()
})
```

`electron/preload.cjs`:

```js
const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('pac', {
  openFile: () => ipcRenderer.invoke('file:open'),
  saveFile: (text, path) => ipcRenderer.invoke('file:save', text, path),
  onMenu: (cb) => ipcRenderer.on('menu', (_event, cmd) => cb(cmd)),
})
```

`scripts/dev.mjs`:

```js
import { spawn } from 'node:child_process'
import electron from 'electron'
import { createServer } from 'vite'

const server = await createServer()
await server.listen()
const url = server.resolvedUrls.local[0]
const child = spawn(electron, ['.'], { stdio: 'inherit', env: { ...process.env, PAC_DEV_URL: url } })
child.on('exit', async (code) => {
  await server.close()
  process.exit(code ?? 0)
})
```

- [ ] **Step 4: Implement the renderer entry, worker and client**

`index.html`:

```html
<!doctype html>
<html lang="it">
  <head>
    <meta charset="UTF-8" />
    <title>Pac-Track</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/ui/main.tsx"></script>
  </body>
</html>
```

`vite.config.ts`:

```ts
import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// base './' so the built index.html works from file:// inside Electron.
export default defineConfig({ base: './', plugins: [react(), tailwindcss()] })
```

`src/worker/engine.worker.ts`:

```ts
import type { Reply, Request, WorkerMessage } from '../shared/protocol'
import { Runtime } from './runtime'

const TICK_MS = 50
const runtime = new Runtime()
const scope = self as unknown as Worker
const post = (m: WorkerMessage) => scope.postMessage(m)

scope.onmessage = (e: MessageEvent<Request>) => {
  let reply: Reply
  try {
    runtime.handle(e.data)
    reply = { reqId: e.data.reqId, ok: true }
  } catch (err) {
    reply = { reqId: e.data.reqId, ok: false, error: err instanceof Error ? err.message : String(err) }
  }
  // Snapshot travels with the reply so the UI never resolves an action against stale state.
  post({ type: 'reply', reply, snapshot: runtime.snapshot() })
}

let last = performance.now()
setInterval(() => {
  const now = performance.now()
  runtime.advance(now - last)
  last = now
  post({ type: 'tick', snapshot: runtime.snapshot() })
}, TICK_MS)
```

`src/ui/engine-client.ts`:

```ts
import type { Command, Reply, WorkerMessage } from '../shared/protocol'
import EngineWorker from '../worker/engine.worker?worker&inline'
import { setClient } from './actions'
import { useApp } from './store'

/** Starts the engine worker and routes actions to it. */
export function connectWorker(): void {
  const worker = new EngineWorker()
  const pending = new Map<number, (r: Reply) => void>()
  let nextReq = 0
  worker.onmessage = (e: MessageEvent<WorkerMessage>) => {
    const m = e.data
    useApp.setState({ snapshot: m.snapshot })
    if (m.type === 'reply') {
      pending.get(m.reply.reqId)?.(m.reply)
      pending.delete(m.reply.reqId)
    }
  }
  setClient({
    send: (cmd: Command) =>
      new Promise<void>((resolve, reject) => {
        const reqId = ++nextReq
        pending.set(reqId, (r) => (r.ok ? resolve() : reject(new Error(r.error))))
        worker.postMessage({ ...cmd, reqId })
      }),
  })
}
```

`src/ui/files.ts`:

```ts
import { openProject, projectText } from './actions'
import { useApp } from './store'

export interface PacBridge {
  openFile(): Promise<{ path: string; text: string } | null>
  saveFile(text: string, path: string | null): Promise<string | null>
  onMenu(cb: (cmd: string) => void): void
}

declare global {
  interface Window {
    pac: PacBridge
  }
}

export async function openFile(): Promise<void> {
  const file = await window.pac.openFile()
  if (file) await openProject(file.text, file.path)
}

export async function saveFile(saveAs = false): Promise<void> {
  try {
    const path = await window.pac.saveFile(projectText(), saveAs ? null : useApp.getState().filePath)
    if (path) useApp.setState({ filePath: path, error: null })
  } catch (e) {
    useApp.setState({ error: { key: 'file', message: e instanceof Error ? e.message : String(e) } })
  }
}
```

`src/ui/shortcuts.ts`:

```ts
import { useEffect } from 'react'
import { newProject, redo, run, undo } from './actions'
import { openFile, saveFile } from './files'
import { useApp } from './store'

const isTyping = () => {
  const el = document.activeElement
  return el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement || el instanceof HTMLSelectElement
}

const MENU: Record<string, () => unknown> = {
  new: newProject,
  open: openFile,
  save: () => saveFile(),
  saveAs: () => saveFile(true),
  undo,
  redo,
}

/** Menu accelerators (from the main process) plus Space = play/pause and Escape = close menu. */
export function useShortcuts(): void {
  useEffect(() => {
    window.pac.onMenu((cmd) => {
      // Inside a text field, undo/redo edit the text, not the network.
      if ((cmd === 'undo' || cmd === 'redo') && isTyping()) document.execCommand(cmd)
      else void MENU[cmd]?.()
    })
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') useApp.setState({ menu: null })
      if (e.key === ' ' && !isTyping() && !(document.activeElement instanceof HTMLButtonElement)) {
        e.preventDefault()
        void run({ type: 'setRunning', running: !useApp.getState().snapshot.running })
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])
}
```

- [ ] **Step 5: Implement theme, primitives, toolbar and layout**

`src/ui/theme.css`:

```css
@import 'tailwindcss';

@theme {
  --color-bg: #1e1f22;
  --color-panel: #2b2d30;
  --color-border: #393b40;
  --color-border-strong: #43454a;
  --color-fg: #bcbec4;
  --color-fg-strong: #dfe1e5;
  --color-muted: #6f737a;
  --color-accent: #3574f0;
  --color-ok: #5fb865;
  --color-warn: #f0a732;
  --color-err: #e5507a;
  --font-mono: ui-monospace, 'JetBrains Mono', Menlo, monospace;
}

html,
body,
#root {
  height: 100%;
  margin: 0;
}

body {
  background: var(--color-bg);
  color: var(--color-fg);
  font: 12px/1.5 -apple-system, system-ui, sans-serif;
  user-select: none;
}

input,
select {
  user-select: text;
}
```

`src/ui/ui.tsx`:

```tsx
import { useRef, useState, type ReactNode } from 'react'
import { useApp } from './store'

export const inputClass =
  'w-full rounded border border-border-strong bg-bg px-1.5 py-0.5 font-mono text-fg outline-none focus:border-accent'

export function ToolButton(props: { title: string; onClick(): void; disabled?: boolean; children: ReactNode }) {
  return (
    <button
      type="button"
      title={props.title}
      aria-label={props.title}
      disabled={props.disabled}
      onClick={props.onClick}
      className="rounded p-1.5 text-fg hover:bg-border disabled:opacity-40 disabled:hover:bg-transparent"
    >
      {props.children}
    </button>
  )
}

export function Button(props: { onClick?(): void; type?: 'button' | 'submit'; danger?: boolean; children: ReactNode }) {
  return (
    <button
      type={props.type ?? 'button'}
      onClick={props.onClick}
      className={`rounded border border-border-strong px-2 py-0.5 hover:bg-border ${props.danger ? 'text-err' : 'text-fg-strong'}`}
    >
      {props.children}
    </button>
  )
}

export function ErrorText({ errorKey }: { errorKey: string }) {
  const message = useApp((s) => (s.error?.key === errorKey ? s.error.message : null))
  return message ? (
    <p role="alert" className="mt-0.5 text-[10px] text-err">
      {message}
    </p>
  ) : null
}

/** Text field that commits on Enter/blur and reverts on Escape. Shows the error tagged `errorKey`. */
export function Field(props: {
  label: string
  value: string
  placeholder?: string
  errorKey: string
  testId?: string
  onCommit(value: string): unknown
}) {
  const [draft, setDraft] = useState(props.value)
  const [editing, setEditing] = useState(false)
  const cancelled = useRef(false)
  const commit = () => {
    setEditing(false)
    if (cancelled.current) cancelled.current = false
    else if (draft !== props.value) void props.onCommit(draft)
  }
  return (
    <label className="block">
      <span className="mb-0.5 block text-[10px] text-muted">{props.label}</span>
      <input
        data-testid={props.testId}
        className={inputClass}
        value={editing ? draft : props.value}
        placeholder={props.placeholder}
        onFocus={() => {
          setDraft(props.value)
          setEditing(true)
        }}
        onChange={(e) => setDraft(e.target.value)}
        onBlur={commit}
        onKeyDown={(e) => {
          if (e.key === 'Enter') e.currentTarget.blur()
          if (e.key === 'Escape') {
            cancelled.current = true
            e.currentTarget.blur()
          }
        }}
      />
      <ErrorText errorKey={props.errorKey} />
    </label>
  )
}

export function Tabs<T extends string>(props: { tabs: readonly T[]; value: T; onChange(tab: T): void }) {
  return (
    <div role="tablist" className="flex gap-3 border-b border-border px-3">
      {props.tabs.map((t) => (
        <button
          key={t}
          type="button"
          role="tab"
          aria-selected={t === props.value}
          onClick={() => props.onChange(t)}
          className={`py-1.5 text-[11px] ${t === props.value ? 'border-b-2 border-accent text-fg-strong' : 'text-muted hover:text-fg'}`}
        >
          {t}
        </button>
      ))}
    </div>
  )
}
```

`src/ui/Toolbar.tsx`:

```tsx
import { FilePlus, FolderOpen, Pause, Play, Redo2, Save, Undo2 } from 'lucide-react'
import { SPEEDS } from '../shared/protocol'
import { newProject, redo, run, undo } from './actions'
import { openFile, saveFile } from './files'
import { useApp } from './store'
import { ErrorText, ToolButton } from './ui'

export function Toolbar() {
  const running = useApp((s) => s.snapshot.running)
  const speed = useApp((s) => s.snapshot.speed)
  const timeNs = useApp((s) => s.snapshot.timeNs)
  const canUndo = useApp((s) => s.past.length > 0)
  const canRedo = useApp((s) => s.future.length > 0)
  const filePath = useApp((s) => s.filePath)

  return (
    <header className="flex h-9 shrink-0 items-center gap-0.5 border-b border-border bg-panel px-2">
      <b className="mr-3 text-fg-strong">Pac-Track</b>
      <ToolButton title="Nuovo (⌘N)" onClick={newProject}>
        <FilePlus size={15} />
      </ToolButton>
      <ToolButton title="Apri (⌘O)" onClick={openFile}>
        <FolderOpen size={15} />
      </ToolButton>
      <ToolButton title="Salva (⌘S)" onClick={() => saveFile()}>
        <Save size={15} />
      </ToolButton>
      <span className="mx-1 h-4 w-px bg-border-strong" />
      <ToolButton title="Annulla (⌘Z)" disabled={!canUndo} onClick={undo}>
        <Undo2 size={15} />
      </ToolButton>
      <ToolButton title="Ripeti (⇧⌘Z)" disabled={!canRedo} onClick={redo}>
        <Redo2 size={15} />
      </ToolButton>
      <span className="ml-3 truncate text-muted">{filePath?.split(/[\\/]/).pop() ?? 'senza titolo'}</span>
      <div className="ml-3">
        <ErrorText errorKey="file" />
      </div>
      <div className="ml-auto flex items-center gap-2">
        <ToolButton title={running ? 'Pausa (Spazio)' : 'Avvia (Spazio)'} onClick={() => run({ type: 'setRunning', running: !running })}>
          {running ? <Pause size={15} /> : <Play size={15} />}
        </ToolButton>
        <select
          aria-label="Velocità"
          value={speed}
          onChange={(e) => run({ type: 'setSpeed', speed: Number(e.target.value) })}
          className="rounded border border-border-strong bg-bg px-1 py-0.5 font-mono text-fg"
        >
          {SPEEDS.map((v) => (
            <option key={v} value={v}>
              {v}×
            </option>
          ))}
        </select>
        <span data-testid="clock" className="w-28 text-right font-mono text-muted">
          t = {(timeNs / 1e9).toFixed(3)} s
        </span>
      </div>
    </header>
  )
}
```

`src/ui/App.tsx`:

```tsx
import { Toolbar } from './Toolbar'
import { useShortcuts } from './shortcuts'

export function App() {
  useShortcuts()
  return (
    <div className="flex h-full flex-col">
      <Toolbar />
      <main className="flex min-h-0 flex-1" />
    </div>
  )
}
```

`src/ui/main.tsx`:

```tsx
import '@xyflow/react/dist/style.css'
import { createRoot } from 'react-dom/client'
import { App } from './App'
import { connectWorker } from './engine-client'
import './theme.css'

connectWorker()
createRoot(document.getElementById('root')!).render(<App />)
```

- [ ] **Step 6: Run the e2e and unit suites**

Run: `npm run e2e && npm test && npm run typecheck`
Expected: 2 e2e tests PASS, unit tests PASS (93), typecheck exits 0.

- [ ] **Step 7: Commit**

```bash
git add package.json package-lock.json .gitignore index.html vite.config.ts vitest.config.ts playwright.config.ts scripts electron e2e src/worker/engine.worker.ts src/ui
git commit -m "feat(app): add Electron shell, engine worker, toolbar and application menu"
```

---

### Task 5: Canvas, palette and device nodes

**Files:**
- Create: `src/ui/icons.tsx`, `src/ui/Palette.tsx`, `src/ui/DeviceNode.tsx`, `src/ui/Canvas.tsx`, `e2e/canvas.spec.ts`
- Modify: `src/ui/App.tsx`, `e2e/helpers.ts`

**Interfaces:**
- Consumes: `addDevice`, `connect`, `removeElements`, `select`, `setPosition`, `moveStart`, `moveEnd`, `openMenu` (Task 3); `KIND_LABEL`, `firstIp` (Task 3)
- Produces: `DeviceIcon({ kind, size })`; `DRAG_TYPE`; `data-testid="palette-<kind>"`, `data-testid="node-<name>"`; e2e helpers `dropDevice(page, kind, x, y)`, `connectNodes(page, a, b)`

- [ ] **Step 1: Write the failing e2e test**

Append to `e2e/helpers.ts`:

```ts
/** Drags a palette entry onto the canvas at pane-relative (x, y). */
export async function dropDevice(page: Page, kind: string, x: number, y: number): Promise<void> {
  await page.getByTestId(`palette-${kind}`).dragTo(page.locator('.react-flow__pane'), { targetPosition: { x, y } })
}

/** Draws a cable from `a`'s bottom handle to `b`'s top handle. */
export async function connectNodes(page: Page, a: string, b: string): Promise<void> {
  const from = await page.getByTestId(`node-${a}`).locator('.react-flow__handle-bottom').boundingBox()
  const to = await page.getByTestId(`node-${b}`).locator('.react-flow__handle-top').boundingBox()
  if (!from || !to) throw new Error('handles not visible')
  await page.mouse.move(from.x + from.width / 2, from.y + from.height / 2)
  await page.mouse.down()
  await page.mouse.move(to.x + to.width / 2, to.y + to.height / 2, { steps: 10 })
  await page.mouse.up()
}
```

`e2e/canvas.spec.ts`:

```ts
import { expect, test, type ElectronApplication, type Page } from '@playwright/test'
import { connectNodes, dropDevice, launch } from './helpers'

let app: ElectronApplication
let page: Page

test.beforeEach(async () => ({ app, page } = await launch()))
test.afterEach(async () => app.close())

test('drops devices from the palette and cables them', async () => {
  await dropDevice(page, 'pc', 150, 150)
  await dropDevice(page, 'switch', 450, 150)
  await expect(page.getByTestId('node-PC1')).toBeVisible()
  await expect(page.getByTestId('node-SW1')).toBeVisible()
  await connectNodes(page, 'PC1', 'SW1')
  await expect(page.locator('.react-flow__edge')).toHaveCount(1)
  await expect(page.locator('.react-flow__edge')).toContainText('eth0 ↔ Gi0/1')
})

test('deletes the selected device with its cable, and undo brings both back', async () => {
  await dropDevice(page, 'pc', 150, 150)
  await dropDevice(page, 'switch', 450, 150)
  await connectNodes(page, 'PC1', 'SW1')
  await page.getByTestId('node-SW1').click()
  await page.keyboard.press('Delete')
  await expect(page.getByTestId('node-SW1')).toHaveCount(0)
  await expect(page.locator('.react-flow__edge')).toHaveCount(0)
  await page.getByRole('button', { name: /Annulla/ }).click()
  await expect(page.getByTestId('node-SW1')).toBeVisible()
  await expect(page.locator('.react-flow__edge')).toHaveCount(1)
})
```

Run: `npm run e2e`
Expected: the 2 new tests FAIL — `palette-pc` not found.

- [ ] **Step 2: Implement icons, palette and node**

`src/ui/icons.tsx`:

```tsx
import { Laptop, Monitor, Network, Router, Server, Share2, type LucideIcon } from 'lucide-react'
import type { DeviceKind } from '../shared/protocol'

const ICONS: Record<DeviceKind, LucideIcon> = { pc: Monitor, laptop: Laptop, server: Server, router: Router, switch: Network, hub: Share2 }

export function DeviceIcon({ kind, size = 14 }: { kind: DeviceKind; size?: number }) {
  const Icon = ICONS[kind]
  return <Icon size={size} aria-hidden />
}
```

`src/ui/Palette.tsx`:

```tsx
import type { DeviceKind } from '../shared/protocol'
import { DeviceIcon } from './icons'
import { KIND_LABEL } from './topology'

export const DRAG_TYPE = 'application/x-pactrack-kind'

const GROUPS: { title: string; kinds: DeviceKind[] }[] = [
  { title: 'Rete', kinds: ['router', 'switch', 'hub'] },
  { title: 'Host', kinds: ['pc', 'laptop', 'server'] },
]

export function Palette() {
  return (
    <aside className="w-40 shrink-0 overflow-y-auto border-r border-border bg-panel p-2">
      {GROUPS.map((g) => (
        <section key={g.title} className="mb-3">
          <h3 className="mb-1 px-1 text-[10px] uppercase tracking-wide text-muted">{g.title}</h3>
          {g.kinds.map((kind) => (
            <div
              key={kind}
              draggable
              data-testid={`palette-${kind}`}
              onDragStart={(e) => {
                e.dataTransfer.setData(DRAG_TYPE, kind)
                e.dataTransfer.effectAllowed = 'copy'
              }}
              className="flex cursor-grab items-center gap-2 rounded px-2 py-1 text-fg hover:bg-border"
            >
              <DeviceIcon kind={kind} />
              {KIND_LABEL[kind]}
            </div>
          ))}
        </section>
      ))}
      <p className="mt-4 px-1 text-[10px] leading-relaxed text-muted">
        Trascina un dispositivo sul canvas. Collega due dispositivi trascinando da un pallino all'altro.
      </p>
    </aside>
  )
}
```

`src/ui/DeviceNode.tsx`:

```tsx
import { Handle, Position, type Node, type NodeProps } from '@xyflow/react'
import type { NodeView } from '../shared/protocol'
import { DeviceIcon } from './icons'
import { firstIp } from './topology'

export type DeviceFlowNode = Node<{ view: NodeView }, 'device'>

const handleStyle = { background: 'var(--color-muted)', width: 7, height: 7, border: 'none' }

export function DeviceNode({ data, selected }: NodeProps<DeviceFlowNode>) {
  const v = data.view
  const ip = firstIp(v)
  const cabled = v.ifaces.some((i) => i.linked)
  return (
    <div
      data-testid={`node-${v.name}`}
      className={`min-w-[84px] rounded-md border bg-panel px-2 py-1.5 text-center ${selected ? 'border-accent' : 'border-border-strong'}`}
    >
      <Handle type="target" position={Position.Top} style={handleStyle} />
      <div className="flex items-center justify-center gap-1.5 text-fg-strong">
        <DeviceIcon kind={v.kind} />
        <span className="font-medium">{v.name}</span>
        <span className={`h-1.5 w-1.5 rounded-full ${cabled ? 'bg-ok' : 'bg-muted'}`} />
      </div>
      {ip && <div className="font-mono text-[10px] text-muted">{ip}</div>}
      <Handle type="source" position={Position.Bottom} style={handleStyle} />
    </div>
  )
}
```

- [ ] **Step 3: Implement the canvas and wire the layout**

`src/ui/Canvas.tsx`:

```tsx
import {
  Background,
  ConnectionMode,
  Controls,
  MiniMap,
  ReactFlow,
  useReactFlow,
  type Connection,
  type Edge,
  type EdgeChange,
  type NodeChange,
} from '@xyflow/react'
import { useMemo, useRef, type DragEvent } from 'react'
import type { DeviceKind } from '../shared/protocol'
import { addDevice, connect, moveEnd, moveStart, openMenu, removeElements, select, setPosition } from './actions'
import { DeviceNode, type DeviceFlowNode } from './DeviceNode'
import { DRAG_TYPE } from './Palette'
import { useApp } from './store'

const NODE_TYPES = { device: DeviceNode }
const GRID = 14

export function Canvas() {
  const snapshot = useApp((s) => s.snapshot)
  const positions = useApp((s) => s.positions)
  const selected = useApp((s) => s.selected)
  const { screenToFlowPosition } = useReactFlow()
  // React Flow measures nodes once; we rebuild node objects from snapshots, so keep the sizes it reported.
  const measured = useRef<Record<string, { width: number; height: number }>>({})

  const nodes = useMemo<DeviceFlowNode[]>(
    () =>
      snapshot.nodes.map((n) => ({
        id: n.id,
        type: 'device',
        position: positions[n.id] ?? { x: 0, y: 0 },
        data: { view: n },
        selected: selected?.kind === 'node' && selected.id === n.id,
        measured: measured.current[n.id],
      })),
    [snapshot.nodes, positions, selected],
  )

  const edges = useMemo<Edge[]>(
    () =>
      snapshot.links.map((l) => ({
        id: l.id,
        source: l.a.node,
        target: l.b.node,
        label: `${l.a.iface} ↔ ${l.b.iface}`,
        selected: selected?.kind === 'link' && selected.id === l.id,
      })),
    [snapshot.links, selected],
  )

  const onNodesChange = (changes: NodeChange<DeviceFlowNode>[]) => {
    for (const c of changes) {
      if (c.type === 'position' && c.position) setPosition(c.id, c.position)
      if (c.type === 'dimensions' && c.dimensions) measured.current[c.id] = c.dimensions
      if (c.type === 'select' && c.selected) select({ kind: 'node', id: c.id })
    }
  }

  const onEdgesChange = (changes: EdgeChange[]) => {
    for (const c of changes) if (c.type === 'select' && c.selected) select({ kind: 'link', id: c.id })
  }

  const onDrop = (e: DragEvent) => {
    const kind = e.dataTransfer.getData(DRAG_TYPE) as DeviceKind
    if (!kind) return
    e.preventDefault()
    void addDevice(kind, screenToFlowPosition({ x: e.clientX, y: e.clientY }))
  }

  return (
    <div
      className="relative min-w-0 flex-1"
      onDragOver={(e) => {
        e.preventDefault()
        e.dataTransfer.dropEffect = 'copy'
      }}
      onDrop={onDrop}
    >
      <ReactFlow
        nodes={nodes}
        edges={edges}
        nodeTypes={NODE_TYPES}
        colorMode="dark"
        style={{ background: 'var(--color-bg)' }}
        connectionMode={ConnectionMode.Loose}
        snapToGrid
        snapGrid={[GRID, GRID]}
        deleteKeyCode={['Delete', 'Backspace']}
        proOptions={{ hideAttribution: true }}
        onNodesChange={onNodesChange}
        onEdgesChange={onEdgesChange}
        onConnect={(c: Connection) => void connect(c.source, c.target)}
        onNodeDragStart={moveStart}
        onNodeDragStop={moveEnd}
        onPaneClick={() => select(null)}
        onDelete={({ nodes: ns, edges: es }) => void removeElements(ns.map((n) => n.id), es.map((e) => e.id))}
        onPaneContextMenu={(e) => {
          e.preventDefault()
          openMenu({ kind: 'pane', x: e.clientX, y: e.clientY, pos: screenToFlowPosition({ x: e.clientX, y: e.clientY }) })
        }}
        onNodeContextMenu={(e, n) => {
          e.preventDefault()
          openMenu({ kind: 'node', x: e.clientX, y: e.clientY, id: n.id })
        }}
        onEdgeContextMenu={(e, edge) => {
          e.preventDefault()
          openMenu({ kind: 'link', x: e.clientX, y: e.clientY, id: edge.id })
        }}
      >
        <Background gap={GRID} size={1} />
        <Controls />
        <MiniMap pannable zoomable />
      </ReactFlow>
    </div>
  )
}
```

Replace `src/ui/App.tsx` with:

```tsx
import { ReactFlowProvider } from '@xyflow/react'
import { Canvas } from './Canvas'
import { Palette } from './Palette'
import { Toolbar } from './Toolbar'
import { useShortcuts } from './shortcuts'

export function App() {
  useShortcuts()
  return (
    <ReactFlowProvider>
      <div className="flex h-full flex-col">
        <Toolbar />
        <main className="flex min-h-0 flex-1">
          <Palette />
          <Canvas />
        </main>
      </div>
    </ReactFlowProvider>
  )
}
```

- [ ] **Step 4: Run tests**

Run: `npm run e2e && npm test && npm run typecheck`
Expected: 4 e2e PASS, unit tests PASS, typecheck exits 0.

- [ ] **Step 5: Commit**

```bash
git add src/ui e2e
git commit -m "feat(ui): add canvas, device palette and device nodes"
```

---

### Task 6: Inspector and output panel

**Files:**
- Create: `src/ui/Inspector.tsx`, `src/ui/OutputPanel.tsx`, `e2e/inspector.spec.ts`
- Modify: `src/ui/App.tsx`, `e2e/helpers.ts`

**Interfaces:**
- Consumes: `edit`, `run`, `remove` (Task 3); `Field`, `Tabs`, `Button`, `ErrorText`, `inputClass` (Task 4); `IP_KINDS`, `KIND_LABEL`, `gatewayOf` (Task 3)
- Produces: `data-testid` hooks `inspector`, `node-name`, `ip-<iface>`, `gateway`, `app-target`, `output`; tab names `Interfacce`, `Routing`, `Tabelle`, `App`, `Porte`; e2e helper `setIp(page, node, cidr)`

- [ ] **Step 1: Write the failing e2e test**

Append to `e2e/helpers.ts`:

```ts
/** Selects `node` and sets the address of its first interface. */
export async function setIp(page: Page, node: string, cidr: string): Promise<void> {
  await page.getByTestId(`node-${node}`).click()
  await page.getByRole('tab', { name: 'Interfacce' }).click()
  const input = page.getByTestId('inspector').locator('input[data-testid^="ip-"]').first()
  await input.fill(cidr)
  await input.press('Enter')
}

/** PC1 (10.0.0.1) and PC2 (10.0.0.2) on SW1. */
export async function buildLan(page: Page): Promise<void> {
  await dropDevice(page, 'pc', 120, 260)
  await dropDevice(page, 'pc', 480, 260)
  await dropDevice(page, 'switch', 300, 80)
  await connectNodes(page, 'SW1', 'PC1')
  await connectNodes(page, 'SW1', 'PC2')
  await setIp(page, 'PC1', '10.0.0.1/24')
  await setIp(page, 'PC2', '10.0.0.2/24')
}
```

`e2e/inspector.spec.ts`:

```ts
import { expect, test, type ElectronApplication, type Page } from '@playwright/test'
import { buildLan, dropDevice, launch, setIp } from './helpers'

let app: ElectronApplication
let page: Page

test.beforeEach(async () => ({ app, page } = await launch()))
test.afterEach(async () => app.close())

test('configures addresses and pings from the App tab', async () => {
  await buildLan(page)
  await expect(page.getByTestId('node-PC2')).toContainText('10.0.0.2')
  await page.getByTestId('node-PC1').click()
  await page.getByRole('tab', { name: 'App' }).click()
  await page.getByTestId('app-target').fill('10.0.0.2')
  await page.getByRole('button', { name: 'Ping', exact: true }).click()
  await expect(page.getByTestId('output')).toContainText('64 bytes from 10.0.0.2', { timeout: 10_000 })
  await page.getByRole('tab', { name: 'Tabelle' }).click()
  await expect(page.getByTestId('inspector')).toContainText('10.0.0.2')
})

test('shows the engine error next to a bad address and keeps the old one', async () => {
  await dropDevice(page, 'pc', 200, 200)
  await setIp(page, 'PC1', '10.0.0.1/24')
  await setIp(page, 'PC1', '10.0.0.999/24')
  await expect(page.getByRole('alert')).toContainText('Invalid IPv4 address')
  await expect(page.getByTestId('node-PC1')).toContainText('10.0.0.1')
})

test('renames a device', async () => {
  await dropDevice(page, 'router', 200, 200)
  await page.getByTestId('node-R1').click()
  await page.getByTestId('node-name').fill('Core')
  await page.getByTestId('node-name').press('Enter')
  await expect(page.getByTestId('node-Core')).toBeVisible()
})
```

Run: `npm run e2e`
Expected: the 3 new tests FAIL — `tab "Interfacce"` not found.

- [ ] **Step 2: Implement the inspector**

`src/ui/Inspector.tsx`:

```tsx
import { useState } from 'react'
import type { LinkView, NodeView } from '../shared/protocol'
import { edit, remove, run } from './actions'
import { DeviceIcon } from './icons'
import { useApp } from './store'
import { IP_KINDS, KIND_LABEL, gatewayOf } from './topology'
import { Button, ErrorText, Field, Tabs, inputClass } from './ui'

export function Inspector() {
  const selected = useApp((s) => s.selected)
  const nodes = useApp((s) => s.snapshot.nodes)
  const links = useApp((s) => s.snapshot.links)
  const node = selected?.kind === 'node' ? nodes.find((n) => n.id === selected.id) : undefined
  const link = selected?.kind === 'link' ? links.find((l) => l.id === selected.id) : undefined
  return (
    <aside data-testid="inspector" className="w-72 shrink-0 overflow-y-auto border-l border-border bg-panel">
      {node ? (
        <NodeInspector key={node.id} node={node} />
      ) : link ? (
        <LinkInspector link={link} nodes={nodes} />
      ) : (
        <p className="p-3 text-muted">Seleziona un dispositivo o un collegamento.</p>
      )}
    </aside>
  )
}

const IP_TABS = ['Interfacce', 'Routing', 'Tabelle', 'App'] as const
const SWITCH_TABS = ['Porte', 'Tabelle'] as const
const HUB_TABS = ['Porte'] as const
type Tab = (typeof IP_TABS)[number] | (typeof SWITCH_TABS)[number]

function NodeInspector({ node }: { node: NodeView }) {
  const tabs: readonly Tab[] = IP_KINDS.has(node.kind) ? IP_TABS : node.kind === 'switch' ? SWITCH_TABS : HUB_TABS
  const [tab, setTab] = useState<Tab>(tabs[0])
  return (
    <>
      <div className="flex items-center gap-2 border-b border-border p-3">
        <DeviceIcon kind={node.kind} size={16} />
        <div className="flex-1">
          <Field
            label={KIND_LABEL[node.kind]}
            value={node.name}
            errorKey={`name:${node.id}`}
            testId="node-name"
            onCommit={(name) => edit({ type: 'rename', id: node.id, name }, `name:${node.id}`)}
          />
        </div>
      </div>
      <Tabs tabs={tabs} value={tab} onChange={setTab} />
      {tab === 'Interfacce' && <InterfacesTab node={node} />}
      {tab === 'Porte' && <PortsTab node={node} />}
      {tab === 'Routing' && <RoutingTab node={node} />}
      {tab === 'Tabelle' && <TablesTab node={node} />}
      {tab === 'App' && <AppTab node={node} />}
    </>
  )
}

function InterfacesTab({ node }: { node: NodeView }) {
  return (
    <div className="space-y-4 p-3">
      {node.ifaces.map((i) => {
        const key = `ip:${node.id}:${i.name}`
        return (
          <div key={i.name} className="space-y-1">
            <div className="flex justify-between text-[11px]">
              <span className="text-fg-strong">{i.name}</span>
              <span className={i.linked ? 'text-ok' : 'text-muted'}>{i.linked ? '● collegata' : '○ libera'}</span>
            </div>
            <Field
              label="Indirizzo IPv4 / prefisso"
              placeholder="192.168.1.10/24"
              value={i.cidr ?? ''}
              errorKey={key}
              testId={`ip-${i.name}`}
              onCommit={(v) => edit({ type: 'setIp', node: node.id, iface: i.name, cidr: v.trim() || null }, key)}
            />
            <div className="font-mono text-[10px] text-muted">MAC {i.mac}</div>
          </div>
        )
      })}
    </div>
  )
}

function PortsTab({ node }: { node: NodeView }) {
  return (
    <ul className="space-y-0.5 p-3 font-mono text-[11px]">
      {node.ifaces.map((i) => (
        <li key={i.name} className="flex justify-between">
          <span>{i.name}</span>
          <span className={i.linked ? 'text-ok' : 'text-muted'}>{i.linked ? '● collegata' : '○ libera'}</span>
        </li>
      ))}
    </ul>
  )
}

function RoutingTab({ node }: { node: NodeView }) {
  const [cidr, setCidr] = useState('')
  const [via, setVia] = useState('')
  const gateway = gatewayOf(node) ?? ''
  const gwKey = `gw:${node.id}`
  const routeKey = `route:${node.id}`
  const statics = node.routes.filter((r) => r.kind === 'static' && r.dest !== '0.0.0.0/0')
  const setGateway = (v: string) =>
    v.trim()
      ? edit({ type: 'addRoute', node: node.id, cidr: '0.0.0.0/0', nextHop: v.trim() }, gwKey)
      : gateway && edit({ type: 'removeRoute', node: node.id, cidr: '0.0.0.0/0' }, gwKey)
  return (
    <div className="space-y-4 p-3">
      <Field label="Gateway predefinito" placeholder="192.168.1.1" value={gateway} errorKey={gwKey} testId="gateway" onCommit={setGateway} />
      <section>
        <h4 className="mb-1 text-[10px] uppercase tracking-wide text-muted">Route statiche</h4>
        {statics.length === 0 && <p className="text-[11px] text-muted">nessuna</p>}
        <ul className="font-mono text-[11px]">
          {statics.map((r) => (
            <li key={r.dest} className="flex items-center gap-2">
              <span className="flex-1">
                {r.dest} via {r.nextHop}
              </span>
              <button
                type="button"
                title="Rimuovi route"
                className="text-muted hover:text-err"
                onClick={() => edit({ type: 'removeRoute', node: node.id, cidr: r.dest }, routeKey)}
              >
                ✕
              </button>
            </li>
          ))}
        </ul>
        <form
          className="mt-2 flex gap-1"
          onSubmit={(e) => {
            e.preventDefault()
            void edit({ type: 'addRoute', node: node.id, cidr, nextHop: via }, routeKey).then((ok) => {
              if (ok) {
                setCidr('')
                setVia('')
              }
            })
          }}
        >
          <input className={inputClass} placeholder="10.0.2.0/24" value={cidr} onChange={(e) => setCidr(e.target.value)} />
          <input className={inputClass} placeholder="next hop" value={via} onChange={(e) => setVia(e.target.value)} />
          <Button type="submit">+</Button>
        </form>
        <ErrorText errorKey={routeKey} />
      </section>
    </div>
  )
}

function Table({ title, head, rows }: { title: string; head: string[]; rows: string[][] }) {
  return (
    <section>
      <h4 className="mb-1 font-sans text-[10px] uppercase tracking-wide text-muted">{title}</h4>
      {rows.length === 0 ? (
        <p className="text-muted">vuota</p>
      ) : (
        <table className="w-full">
          <thead>
            <tr>
              {head.map((h) => (
                <th key={h} className="pr-2 text-left font-normal text-muted">
                  {h}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((r, i) => (
              <tr key={i}>
                {r.map((c, j) => (
                  <td key={j} className="pr-2">
                    {c}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  )
}

function TablesTab({ node }: { node: NodeView }) {
  return (
    <div className="space-y-4 p-3 font-mono text-[10px]">
      {node.kind === 'switch' ? (
        <Table title="Tabella MAC" head={['MAC', 'Porta', 'Età']} rows={node.mac.map((m) => [m.mac, m.iface, `${m.ageS}s`])} />
      ) : (
        <>
          <Table
            title="Tabella di routing"
            head={['Destinazione', 'Next hop', 'Int.']}
            rows={node.routes.map((r) => [r.dest, r.nextHop ?? 'connessa', r.iface])}
          />
          <Table title="Cache ARP" head={['IP', 'MAC', 'Int.', 'TTL']} rows={node.arp.map((a) => [a.ip, a.mac, a.iface, `${a.ttlS}s`])} />
        </>
      )}
    </div>
  )
}

function AppTab({ node }: { node: NodeView }) {
  const [target, setTarget] = useState('')
  const key = `app:${node.id}`
  return (
    <div className="space-y-2 p-3">
      <label className="block">
        <span className="mb-0.5 block text-[10px] text-muted">Destinazione</span>
        <input
          data-testid="app-target"
          className={inputClass}
          placeholder="10.0.0.2"
          value={target}
          onChange={(e) => setTarget(e.target.value)}
        />
      </label>
      <div className="flex gap-1">
        <Button onClick={() => void run({ type: 'ping', node: node.id, target }, key)}>Ping</Button>
        <Button onClick={() => void run({ type: 'traceroute', node: node.id, target }, key)}>Traceroute</Button>
      </div>
      <ErrorText errorKey={key} />
      <p className="text-[10px] text-muted">L'output compare nel pannello in basso.</p>
    </div>
  )
}

function LinkInspector({ link, nodes }: { link: LinkView; nodes: NodeView[] }) {
  const name = (id: string) => nodes.find((n) => n.id === id)?.name ?? '?'
  return (
    <div className="space-y-3 p-3">
      <h3 className="text-fg-strong">Collegamento Ethernet</h3>
      <p className="font-mono text-[11px]">
        {name(link.a.node)} {link.a.iface} ↔ {name(link.b.node)} {link.b.iface}
      </p>
      <p className="text-[10px] text-muted">1 Gb/s · 500 ns (modificabile nella prossima versione)</p>
      <Button danger onClick={() => void remove({ kind: 'link', id: link.id })}>
        Scollega
      </Button>
    </div>
  )
}
```

`src/ui/OutputPanel.tsx`:

```tsx
import { useEffect, useRef } from 'react'
import { useApp } from './store'

export function OutputPanel() {
  const apps = useApp((s) => s.snapshot.apps)
  const nodes = useApp((s) => s.snapshot.nodes)
  const box = useRef<HTMLDivElement>(null)
  const lineCount = apps.reduce((n, a) => n + a.lines.length, 0)
  useEffect(() => {
    box.current?.scrollTo({ top: box.current.scrollHeight })
  }, [lineCount])
  const name = (id: string) => nodes.find((n) => n.id === id)?.name ?? '(rimosso)'
  return (
    <section className="flex h-44 shrink-0 flex-col border-t border-border bg-panel">
      <div className="border-b border-border px-3 py-1 text-[11px] text-fg-strong">Output app</div>
      <div ref={box} data-testid="output" className="flex-1 overflow-y-auto px-3 py-1 font-mono text-[11px] select-text">
        {apps.length === 0 && (
          <p className="text-muted">Nessuna applicazione avviata: usa la scheda App dell'ispettore o il menu contestuale di un dispositivo.</p>
        )}
        {apps.map((a) => (
          <div key={a.id} className="mb-2">
            <div className="text-accent">
              {name(a.node)}$ {a.title}
              {a.done ? '' : ' …'}
            </div>
            {a.lines.map((l, i) => (
              <div key={i} className="whitespace-pre">
                {l}
              </div>
            ))}
          </div>
        ))}
      </div>
    </section>
  )
}
```

Replace `src/ui/App.tsx` with:

```tsx
import { ReactFlowProvider } from '@xyflow/react'
import { Canvas } from './Canvas'
import { Inspector } from './Inspector'
import { OutputPanel } from './OutputPanel'
import { Palette } from './Palette'
import { Toolbar } from './Toolbar'
import { useShortcuts } from './shortcuts'

export function App() {
  useShortcuts()
  return (
    <ReactFlowProvider>
      <div className="flex h-full flex-col">
        <Toolbar />
        <main className="flex min-h-0 flex-1">
          <Palette />
          <Canvas />
          <Inspector />
        </main>
        <OutputPanel />
      </div>
    </ReactFlowProvider>
  )
}
```

- [ ] **Step 3: Run tests**

Run: `npm run e2e && npm test && npm run typecheck`
Expected: 7 e2e PASS, unit tests PASS, typecheck exits 0.

- [ ] **Step 4: Commit**

```bash
git add src/ui e2e
git commit -m "feat(ui): add inspector tabs and app output panel"
```

---

### Task 7: Context menus

**Files:**
- Create: `src/ui/ContextMenu.tsx`, `e2e/menus.spec.ts`
- Modify: `src/ui/App.tsx`

**Interfaces:**
- Consumes: `useApp().menu` set by `Canvas` (Task 5); `addDevice`, `remove`, `run`, `select` (Task 3); `ALL_KINDS`, `KIND_LABEL`, `IP_KINDS`, `firstIp` (Task 3); `DeviceIcon` (Task 5); `buildLan` (Task 6)
- Produces: menus with `role="menu"` / `role="menuitem"` — pane: *Aggiungi dispositivo ▸*, *Adatta alla vista*; node: *Apri ispettore*, *Ping verso ▸*, *Traceroute verso ▸*, *Elimina*; link: *Scollega*

- [ ] **Step 1: Write the failing e2e test**

`e2e/menus.spec.ts`:

```ts
import { expect, test, type ElectronApplication, type Page } from '@playwright/test'
import { buildLan, launch } from './helpers'

let app: ElectronApplication
let page: Page

test.beforeEach(async () => ({ app, page } = await launch()))
test.afterEach(async () => app.close())

test('adds a device from the canvas menu and deletes it from its own menu', async () => {
  await page.locator('.react-flow__pane').click({ button: 'right', position: { x: 300, y: 200 } })
  await page.getByText('Aggiungi dispositivo').hover()
  await page.getByRole('menuitem', { name: 'Router' }).click()
  await expect(page.getByTestId('node-R1')).toBeVisible()
  await page.getByTestId('node-R1').click({ button: 'right' })
  await page.getByRole('menuitem', { name: 'Elimina' }).click()
  await expect(page.getByTestId('node-R1')).toHaveCount(0)
})

test('pings and traceroutes another device from the node menu', async () => {
  await buildLan(page)
  await page.getByTestId('node-PC1').click({ button: 'right' })
  await page.getByText('Ping verso').hover()
  await page.getByRole('menuitem', { name: /PC2/ }).click()
  await expect(page.getByTestId('output')).toContainText('PC1$ ping 10.0.0.2')
  await expect(page.getByTestId('output')).toContainText('64 bytes from 10.0.0.2', { timeout: 10_000 })
})

test('disconnects a cable from its menu and Escape closes a menu', async () => {
  await buildLan(page)
  await page.locator('.react-flow__edge').first().click({ button: 'right' })
  await page.keyboard.press('Escape')
  await expect(page.getByRole('menu')).toHaveCount(0)
  await page.locator('.react-flow__edge').first().click({ button: 'right' })
  await page.getByRole('menuitem', { name: 'Scollega' }).click()
  await expect(page.locator('.react-flow__edge')).toHaveCount(1)
})
```

Run: `npm run e2e`
Expected: the 3 new tests FAIL — `Aggiungi dispositivo` not found.

- [ ] **Step 2: Implement**

`src/ui/ContextMenu.tsx`:

```tsx
import { useReactFlow } from '@xyflow/react'
import { useEffect, type ReactNode } from 'react'
import type { NodeView } from '../shared/protocol'
import { addDevice, remove, run, select } from './actions'
import { DeviceIcon } from './icons'
import { useApp } from './store'
import { ALL_KINDS, IP_KINDS, KIND_LABEL, firstIp } from './topology'

const panel = 'min-w-44 rounded border border-border-strong bg-panel py-1 shadow-xl'

function Item(props: { onClick(): void; danger?: boolean; children: ReactNode }) {
  return (
    <button
      type="button"
      role="menuitem"
      onClick={props.onClick}
      className={`flex w-full items-center gap-2 px-3 py-1 text-left hover:bg-accent hover:text-white ${props.danger ? 'text-err' : 'text-fg'}`}
    >
      {props.children}
    </button>
  )
}

function Submenu(props: { label: string; children: ReactNode; empty?: boolean }) {
  return (
    <div className="group relative">
      <div className={`flex items-center px-3 py-1 ${props.empty ? 'text-muted' : 'text-fg group-hover:bg-accent group-hover:text-white'}`}>
        {props.label}
        <span className="ml-auto pl-4">▸</span>
      </div>
      {!props.empty && (
        <div role="menu" className={`absolute top-0 left-full hidden group-hover:block ${panel}`}>
          {props.children}
        </div>
      )}
    </div>
  )
}

function AppTargets(props: { from: NodeView; nodes: NodeView[]; app: 'ping' | 'traceroute' }) {
  const targets = props.nodes.filter((n) => n.id !== props.from.id && firstIp(n))
  return (
    <Submenu label={props.app === 'ping' ? 'Ping verso' : 'Traceroute verso'} empty={targets.length === 0}>
      {targets.map((t) => (
        <Item key={t.id} onClick={() => void run({ type: props.app, node: props.from.id, target: firstIp(t)! }, `app:${props.from.id}`)}>
          {t.name}
          <span className="ml-auto pl-4 font-mono text-[10px] opacity-70">{firstIp(t)}</span>
        </Item>
      ))}
    </Submenu>
  )
}

export function ContextMenu() {
  const menu = useApp((s) => s.menu)
  const nodes = useApp((s) => s.snapshot.nodes)
  const { fitView } = useReactFlow()

  useEffect(() => {
    if (!menu) return
    const close = () => useApp.setState({ menu: null })
    window.addEventListener('click', close)
    window.addEventListener('blur', close)
    return () => {
      window.removeEventListener('click', close)
      window.removeEventListener('blur', close)
    }
  }, [menu])

  if (!menu) return null

  let items: ReactNode = null
  if (menu.kind === 'pane') {
    items = (
      <>
        <Submenu label="Aggiungi dispositivo">
          {ALL_KINDS.map((k) => (
            <Item key={k} onClick={() => void addDevice(k, menu.pos)}>
              <DeviceIcon kind={k} />
              {KIND_LABEL[k]}
            </Item>
          ))}
        </Submenu>
        <Item onClick={() => void fitView({ duration: 200 })}>Adatta alla vista</Item>
      </>
    )
  } else if (menu.kind === 'node') {
    const node = nodes.find((n) => n.id === menu.id)
    if (!node) return null
    items = (
      <>
        <Item onClick={() => select({ kind: 'node', id: node.id })}>Apri ispettore</Item>
        {IP_KINDS.has(node.kind) && (
          <>
            <AppTargets from={node} nodes={nodes} app="ping" />
            <AppTargets from={node} nodes={nodes} app="traceroute" />
          </>
        )}
        <div className="my-1 h-px bg-border" />
        <Item danger onClick={() => void remove({ kind: 'node', id: node.id })}>
          Elimina
        </Item>
      </>
    )
  } else {
    items = (
      <Item danger onClick={() => void remove({ kind: 'link', id: menu.id })}>
        Scollega
      </Item>
    )
  }

  return (
    <div role="menu" className={`fixed z-50 ${panel}`} style={{ left: menu.x, top: menu.y }} onContextMenu={(e) => e.preventDefault()}>
      {items}
    </div>
  )
}
```

Replace `src/ui/App.tsx` with:

```tsx
import { ReactFlowProvider } from '@xyflow/react'
import { Canvas } from './Canvas'
import { ContextMenu } from './ContextMenu'
import { Inspector } from './Inspector'
import { OutputPanel } from './OutputPanel'
import { Palette } from './Palette'
import { Toolbar } from './Toolbar'
import { useShortcuts } from './shortcuts'

export function App() {
  useShortcuts()
  return (
    <ReactFlowProvider>
      <div className="flex h-full flex-col">
        <Toolbar />
        <main className="flex min-h-0 flex-1">
          <Palette />
          <Canvas />
          <Inspector />
        </main>
        <OutputPanel />
      </div>
      <ContextMenu />
    </ReactFlowProvider>
  )
}
```

- [ ] **Step 3: Run the full suites**

Run: `npm run e2e && npm test && npm run typecheck`
Expected: 10 e2e PASS, unit tests PASS, typecheck exits 0.

- [ ] **Step 4: Commit**

```bash
git add src/ui e2e
git commit -m "feat(ui): add canvas, device and cable context menus"
```

---

## Done criteria for M2a

- `npm test`, `npm run typecheck` and `npm run e2e` all green.
- `npm start` opens the app: drag devices, cable them, set IPs/gateway/routes, ping/traceroute from the inspector or the node menu, read ARP/MAC/routing tables live, undo/redo, save and reopen a `.ptk`.
- Next: M2b plan (Simulation mode, events + PDU inspector, packet animation, link properties, power, copy/paste, palette search, resizable panel, loop warning).
