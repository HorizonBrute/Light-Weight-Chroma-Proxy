# Lightweight Chroma Proxy

**TLS termination and role-based admission control for [ChromaDB](https://www.trychroma.com/) — as a reverse-proxy configuration pattern. No application code, no Chroma RBAC, no CA to run, and no dependency on Docker or any specific proxy.**

Chroma is a great vector database, but the moment you expose it beyond `localhost` two gaps appear:

1. **No native TLS.** The server speaks plain HTTP; the vendor's own guidance is "put a reverse proxy in front of it."
2. **All-or-nothing auth.** Chroma's core authentication is a single static token — present it and you can read *and* write *and* delete. There is no built-in "read-only" user.

Closing gap #2 *properly* means adopting an add-on authorization stack (a custom authz provider, an Envoy RBAC filter chain, or an external policy engine like OpenFGA) — real infrastructure to build, run, and maintain.

**This project closes both gaps with a handful of reverse-proxy rules.** A transparent reverse proxy sits in front of Chroma and:

- terminates **TLS** at the edge (self-signed by default; bring your own cert by overwriting one file),
- enforces **two roles by admission control** — a *reader* (no credentials, read-only) and a *writer* (bearer token, full access) — by allow-listing paths/methods,
- stays **transparent**: clients speak Chroma's native API, so *any* existing Chroma client or plugin works unmodified,
- leaves **Chroma itself untouched** — no plugins, no authz providers, no schema changes.

It's role-based admission control without the cost of real RBAC — the 80% that most self-hosted deployments actually need, at a fraction of the effort.

---

## This is a pattern, not a product

The important idea: **you almost certainly already run something that can do this.** The proxy only needs to:

1. terminate **TLS**,
2. **route by path + method** (allow a fixed read set, default-deny the rest),
3. **conditionally require a credential** (bearer token / header / mTLS) for the write set,
4. **inject Chroma's upstream token** so clients stay unauthenticated,
5. **log** requests.

Anything that meets that contract works — **nginx, Caddy, HAProxy, Envoy, Traefik, a cloud load balancer, or your existing corporate API gateway.** It does **not** require Docker, and it does **not** require nginx. In most real deployments this is just a few extra route blocks in the reverse proxy already sitting in front of your web stack, pointed at your existing Chroma.

The Docker + nginx stack in this repo is a **runnable sample** — a worked example you can copy the rules from and test against — not the prescribed deployment shape.

---

## Architecture

```
   client / plugin              reverse proxy (your choice)             Chroma
  ┌────────────────┐   HTTPS   ┌──────────────────────────┐  HTTP   ┌──────────────┐
  │ native Chroma  │──────────▶│ 1. terminate TLS         │────────▶│  :8000       │
  │ API + (token)  │◀──────────│ 2. role admission control│◀────────│  vector store│
  └────────────────┘           │ 3. inject Chroma creds   │         └──────────────┘
                               │ 4. structured access log │      (never exposed directly)
                               └──────────────────────────┘
   (nginx / Caddy / HAProxy / Envoy / cloud LB / API gateway — any of them)
```

Two roles, decided entirely at the proxy:

| Role | Presents | Allowed |
|------|----------|---------|
| **reader** | nothing | read-only: `heartbeat`, `version`, list/get collections, `query`, `get`, `count` |
| **writer** | a bearer token | everything the reader can, **plus** `add` / `update` / `upsert` / `delete`, create/delete collections, `reset` |

The read and write sets both use `POST` for some operations, so the split is enforced by **path**, and everything unlisted is **denied by default** — the proxy fails *closed*. Full endpoint map in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

---

## Why this is the right amount of engineering

- **Separation of concerns.** The proxy owns *scope* (read vs write) and *transport* (TLS). Chroma owns *identity* (the one token the proxy injects) and *storage*. Neither reimplements the other.
- **Config, not code.** Nothing to write in a programming language, nothing that tracks Chroma's client API version. The proxy only inspects method + path + one header.
- **Transparent.** Passes Chroma's native API straight through, so the official clients, LangChain/LlamaIndex integrations, and community plugins work with zero changes — they just point at the proxy URL.
- **Credential injection.** The reader needs no secret; the proxy holds Chroma's token and attaches it upstream.
- **Fails closed.** Default-deny means the posture degrades to "unavailable," never "wide open."
- **Runs anywhere.** Existing infra, a VM, bare metal, or the sample container — no runtime is mandated.

## What it deliberately is **not**

- **Not multi-user identity.** Two roles, keyed on "holds the writer token or not." When you genuinely need per-user tokens with expiry, scopes, and lifecycle, that's where a real authz layer (Chroma authz provider / Envoy RBAC / OpenFGA / a commercial API gateway) earns its keep. This is the pragmatic tier *below* that — and it documents exactly where the ceiling is.
- **Not a CA.** TLS is self-signed by default; for a real trust chain you drop in a cert from your own CA/service. Running a CA was explicitly rejected as more infrastructure than the problem warrants.

## Verified against current Chroma

Both gaps were confirmed against current Chroma docs (2026-07):

- **No native TLS** — a reverse proxy is Chroma's documented HTTPS pattern. [SSL/TLS Proxy — Chroma Cookbook](https://cookbook.chromadb.dev/security/ssl-proxies/)
- **Static-token, all-or-nothing auth** in core; RBAC only via add-ons. [Authentication in Chroma v1.0.x — Chroma Cookbook](https://cookbook.chromadb.dev/security/auth-1.0.x/)

## Quickstart

The [`sample/`](sample/) directory is a self-contained, runnable demo (Docker Compose + OSS nginx):

```bash
cd sample
cp .env.example .env                                   # set CHROMA_TOKEN + WRITER_TOKEN
cp nginx/writer_tokens.map.example nginx/writer_tokens.map
./scripts/gen-cert.sh                                   # self-signed cert -> certs/
docker compose up -d                                    # Chroma (internal) + proxy on 127.0.0.1:8443
./scripts/smoke-test.sh                                 # reader vs writer, PASS/FAIL per case
```

Copy the `sample/nginx/` map + location blocks into whatever proxy you already run — that's the deliverable. See [`sample/README.md`](sample/README.md) for details.

---

## Technical white paper — how it functions

This condenses the design; [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) is the deep dive (full endpoint table, tiers, threat model).

### The reverse-proxy contract

The pattern is proxy-agnostic. Any reverse proxy that can do these five things implements it:

1. **Terminate TLS** at the edge.
2. **Route by path + method** — allow a fixed read set, deny everything else by default.
3. **Conditionally require a credential** for the write set.
4. **Inject Chroma's upstream credential** so downstream clients stay unauthenticated.
5. **Emit an access log.**

nginx, Caddy, HAProxy, Envoy, Traefik, a cloud LB, or an existing corporate API gateway all qualify. Docker and nginx are the *sample's* choices, not requirements.

### Default-deny, path-based allow-list

Chroma's `query`, `get`, and `count` are **reads that use `POST`** (the query travels in the body), while `add` / `update` / `upsert` / `delete` are **writes that also use `POST`**. HTTP method therefore cannot separate read from write — the split is by **path suffix**. The proxy **allow-lists the read routes and denies everything else by default**, so a route you forgot to classify fails *closed* (blocked), never silently writable.

Read set (allowed for the reader): `GET /heartbeat`, `GET /version`, `GET …/pre-flight-checks`, `GET /api/v2/auth/identity` (the official client's connect handshake — see the POC note below), `GET …/tenants/{t}`, `GET …/databases(/{db})`, `GET …/collections` (list), `GET …/collections/{id}`, `GET …/collections/{id}/count`, `POST …/collections/{id}/query`, `POST …/collections/{id}/get`. Everything else — create/delete collections, `add`/`update`/`upsert`/`delete`, `fork`, tenant/database creation, and `reset` — is a write.

> **Proven with the real client.** The full pattern was validated end-to-end with the official `chromadb.HttpClient` over TLS — a writer client seeded a real corpus, a reader client `query`/`get`/`count`'d it back (real semantic hits), and the reader's write was denied `403`. This surfaced one allow-list gap: the client calls `GET /api/v2/auth/identity` on connect, which must be in the read set or a *reader* client can't even initialise. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) → *Proof of concept*.

The sample implements this with nginx `map` blocks (no stacked `if`s): `map "$request_method:$request_uri" $is_read` (regex, `[^/]+` for dynamic segments, default `0`), a writer-token `map $http_authorization $is_writer`, combined via `map $is_read$is_writer $allowed` and a single `if ($allowed = 0) { return 403; }`.

### Credential injection

The reader presents nothing. The proxy holds Chroma's single service token and attaches it to every proxied request (`proxy_set_header Authorization "Bearer <CHROMA_TOKEN>"`), so read-only access is frictionless while Chroma still rejects anything bypassing the proxy. A writer presents *your* admission token; the proxy validates it at the edge and then forwards the **same Chroma service token** upstream. Net effect: the writer token is your admission secret (rotate/revoke at the proxy) and **Chroma only ever sees its own token** — the writer's token never reaches it.

### Hardening (defense-in-depth)

Beyond the five-point contract, the sample config is hardened so the front door reveals nothing about itself or Chroma, and absorbs abuse — all **stock nginx**, no third-party modules:

- **`server_tokens off`** — strips the nginx **version** from the `Server` header *and* every error page (not just `403`), killing version/method-enumeration recon. (Removing the *name* `nginx` too would need the `headers_more` module — the deliberate stop; `Server: nginx` with no version is the pragmatic line.)
- **JSON errors** (`proxy_intercept_errors on` + `error_page … @eNNN`) — uniform `{"status":N,"message":"…"}`, so no nginx name in bodies and no upstream error detail leaks. **`422` is passed through** (Chroma validation detail a client needs).
- **`proxy_hide_header Server`** — hides Chroma's `uvicorn` banner on proxied `200`s.
- **Rate limiting** (`limit_req`, JSON `429`) — per-IP and per-token buckets blunt token brute-forcing and read floods.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) → *Hardening* for the rationale and directives.

### Roles & access tiers

| Role | Presents | Allowed |
|------|----------|---------|
| **reader** | nothing | the read set |
| **writer** | a bearer token | read set **+** all writes/deletes/`reset` |

Compose the roles with a network boundary to get tiers: (1) localhost-only read+write, no token; (2) LAN reader-only; (3) LAN reader+writer with a required bearer token; and the explicitly **documented-dangerous** LAN read+write with no token. A firewall rule ships with any network-exposed tier.

### Cert model

Self-signed by default with a correct SAN (`DNS:localhost,IP:127.0.0.1`), key permission-locked (mode `600`). **BYO-cert = overwrite `certs/cert.pem` + `certs/key.pem`** with a cert from your own CA/service. No CA is run — rejected as more infrastructure than the problem warrants. The internal proxy→Chroma hop may stay plain HTTP when both sit in one trust domain; TLS guards the edge.

### Threat model & ceiling

**Protects against:** plaintext exposure on the wire (TLS); unauthenticated or read-only clients performing writes/deletes/`reset` (admission control + default-deny); direct database exposure (Chroma is never published — only the proxy is).

**Ceiling (by design):** this is not per-user identity — it is two roles keyed on one write credential. When you need per-user tokens with **expiry, scopes, or lifecycle**, graduate to a real authorization layer (a Chroma authz provider, Envoy RBAC, OpenFGA, or a full API gateway). This project is the pragmatic tier *below* that, and names exactly where the line is.

---

## References — Chroma documentation used

The endpoint read/write split and the two verified gaps are grounded in Chroma's own docs:

- **Chroma Cookbook — Authentication (v1.0.x):** static-token, all-or-nothing auth in core; RBAC only via add-ons. https://cookbook.chromadb.dev/security/auth-1.0.x/
- **Chroma Cookbook — SSL/TLS Proxy:** a reverse proxy is Chroma's documented HTTPS pattern (no native TLS). https://cookbook.chromadb.dev/security/ssl-proxies/
- **Chroma API reference:** the v2 endpoint list used to build the allow-list. https://github.com/chroma-core/docs/blob/main/docs/api-reference.md

> Verify exact path patterns against your target server's own `/openapi.json` at deploy time — minor versions drift — but the read/write *operation* split is stable.

---

## Status

Design complete and the endpoint allow-list is pinned. The runnable sample (Docker Compose + OSS nginx) is implemented in [`sample/`](sample/).

```
lightweight-chroma-proxy/
├── README.md              ← you are here
├── docs/
│   └── ARCHITECTURE.md    ← design, endpoint allow-list, threat model, tiers, cert model
└── sample/                ← ONE worked example: docker compose + nginx config
    ├── compose.yaml       ← proxy + Chroma, runnable demo
    ├── nginx/             ← the allow-list, TLS, role gating — copy these rules anywhere
    ├── scripts/           ← self-signed cert generation + smoke test
    └── README.md          ← how to run the demo, BYO-cert note
```
