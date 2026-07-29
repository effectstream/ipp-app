# IPP Cardano anchor devnet

A local Cardano devnet plus a sync node that turns IPP's on-chain anchors into a
queryable table. Built on the **EffectStream** packages and
adapted from the `cardano-delegation` template - **no smart contract, no Docker**
(yaci-devkit and Dolos run as native binaries).

The backend's `CardanoAdapter`
([../backend/src/adapters/cardano.ts](../backend/src/adapters/cardano.ts))
submits anchors here; this workspace indexes them back into `ipp_anchors`, which
the backend reads for verification.

## Quick start

```bash
cd cardano
./link.sh            # one-time: symlink the local @effectstream packages
bun install
bun run dev          # orchestrator: pglite + yaci + Dolos + sync node
```

Then point the backend at it: set `CHAIN=cardano` in `backend/.env` and restart.

## How it works

```
backend CardanoAdapter (Lucid Evolution)
  │ pay.ToAddress(self, 2 ADA).attachMetadata(8327, { t, k, v })
  ▼
YACI DevKit (:10000 admin / :3001 node)  ──submit──▶  Cardano devnet
  ▼ block produced
Dolos  (:50051 UTxO-RPC · :3000 mini-Blockfrost)
  ▼ streamed to
sync node: CardanoTransfer primitive → state machine
  │ keep only label 8327 { t:"ipp"|"ipp-study", k, v }
  ▼ INSERT
ipp_anchors  (pglite, :5432)
  ▲ read by
backend CardanoAdapter.read(key)  →  GET /api/v1/verify · /onchain
```

All state changes happen through blockchain transactions; the sync node and its
read API are read-only. The metadata payload is `{ t, k, v }` where `k =
SHA-256(rut)` (or a study id) and `v = SHA-256(canonical record)` (or a study
Merkle root) - hashes only, never patient data.

## Services & ports

| Service              | Port  | Description                              |
|----------------------|-------|------------------------------------------|
| YACI DevKit (admin)  | 10000 | Cardano devnet admin API (tx submit, faucet) |
| Cardano node         | 3001  | Devnet node                              |
| Dolos UTxO-RPC       | 50051 | Chain sync stream the primitive consumes |
| Dolos mini-Blockfrost| 3000  | Blockfrost-compatible read API (`CARDANO_DOLOS_URL`) |
| pglite               | 5432  | In-process Postgres holding `ipp_anchors` |
| EffectStream API     | 4747  | Orchestrator API (`/api/anchors`)        |
| Sync node            | 9999  | Internal sync HTTP server                |

## Project structure

```
packages/
├── node/                 # the IPP sync node
│   ├── grammar.ts         # cardano-transfer grammar
│   ├── config.dev.ts      # NTP + Cardano UTxO-RPC + CardanoTransfer primitive
│   ├── state-machine.ts   # filter label 8327 → INSERT into ipp_anchors
│   ├── api.ts             # read API over ipp_anchors (/api/anchors/:key)
│   └── main.dev.ts        # entry point
├── database/
│   └── migrations/000-init.sql   # ipp_anchors table
└── contracts-cardano/     # yaci-devkit + Dolos config (+ Lucid tx helpers)
    └── temp/alonzo-genesis2.json # required by Dolos (see gotcha below)
start.dev.ts               # orchestrator config (pglite + cardano + sync)
```

## Gotcha

Dolos needs `packages/contracts-cardano/temp/alonzo-genesis2.json` to bootstrap;
it is force-kept in `.gitignore` (the rest of `temp/` is ignored). If Dolos
fails to start with a genesis error, confirm that file is present.

## Notes

- Each devnet boot starts from genesis, so `ipp_anchors` begins empty and
  re-indexes as anchors are submitted.
- The default backend wallet is generated and faucet-funded on first anchor; set
  `CARDANO_WALLET_SEED` in `backend/.env` to pin a wallet.
- For a real network, point `CARDANO_*` at Blockfrost (preprod/mainnet) instead
  of the local Dolos/Yaci endpoints.
