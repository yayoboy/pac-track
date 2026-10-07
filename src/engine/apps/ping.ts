import { formatIp, parseIp } from '../addr'
import type { IpNode } from '../l3/ip-node'
import { ICMP_DEST_UNREACH, ICMP_ECHO_REPLY, ICMP_ECHO_REQUEST, ICMP_TIME_EXCEEDED, makeIcmp } from '../pdu'
import type { Timer } from '../scheduler'
import { MS, S } from '../time'

export interface PingOptions {
  count: number
  intervalNs: number
  /** How long to wait after the last request before giving up. */
  timeoutNs: number
  size: number
  ttl?: number
}

export const PING_DEFAULTS: PingOptions = { count: 4, intervalNs: 1 * S, timeoutNs: 10 * S, size: 56 }

export interface PingReply {
  seq: number
  from: string
  ttl: number
  rttNs: number
}

export interface PingError {
  seq: number
  from: string
  type: number
  code: number
}

export interface PingResult {
  transmitted: number
  received: number
  replies: PingReply[]
  errors: PingError[]
  lines: string[]
  done: boolean
}

export interface PingHandle {
  readonly result: PingResult
  stop(): void
}

const ERROR_TEXT: Record<string, string> = {
  '3/0': 'Destination Net Unreachable',
  '3/1': 'Destination Host Unreachable',
  '3/3': 'Destination Port Unreachable',
  '3/4': 'Frag needed and DF set',
  '11/0': 'Time to live exceeded',
}

/** Linux-style ping. Output lines mimic iputils. */
export function ping(node: IpNode, target: string, options: Partial<PingOptions> = {}): PingHandle {
  const opts = { ...PING_DEFAULTS, ...options }
  const valid =
    Number.isInteger(opts.count) && opts.count >= 1 &&
    opts.intervalNs > 0 && opts.timeoutNs > 0 &&
    Number.isInteger(opts.size) && opts.size >= 0 && opts.size <= 65507 &&
    (opts.ttl === undefined || (Number.isInteger(opts.ttl) && opts.ttl >= 1 && opts.ttl <= 255))
  if (!valid) throw new Error(`Invalid ping option: ${JSON.stringify(options)}`)
  const dst = parseIp(target)
  const sim = node.sim
  const id = sim.rng.int(0x10000)
  const sentAt = new Map<number, number>()
  const timers: Timer[] = []
  const result: PingResult = {
    transmitted: 0,
    received: 0,
    replies: [],
    errors: [],
    lines: [`PING ${target} (${target}) ${opts.size}(${opts.size + 28}) bytes of data.`],
    done: false,
  }

  const finish = (withStats: boolean) => {
    if (result.done) return
    result.done = true
    timers.forEach((t) => t.cancel())
    unlisten()
    if (!withStats) return
    const lost = result.transmitted - result.received
    const loss = result.transmitted === 0 ? 0 : Math.round((lost / result.transmitted) * 100)
    const errors = result.errors.length ? `+${result.errors.length} errors, ` : ''
    result.lines.push(
      `--- ${target} ping statistics ---`,
      `${result.transmitted} packets transmitted, ${result.received} received, ${errors}${loss}% packet loss`,
    )
  }

  const settleIfComplete = () => {
    if (result.transmitted === opts.count && sentAt.size === 0) finish(true)
  }

  const unlisten = node.onIcmp((p, icmp) => {
    if (icmp.type === ICMP_ECHO_REPLY) {
      const at = sentAt.get(icmp.seq)
      if (icmp.id !== id || at === undefined) return
      sentAt.delete(icmp.seq)
      const rttNs = sim.now - at
      result.received++
      result.replies.push({ seq: icmp.seq, from: formatIp(p.src), ttl: p.ttl, rttNs })
      result.lines.push(
        `${icmp.data.length + 8} bytes from ${formatIp(p.src)}: icmp_seq=${icmp.seq} ttl=${p.ttl} time=${(rttNs / MS).toFixed(3)} ms`,
      )
      settleIfComplete()
      return
    }
    if (icmp.type !== ICMP_DEST_UNREACH && icmp.type !== ICMP_TIME_EXCEEDED) return
    // Quoted datagram: our IPv4 header (20 B) + first 8 B of our echo request.
    const q = icmp.data
    if (q.length < 28 || q[20] !== ICMP_ECHO_REQUEST || ((q[24] << 8) | q[25]) !== id) return
    const seq = (q[26] << 8) | q[27]
    sentAt.delete(seq)
    result.errors.push({ seq, from: formatIp(p.src), type: icmp.type, code: icmp.code })
    const text = ERROR_TEXT[`${icmp.type}/${icmp.code}`] ?? `ICMP type ${icmp.type} code ${icmp.code}`
    result.lines.push(`From ${formatIp(p.src)} icmp_seq=${seq} ${text}`)
    settleIfComplete()
  })

  const send = (seq: number) => {
    const payload = makeIcmp({ type: ICMP_ECHO_REQUEST, code: 0, id, seq, data: new Uint8Array(opts.size) })
    sentAt.set(seq, sim.now)
    if (!node.sendPacket(dst, payload, opts.ttl)) {
      sentAt.delete(seq)
      result.lines.push('ping: connect: Network is unreachable')
      finish(false)
      return
    }
    result.transmitted++
  }

  for (let seq = 1; seq <= opts.count; seq++) {
    timers.push(sim.sched.after((seq - 1) * opts.intervalNs, () => send(seq)))
  }
  timers.push(sim.sched.after((opts.count - 1) * opts.intervalNs + opts.timeoutNs, () => finish(true)))

  return { result, stop: () => finish(true) }
}
