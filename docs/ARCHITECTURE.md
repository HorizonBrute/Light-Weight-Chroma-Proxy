---
type: Architecture
title: Architecture & Design
description: The design of the Lightweight Chroma Proxy pattern — the reverse-proxy contract, endpoint allow-list, credential injection, access tiers, cert model, hardening, and threat model.
tags: [architecture, design, chromadb, allow-list, threat-model, hardening]
timestamp: 2026-07-03
---

# Architecture & Design

## The problem (verified against current Chroma, 2026-07)

Two gaps appear the instant you expose ChromaDB beyond `localhost`:

1. **No native TLS.** The Chroma server speaks plain HTTP. The vendor's own guidance is to terminate TLS in a reverse proxy in front of it. ([Chroma Cookbook — SSL/TLS Proxy](https://cookbook.chromadb.dev/security/ssl-proxies/))
2. **All-or-nothing auth.** Core Chroma authentication is a single static token (`Authorization: Bearer …` or `X-Chroma-Token: …`). Present it → full read *and* write *and* delete. There is no built-in read-only role; fine-grained authorization only exists via add-ons (a custom authz provider, an Envoy RBAC filter chain, or OpenFGA). ([Chroma Cookbook — Auth v1.0.x](https://cookbook.chromadb.dev/security/auth-1.0.x/))

## The pattern (proxy-agnostic)

This is **a configuration pattern, not a piece of software.** Any reverse proxy that can do the following can implement it — put it in front of Chroma and you have TLS + role-based admission control:

**Reverse-proxy contract (the only requirements):**
1. **Terminate TLS** at the edge.
2. **Route by path + method** — allow a fixed read set, deny everything else by default.
3. **Conditionally require a credential** (a bearer token / header / mTLS cert) for the write set.
4. **Inject Chroma's upstream credential** so downstream clients stay unauthenticated.
5. **Emit an access log.**

nginx, Caddy, HAProxy, Envoy, Traefik, a cloud load balancer, or an existing corporate API gateway all satisfy this. It does **not** require Docker and does **not** require nginx specifically — the provided Docker + nginx stack is a **runnable sample**, not the product. In most real deployments this lives as a few extra location/route blocks in the reverse proxy you already run in front of your web stack, pointed at your existing Chroma.

## Role-based admission control (RBAC-lite)

Two roles, decided entirely at the proxy — no Chroma authz involved:

| Role | Presents | May do |
|------|----------|--------|
| **reader** | nothing | the READ set below |
| **writer** | the write credential (bearer token) | READ set **+** WRITE set |

This deliberately delivers the common 80% — "everyone can read, only holders of the token can write" — without building or running an authorization engine. See *Ceiling* below for where it stops.

## The endpoint map (the allow-list)

ChromaDB v2 routes are scoped under
`/api/v2/tenants/{tenant}/databases/{database}/collections/{collection_id}/…`
plus a few server-level routes. Authoritative operation → class split (from the official client API and reference):

**READ (allow for reader):**

| Method | Path (suffix) | Operation |
|--------|---------------|-----------|
| GET  | `/api/v2/heartbeat` | liveness |
| GET  | `/api/v2/version` | version |
| GET  | `…/pre-flight-checks` | limits/config |
| GET  | `/api/v2/auth/identity` | caller identity — **required by the official `chromadb` client on connect** (see POC below) |
| GET  | `…/tenants/{tenant}` · `…/databases` · `…/databases/{db}` | list/get tenant & database |
| GET  | `…/collections` | list collections |
| GET  | `…/collections/{id}` | get collection |
| GET  | `…/collections/{id}/count` | count |
| POST | `…/collections/{id}/query` | nearest-neighbour search |
| POST | `…/collections/{id}/get` | fetch records (also backs `peek`) |

**WRITE / MUTATE (deny for reader; allow only for writer):**

| Method | Path (suffix) | Operation |
|--------|---------------|-----------|
| POST   | `…/collections` | create collection |
| PUT    | `…/collections/{id}` | modify collection (name/metadata) |
| DELETE | `…/collections/{id}` | delete collection |
| POST   | `…/collections/{id}/add` | add records |
| POST   | `…/collections/{id}/update` | update records |
| POST   | `…/collections/{id}/upsert` | upsert records |
| POST   | `…/collections/{id}/delete` | delete records |
| POST   | `…/collections/{id}/fork` | fork collection |
| POST   | `…/tenants` · `…/databases` | create tenant / database |
| DELETE | `…/databases/{db}` | delete database |
| POST   | `…/reset` | **wipe the entire database** (block hard) |

> **Critical implementation note.** `query`, `get`, and `count` are **reads that use `POST`** (a request body carries the query) — while `add`/`update`/`upsert`/`delete` are **writes that also use `POST`**. You therefore *cannot* separate read from write by HTTP method. Match on the **path suffix**, and **default-deny** anything unmatched. Default-deny means a route you forgot to classify is *blocked* (fails closed), never silently writable. Verify exact path patterns against the target server's own `/openapi.json` at deploy time, since minor versions drift — but the read/write *operation* split above is stable.

> **Passthrough verified (2026-07).** A real client's full connect handshake — `GET pre-flight-checks` → `version` → `heartbeat` → tenant / databases / database validation → `collections` list — passes the read allow-list end-to-end **through the proxy to Chroma** (`200` with live data: `pre-flight-checks` returned `max_batch_size`/`supports_base64_encoding`, `version` `"1.0.0"`), while `POST …/collections` (create) and any **no-token** request are denied `403`.

## Proof of concept — the official `chromadb` client end to end

The read/write split above was validated with the **real `chromadb.HttpClient`** (not just `curl`) against a hardened TLS instance:

1. A **writer**-token client created a collection and `upsert`ed a real document corpus (77 chunks of Markdown, embedded with a local model), exercising the **write** path.
2. A **reader**-token client then ran `count` → `query` (nearest-neighbour, real semantic hits) → `get`, exercising the **collection-level reads** (`{id}`, `count`, `query`, `get`) — all `200` through the proxy.
3. The reader's `upsert` was **denied `403`** — confirming role separation end to end.

**Finding that fixed the allow-list:** the official client calls **`GET /api/v2/auth/identity`** during `HttpClient()` construction (to resolve its tenant/database). That route was missing from the original read set, so a *reader* client failed to initialise (`403`) while a *writer* (allowed on any path) succeeded — a subtle asymmetry. It is now in the READ table above. **Lesson:** enumerate the allow-list against your client library's *actual* connect trace, not just the documented CRUD endpoints — clients issue identity/handshake calls you won't find in the CRUD reference. Default-deny makes this fail *closed* (safe), but it will block a legitimate reader until the handshake route is allowed.

**Run it yourself.** The sample ships this as a script: [`sample/scripts/client_poc.py`](../sample/scripts/client_poc.py) drives the real `chromadb.HttpClient` against the running sample proxy (writer creates + adds, reader `query`/`get`/`count`s, reader write denied `403`). It needs only `pip install chromadb-client` and uses a trivial built-in embedding function so there's no model to download. See [`sample/README.md`](../sample/README.md) step 5.

## Credential injection

The reader presents no secret. The proxy holds Chroma's single upstream token and attaches it to every proxied request, so "read-only, no login" is frictionless while Chroma still rejects anything that bypasses the proxy. When a writer presents the write credential, the proxy validates it at the edge and then forwards the same upstream Chroma token. Net effect: the writer credential is *your* admission secret (rotate/revoke it at the proxy); Chroma only ever sees its own service token.

## Access tiers (network × role × auth)

Compose the two roles with a network boundary; a firewall rule ships with any network-exposed tier:

| Tier | Reachable from | Roles enabled | Write credential |
|------|----------------|---------------|------------------|
| 1 | localhost only | reader + writer | none (trusted host) |
| 2 | LAN | reader only | n/a |
| 3 | LAN | reader + writer | bearer token required |
| ⚠️ | LAN | reader + writer | none — **documented dangerous** |

Localhost read-write with no token is fine (only local processes). Write-on-LAN without a token is the one to make an explicit, eyes-open choice.

## Fronting multiple services (one proxy, many upstreams)

The pattern generalizes past Chroma. The same proxy in front of Chroma can front **additional backend
services** on their own listeners, each with its **own role-based endpoint allow-list**, while sharing the
proxy's TLS material, token mechanism, hardening, and rate-limiting. The proxy becomes a **multi-service
front**, not a Chroma-only shim.

A concrete second upstream is a **model server (e.g. Ollama)** — a natural fit because it shares Chroma's
two gaps in an even sharper form:

- **No native TLS** — plain HTTP, so the edge proxy supplies HTTPS.
- **No auth at all** — Ollama ships **zero** authentication and **zero** authorization: no tokens, no
  roles, no users. *Every* endpoint (including destructive management: `pull` / `create` / `copy` /
  `push` / `delete`) is open to anyone who can reach it. (`OLLAMA_ORIGINS` is a **CORS allow-list, not
  auth**.) So the proxy doesn't merely *scope* access as with Chroma — it supplies the **entire** auth
  layer the service lacks.

**Per-service roles, same admission-control shape.** Each service defines its own two-role split as a
default-deny, path-based allow-list — the exact mechanism used for Chroma reader/writer:

| Service | "read/use" role | "write/admin" role |
|---------|-----------------|--------------------|
| Chroma  | **reader** — `heartbeat`/`version`, list/get, `query`/`get`/`count` | **writer** — reader **+** `add`/`update`/`upsert`/`delete`, create/delete collections, `reset` |
| Model server (Ollama) | **use** — all inference: `/api/embeddings`, `/api/embed`, `/api/generate`, `/api/chat`, `/api/tags`, `/api/show`, `/api/ps`, `/api/version`, and all `/v1/*` OpenAI-compatible routes | **admin** — use **+** store management: `/api/pull`, `/api/create`, `/api/copy`, `/api/push`, `DELETE /api/delete`, `/api/blobs/*` |

> **Hard rule (same as Chroma's `reset`):** the destructive **management** routes are **never** reachable
> by the read/use role — even in a bare-minimum exposure. And as with Chroma, inference and management
> both use `POST`, so the split is by **path**, default-deny (a route you forgot to classify fails
> *closed*). Pre-listing the OpenAI-compatible `/v1/*` routes in the `use` set keeps the allow-list
> scaffold-ready even before a client uses them.

**Exposure is opt-in and sealed by default.** A backend the proxy *can* front need not be *exposed*: the
default posture is **no listener** (the service stays reachable only on the internal trusted network, as
Chroma is never published directly). Turn a service's listener on deliberately. **TLS modes** per exposed
service are **`off`** (plain HTTP on the service port) or **`enforced`** (HTTPS, TLS terminated at the
proxy reusing its cert) — the same two-state edge choice, per listener.

### The authorization-filtering mechanism (the POC, generalized)

This is the core of the pattern for an **auth-free upstream**: the proxy imposes bearer-token *authorization*
that the backend has no concept of, using nothing but request inspection + default-deny maps. Ollama is the
worked example, but the mechanism is provider-agnostic — any auth-free HTTP service gets role separation the
same way. Two independent facts are derived per request, then combined:

1. **Which route class is this?** Two default-deny, path-matched maps classify the request:
   `$is_inference` = 1 for a `use` route (embeddings/generate/chat/tags/…, `/v1/*`); `$is_management` = 1
   for an `admin` route (`pull`/`create`/`copy`/`push`/`delete`/`blobs`). A path in neither stays `0/0` →
   denied. (Inference and management both `POST`, so classification is by **path**, never method.)
2. **What role does the token hold?** Two token maps — generated from the unified registry (below) — set
   `$is_use` and `$is_admin` from the presented bearer token (either may be 0).

The admission decision is a single **default-deny composite** over those four bits — allow only the
enumerated combinations, deny everything else:

| route \ token | use only | admin (or use+admin) | no/invalid token |
|---------------|----------|----------------------|------------------|
| **inference** | ✅ allow  | ✅ allow             | ❌ 403           |
| **management**| ❌ **403** | ✅ allow            | ❌ 403           |

The one load-bearing cell is **management + use-only → deny**: the destructive routes are **never** reachable
by a use token, by construction (that combination is simply absent from the allow-list, so it falls through
to the default deny). Roles are a **superset** — an admin token passes both inference and management — so
tokens are not duplicated across maps; the superset lives here in the admission table, not in the membership
lists. Switching authz strictness is just swapping this one composite map: `token-role` (the table above),
`token` (any valid token = use; management still admin-only), or `open` (inference needs no token; management
still admin-only). **The whole authorization filter is this: two path maps, two token maps, one composite —
no code, no backend change.**

**Safe-by-construction exposure.** Because an auth-free upstream is only as safe as the proxy in front of it,
the reference implementation keeps *all* of a service's proxy config (its upstream, maps, and listener) behind
a single **glob include that resolves to nothing when the service is sealed** — so a proxy fronting other
services can't be broken by (for example) a model server that isn't running, and the sealed default path is
byte-identical to not having the feature at all.

> **Two-upstream path verified end-to-end (2026-07).** The full consumer path across *both* upstreams was
> driven through the proxy on the Horizon AIOS brain gateway (its production instance, ADRs 0009/0010/0013):
> a **use** token embedded documents via Ollama (`/api/tags` → `/api/embed`, 768-dim), a **writer** token
> created a Chroma collection and added those docs, a semantic `query` returned the correct nearest neighbour,
> and the collection was deleted — all `200/201`, residue-free. Confirms the per-service role split (Ollama
> `use` + Chroma `writer`) composes cleanly through one proxy. (Note against current Chroma **1.0.0**:
> collection names must match `[a-zA-Z0-9._-]{3,512}` starting/ending alphanumeric — a bad name is a genuine
> Chroma `400`, which the proxy's `proxy_intercept_errors` then masks to a generic body.)

## Unified token registry (one source of truth → generated per-service maps)

Once the proxy fronts more than one service, "a `map` file per service per role" means the **same key gets
hand-copied into multiple files and must be kept absent from others** — error-prone and worse with every
service added. Instead, use **one authoritative token-registry file** as the single source of truth, and
**generate** the per-service role maps from it.

Each token is listed **once**, with a **per-service role grant**; a token may be granted on one service,
several, or all — each grant honored independently:

```yaml
- token: <bearer-1>
  grants: { chroma: reader, ollama: use }   # reads Chroma AND runs inference; no writes, no model mgmt
- token: <bearer-2>
  grants: { ollama: admin }                 # manages the model store; no Chroma access at all
- token: <bearer-3>
  grants: { chroma: writer }                # writes Chroma; no model access
```

Backend tooling **emits** the per-service proxy maps (Chroma `reader`/`writer`, model-server `use`/`admin`,
…) from this one file at build/apply time. The admin **edits one file**; a key is never hand-synced across
maps, and because each map is regenerated, revoking a token in the registry removes it from every map it
was in — **no orphaned keys**. Adding a future service is then just a new grant field plus the generator
emitting its map — **new services cost data, not a new hand-maintained file convention.** The registry is
the admin-editable source of truth; the generated `.map` files are runtime artifacts (never hand-edited).

## TLS / certificate model

- **Self-signed by default**, generated at install with a correct SAN, private key permission-locked to the proxy identity.
- **Bring your own cert = overwrite the cert files** at the exposed path (tooling provided in the sample). Anyone who wants a real chain of trust supplies a cert from their own CA/service.
- **No CA is run.** A local CA was rejected as more infrastructure than the problem warrants.
- Internal proxy→Chroma hop can stay plain HTTP when both sit in one trust domain (same host/box); TLS is for the edge where data leaves it.

## Logging

Structured (JSON) access log at the proxy — the single choke point, so it doubles as the front-door audit trail even when no auth is enforced: source, timestamp, method, path, role (reader/writer), status, bytes. Rotate on a configurable schedule (default 30 days) so it never fills the host. Aggregation to a SIEM is left to the deployer.

## Hardening (defense-in-depth)

The admission control above is the *functional* core; these directives make the proxy **quiet and abuse-resistant** at the edge. All are stock-nginx (no third-party modules), mode-agnostic, and included in the sample `nginx.conf.template`. They sit *outside* the five-point contract — not required to make the pattern work — but are strongly recommended for any network-exposed tier: the front door should reveal nothing about itself or what's behind it, and should absorb abuse.

- **Suppress the server banner — `server_tokens off`.** Strips the version from the `Server` header *and* every generated error page (not just `403`). Without it, a probe with any odd method reads `Server: nginx/<version>` plus the HTML error footer — free version/method-enumeration recon. (Removing the *name* `nginx` as well would need the third-party `headers_more` module; a deliberate line the stock sample does not cross — `Server: nginx` with **no version** is the pragmatic stop.)
- **Uniform JSON errors — `proxy_intercept_errors on` + `error_page … @eNNN`.** Every gateway-generated error (the `403` from the admission gate, plus `400`/`405`/`413`/`429`) and intercepted upstream error returns `{"status":N,"message":"…"}` instead of nginx's HTML — no nginx name in the body, and **backend error detail never escapes**. One deliberate exception: **`422` is *not* intercepted** — Chroma/FastAPI validation errors carry field detail a legitimate client needs.
- **Hide the backend — `proxy_hide_header Server`.** Drops Chroma's own `Server` (e.g. `uvicorn`) on proxied `200`s so the upstream stack is invisible; nginx re-stamps its own bare `Server: nginx`.
- **Rate limiting — `limit_req_zone` + `limit_req` (`429`).** Per-client-IP and per-bearer-token leaky buckets (sample: `30r/s` and `60r/s` with matching bursts), returning a JSON `429`. Blunts brute-forcing the write token and abusive read floods. Rates are literal — tune per exposure tier.
- **Intrusion banning — fail2ban companion (optional edge layer).** Rate limiting *throttles* a burst but has no memory: an IP that keeps probing the write token (repeated `403`s from the default-deny admission map, §"Role-based admission control") stays free to keep probing, just at the rate limit. The companion to the authorization filtering is to *ban* a persistent abuser: a fail2ban sidecar watches the JSON access log (§Logging — real client IP, never the token) and, after `maxretry` denials in `findtime`, bans the source IP for `bantime`, then self-heals (auto-unban). Done as a sidecar sharing the proxy container's network namespace with only `NET_ADMIN`, the ban is L3 (`iptables`), dropped *before* nginx — so the allow-list config is untouched. This is the production posture of the Horizon AIOS brain gateway (its ADR 0012); the failure signal is exactly this pattern's default-deny `403`. Correctness depends on the log showing real client IPs (not a SNAT'd container address) — verify per deployment.

## Threat model & ceiling

**Protects against:** plaintext exposure on the wire (TLS); unauthenticated or read-only clients performing writes/deletes/`reset` (admission control + default-deny); direct database exposure (Chroma is never published — only the proxy is); **server/backend fingerprinting** (version + identity suppression); **request floods / token brute-forcing** (rate limiting); and, with the fail2ban companion, a **persistent token-probing source** (banned at L3 after repeated `403`s, then self-healed).

**Ceiling (by design):** this is not per-user identity. It is two roles keyed on one write credential. When you need per-user tokens with **expiry, scopes, or lifecycle**, graduate to a real authorization layer (a Chroma authz provider, Envoy RBAC, OpenFGA, or a full API gateway). This project is the pragmatic tier *below* that — and names exactly where the line is.

## Reference implementation (sample)

The included Docker Compose + nginx config is a **self-contained, runnable demonstration**: it stands up Chroma + the proxy, generates a self-signed cert, enforces the allow-list above, and exercises reader vs writer. Treat it as a worked example to copy the config blocks from — not as the required deployment shape.
