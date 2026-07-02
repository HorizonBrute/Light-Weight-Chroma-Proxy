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
    └── smoke-test.sh               reader/writer PASS/FAIL checks over TLS
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

# 4. Exercise reader vs writer over TLS
./scripts/smoke-test.sh
```

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
