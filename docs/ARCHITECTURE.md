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

## TLS / certificate model

- **Self-signed by default**, generated at install with a correct SAN, private key permission-locked to the proxy identity.
- **Bring your own cert = overwrite the cert files** at the exposed path (tooling provided in the sample). Anyone who wants a real chain of trust supplies a cert from their own CA/service.
- **No CA is run.** A local CA was rejected as more infrastructure than the problem warrants.
- Internal proxy→Chroma hop can stay plain HTTP when both sit in one trust domain (same host/box); TLS is for the edge where data leaves it.

## Logging

Structured (JSON) access log at the proxy — the single choke point, so it doubles as the front-door audit trail even when no auth is enforced: source, timestamp, method, path, role (reader/writer), status, bytes. Rotate on a configurable schedule (default 30 days) so it never fills the host. Aggregation to a SIEM is left to the deployer.

## Threat model & ceiling

**Protects against:** plaintext exposure on the wire (TLS); unauthenticated or read-only clients performing writes/deletes/`reset` (admission control + default-deny); direct database exposure (Chroma is never published — only the proxy is).

**Ceiling (by design):** this is not per-user identity. It is two roles keyed on one write credential. When you need per-user tokens with **expiry, scopes, or lifecycle**, graduate to a real authorization layer (a Chroma authz provider, Envoy RBAC, OpenFGA, or a full API gateway). This project is the pragmatic tier *below* that — and names exactly where the line is.

## Reference implementation (sample)

The included Docker Compose + nginx config is a **self-contained, runnable demonstration**: it stands up Chroma + the proxy, generates a self-signed cert, enforces the allow-list above, and exercises reader vs writer. Treat it as a worked example to copy the config blocks from — not as the required deployment shape.
