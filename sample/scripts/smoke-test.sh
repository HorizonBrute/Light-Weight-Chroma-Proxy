#!/usr/bin/env bash
# Smoke test for the Lightweight Secure Chroma Proxy sample.
#
# Exercises the read/write admission control end-to-end over TLS against the
# proxy on 127.0.0.1:8443. Prints PASS/FAIL per case; exits non-zero on any
# failure. `-k` because the demo cert is self-signed.
#
# Portable: captures body + status via `curl -w` on stdout (NO temp files), so
# it also works under Git Bash on Windows, where `curl -o <mktemp>` writes to a
# different /tmp than the shell reads. WSL/Linux/macOS still recommended.
#
# Prereq:  ./scripts/gen-cert.sh  &&  docker compose up -d   (and .env populated)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${SAMPLE_DIR}/.env" ]]; then
    set -a; . "${SAMPLE_DIR}/.env"; set +a
else
    echo "FATAL: ${SAMPLE_DIR}/.env not found (copy .env.example -> .env)"; exit 2
fi

PORT="${PROXY_TLS_PORT:-8443}"
BASE="https://127.0.0.1:${PORT}"
WRITER="${WRITER_TOKEN:?WRITER_TOKEN must be set in .env}"
TENANT="default_tenant"; DB="default_database"
CB="/api/v2/tenants/${TENANT}/databases/${DB}/collections"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# req METHOD PATH [--data DATA] [HEADER ...]  ->  sets globals CODE and BODY.
# Appends the status code on its own trailing line via -w, then splits it back
# off. No temp files => portable across shells (incl. Windows Git Bash).
CODE=""; BODY=""
req() {
    local method="$1" path="$2"; shift 2
    local data=""; local -a hdr=()
    if [[ "${1:-}" == "--data" ]]; then data="$2"; shift 2; fi
    while [[ $# -gt 0 ]]; do hdr+=(-H "$1"); shift; done
    local out
    if [[ -n "$data" ]]; then
        out=$(curl -k -s -w $'\n%{http_code}' -X "$method" \
              -H 'Content-Type: application/json' "${hdr[@]}" --data "$data" "${BASE}${path}")
    else
        out=$(curl -k -s -w $'\n%{http_code}' -X "$method" "${hdr[@]}" "${BASE}${path}")
    fi
    CODE="${out##*$'\n'}"
    BODY="${out%$'\n'*}"
}

echo "=== Lightweight Secure Chroma Proxy smoke test ( ${BASE} ) ==="

# --- wait for readiness (proxy serving + Chroma accepting connections) ------
# No compose healthcheck (the Chroma image has no in-container HTTP client), so
# poll the proxy heartbeat until it stops returning 502.
echo -n "waiting for readiness"
for i in $(seq 1 60); do
    req GET /api/v2/heartbeat
    [[ "$CODE" == "200" ]] && { echo " ready"; break; }
    echo -n "."; sleep 2
    [[ "$i" -eq 60 ]] && echo " TIMEOUT (last HTTP code: $CODE)"
done

# --- (0) reader: heartbeat -> 200 ------------------------------------------
req GET /api/v2/heartbeat
[[ "$CODE" == "200" ]] && ok "reader GET /heartbeat -> 200" || bad "reader GET /heartbeat -> $CODE (want 200)"

# --- setup: writer creates a collection ------------------------------------
# Record ops (add/get/query/count) key on the collection's UUID id; the
# collection-level DELETE keys on its NAME (a Chroma v2 quirk).
COL_NAME="lwcp_smoke_$$"
req POST "${CB}" --data "{\"name\":\"${COL_NAME}\"}" "Authorization: Bearer ${WRITER}"
[[ "$CODE" == "200" || "$CODE" == "201" ]] \
    && ok "writer POST /collections (create) -> $CODE" \
    || { bad "writer POST /collections (create) -> $CODE (want 200/201)"; echo "$BODY"; }
CID=$(printf '%s' "$BODY" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F-]\{36\}\)".*/\1/p' | head -1)
echo "    collection id=${CID:-<none>}  name=${COL_NAME}"

# --- (c) writer: add records -> success ------------------------------------
ADD='{"ids":["a","b"],"embeddings":[[0.1,0.2,0.3],[0.4,0.5,0.6]],"documents":["alpha","beta"]}'
req POST "${CB}/${CID}/add" --data "${ADD}" "Authorization: Bearer ${WRITER}"
[[ "$CODE" == "200" || "$CODE" == "201" ]] && ok "writer POST /add -> $CODE" || { bad "writer POST /add -> $CODE (want 200/201)"; echo "$BODY"; }

# --- (a) reader: query (read via POST, no token) -> 200 --------------------
req POST "${CB}/${CID}/query" --data '{"query_embeddings":[[0.1,0.2,0.3]],"n_results":1}'
[[ "$CODE" == "200" ]] && ok "reader POST /query -> 200" || { bad "reader POST /query -> $CODE (want 200)"; echo "$BODY"; }

# --- (a') reader: get (read via POST, no token) -> 200 ---------------------
req POST "${CB}/${CID}/get" --data '{"ids":["a"]}'
[[ "$CODE" == "200" ]] && ok "reader POST /get -> 200" || { bad "reader POST /get -> $CODE (want 200)"; echo "$BODY"; }

# --- reader: count (GET read, no token) -> 200 -----------------------------
req GET "${CB}/${CID}/count"
[[ "$CODE" == "200" ]] && ok "reader GET /count -> 200" || bad "reader GET /count -> $CODE (want 200)"

# --- (b) reader: add (write, no token) -> 403 ------------------------------
req POST "${CB}/${CID}/add" --data "${ADD}"
[[ "$CODE" == "403" ]] && ok "reader POST /add -> 403 (blocked)" || bad "reader POST /add -> $CODE (want 403)"

# --- reader: reset (destructive write, no token) -> 403 --------------------
req POST /api/v2/reset
[[ "$CODE" == "403" ]] && ok "reader POST /reset -> 403 (blocked)" || bad "reader POST /reset -> $CODE (want 403)"

# --- reader: delete collection (write, no token) -> 403 --------------------
# Blocked at the proxy before Chroma; identifier (name vs id) is irrelevant here.
req DELETE "${CB}/${COL_NAME}"
[[ "$CODE" == "403" ]] && ok "reader DELETE /collections -> 403 (blocked)" || bad "reader DELETE /collections -> $CODE (want 403)"

# --- cleanup: writer deletes the collection BY NAME -> 200 -----------------
req DELETE "${CB}/${COL_NAME}" "Authorization: Bearer ${WRITER}"
[[ "$CODE" == "200" || "$CODE" == "204" ]] && ok "writer DELETE /collections (cleanup) -> $CODE" || bad "writer DELETE /collections -> $CODE (want 200/204)"

echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "${FAIL}" -eq 0 ]]
