#!/usr/bin/env node
// Recomputes a Lucyd partner's earnings from the chain alone and compares them with the payouts.
//
//   npm install viem
//   node verify-partner.mjs --partner 0xYourWallet --from 2026-10-14 --to 2026-10-20
//
// For every UTC day in the range it takes the traders bound to the partner (PartnerProgram
// TraderBound events), the Exchange fills of that day (OrdersMatched + the matchOrders calldata,
// whose signed orders give taker, maker and amounts), keeps fills where a bound trader is the taker
// (bound in an earlier block) and the market maker is the maker, and computes
//   volume  = USDC the taker paid on a buy / received on a sell
//   accrued = floor(sum(volume) * rate)
// Then it lists the partner's Paid events. Accrued minus paid is the balance still due (paid out
// once it reaches $10). With --report it also compares each day with the public daily report.
//
// Options (defaults: Lucyd Sepolia testnet):
//   --rpc <url>          Sepolia JSON-RPC (an archive-capable node for older days)
//   --program <address>  PartnerProgram
//   --exchange <address> Exchange (ClobSettlement)
//   --mm <a,b>           market maker wallets
//   --rate <fraction>    partner rate, default 0.001 (0.1%)
//   --start-block <n>    PartnerProgram deploy block
//   --report             also fetch https://data.testnet.lucyd.trade/partners/reports/<day>.json

import {
  createPublicClient, http, parseAbi, parseAbiItem, decodeFunctionData, hashTypedData, getAddress,
} from 'viem'
import { sepolia } from 'viem/chains'

const DEFAULTS = {
  rpc: 'https://ethereum-sepolia-rpc.publicnode.com',
  program: '0xf1552eEBe261c0438a31DcbC39c57d31Fa7b0A25',
  exchange: '0x6588c789c6b6df8f8b6b92e6433f813cc2d1d4d0',
  mm: '0x2c2b35ff4055522a7bf228efb07540d6c8f73744',
  rate: '0.001',
  'start-block': '11906089',
  reports: 'https://data.testnet.lucyd.trade/partners/reports',
}
const CHUNK = 1000n

function args() {
  const out = { ...DEFAULTS }
  const argv = process.argv.slice(2)
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i].replace(/^--/, '')
    if (k === 'report') out.report = true
    else out[k] = argv[++i]
  }
  if (!out.partner || !out.from) {
    console.error('usage: node verify-partner.mjs --partner 0x… --from YYYY-MM-DD [--to YYYY-MM-DD] [--report]')
    process.exit(2)
  }
  out.to ??= out.from
  return out
}

const ORDER = [
  { name: 'protocolVersion', type: 'uint16' },
  { name: 'maker', type: 'address' },
  { name: 'signer', type: 'address' },
  { name: 'taker', type: 'address' },
  { name: 'outcomeId', type: 'bytes32' },
  { name: 'marketId', type: 'bytes32' },
  { name: 'side', type: 'uint8' },
  { name: 'timeInForce', type: 'uint8' },
  { name: 'makerAmount', type: 'uint64' },
  { name: 'takerAmount', type: 'uint64' },
  { name: 'minFillAmount', type: 'uint64' },
  { name: 'expiration', type: 'uint64' },
  { name: 'nonceEpoch', type: 'uint64' },
  { name: 'salt', type: 'bytes32' },
]
const ORDER_TUPLE = '(uint16 protocolVersion,address maker,address signer,address taker,bytes32 outcomeId,bytes32 marketId,uint8 side,uint8 timeInForce,uint64 makerAmount,uint64 takerAmount,uint64 minFillAmount,uint64 expiration,uint64 nonceEpoch,bytes32 salt)'
const FILL_TUPLE = '(uint64 makerAmount,uint64 takerAmount,uint64 makerReceiveAmount,uint64 takerReceiveAmount)'
const EXCHANGE_ABI = parseAbi([
  `function matchOrders(${ORDER_TUPLE} taker, bytes takerSignature, ${ORDER_TUPLE}[] makers, bytes[] makerSignatures, ${FILL_TUPLE}[] fills)`,
  `function matchOrdersBatch((${ORDER_TUPLE} taker, bytes takerSignature, ${ORDER_TUPLE}[] makers, bytes[] makerSignatures, ${FILL_TUPLE}[] fills)[] matches)`,
])
const ORDERS_MATCHED = parseAbiItem(`event OrdersMatched(bytes32 indexed takerOrderId, bytes32 indexed makerOrderId, uint8 matchType, ${FILL_TUPLE} fill)`)
const TRADER_BOUND = parseAbiItem('event TraderBound(address indexed trader, address indexed partner)')
const PAID = parseAbiItem('event Paid(uint32 indexed day, address indexed partner, uint256 amount)')

const usd = (v) => `${v / 1_000_000n}.${(v % 1_000_000n).toString().padStart(6, '0')}`
const dayNumber = (d) => Math.floor(Date.parse(`${d}T00:00:00Z`) / 86_400_000)
const dayString = (n) => new Date(n * 86_400_000).toISOString().slice(0, 10)

