# IPP backend

Bun + Fastify HTTP service backing the IPP iOS app and the web dashboard.
Stores patients in Neon Postgres; anchors signed record hashes via a swappable
`ChainAdapter`. See the top-level [README](../README.md) for the architecture
and the full endpoint list.

## Environment

| Variable          | Default                | Notes                                                |
|-------------------|------------------------|------------------------------------------------------|
| `DATABASE_URL`    | _(required)_           | Postgres connection string. Neon requires `sslmode=require`. |
| `PASSCODE_SECRET` | _(required)_           | HMAC key for patient passcodes. Must stay stable across restarts (changing it invalidates every stored hash). |
| `PORT`            | `3334`                 |                                                      |
| `HOST`            | `0.0.0.0`              |                                                      |
| `CHAIN`           | `local`                | `local` (no-op) or `cardano` (anchors hashes in Cardano tx metadata via the EffectStream/yaci devnet - see [`../cardano/`](../cardano/)). |
| `CARDANO_*`       | _(see `.env.example`)_ | Dolos / Yaci URLs, pglite read URL, optional wallet seed (only when `CHAIN=cardano`). |

## Tables (Neon)

All created on startup via idempotent `CREATE TABLE IF NOT EXISTS` (+ additive
`ALTER ... IF NOT EXISTS`), so first run against a fresh Neon database just works.

```sql
patients (
  id UUID PRIMARY KEY,
  rut TEXT UNIQUE NOT NULL,
  passcode_hash TEXT,          -- HMAC-SHA256 of the 6-digit passcode, NEVER plaintext
  schema_version INT,          -- form-schema version this record was captured under
  doctor_name TEXT,            -- who first registered the patient (set once, not overwritten)
  latitude DOUBLE PRECISION,
  longitude DOUBLE PRECISION,
  data JSONB NOT NULL,         -- full Patient record from the client
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
)

anchored_hashes (              -- append-only log of signed hash submissions
  id BIGSERIAL PRIMARY KEY, patient_id UUID NOT NULL, hash TEXT NOT NULL,
  public_key TEXT NOT NULL, signature TEXT NOT NULL, client_timestamp BIGINT NOT NULL,
  received_at TIMESTAMPTZ DEFAULT NOW(), chain_tx_id TEXT, chain_name TEXT NOT NULL
)
```

Plus:

- **`doctors`** - binds a username to the ed25519 public key that authorizes
  doctor-scope endpoints (trust-on-first-use registration).
- **`studies`** - a published snapshot whose Merkle root (over the included
  record hashes) is anchored on chain, so a dataset can be validated against the
  root without the records going on chain.
- **`doctor_events`** - append-only log of point-scoring actions (searches);
  patient/field points are derived from `patients`.
- **`feedback`** - free-text team notes; `sender` is the authenticated username
  (NULL when sent anonymously).
- **`form_schema`** - singleton (`id = 1`) holding the current form schema; the
  single source of truth both clients read, seeded from `schema-defaults.ts`.

> The synced on-chain anchors table (`ipp_anchors`) lives in the **cardano
> workspace's pglite**, not Neon - the backend reads it through the
> `CardanoAdapter`. See [`../cardano/README.md`](../cardano/README.md).

## Passcodes

On first insert the backend generates a 6-digit numeric passcode, stores only
its **HMAC-SHA256** (`PASSCODE_SECRET`), and returns the plaintext exactly
**once** in the create response. `/api/v1/lookup` compares a candidate against
the stored hash in constant time and is rate-limited per rut+IP.

## Endpoint contracts

See the [main README](../README.md#endpoints) for the full list and auth model.
