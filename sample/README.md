---
type: Guide
title: Sample — Docker Compose + nginx
description: A self-contained, runnable demonstration of the Lightweight Chroma Proxy pattern using Docker Compose and OSS nginx, with instructions to run, verify, and adapt it.
tags: [sample, guide, docker, nginx, quickstart]
timestamp: 2026-07-03
---

# Sample — Docker Compose + nginx

A self-contained, runnable demonstration of the Lightweight Chroma Proxy pattern:
OSS nginx terminates TLS, enforces a **default-deny read-only allow-list**, gates
writes behind a bearer token, and injects Chroma's service token upstream. Chroma
itself is never exposed to the host.

This is **one worked example** — copy the `nginx/` map + location blocks into whatever
proxy you already run. See [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) for the design.

## Layout

```
sample/
├── compose.yaml                    two services on a private network:
│                                     chroma (internal-only) + proxy (127.0.0.1:8443)
├── .env.example                    tokens + ports  ->  copy to .env
├── nginx/
│   ├── nginx.conf.template         the whole pattern: TLS, allow-list, role gate, log
│   └── writer_tokens.map.example   writer token allow-list  ->  copy to writer_tokens.map
├── certs/                          generated cert.pem + key.pem land here (gitignored)
└── scripts/
    ├── gen-cert.sh                 self-signed cert w/ SAN, key mode 600
    ├── smoke-test.sh               reader/writer PASS/FAIL checks over TLS (curl)
    ├── client_poc.py               OFFICIAL chromadb client works through the proxy (write/read/deny)
    └── testupload_through_gateway.py   stdlib-only UPLOAD smoke test — push docs IN via raw v2 REST
```

## Run it

From this `sample/` directory:

```bash
# 1. Configure secrets (edit the tokens after copying)
cp .env.example .env
cp nginx/writer_tokens.map.example nginx/writer_tokens.map
#   -> set CHROMA_TOKEN + WRITER_TOKEN in .env, and make the token in
#      writer_tokens.map match WRITER_TOKEN.  Generate strong ones with:
#        openssl rand -hex 32

# 2. Generate the self-signed TLS cert (-> certs/cert.pem, certs/key.pem)
./scripts/gen-cert.sh

# 3. Bring up Chroma + proxy
docker compose up -d

# 4. Exercise reader vs writer over TLS (curl — proves the endpoints)
./scripts/smoke-test.sh

# 5. (optional) Prove the OFFICIAL chromadb client works through the proxy
pip install chromadb-client
WRITER_TOKEN=$(grep -oP 'WRITER_TOKEN=\K.*' .env) python scripts/client_poc.py
```

`client_poc.py` is the stronger proof: it drives the real `chromadb.HttpClient` (a
writer creates + adds, a reader query/get/counts, and the reader's write is denied
`403`). It also exercises `GET /api/v2/auth/identity`, which the client calls on
connect — a route that MUST be in the read allow-list or a reader client can't even
initialise (see `../docs/ARCHITECTURE.md` → *Proof of concept*).

Where `client_poc.py` needs `chromadb-client`, `testupload_through_gateway.py` proves
the same **upload** path with **zero dependencies** — pure Python stdlib against the raw
Chroma v2 REST API through the proxy. It creates a collection, uploads every top-level
`*.md` in a docs dir as one document each, then reads them back (count + get by id). Run
it against **any** gateway-fronted Chroma, not just this sample:

```bash
CHROMA_WRITER_TOKEN=$(grep -oP 'WRITER_TOKEN=\K.*' .env) \
CHROMA_GATEWAY_BASE=https://127.0.0.1:8443 \
CHROMA_COLLECTION=upload_smoke \
python scripts/testupload_through_gateway.py ./docs
```

Everything is env/argv driven with documented defaults — `CHROMA_WRITER_TOKEN` (required),
`CHROMA_GATEWAY_BASE`, `CHROMA_TENANT`, `CHROMA_DATABASE`, `CHROMA_COLLECTION`,
`CHROMA_DOCS_DIR` (or `argv[1]`), and `CHROMA_TLS_VERIFY` (a CA-cert path to verify TLS,
else it skips verify like `curl -k`). See the script header for the full list.

