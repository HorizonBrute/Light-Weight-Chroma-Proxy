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

## Status

Design complete; the endpoint allow-list is pinned. Sample reverse-proxy config + runnable demo in progress.

```
lightweight-chroma-proxy/
├── README.md              ← you are here
├── docs/
│   └── ARCHITECTURE.md    ← design, endpoint allow-list, threat model, tiers, cert model
└── sample/                ← (coming) ONE worked example: docker compose + nginx config
    ├── nginx/             ← the allow-list, TLS, role gating — copy these rules anywhere
    ├── compose.yaml       ← proxy + Chroma, runnable demo
    └── scripts/           ← self-signed cert generation, BYO-cert swap
```
