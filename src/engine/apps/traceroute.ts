import { formatIp, parseIp } from '../addr'
import type { IpNode } from '../l3/ip-node'
import { ICMP_DEST_UNREACH, ICMP_TIME_EXCEEDED, IPPROTO_UDP, UNREACH_PORT } from '../pdu'
import type { Timer } from '../scheduler'
import { MS, S } from '../time'

export interface TracerouteOptions {
  maxHops: number
  probes: number
  waitNs: number
  firstPort: number
}

export const TRACEROUTE_DEFAULTS: TracerouteOptions = { maxHops: 30, probes: 3, waitNs: 5 * S, firstPort: 33434 }

export interface TraceProbe {
  from?: string
  rttNs?: number
  note?: string
}

export interface TraceHop {
  ttl: number
  probes: TraceProbe[]
}

export interface TracerouteResult {
  hops: TraceHop[]
  reached: boolean
  done: boolean
  lines: string[]
}

const NOTES: Record<number, string> = { 0: '!N', 1: '!H', 4: '!F' }

function formatHop(hop: TraceHop): string {
  let line = `${String(hop.ttl).padStart(2)} `
  let last: string | undefined
  for (const p of hop.probes) {
    if (!p.from) {
      line += ' *'
      continue
    }
    if (p.from !== last) {
      line += ` ${p.from} (${p.from})`
      last = p.from
    }
    line += `  ${(p.rttNs! / MS).toFixed(3)} ms${p.note ? ` ${p.note}` : ''}`
  }
  return line
}

interface InFlight {
  hop: TraceHop
  sent: Map<number, { index: number; at: number }>
  pending: number
  timer?: Timer
}

/** Linux-style UDP traceroute: `probes` probes per TTL, one hop at a time. */
export function traceroute(node: IpNode, target: string, options: Partial<TracerouteOptions> = {}) {
  const opts = { ...TRACEROUTE_DEFAULTS, ...options }
  const valid =
    Number.isInteger(opts.maxHops) && opts.maxHops >= 1 && opts.maxHops <= 255 &&
    Number.isInteger(opts.probes) && opts.probes >= 1 &&
    opts.waitNs > 0 &&
    Number.isInteger(opts.firstPort) && opts.firstPort >= 1 &&
    opts.firstPort + opts.maxHops * opts.probes <= 0x10000
  if (!valid) throw new Error(`Invalid traceroute option: ${JSON.stringify(options)}`)
  const dst = parseIp(target)
  const sim = node.sim
  const srcPort = 33000 + sim.rng.int(10000)
  let port = opts.firstPort
  let current: InFlight | undefined
  const result: TracerouteResult = {
    hops: [],
    reached: false,
    done: false,
    lines: [`traceroute to ${target} (${target}), ${opts.maxHops} hops max, 60 byte packets`],
  }

  const finish = () => {
    if (result.done) return
    result.done = true
    current?.timer?.cancel()
    current = undefined
    unlisten()
  }

  const closeHop = () => {
    const c = current!
    c.timer?.cancel()
    current = undefined
    result.lines.push(formatHop(c.hop))
    if (result.reached || c.hop.ttl >= opts.maxHops) finish()
    else sendHop(c.hop.ttl + 1)
  }

  const sendHop = (ttl: number) => {
    const hop: TraceHop = { ttl, probes: Array.from({ length: opts.probes }, () => ({})) }
    result.hops.push(hop)
    current = { hop, sent: new Map(), pending: opts.probes }
    for (let i = 0; i < opts.probes; i++) {
      const dport = port++
      current.sent.set(dport, { index: i, at: sim.now })
      if (!node.sendUdp(dst, srcPort, dport, new Uint8Array(32), ttl)) {
        result.lines.push('connect: Network is unreachable')
        finish()
        return
      }
    }
    current.timer = sim.sched.after(opts.waitNs, closeHop)
  }

  const unlisten = node.onIcmp((p, icmp) => {
    if (!current || (icmp.type !== ICMP_TIME_EXCEEDED && icmp.type !== ICMP_DEST_UNREACH)) return
    // Quoted datagram: original IPv4 header (20 B) + UDP header (8 B).
    const q = icmp.data
    if (q.length < 28 || q[9] !== IPPROTO_UDP) return
    // Only our own probes: quoted destination and source port must match this run.
    const quotedDst = ((q[16] << 24) | (q[17] << 16) | (q[18] << 8) | q[19]) >>> 0
    if (quotedDst !== dst || ((q[20] << 8) | q[21]) !== srcPort) return
    const dport = (q[22] << 8) | q[23]
    const probe = current.sent.get(dport)
    if (!probe) return
    current.sent.delete(dport)
    const note = icmp.type === ICMP_DEST_UNREACH && icmp.code !== UNREACH_PORT ? NOTES[icmp.code] ?? `!<${icmp.code}>` : undefined
    current.hop.probes[probe.index] = { from: formatIp(p.src), rttNs: sim.now - probe.at, note }
    if (icmp.type === ICMP_DEST_UNREACH) result.reached = true
    if (--current.pending === 0) closeHop()
  })

  sim.sched.after(0, () => sendHop(1))
  return { result, stop: finish }
}
