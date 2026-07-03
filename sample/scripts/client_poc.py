#!/usr/bin/env python3
r"""client_poc.py — prove the OFFICIAL chromadb client works through the proxy.

Where `smoke-test.sh` uses curl to prove the *endpoints* answer, this proves the real
`chromadb.HttpClient` library works end to end against the sample proxy — which is the
stronger claim (a client issues connect/handshake calls curl never makes).

What it does (mode B sample: reads open, writes need the WRITER_TOKEN):
  1. WRITER client (bearer WRITER_TOKEN) — create a collection + add records  [WRITE path]
  2. READER client (no token)           — count / query / get them back       [READ path]
  3. READER attempts a write            — expect it to be DENIED (403)         [role split]

Embeddings are a trivial deterministic function (no model download) — this is a proxy
POC, not an embedding-quality demo. Swap in a real embedding_function for real use.

Requirements:  pip install chromadb-client     (thin remote client; no server/onnx)
Config (env, with sensible defaults for the sample):
  WRITER_TOKEN   required — must match a line in nginx/writer_tokens.map
  PROXY_HOST     default 127.0.0.1
  PROXY_PORT     default 8443
  PROXY_CERT     default ../certs/cert.pem  (the sample's self-signed cert to trust)
Usage:  WRITER_TOKEN=$(grep -oP 'WRITER_TOKEN=\K.*' ../.env) python client_poc.py
"""
import os, sys
import chromadb
from chromadb import Documents, EmbeddingFunction, Embeddings
from chromadb.config import Settings

HOST = os.environ.get("PROXY_HOST", "127.0.0.1")
PORT = int(os.environ.get("PROXY_PORT", "8443"))
CERT = os.environ.get("PROXY_CERT", os.path.join(os.path.dirname(__file__), "..", "certs", "cert.pem"))
WRITER = os.environ.get("WRITER_TOKEN")
COLL = "poc_collection"

if not WRITER:
    sys.exit("set WRITER_TOKEN (must match a line in nginx/writer_tokens.map)")


class TinyHashEF(EmbeddingFunction):
    """Deterministic 16-dim embedding from text — zero deps, enough to move real
    records through the proxy. Replace with a real embedder for production."""
    def __call__(self, input: Documents) -> Embeddings:
        out = []
        for t in input:
            v = [0.0] * 16
            for i, ch in enumerate(t):
                v[i % 16] += ord(ch)
            n = sum(x * x for x in v) ** 0.5 or 1.0
            out.append([x / n for x in v])
        return out
    @staticmethod
    def name() -> str: return "tiny_hash"
    def get_config(self): return {}
    @staticmethod
    def build_from_config(config): return TinyHashEF()


def client(bearer):
    headers = {"Authorization": f"Bearer {bearer}"} if bearer else {}
    return chromadb.HttpClient(
        host=HOST, port=PORT, ssl=True, headers=headers,
        settings=Settings(chroma_server_ssl_verify=CERT, anonymized_telemetry=False))


def main():
    ef = TinyHashEF()

    # 1. WRITE path — writer token
    w = client(WRITER)
    print("[writer] heartbeat ns:", w.heartbeat())
    col = w.get_or_create_collection(COLL, embedding_function=ef)
    col.upsert(ids=["a", "b", "c"],
               documents=["the quick brown fox", "lorem ipsum dolor", "vector search rocks"],
               metadatas=[{"n": 1}, {"n": 2}, {"n": 3}])
    print(f"[writer] WRITE ok -> count={col.count()}")

    # 2. READ path — reader (no token in mode B)
    r = client(None)
    rc = r.get_collection(COLL, embedding_function=ef)
    print("[reader] count:", rc.count())
    res = rc.query(query_texts=["quick fox"], n_results=2, include=["documents"])
    print("[reader] query ->", res["documents"][0])
    print("[reader] get 'a' ->", rc.get(ids=["a"], include=["documents"])["documents"])

    # 3. reader must NOT write
    try:
        rc.upsert(ids=["x"], documents=["should be rejected"])
        print("[reader] WRITE-DENY: *** FAIL — reader was allowed to write ***"); sys.exit(1)
    except Exception as e:
        m = str(e)
        print("[reader] WRITE-DENY ok:", "403" if "403" in m else type(e).__name__)
    print("POC PASS")


if __name__ == "__main__":
    main()
