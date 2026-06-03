# TechniDox Sample App

An end-to-end sample that proves a **real user can sign in and use the live
TechniDox backend** (`dev-api.technidox.dev`) — Aortem's documentation trust,
compliance, and release-readiness platform. It exercises TechniDox against its
deployed contracts, not mocks, so regressions show up immediately.

It is a sibling of the
[DartStream](https://github.com/brian-chebon/dartstream-sample-app) and
[DartCodeAI](https://github.com/brian-chebon/dartcodeai-sample-app) sample apps
and follows the same playbook: headless `PASS/FAIL/SKIP` deep-dive harnesses per
surface, plus a Flutter web client with one screen per feature.

> **Status:** in progress. The smoke CLI (`bin/smoke.dart`) and the first
> per-surface deep-dive (`bin/auth_deepdive.dart`) are in place; remaining
> per-surface deep-dives and the Flutter client are next.

---

## How auth works

TechniDox authenticates **users** via Firebase and verifies the ID token
server-side — the same model as the DartStream sample (and unlike DartCodeAI,
which is product-to-product with a Bearer API key):

```
email + password ─▶ Firebase Identity Toolkit (REST) ─▶ idToken
idToken ─▶ Authorization: Bearer <idToken> + X-Tenant-ID ─▶ TechniDox API
```

- Firebase project: **`technidox-prod`** (web API key injected at runtime, never
  committed).
- The unauthenticated `/health` check always runs; without `FIREBASE_API_KEY`
  every authenticated step is **SKIPPED** (not failed).
- TechniDox may consume DartCodeAI internally (licensing, entitlements, AI
  gateway), but customers experience TechniDox as its own product — this sample
  only talks to the TechniDox API.

---

## Surfaces under test

| Surface | What it does |
| --- | --- |
| **auth / users** | signup / login (Firebase), `/me`, team, invitations, avatar |
| **technidox** | the documentation product: dashboard stats, doc sources & inventory, Doc Health Score, drift detection, release gates, compliance reports, audit snapshots |
| **projects** | project create / list / default |
| **billing** | checkout, portal, subscription |

(Phase 1 product scope: GitHub Actions doc gate, Doc Health Score, drift
detection, PR feedback, release-readiness report, control-room dashboards.)

---

## Configuration & secrets

```sh
cp .env.example .env
# set FIREBASE_API_KEY (technidox-prod web app) + a test email/password
set -a && source .env && set +a
```

| Variable | Purpose |
| --- | --- |
| `TECHNIDOX_API_BASE_URL` | API host (dev default; prod `https://api.technidox.dev`) |
| `FIREBASE_API_KEY` | `technidox-prod` web API key (blank → authed steps SKIP) |
| `TEST_EMAIL` / `TEST_PASSWORD` | credentials the harness signs up / in with |
| `TECHNIDOX_TENANT_ID` | tenant scoping override (`x-tenant-id`) |

The real values live only in your gitignored `.env`; the tracked `.env.example`
carries placeholders only.

---

## Running the harnesses

```sh
cp .env.example .env            # optional: fill FIREBASE_API_KEY + test creds
set -a && source .env && set +a
dart pub get
dart run bin/smoke.dart            # one endpoint per surface
dart run bin/auth_deepdive.dart    # deep on the auth/users surface
```

- **`bin/smoke.dart`** — `/health` (unauth) + one authed probe per surface:
  `/api/v1/auth/login`, `/api/v1/me`, `/api/v1/technidox/dashboard/stats`,
  `/api/v1/billing/subscription`.
- **`bin/auth_deepdive.dart`** — `/health` + the full auth/users surface:
  login, `/me` (get + update), `/me/tenant`, roles, team members, users,
  pending invites, the avatar lifecycle (set / view / remove), and logout.

Both authenticate via Firebase Identity Toolkit first (like the DartStream
sample). Without `FIREBASE_API_KEY` + test creds, `/health` still PASSes and the
authed steps SKIP — so a keyless run confirms connectivity. (Confirmed live:
`/health` → 200.)

---

## License

MIT © 2026 Brian Chebon
