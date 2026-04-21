// Minimal @bsv/simple server wallet for x402-rack e2e tests.
//
// Wraps @bsv/simple's ServerWallet with additional BRC-100 endpoints
// that the RemoteWallet adapter needs (getPublicKey, internalizeAction).
//
// Environment variables:
//   SERVER_PRIVATE_KEY — hex private key for the wallet (required)
//   WALLET_PORT        — HTTP port (default 9494)
//
// Endpoints:
//   GET  /api/server-wallet?action=create          — identity key
//   GET  /api/server-wallet?action=getPublicKey     — BRC-42 key derivation
//   GET  /api/server-wallet?action=request          — BRC-29 payment request
//   GET  /api/server-wallet?action=balance          — spendable balance
//   GET  /api/server-wallet?action=outputs          — list outputs
//   POST /api/server-wallet?action=receive          — internalize payment
//   GET  /health                                    — health check
//
// Usage:
//   SERVER_PRIVATE_KEY=<hex> node wallet-server.mjs

import http from 'node:http'
import { URL } from 'node:url'
import { ServerWallet, createServerWalletHandler } from '@bsv/simple/server'

const port = parseInt(process.env.WALLET_PORT || '9494', 10)

if (!process.env.SERVER_PRIVATE_KEY) {
  console.error('SERVER_PRIVATE_KEY is required')
  process.exit(1)
}

// Create the wallet instance for direct API access
const wallet = await ServerWallet.create({
  privateKey: process.env.SERVER_PRIVATE_KEY,
  network: 'test'
})
const client = wallet.getClient()

// Also create the handler for standard @bsv/simple endpoints
const handler = createServerWalletHandler({
  envVar: 'SERVER_PRIVATE_KEY',
  network: 'test'
})

// JSON response helper
function jsonResponse (res, status, data) {
  res.writeHead(status, { 'Content-Type': 'application/json' })
  res.end(JSON.stringify(data))
}

// Custom handler for getPublicKey — exposes BRC-42 derivation
async function handleGetPublicKey (url, res) {
  const identityKey = url.searchParams.get('identityKey') === 'true'

  if (identityKey) {
    const result = await client.getPublicKey({ identityKey: true })
    return jsonResponse(res, 200, result)
  }

  const protocolIdStr = url.searchParams.get('protocolId')
  const keyId = url.searchParams.get('keyId')

  if (!protocolIdStr || !keyId) {
    return jsonResponse(res, 400, { error: 'protocolId and keyId are required' })
  }

  // Parse protocolId from "2,3241645161d8" format
  const parts = protocolIdStr.split(',')
  const protocolID = [parseInt(parts[0], 10), parts[1]]

  const counterparty = url.searchParams.get('counterparty') || undefined
  const forSelf = url.searchParams.get('forSelf') !== 'false'

  const result = await client.getPublicKey({
    protocolID,
    keyID: keyId,
    counterparty,
    forSelf
  })

  return jsonResponse(res, 200, result)
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${port}`)

  if (url.pathname === '/api/server-wallet') {
    const action = url.searchParams.get('action')

    // Custom getPublicKey action (not in @bsv/simple handler)
    if (req.method === 'GET' && action === 'getPublicKey') {
      try {
        return await handleGetPublicKey(url, res)
      } catch (err) {
        console.error('getPublicKey error:', err.message)
        return jsonResponse(res, 500, { error: err.message })
      }
    }

    // Custom receive action — passes BEEF bytes through to internalizeAction.
    // The client is expected to send BEEF (BRC-62) in the tx field.
    if (req.method === 'POST' && action === 'receive') {
      try {
        let body = ''
        for await (const chunk of req) body += chunk
        const payment = JSON.parse(body)

        await client.internalizeAction({
          tx: payment.tx,
          outputs: [{
            outputIndex: payment.outputIndex ?? 0,
            protocol: 'wallet payment',
            paymentRemittance: {
              senderIdentityKey: payment.senderIdentityKey,
              derivationPrefix: payment.derivationPrefix,
              derivationSuffix: payment.derivationSuffix
            }
          }],
          description: payment.description || 'PayGateway payment'
        })
        return jsonResponse(res, 200, { success: true })
      } catch (err) {
        console.error('receive error:', err.message)
        return jsonResponse(res, 500, { success: false, error: `receive failed: ${err.message}` })
      }
    }

    // Sweep all spendable outputs back to a given address.
    // POST /api/server-wallet?action=sweep  body: { address: "..." }
    if (req.method === 'POST' && action === 'sweep') {
      try {
        let body = ''
        for await (const chunk of req) body += chunk
        const { address } = JSON.parse(body)
        if (!address) return jsonResponse(res, 400, { error: 'address is required' })

        // List spendable outputs to calculate total
        const { outputs } = await client.listOutputs({ basket: 'default', include: 'locking scripts' })
        const total = outputs.reduce((sum, o) => sum + o.satoshis, 0)
        if (total === 0) return jsonResponse(res, 200, { swept: 0, txid: null })

        // Leave room for fee
        const fee = 200
        const sendAmount = total - fee
        if (sendAmount <= 0) return jsonResponse(res, 200, { swept: 0, txid: null })

        // Import the SDK for Script
        const { Script } = await import('@bsv/sdk')
        const result = await client.createAction({
          description: 'Sweep funds back to test client',
          outputs: [{
            satoshis: sendAmount,
            lockingScript: Script.fromAddress(address).toHex(),
            outputDescription: 'sweep refund'
          }]
        })

        return jsonResponse(res, 200, { swept: sendAmount, txid: result.txid })
      } catch (err) {
        console.error('sweep error:', err.message)
        return jsonResponse(res, 500, { error: `sweep failed: ${err.message}` })
      }
    }

    // Delegate everything else to @bsv/simple handler
    let body = ''
    if (req.method === 'POST') {
      for await (const chunk of req) body += chunk
    }

    const fakeReq = {
      method: req.method,
      url: req.url,
      headers: req.headers,
      searchParams: url.searchParams,
      json: () => JSON.parse(body || '{}')
    }

    try {
      let result
      if (req.method === 'GET') {
        result = await handler.GET(fakeReq)
      } else if (req.method === 'POST') {
        result = await handler.POST(fakeReq)
      } else {
        res.writeHead(405)
        return res.end('Method not allowed')
      }

      const status = result.status || 200
      const responseBody = typeof result.body === 'string'
        ? result.body
        : JSON.stringify(await result.json())

      res.writeHead(status, { 'Content-Type': 'application/json' })
      res.end(responseBody)
    } catch (err) {
      console.error('Handler error:', err.message)
      jsonResponse(res, 500, { error: err.message })
    }
  } else if (url.pathname === '/health') {
    jsonResponse(res, 200, { status: 'ok' })
  } else {
    res.writeHead(404)
    res.end('Not found')
  }
})

server.listen(port, () => {
  console.log(`wallet-server listening on port ${port}`)
})