> **Placeholder-embedding caveat:** the embedding vectors are deterministic hashes, **not**
> semantic embeddings. Upload, storage, and retrieval **by id / metadata** are real; a
> **semantic query is NOT meaningful** until you re-ingest with a real embedding function.
> Record data always enters through the client API / proxy, never by writing raw files into
> the store.

Tear down with `docker compose down -v` (the `-v` also drops the demo's data volume).

> **Windows note.** Run the scripts under WSL, macOS, or Linux. On native Git Bash, MSYS
> rewrites the `openssl -subj "/CN=..."` argument; prefix the command with
> `MSYS_NO_PATHCONV=1`, or generate the cert in a container:
> `docker run --rm -v "$PWD/certs:/certs" alpine/openssl req -x509 -newkey rsa:2048 -nodes -keyout /certs/key.pem -out /certs/cert.pem -days 3650 -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"`.

## What each piece does

| Piece | Role |
|-------|------|
| `chroma` service | ChromaDB, requires its static token (`CHROMA_SERVER_AUTHN_*`). No `ports:` — reachable only inside the `lwcp` network. |
| `proxy` service | nginx. Publishes TLS on `127.0.0.1:8443` only. Renders `nginx.conf.template` at start (envsubst injects `CHROMA_TOKEN`). |
| `map $request_method:$request_uri $is_read` | Default-deny READ allow-list. `1` only for the read routes; dynamic `{tenant}/{database}/{id}` segments are `[^/]+`. |
| `map $http_authorization $is_writer` | `1` when the bearer token matches `writer_tokens.map`. |
| `map $is_read$is_writer $allowed` | Combines both flags — allowed unless both are `0`. One `if ($allowed = 0) return 403;`. |
| `proxy_set_header Authorization "Bearer <CHROMA_TOKEN>"` | Injects Chroma's token upstream; the client's/writer's token never reaches Chroma. |
| `log_format lwcp_json` | Structured JSON access log with a `role` (reader/writer) field. |
| `server_tokens off` | **Hardening.** Removes the nginx version from the `Server` header and every error page (kills version enumeration). |
| `error_page … @eNNN` + `proxy_intercept_errors on` | **Hardening.** Uniform JSON errors (`{"status":N,"message":…}`); no nginx/backend detail in bodies. `422` passed through (client validation). |
| `proxy_hide_header Server` | **Hardening.** Strips Chroma's `uvicorn` `Server` header on proxied `200`s. |
| `limit_req_zone` / `limit_req` (`limit_req_status 429`) | **Hardening.** Per-IP + per-token rate limits; JSON `429` on breach. |

**Decision matrix:**

| Caller | Read route | Write route |
|--------|-----------|-------------|
| no token (reader) | allowed | **403** |
| valid writer token | allowed | allowed |
| invalid/absent token on write | — | **403** |

## Bring your own cert (BYO-cert)

The self-signed cert is a default, not a requirement. To use a real cert:

1. Skip `gen-cert.sh`.
2. Drop your `cert.pem` and `key.pem` (same filenames) into `sample/certs/`.
3. `docker compose restart proxy`.

That's the entire swap — nothing in `nginx.conf.template` or `compose.yaml` changes.

## Rotating / adding writers

Edit `nginx/writer_tokens.map` (one regex line per token), then
`docker compose restart proxy`. Revoking a writer = delete its line. The token is
*your* admission secret at the proxy; Chroma only ever sees its own service token.

## Validate the nginx config without running the stack

```bash
docker run --rm \
  -e CHROMA_TOKEN=x \
  -e NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx \
  -e NGINX_ENVSUBST_FILTER=CHROMA \
  -v "$PWD/nginx/nginx.conf.template:/etc/nginx/templates/nginx.conf.template:ro" \
  -v "$PWD/nginx/writer_tokens.map.example:/etc/nginx/writer_tokens.map:ro" \
  nginx:1.27 sh -c '/docker-entrypoint.sh nginx -t'
```
