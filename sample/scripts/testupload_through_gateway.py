#!/usr/bin/env python3
r"""testupload_through_gateway.py — one-shot UPLOAD smoke test through any
gateway-fronted Chroma. Standard library only.

WHAT THIS PROVES
  You can push documents INTO a Chroma vector store THROUGH a bearer-token
  reverse proxy using nothing but the Python standard library — no `chromadb`
  install, no embedding model download. It exercises the full write path a real
  ingester uses: create collection -> add records -> read them back (count +
  get by id). Where `client_poc.py` proves the OFFICIAL client library works
  through the proxy, this proves the raw v2 REST write path works with zero deps.

PLACEHOLDER-EMBEDDING CAVEAT (read this)
  The embedding vectors here are DETERMINISTIC HASHES of the text, NOT semantic
  embeddings. That proves upload + storage + retrieval BY ID or BY METADATA
  works. It is NOT enough for semantic query: a `query` by meaning returns
  garbage until you re-ingest with a real embedding function.

INGESTION GOES THROUGH THE CLIENT API / GATEWAY
  Record data enters the store via the Chroma v2 REST API behind the proxy
  (this script's `add` call), authorised by the writer bearer token — never by
  writing raw files into the store on disk.

CONFIG (all overridable via env / argv; token is REQUIRED)
  CHROMA_WRITER_TOKEN    required — the WRITER bearer token (never printed)
  CHROMA_GATEWAY_BASE    default https://127.0.0.1:8000  (scheme://host:port)
  CHROMA_TENANT          default default_tenant
  CHROMA_DATABASE        default default_database
  CHROMA_COLLECTION      default upload_smoke
  CHROMA_DOCS_DIR        default ./  (uploads every top-level *.md in this dir)
  CHROMA_TLS_VERIFY      default 0   set to a CA cert path to verify TLS, or
                                     leave 0/empty to skip verify (-k equivalent)
  argv[1] (optional)     overrides the docs dir for this run

USAGE
  CHROMA_WRITER_TOKEN=<token> \
  CHROMA_GATEWAY_BASE=https://myhost:8443 \
  python testupload_through_gateway.py ./docs
"""
import glob, hashlib, json, os, ssl, sys, urllib.error, urllib.request

WR = os.environ.get("CHROMA_WRITER_TOKEN")
if not WR:
    sys.exit("ERROR: set CHROMA_WRITER_TOKEN (the writer bearer token) in your env first.")

GATEWAY  = os.environ.get("CHROMA_GATEWAY_BASE", "https://127.0.0.1:8000").rstrip("/")
TENANT   = os.environ.get("CHROMA_TENANT", "default_tenant")
DATABASE = os.environ.get("CHROMA_DATABASE", "default_database")
COLL     = os.environ.get("CHROMA_COLLECTION", "upload_smoke")
DOCS     = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("CHROMA_DOCS_DIR", ".")
VERIFY   = os.environ.get("CHROMA_TLS_VERIFY", "0")
BASE = f"{GATEWAY}/api/v2/tenants/{TENANT}/databases/{DATABASE}"
DIM  = 8

if VERIFY and VERIFY not in ("0", "false", "False", ""):
    CTX = ssl.create_default_context(cafile=VERIFY)   # verify against the given CA cert
else:
    CTX = ssl._create_unverified_context()            # -k equivalent; quick local check


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method,
            headers={"Authorization": f"Bearer {WR}", "Content-Type": "application/json"})
    try:
        r = urllib.request.urlopen(req, context=CTX)
        raw = r.read().decode()
        return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def fake_vec(text):
    """Deterministic PLACEHOLDER embedding (NOT semantic) from a hash."""
    h = hashlib.sha256(text.encode()).digest()
    return [(h[i] / 255.0) for i in range(DIM)]


# 1) create collection (get_or_create)
st, res = call("POST", "/collections", {"name": COLL, "get_or_create": True})
print(f"[create] {st}  {res if st>=400 else 'ok id='+res.get('id','?')}")
if st >= 400:
    sys.exit(1)
cid = res["id"]

# 2) upload each top-level .md as one document
files = sorted(glob.glob(os.path.join(DOCS, "*.md")))
if not files:
    print(f"[warn]   no .md files under {DOCS} — nothing to upload"); sys.exit(1)
ids, embs, docs, metas = [], [], [], []
for f in files:
    txt = open(f, encoding="utf-8").read()
    ids.append(os.path.basename(f))
    embs.append(fake_vec(txt))
    docs.append(txt)
    metas.append({"source": os.path.basename(f), "bytes": len(txt.encode())})

st, res = call("POST", f"/collections/{cid}/add",
               {"ids": ids, "embeddings": embs, "documents": docs, "metadatas": metas})
print(f"[add]    {st}  files={len(ids)} -> {[os.path.basename(f) for f in files]}")
if st >= 400:
    print("  body:", res); sys.exit(1)

# 3) verify: count + fetch one back (retrieval by id — meaningful even with placeholder vecs)
st, res = call("GET", f"/collections/{cid}/count")
print(f"[count]  {st}  count={res}")
st, res = call("POST", f"/collections/{cid}/get",
               {"ids": [ids[0]], "include": ["metadatas", "documents"]})
if st < 400:
    meta = res.get("metadatas", [[]])
    print(f"[get]    {st}  id={ids[0]}  meta={meta}  doc_preview={repr((docs[0][:60]))}")
else:
    print(f"[get]    {st}  {res}")