async function logsInChunks(client, params, from, to) {
  const out = []
  for (let a = from; a <= to; a += CHUNK) {
    const b = a + CHUNK - 1n < to ? a + CHUNK - 1n : to
    out.push(...await client.getLogs({ ...params, fromBlock: a, toBlock: b }))
  }
  return out
}

/** First block with timestamp >= ts (binary search). */
async function blockAt(client, ts, head) {
  let lo = 0n, hi = head.number
  if (head.timestamp < ts) return head.number + 1n
  while (lo < hi) {
    const mid = (lo + hi) / 2n
    const b = await client.getBlock({ blockNumber: mid })
    if (b.timestamp < BigInt(ts)) lo = mid + 1n
    else hi = mid
  }
  return lo
}

async function main() {
  const o = args()
  const client = createPublicClient({ chain: sepolia, transport: http(o.rpc) })
  const partner = getAddress(o.partner)
  const exchange = getAddress(o.exchange)
  const mm = new Set(o.mm.split(',').map((a) => a.trim().toLowerCase()))
  const ratePpm = BigInt(Math.round(Number(o.rate) * 1_000_000))
  const chainId = await client.getChainId()
  const domain = { name: 'Exchange', version: '1', chainId, verifyingContract: exchange }
  const orderId = (order) => hashTypedData({ domain, types: { SettlementOrderV1: ORDER }, primaryType: 'SettlementOrderV1', message: order })
  const head = await client.getBlock()

  // Traders bound to the partner, with the block of the binding
  const bound = await logsInChunks(client, { address: o.program, event: TRADER_BOUND, args: { partner } }, BigInt(o['start-block']), head.number)
  const traders = new Map(bound.map((l) => [l.args.trader.toLowerCase(), l.blockNumber]))
  console.log(`partner ${partner}: ${traders.size} bound trader(s)`)

  const txCache = new Map()
  async function decodeTx(hash) {
    if (!txCache.has(hash)) {
      const tx = await client.getTransaction({ hash })
      const { functionName, args } = decodeFunctionData({ abi: EXCHANGE_ABI, data: tx.input })
      const matches = functionName === 'matchOrders'
        ? [{ taker: args[0], makers: args[2] }]
        : args[0].map((m) => ({ taker: m.taker, makers: m.makers }))
      txCache.set(hash, matches.map((m) => ({
        taker: m.taker, takerId: orderId(m.taker),
        makers: m.makers.map((x) => ({ order: x, id: orderId(x) })),
      })))
    }
    return txCache.get(hash)
  }

  let totalAccrued = 0n
  for (let d = dayNumber(o.from); d <= dayNumber(o.to); d++) {
    const from = await blockAt(client, d * 86400, head)
    const to = (await blockAt(client, (d + 1) * 86400, head)) - 1n
    const logs = from <= to ? await logsInChunks(client, { address: exchange, event: ORDERS_MATCHED }, from, to) : []
    let volume = 0n, count = 0
    for (const log of logs) {
      const entries = await decodeTx(log.transactionHash)
      const found = entries
        .filter((e) => e.takerId === log.args.takerOrderId)
        .flatMap((e) => e.makers.filter((m) => m.id === log.args.makerOrderId).map((m) => ({ taker: e.taker, maker: m.order })))[0]
      if (!found) continue
      const trader = found.taker.maker.toLowerCase()
      const boundAt = traders.get(trader)
      if (boundAt === undefined || boundAt >= log.blockNumber) continue
      if (!mm.has(found.maker.maker.toLowerCase())) continue
      const fill = log.args.fill
      const v = found.taker.side === 0 ? fill.takerAmount : fill.takerReceiveAmount
      volume += v
      count++
      console.log(`  ${dayString(d)} ${log.transactionHash}#${log.logIndex} trader ${trader} ${found.taker.side === 0 ? 'buy ' : 'sell'} ${usd(v)} USDC`)
    }
    const accrued = volume * ratePpm / 1_000_000n
    totalAccrued += accrued
    let line = `${dayString(d)}: ${count} fill(s), volume ${usd(volume)} USDC, accrued ${usd(accrued)} USDC`
    if (o.report) {
      const res = await fetch(`${o.reports}/${dayString(d)}.json`)
      if (res.ok) {
        const r = await res.json()
        const row = r.partners.find((p) => p.partner.toLowerCase() === partner.toLowerCase())
        const reported = row ? row.accrued_usdc : '0.000000'
        line += ` | report: ${reported} ${reported === usd(accrued) ? '✓' : '✗ MISMATCH'}`
      } else {
        line += ` | report: not found (${res.status})`
      }
    }
    console.log(line)
  }

  const paid = await logsInChunks(client, { address: o.program, event: PAID, args: { partner } }, BigInt(o['start-block']), head.number)
  let totalPaid = 0n
  for (const p of paid) {
    totalPaid += p.args.amount
    console.log(`paid for ${dayString(p.args.day)}: ${usd(p.args.amount)} USDC  tx ${p.transactionHash}`)
  }
  console.log(`\naccrued in range: ${usd(totalAccrued)} USDC; paid all time: ${usd(totalPaid)} USDC`)
  console.log('Run the range from your first bound day to yesterday: paid ≤ accrued, the difference is the balance below the $10 minimum or not paid yet.')
}

main().catch((e) => { console.error(e); process.exit(1) })
