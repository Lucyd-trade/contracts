#!/usr/bin/env node
// Recomputes what a Lucyd scout is owed from the chain alone and compares it with the payouts.
//
//   npm install viem
//   node verify-scout.mjs --scout 0xYourWallet
//
// It takes the partners bound to the scout (ScoutProgram PartnerBound, with boundAt), every payout
// to those partners (PartnerProgram Paid events) and every payout to the scout (ScoutProgram Paid).
// For each partner payout on UTC day D, from the binding day on, the scout is owed
//   floor(paid * share), share = 50% while D is less than 180 days after the binding day, 10% after.
// A scout is paid later and in lumps (only with 2+ bound partners, from $10), so the check is
// cumulative: by the end of every day the scout's Paid total must not exceed what was owed up to that
// day. Any day where it does is printed as a MISMATCH. Owed minus paid is what is still pending,
// waiting for the minimum, expired (threshold not reached in 90 days) or withheld (scout disabled).
// With --report it also compares each day's owed amounts with the `scouts` section of the public
// daily report.
//
// Options (defaults: Lucyd Sepolia testnet):
//   --rpc <url>                 Sepolia JSON-RPC
//   --partner-program <address> PartnerProgram
//   --scout-program <address>   ScoutProgram
//   --start-block <n>           PartnerProgram deploy block
//   --scout-start-block <n>     ScoutProgram deploy block
//   --report                    also fetch https://data.testnet.lucyd.trade/partners/reports/<day>.json

import { createPublicClient, http, parseAbiItem, getAddress } from 'viem'
import { sepolia } from 'viem/chains'

const DEFAULTS = {
  rpc: 'https://ethereum-sepolia-rpc.publicnode.com',
  'partner-program': '0xf1552eEBe261c0438a31DcbC39c57d31Fa7b0A25',
  'scout-program': '0x03d75C08db918065DCdb86fcB813Fe2b5d619F27',
  'start-block': '11906089',
  'scout-start-block': '11998967',
  reports: 'https://data.testnet.lucyd.trade/partners/reports',
}
const CHUNK = 1000n
/** Same as contracts partners/src/scouts.rs. */
const EARLY_BPS = 5000n
const EARLY_DAYS = 180
const LATE_BPS = 1000n

const PARTNER_BOUND = parseAbiItem('event PartnerBound(address indexed partner, address indexed scout, uint64 boundAt)')
const PARTNER_PAID = parseAbiItem('event Paid(uint32 indexed day, address indexed partner, uint256 amount)')
const SCOUT_PAID = parseAbiItem('event Paid(uint32 indexed day, address indexed scout, uint256 amount)')

const usd = (v) => `${v / 1_000_000n}.${(v % 1_000_000n).toString().padStart(6, '0')}`
const dayString = (n) => new Date(n * 86_400_000).toISOString().slice(0, 10)

/** Scout's share (bps) of a partner payout on `day` for a partner bound on `boundDay`; 0 before the binding. */
function shareBps(day, boundDay) {
  if (day < boundDay) return 0n
  return day - boundDay < EARLY_DAYS ? EARLY_BPS : LATE_BPS
}

function args() {
  const out = { ...DEFAULTS }
  const argv = process.argv.slice(2)
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i].replace(/^--/, '')
    if (k === 'report') out.report = true
    else out[k] = argv[++i]
  }
  if (!out.scout || !out['scout-program'] || !out['scout-start-block']) {
    console.error('usage: node verify-scout.mjs --scout 0x… [--scout-program 0x… --scout-start-block N] [--report]')
    process.exit(2)
  }
  return out
}

async function logsInChunks(client, params, from, to) {
  const out = []
  for (let a = from; a <= to; a += CHUNK) {
    const b = a + CHUNK - 1n < to ? a + CHUNK - 1n : to
    out.push(...await client.getLogs({ ...params, fromBlock: a, toBlock: b }))
  }
  return out
}

async function main() {
  const o = args()
  const client = createPublicClient({ chain: sepolia, transport: http(o.rpc) })
  const scout = getAddress(o.scout)
  const head = await client.getBlockNumber()

  const bound = await logsInChunks(client, { address: o['scout-program'], event: PARTNER_BOUND, args: { scout } }, BigInt(o['scout-start-block']), head)
  console.log(`scout ${scout}: ${bound.length} bound partner(s)`)
  // day → [{ partner, paid, bps, owed }]
  const owedByDay = new Map()
  for (const b of bound) {
    const partner = b.args.partner
    const boundDay = Math.floor(Number(b.args.boundAt) / 86400)
    console.log(`  ${partner} bound ${dayString(boundDay)}, 50% until ${dayString(boundDay + EARLY_DAYS - 1)}`)
    const paid = await logsInChunks(client, { address: o['partner-program'], event: PARTNER_PAID, args: { partner } }, BigInt(o['start-block']), head)
    for (const p of paid) {
      const day = Number(p.args.day)
      const bps = shareBps(day, boundDay)
      if (bps === 0n) continue
      const owed = p.args.amount * bps / 10_000n
      if (!owedByDay.has(day)) owedByDay.set(day, [])
      owedByDay.get(day).push({ partner, paid: p.args.amount, bps, owed })
    }
  }

  const scoutPaid = await logsInChunks(client, { address: o['scout-program'], event: SCOUT_PAID, args: { scout } }, BigInt(o['scout-start-block']), head)
  const paidByDay = new Map()
  for (const p of scoutPaid) {
    const day = Number(p.args.day)
    paidByDay.set(day, (paidByDay.get(day) ?? 0n) + p.args.amount)
  }

  const days = [...new Set([...owedByDay.keys(), ...paidByDay.keys()])].sort((a, b) => a - b)
  let owedTotal = 0n, paidTotal = 0n, mismatches = 0
  for (const day of days) {
    const rows = owedByDay.get(day) ?? []
    const owed = rows.reduce((s, r) => s + r.owed, 0n)
    const paid = paidByDay.get(day) ?? 0n
    owedTotal += owed
    paidTotal += paid
    for (const r of rows) {
      console.log(`  ${dayString(day)} partner ${r.partner} paid ${usd(r.paid)} × ${Number(r.bps) / 100}% → owed ${usd(r.owed)}`)
    }
    let line = `${dayString(day)}: owed ${usd(owed)}, paid ${usd(paid)} | to date owed ${usd(owedTotal)}, paid ${usd(paidTotal)}`
    if (paidTotal > owedTotal) {
      line += `  ✗ MISMATCH: paid ${usd(paidTotal - owedTotal)} more than owed`
      mismatches++
    }
    if (o.report && rows.length) {
      const res = await fetch(`${o.reports}/${dayString(day)}.json`)
      if (res.ok) {
        const r = await res.json()
        const reported = (r.scouts?.accruals ?? []).filter((a) => a.scout.toLowerCase() === scout.toLowerCase())
        const sum = reported.reduce((s, a) => s + BigInt(a.accrued_usdc.replace('.', '')), 0n)
        line += ` | report: ${usd(sum)} ${sum === owed ? '✓' : sum < owed ? '(less: scout disabled that day?)' : '✗ MISMATCH'}`
        if (sum > owed) mismatches++
      } else {
        line += ` | report: not found (${res.status})`
      }
    }
    console.log(line)
  }
  console.log(`\nowed all time: ${usd(owedTotal)} USDC; paid all time: ${usd(paidTotal)} USDC`)
  console.log(mismatches ? `${mismatches} mismatch(es) found` : 'No mismatches: the scout was never paid more than owed.')
  if (mismatches) process.exit(1)
}

main().catch((e) => { console.error(e); process.exit(1) })
