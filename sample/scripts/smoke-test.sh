#!/usr/bin/env bash
# Smoke test for the Lightweight Chroma Proxy sample.
#
# Exercises the read/write admission control end-to-end over TLS against the
# proxy on 127.0.0.1:8443. Prints PASS/FAIL per case and exits non-zero on any
# failure. `-k` because the demo cert is self-signed.
#
# Prereq:  ../scripts/gen-cert.sh  &&  docker compose up -d   (and .env populated)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- load .env -------------------------------------------------------------
if [[ -f "${SAMPLE_DIR}/.env" ]]; then
    set -a; . "${SAMPLE_DIR}/.env"; set +a
else
    echo "FATAL: ${SAMPLE_DIR}/.env not found (copy .env.example -> .env)"; exit 2
fi

PORT="${PROXY_TLS_PORT:-8443}"
BASE="https://127.0.0.1:${PORT}"
WRITER="${WRITER_TOKEN:?WRITER_TOKEN must be set in .env}"
TENANT="default_tenant"
DB="default_database"
COL_BASE="/api/v2/tenants/${TENANT}/databases/${DB}/collections"

PASS=0
FAIL=0
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# curl helper: prints the HTTP status code, discards body to a temp file we can inspect.
BODY_FILE="$(mktemp)"
trap 'rm -f "${BODY_FILE}"' EXIT
code() {  # code METHOD PATH [DATA] [AUTH_HEADER...]
    local method="$1" path="$2"; shift 2
    local data="" ; local -a hdr=()
    if [[ "${1:-}" == "--data" ]]; then data="$2"; shift 2; fi
    while [[ $# -gt 0 ]]; do hdr+=(-H "$1"); shift; done
    if [[ -n "${data}" ]]; then
        curl -k -s -o "${BODY_FILE}" -w '%{http_code}' -X "${method}" \
            -H 'Content-Type: application/json' "${hdr[@]}" --data "${data}" "${BASE}${path}"
    else
        curl -k -s -o "${BODY_FILE}" -w '%{http_code}' -X "${method}" "${hdr[@]}" "${BASE}${path}"
    fi
}

echo "=== Lightweight Chroma Proxy smoke test ( ${BASE} ) ==="

# --- (0) reader: heartbeat -------------------------------------------------
c=$(code GET /api/v2/heartbeat)
[[ "$c" == "200" ]] && ok "reader GET /heartbeat -> 200" || bad "reader GET /heartbeat -> $c (want 200)"

# --- setup: writer creates a collection to operate on ----------------------
COL_NAME="lwcp_smoke_$$"
c=$(code POST "${COL_BASE}" --data "{\"name\":\"${COL_NAME}\"}" "Authorization: Bearer ${WRITER}")
if [[ "$c" == "200" || "$c" == "201" ]]; then
    ok "writer POST /collections (create) -> $c"
else
    bad "writer POST /collections (create) -> $c (want 200/201)"
    cat "${BODY_FILE}"; echo
fi
# extract collection id (UUID) from the create response
CID="$(grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' "${BODY_FILE}" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
echo "    collection id = ${CID:-<none>}"

# --- (c) writer: add records -> success ------------------------------------
ADD='{"ids":["a","b"],"embeddings":[[0.1,0.2,0.3],[0.4,0.5,0.6]],"documents":["alpha","beta"]}'
c=$(code POST "${COL_BASE}/${CID}/add" --data "${ADD}" "Authorization: Bearer ${WRITER}")
[[ "$c" == "200" || "$c" == "201" ]] && ok "writer POST /add -> $c" || { bad "writer POST /add -> $c (want 200/201)"; cat "${BODY_FILE}"; echo; }

# --- (a) reader: query (read via POST, no token) -> success ----------------
QUERY='{"query_embeddings":[[0.1,0.2,0.3]],"n_results":1}'
c=$(code POST "${COL_BASE}/${CID}/query" --data "${QUERY}")
[[ "$c" == "200" ]] && ok "reader POST /query -> 200" || { bad "reader POST /query -> $c (want 200)"; cat "${BODY_FILE}"; echo; }

# --- (a') reader: get (read via POST, no token) -> success -----------------
c=$(code POST "${COL_BASE}/${CID}/get" --data '{"ids":["a"]}')
[[ "$c" == "200" ]] && ok "reader POST /get -> 200" || { bad "reader POST /get -> $c (want 200)"; cat "${BODY_FILE}"; echo; }

# --- reader: count (GET read) -> success -----------------------------------
c=$(code GET "${COL_BASE}/${CID}/count")
[[ "$c" == "200" ]] && ok "reader GET /count -> 200" || bad "reader GET /count -> $c (want 200)"

# --- (b) reader: add (write, no token) -> 403 ------------------------------
c=$(code POST "${COL_BASE}/${CID}/add" --data "${ADD}")
[[ "$c" == "403" ]] && ok "reader POST /add -> 403 (blocked)" || bad "reader POST /add -> $c (want 403)"

# --- reader: reset (dangerous write, no token) -> 403 ----------------------
c=$(code POST /api/v2/reset)
[[ "$c" == "403" ]] && ok "reader POST /reset -> 403 (blocked)" || bad "reader POST /reset -> $c (want 403)"

# --- reader: delete collection (write, no token) -> 403 --------------------
c=$(code DELETE "${COL_BASE}/${CID}")
[[ "$c" == "403" ]] && ok "reader DELETE /collections/{id} -> 403 (blocked)" || bad "reader DELETE /collections/{id} -> $c (want 403)"

# --- cleanup: writer deletes the collection --------------------------------
c=$(code DELETE "${COL_BASE}/${CID}" "Authorization: Bearer ${WRITER}")
[[ "$c" == "200" || "$c" == "204" ]] && ok "writer DELETE /collections/{id} -> $c (cleanup)" || bad "writer DELETE /collections/{id} -> $c (want 200/204)"

echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "${FAIL}" -eq 0 ]]
