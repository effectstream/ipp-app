# IPP

IPP is a location-based, on-chain-verifiable clinical-records app for Chilean
doctors and medical staff (Spanish UI). It is built as a **prototype /
demonstrator** of a reusable template - GPS + AR on iOS (location-based AR at
capture, plus a camera-based ARKit/RealityKit scene), backed by a Bun service on
Neon Postgres, with each record's hash anchored to
**Cardano** (through the **EffectStream** packages) so the data
can be cryptographically verified later.

The app pairs **GPS** (where each patient lives) with **location-based AR**
(live population context augmenting what the clinician sees as they work),
**camera-based AR** (an ARKit/RealityKit scene that anchors a podium to the real
world and renders the geolocated records as a living data map on the floor -
see [Tiro al Trofeo](#tiro-al-trofeo---camera-based-ar-mini-game)) and a
**gamified** contribution layer that makes the dataset grow.

## What this is

- **An iOS app** (SwiftUI) for capturing a ~70-question women's-health intake
  form across four sections, plus a camera-based AR mini-game on the
  leaderboard (ARKit/RealityKit).
- **A web dashboard** (Vite + React + Leaflet) for population maps, filters,
  feedback, and on-chain verification - also embedded inside the iOS app.
- **A Bun + Fastify backend** on Neon Postgres, with a swappable chain adapter.
- **A reusable template**: the form is schema-driven, the chain is one
  interface, and the anchor pattern is generic - so the same shape powers any
  "private data, publicly verifiable" location app.

## Why GPS + location-based AR

GPS is the backbone: every patient has an address that geocodes to a
latitude/longitude. That location unlocks **augmented reality anchored to
place** - augmenting what the clinician sees about the physical world in front
of them, in three places:

1. **At capture.** As you enter a value, the field shows the population context
   for it - the **local** (the patient's own locality), **país** (country), and
   **mundo** (world) average or share. You see, in the moment, how this patient
   compares to their neighbours and to everyone.
2. **On the map.** Doctors draw **notes and named areas** over the filtered
   population layer, turning patterns into plans - e.g. *"many patients in this
   zone need X, assign a specialist and schedule exams here."*
3. **Through the camera.** The
   [Tiro al Trofeo](#tiro-al-trofeo---camera-based-ar-mini-game) scene uses
   ARKit/RealityKit world tracking to anchor a virtual podium onto the real
   surface in front of the user and projects the anonymized record locations as
   a living data map on the actual floor around it.

> The first two are **location-based AR** - the augmentation is anchored to
> physical place through GPS rather than to a camera feed, and the reality being
> augmented is the clinician's view of the patient and population in front of
> them, keyed to where the patient actually lives. The third is **camera-based
> AR** consuming the same GPS data through the phone's camera.

**Why we prioritized it:** women's-health and pelvic-floor risk cluster
geographically. Location-aware context at the point of capture (and on the map)
turns a plain intake form into a population-health instrument: spot clusters,
size the radius of affectation, and act locally.

## New use-cases this enables

- **Location-aware data entry** - contextual local/país/mundo benchmarks while
  filling each field.
- **Map-driven intervention planning** - annotate zones and assign specialists /
  exams where the data shows need.
- **Population studies** - filter a cohort by medical stats (not by name),
  measure a radius of affectation in km, export the anonymized cohort to CSV.
- **Verifiable multi-site studies** - publish a study whose dataset anyone can
  validate against a single on-chain root, without exposing any record.

## Repository layout

```
.
├── backend/                      # Bun + Fastify API on Neon Postgres
│   ├── src/
│   │   ├── server.ts             # patient CRUD, map/field stats, feedback, leaderboard, anchor + verify
│   │   ├── db.ts                 # postgres connection + schema bootstrap + passcode RNG
│   │   ├── auth.ts               # signed-request (ed25519) verification + doctors table
│   │   ├── merkle.ts             # study Merkle root (set commitment)
│   │   ├── clinical-schema.ts    # default form schema (questions + tabs)
│   │   └── adapters/
│   │       ├── local.ts          # no-op chain adapter (default)
│   │       └── cardano.ts        # Cardano anchoring - Lucid → Yaci tx metadata
│   └── scripts/                  # seed + canonical-hash verification utilities
├── ios/IPP/                      # SwiftUI app
│   ├── Models/                   # Patient, FormSchema, FieldStats, ...
│   ├── Services/                 # APIPatientStore, SessionService, Wallet, SchemaService, AppEnvironment
│   ├── Components/               # AddressPicker (CoreLocation), MultiSelectAutocomplete
│   ├── Game/                     # Tiro al Trofeo - ARKit/RealityKit podium mini-game
│   └── Views/                    # Home, DynamicForm (StatCaption), Leaderboard, WebDashboard, Theme
├── ios/IPPTests/                 # unit tests - game logic, geometry, backend locator (no backend needed)
├── web/src/                      # Vite + React dashboard
│   └── components/               # MapView, MapFilters, AnnotationsLayer, DrawingController, Feedback, PinVerify
└── cardano/                      # EffectStream workspace - local Cardano devnet + sync
```

## How it's integrated

### GPS / location

- iOS `AddressPicker` ([ios/IPP/Components/AddressPicker.swift](ios/IPP/Components/AddressPicker.swift))
  uses `CoreLocation` to geocode a Chilean address into `latitude`/`longitude`,
  stored on the `direccion` answer.
- The web map ([web/src/components/MapView.tsx](web/src/components/MapView.tsx))
  renders an anonymized population heat layer with **Leaflet + OpenStreetMap**
  (no API key), a **distance radius in km**, and schema-derived **filters**
  ([web/src/components/MapFilters.tsx](web/src/components/MapFilters.tsx)) so a
  study is built on medical stats, never on names.

### Location-based AR - at capture

`GET /api/v1/field-stats` aggregates each field across three scopes by haversine
distance from the patient (local / país / mundo); the iOS form renders them as a
discreet line under the input (`StatCaption` in
[ios/IPP/Views/DynamicFormView.swift](ios/IPP/Views/DynamicFormView.swift)) -
averages for numbers, % "sí" for booleans, the selected option's share for
pickers.

### Location-based AR - on the map

Over the filtered population layer, doctors place **notes** and draw **named
areas** ([AnnotationsLayer](web/src/components/AnnotationsLayer.tsx),
[DrawingController](web/src/components/DrawingController.tsx),
[AnnotationsList](web/src/components/AnnotationsList.tsx)) to mark interventions -
the manual planning layer that turns a cluster into "assign a specialist here."
(Again: this layer is anchored through GPS, not through the camera - the one
camera-based piece in IPP is the
[Tiro al Trofeo](#tiro-al-trofeo---camera-based-ar-mini-game) mini-game.)

### Engine

The chain sync runs on the **EffectStream** packages: a primitive
streams Cardano transaction metadata and projects it into an `ipp_anchors` table
the backend reads as ordinary app state. (See [Cardano anchor](#cardano-anchor).)

## Gamification (core)

Gamification is not a side feature - it is how the dataset grows and stays
honest. Every contribution scores points, a **leaderboard** ranks the team, and
that does two things:

- **Social regulation** - participation is visible. Who is registering patients,
  filling fields thoroughly, and searching the data is on the board for the whole
  team to see.
- **Rewarding high performers** - the doctors who contribute the most are
  exactly the ones positioned to author studies and papers from the data, so the
  incentive compounds: more (and better) data → better studies → more reason to
  contribute.

Points model (see [ios/IPP/Views/LeaderboardView.swift](ios/IPP/Views/LeaderboardView.swift)
and the `/api/v1/leaderboard` query):

| Action | Points |
|--------|--------|
| Register a patient record | **+1000** |
| Each field filled | **+20** |
| Each search | **+10** |

Search actions are logged via `POST /api/v1/events`; field/record counts are
computed from the stored data. Each account also has a Cardano wallet address
shown in the app, tying the contributor to an on-chain identity.

### Tiro al Trofeo - camera-based AR mini-game

The leaderboard has a **"Jugar"** entry point that opens **Tiro al Trofeo**, a
single-player ARKit/RealityKit mini-game built around the podium the ranking
already draws in gold/silver/bronze
([ios/IPP/Game/](ios/IPP/Game/), opened from
[LeaderboardView.swift](ios/IPP/Views/LeaderboardView.swift)).

> **Video:** <https://www.youtube.com/watch?v=7qFVhvGDVyk> - a full round on
> device: place the podium → flick → make → summary.

- **Place it.** Scan a desk or the floor, tap a detected horizontal plane, and a
  procedural podium appears - three steps in the leaderboard's exact medal
  colours plus a trophy cup. No 3D asset files: everything is generated in code.
- **Play it.** Flick upward from anywhere on the screen; the ball launches from
  where your finger started, aimed where the phone points. Touching the cup
  scores **+1**, landing inside scores **+10**, and the cup hops to a different
  step after every make. Rounds are 60 s with a countdown, an end-of-round
  summary, and a **device-local** best score.
- **Watch it.** The steps slowly breathe, the top-3 places float above them as
  labels, and a field of dots on the floor around the podium maps where the
  app's records are, pulsing so it reads as live data.
- **The game awards no leaderboard points and writes nothing.** It never touches
  the ranking, never posts an event, and its only persistence is one integer in
  `UserDefaults`. The game module itself makes **zero** network requests.
- **Offline behaviour.** The one thing that is live is the floor map: the app
  layer (not the game) reads the public, anonymized `GET /api/v1/map-pins` and
  hands the game plain coordinates. With the backend up the caption reads
  **"Datos en vivo · N ubicaciones"**; with it down or unreachable the app
  substitutes a synthetic offline sample and the caption reads **"Datos de
  ejemplo · N ubicaciones"**. The game is fully playable either way.
- **Permissions.** The camera is requested the first time you open the game -
  never at app launch - and denying it shows a Spanish explanation with a
  shortcut to Ajustes. On devices without ARKit world tracking (and in the
  Simulator) the "Jugar" row is disabled with a label saying why; the rest of
  the app is unaffected.

Game logic that does not need a camera - toss physics, rounds, best score,
podium and floor-map geometry - is covered by unit tests in
[ios/IPPTests/](ios/IPPTests/) (`xcodebuild test`, see
[iOS app](#ios-app)).

## Cardano anchor

The [`cardano/`](cardano/) workspace runs a local Cardano devnet on the
EffectStream packages - yaci-devkit + Dolos + a sync node, no
smart contract, no Docker. The backend's `CardanoAdapter`
([backend/src/adapters/cardano.ts](backend/src/adapters/cardano.ts)) anchors each
hash in **Cardano transaction metadata** (label `8327`) with Lucid, submitting
through the Yaci admin API:

```
metadata 8327 = { t, k, v }
  t = "ipp" (record) | "ipp-study" (Merkle root)
  k = SHA-256(rut)   | study id
  v = SHA-256(canonical patient JSON) | study Merkle root
```

Both `k` and `v` are 32-byte hashes - no identity or medical content ever
reaches the chain. The EffectStream primitive syncs that metadata into the
`ipp_anchors` table, which the adapter reads back. Flip `CHAIN=cardano` in
`backend/.env` (with the devnet running) and the same endpoints that ran against
the no-op `local` adapter now anchor and verify on a real chain.

## On-chain verification

`GET /api/v1/verify/:rut` (and the map's "Verificar en cadena" popup) closes the
loop: it reads the anchor for `SHA-256(rut)` back from `ipp_anchors` and reports

- **chainMatch** - the chain still holds the exact hash we submitted, and
- **recordMatch** - the record *as it stands now* still hashes to the on-chain
  value (flips to `false` if the stored record was altered after anchoring).

The backend recomputes the record hash with a canonical encoder byte-for-byte
identical to the iOS `PatientHasher` (locked by a test vector in
[backend/scripts/verify-canonical.ts](backend/scripts/verify-canonical.ts)), and
the iOS app re-checks independently with its own encoder - so the doctor's device
verifies without trusting the backend.

A **study** anchors one Merkle root over a whole cohort of record hashes
(`t: "ipp-study"`, [backend/src/merkle.ts](backend/src/merkle.ts)); a third party
validates the published dataset by recomputing the root and checking it against
the single on-chain value - no records leave the database.

## Verifiable dataset export

When a doctor exports a cohort for a study or paper, the export is also a
**record**: the filtered set is anchored on Cardano and the file is stamped with
a **Verification ID**, so anyone can later prove the dataset is authentic and
unaltered - without IPP in the loop.

- **Export = anchor.** "Exportar CSV" on the map
  ([web/src/components/MapView.tsx](web/src/components/MapView.tsx)) sends the
  filtered cohort's member ids + `SHA-256(data CSV)` to `POST /api/v1/studies`.
  The backend builds a Merkle root over the members' record hashes and anchors a
  single value binding the cohort *and* the exact file:
  `anchoredValue = SHA-256(recordsRoot + exportHash)` (the two hex hashes
  concatenated). The CSV downloads with a `#`-prefixed header carrying the
  Verification ID, tx, roots and a verify URL - so the ID travels with the data.
- **Proof bundle (hash-only, publishable).** `GET /api/v1/studies/:id` returns
  record-hash **leaves + Merkle inclusion proofs + the chain pointer** - no
  patient data - so it is safe to attach to a paper. Every export is listed in
  the web **Estudios** tab with its Verification ID and a drift check.
- **Anyone verifies, trustlessly.** The public **`/verificar`** page
  ([web/src/components/VerifyStudy.tsx](web/src/components/VerifyStudy.tsx)) and a
  standalone CLI ([scripts/verify-study-bundle.ts](scripts/verify-study-bundle.ts),
  zero IPP deps) recompute the root + inclusion proofs, recompute `anchoredValue`,
  read the anchor **straight from Cardano by tx id** (Blockfrost-compatible: Dolos
  on the devnet, Blockfrost on a public net), and confirm they match - plus an
  optional check that the CSV in hand hashes to the certified file.

`GET /api/v1/verify-study/:id` complements this as the *doctor-side* drift check
(does the live database still match what was published - `datasetIntact`,
`changed`, `missing`), distinct from the public, chain-only proof.

## Reusing the template

IPP is intentionally thin; most of its surface generalizes to other location +
verifiability apps:

- **Schema-driven form** - the questionnaire is a JSON schema in Postgres,
  fetched and cached by both clients. Editing it in the web "Configurar" tab
  reshapes the iOS form on next launch, no App Store release. Any configurable
  intake (surveys, audits, field inspections) drops in here.
- **Swappable `ChainAdapter`** - `local` (no-op) and `cardano` implement one
  `submit` / `read` interface; add a chain by adding an adapter.
- **Metadata-anchor pattern** - a label plus `{ t, k, v }` is the smallest
  useful Cardano anchor for "I have private data and want to prove it hasn't
  changed." No contract required.

## Endpoints

Auth: **Public** = open read; **Doctor** = signed request (see
[Doctor authentication](#doctor-authentication)); **Signed** = patient-key
signature.

| Method | Path | Auth | Notes |
|--------|------|------|-------|
| GET    | `/health`                          | Public | `{ status, chain, storage }` |
| GET/POST/DELETE | `/api/v1/patients[/:id]`  | Doctor | CRUD; first insert mints a 6-digit passcode (returned once) |
| GET/PUT | `/api/v1/schema`                  | Public read / Doctor write | Form schema; editing reshapes both clients |
| GET    | `/api/v1/map-pins`                 | Public | Anonymized `{ id, latitude, longitude, anchorKey }` |
| GET    | `/api/v1/map-stats`                | Doctor | Signed stats dataset for the population filters |
| GET    | `/api/v1/field-stats`              | Doctor | local / país / mundo aggregates for a field (by lat/lng) |
| GET/POST | `/api/v1/feedback`               | Doctor | Team feedback log (anonymous option) |
| POST   | `/api/v1/events`                   | Doctor | Log a search (ranking points) |
| GET    | `/api/v1/leaderboard`              | Public | Points ranking |
| POST   | `/api/v1/lookup`                   | Public | `{ rut, passcode }` → full row (rate-limited) |
| POST   | `/api/v1/patient-hash`             | Signed | Anchor a record hash |
| GET    | `/api/v1/patient-hash/:patientId`  | Public | List anchors for a patient |
| GET    | `/api/v1/onchain/:key`             | Public | Read the on-chain value for an anchor key |
| GET    | `/api/v1/verify/:rut`              | Public | chainMatch + recordMatch for a record |
| POST   | `/api/v1/studies`                  | Doctor | Publish/export a cohort: anchors its Merkle root (+ export hash) |
| GET    | `/api/v1/studies`                  | Doctor | List published studies / exports |
| GET    | `/api/v1/studies/:id`              | Public | Hash-only proof bundle (leaves + inclusion proofs) |
| GET    | `/api/v1/verify-study/:id`         | Public | Doctor-side drift check vs the live dataset |

## Data flow

```
┌──────────────────┐                          ┌────────────────────────┐
│ IPP iPhone app   │  POST /patients          │ Backend (Bun/Fastify)  │     ┌──────────────┐
│ (SwiftUI)        │ ───────────────────────▶ │  patients (JSONB)      │ ◀──▶│ Neon Postgres│
│  AddressPicker   │  GET  /field-stats       │  feedback / events     │     └──────────────┘
│  (CoreLocation)  │ ◀─────────────────────── │  studies               │
│  DynamicForm     │  POST /patient-hash      │  ChainAdapter          │
│  + StatCaption   │ ───────────────────────▶ │   local │ cardano      │ ──┐  anchor (label 8327)
└──────────────────┘                          └────────────────────────┘   │
        ▲ embeds                                          ▲                 ▼
┌──────────────────┐  map-pins / map-stats               │        ┌────────────────────┐
│ Web dashboard    │ ──────────────────────────────────▶ │        │ Cardano devnet     │
│ Map + filters    │                                      │ read   │ (yaci + Dolos)     │
│ Annotations      │  GET /verify · /onchain  ◀───────────┴────────│ EffectStream sync  │
│ Feedback         │                                   ipp_anchors │ → ipp_anchors      │
└──────────────────┘                                               └────────────────────┘
```

## Running it

### Backend

```bash
cd backend
cp .env.example .env        # set DATABASE_URL (Neon); CHAIN=local or cardano
bun install
bun run dev                 # http://localhost:3334
curl http://localhost:3334/health
# {"status":"ok","chain":"local","storage":"postgres"}
```

Schema is created on startup (idempotent `CREATE TABLE IF NOT EXISTS`).

#### Running against a local Postgres instead of Neon

The backend targets Neon, and three things bite if you point it at a local
database instead. None of them is fixed in code (a fix would touch the
production path); they are written down here so the next person does not
rediscover them:

- **Postgres must serve TLS.** [backend/src/db.ts](backend/src/db.ts) passes
  `ssl: "require"` as a postgres.js *client option*, which overrides any
  `sslmode` in `DATABASE_URL`; unlike `prefer`, `require` never falls back to
  plaintext, so a stock `docker run postgres:16` fails the handshake. A
  self-signed certificate is enough (`require` does not verify the chain):
  generate `server.crt`/`server.key`, copy them into the container's `PGDATA`
  (owner `postgres`, key mode `600`), `ALTER SYSTEM SET ssl = on`, and restart
  the container.
- **`scripts/seed-cities.ts` no longer works.** It POSTs `/api/v1/patients`
  with only a `Content-Type` header, but that route is behind `requireDoctor`
  and every row comes back `401 missing auth headers`. The script predates the
  signed-request auth ([backend/src/auth.ts](backend/src/auth.ts)).
- **`scripts/seed-year.ts` needs a column the schema no longer creates.** Its
  INSERT still lists the legacy plaintext `passcode`, while `initSchema` now
  creates only `passcode_hash`. One
  `ALTER TABLE patients ADD COLUMN IF NOT EXISTS passcode TEXT` before seeding
  makes it run; it writes straight to Postgres, so it needs no auth and is the
  richer data set anyway.

### Cardano devnet (for `CHAIN=cardano`)

```bash
cd cardano
bun install                 # one-time (links the EffectStream packages)
bun run dev                 # yaci-devkit + Dolos + pglite + sync node (no Docker)
```

Then set `CHAIN=cardano` in `backend/.env` and restart the backend.

### Web app

```bash
cd web
bun install                 # one-time
bun run dev                 # http://localhost:5174
```

Backend URL defaults to `http://localhost:3334` (override with `VITE_BACKEND_URL`).

### iOS app

```bash
brew install xcodegen       # one-time
cd ios
xcodegen generate
open IPP.xcodeproj           # pick an iPhone simulator, ⌘R

# unit tests (no backend needed - every suite is offline and deterministic)
xcodebuild test -scheme IPP -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The app talks to `http://localhost:3334` and embeds the web dashboard at
`http://localhost:5174` (both set via `Info.plist`: `BackendURL`, `WebURL`).
Demo logins: `user01`…`user10` / `pass01`…`pass10`.

**Finding the backend from a real iPhone.** `localhost` is the phone itself, so
a device build cannot use `BackendURL` as-is. At launch the app asks each host
in the `Info.plist` array **`BackendCandidates`** for `/health` (1.5 s each, in
order) and points every client - login, patients, field stats, schema,
leaderboard, map pins - at the first one that answers, falling back to
`BackendURL` if none does
([ios/IPP/Services/BackendLocator.swift](ios/IPP/Services/BackendLocator.swift)).
To run against your own Mac, put its LAN address in that array - a plist edit,
no Swift change. In the Simulator the list is skipped and `BackendURL` is used
directly. Requests wait for that resolution, so nothing can leave with a
half-resolved URL; when nothing is reachable the first request pays the probe
timeout once and then the app behaves offline as before.

## Doctor authentication

Doctor-scope endpoints require a **signed request**: the client signs
`${METHOD}|${path}|${timestamp}|${SHA-256(body)}` with an ed25519 key derived
deterministically from the account seed, sending `X-IPP-PubKey` /
`X-IPP-Timestamp` / `X-IPP-Signature` / `X-IPP-Username`. The backend
([backend/src/auth.ts](backend/src/auth.ts)) verifies the signature, checks a
5-minute clock skew, and resolves the key against a `doctors` table
(trust-on-first-use). iOS (CryptoKit) and web (`@noble/ed25519`) derive the
**same** key from the same seed, so a doctor has one identity across both.

## Demo - video & screenshots

> **Camera-AR demo (published):** <https://www.youtube.com/watch?v=7qFVhvGDVyk> -
> a single on-device take: leaderboard → Jugar → plane detection → podium
> anchored on the real table → floor data map → physics toss gameplay.
>
> A screen recording of the end-to-end clinical flow (capture → location-based AR stats → save →
> on-chain verify → population map → gamified leaderboard) and screenshots will
> be added here / in the [EffectStream blog post](https://effectstream.github.io/docs/blog/ipp-clinical-records-cardano).

## Community write-up

The [EffectStream blog post](https://effectstream.github.io/docs/blog/ipp-clinical-records-cardano)
is the long-form write-up of the engineering and use-cases.

## Roadmap

- **Default-trustless web verify** - the standalone CLI and `/verificar` already
  read the anchor directly from Cardano by tx id; make that the web page's
  default (needs a CORS-enabled explorer) so even the browser never trusts IPP.
- **Real signup** - replace the fixed demo-account seeds with per-device keys in
  the iOS Keychain.

## What's intentionally not done

- **The clinical AR is location-based, not camera-based.** Everything that
  augments the *work* - the local/país/mundo stat lines and the map planning
  layer - is anchored to place through GPS, not to a camera feed. The only
  camera-based AR in IPP is the [Tiro al Trofeo](#tiro-al-trofeo---camera-based-ar-mini-game)
  mini-game on the leaderboard, which is a game and nothing else: it reads no
  clinical record, awards no points and writes nothing.
- **Demo accounts ship fixed seeds** - fine for a demo, but a real deployment
  needs per-user generated keys (see Roadmap).
- **No smart-contract token mint** - the chain layer is metadata anchoring only.

## Developer guide

IPP is a template; here is how to adapt and extend it. (To just run all four
pieces, see [Running it](#running-it).)

### Edit the form (no app release needed)

The questionnaire is a JSON schema stored in the `form_schema` table (seeded from
[backend/src/schema-defaults.ts](backend/src/schema-defaults.ts)). Edit it live in
the web **Configurar** tab (signed `PUT /api/v1/schema`); both clients fetch it on
next launch, so you can add / remove / reorder / relabel questions with no app
release. Each question carries `id, label, type, tab, order, options?,
placeholder?, hidden?, dependsOn?/dependsOnValue?, filterable?` (see
[ios/IPP/Models/FormSchema.swift](ios/IPP/Models/FormSchema.swift)).

### Add a question type

Extend the `QuestionType` enum and add a renderer row in
[ios/IPP/Views/DynamicFormView.swift](ios/IPP/Views/DynamicFormView.swift) plus
the matching web input. Numeric / boolean / picker types already drive the
location-based AR stat line under each field.

### Swap or add a chain

Implement `submit(ctx)` / `read(keyHex)` (the `ChainAdapter` interface) in
`backend/src/adapters/<name>.ts`, register it in `pickAdapter`
([backend/src/server.ts](backend/src/server.ts)), and set `CHAIN=<name>`.
`local` ([adapters/local.ts](backend/src/adapters/local.ts)) is the no-op default;
`cardano` ([adapters/cardano.ts](backend/src/adapters/cardano.ts)) anchors in tx
metadata. To target a real network, point `CARDANO_*` at Blockfrost
preprod/mainnet + a funded wallet seed instead of the local devnet.

### Keep the canonical hash byte-identical

The anchored value is `SHA-256` of the record's **canonical JSON** (sorted keys,
passcode excluded). iOS (`PatientHasher`, CryptoKit) and TS
([backend/src/canonical.ts](backend/src/canonical.ts)) must agree byte-for-byte -
that parity is what lets the device verify independently of the backend, and it
is locked by a test vector. If you change the encoding, update **both** encoders
and re-run [backend/scripts/verify-canonical.ts](backend/scripts/verify-canonical.ts).

### Where state lives

- **Neon** - the mutable source of truth (patients + app tables).
- **`ipp_anchors`** (cardano pglite) - an immutable read-model synced from chain;
  the verification path reads here.
- **Cardano** - the root of trust; every proof reduces to the on-chain hash.

### Adapt to another vertical

Swap the schema (surveys, audits, field inspections) and keep the rest - the GPS
map + filters, location-based AR stats, gamified contribution, and the
metadata-anchor + verify pipeline are all schema-agnostic.
