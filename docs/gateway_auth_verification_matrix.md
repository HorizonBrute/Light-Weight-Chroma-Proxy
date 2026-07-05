---
type: Runbook
title: Gateway Auth — By-Hand Verification Matrix
description: Copy-pasteable operator commands (curl / python-stdlib / chromadb) that prove the bearer-token gateway enforces reader-read / writer-write / no-token-deny (authz mode C).
tags: [chromadb, verification, bearer-token, tls, mode-c, runbook]
timestamp: 2026-07-04
---

# Gateway Auth — By-Hand Verification Matrix

**Applies to:** a deployed bearer-token gateway running in **authz mode C** (reader token required for reads, writer token for writes, no-token denied). This is the reference verification for the Horizon AIOS brain deployment of this proxy pattern; env-var names below are that deployment's (`sorcerypunk_dev` brain).
**Audience:** the gateway **operator**. Copy-paste, top to bottom, to prove auth is live.

---

## 0. What this proves

The gateway is the auth boundary. A **reader** token may only read; a **writer** token may read and write; **no token** is denied outright (mode C). These commands exercise all five cells and print the HTTP code so you can eyeball the result against this table:

| Test | reader (`$RD`) | writer (`$WR`) | no token |
|---|---|---|---|
| **READ** — `GET /api/v2/heartbeat` | **200** | **200** | **403** |
| **WRITE** — create/delete `auth_probe` collection | **403** | **200** | **403** |

> Reading tip: no-token **403** = correct (mode C). Heartbeat JSON with no token = mode B (read-open, misconfigured for mode C). Empty response / connection refused = stack down.

**Write test discipline:** the write probe creates **and deletes** a throwaway `auth_probe` collection. **Never** use `/reset` as a write probe — it wipes the store.

---

## 1. Setup (PowerShell)

Tokens come from your shell env vars — reader `SORCERYPUNK_DEV_CHROMA_R`, writer `SORCERYPUNK_DEV_CHROMA_RW` (schema `<BRAIN>_CHROMA_R` / `<BRAIN>_CHROMA_RW`, FULL brain name uppercased). Gateway at `https://127.0.0.1:8000`. The Chroma v2 collections path includes tenant + database.

```powershell
# --- setup (PowerShell) ---
$RD = $env:SORCERYPUNK_DEV_CHROMA_R    # reader token
$WR = $env:SORCERYPUNK_DEV_CHROMA_RW   # writer token
$COL = "https://127.0.0.1:8000/api/v2/tenants/default_tenant/databases/default_database/collections"
```

**TLS trust:** `-k` (curl) / an unverified SSL context (python) skips CA-verify for a quick local check. For a clean, verified run use the real gateway CA — `~/gateway/gateway_out/cert.pem` on the host (SAN covers `127.0.0.1`). Copy it to the client host and swap `-k` for `--cacert <path>` (curl) or a verifying context.

---

## 2. curl

**READ — reader → 200** (writer also → 200; no token → 403)
```powershell
curl.exe -s -k -w "`n%{http_code}`n" --oauth2-bearer $RD https://127.0.0.1:8000/api/v2/heartbeat
```

**WRITE — writer → create 200, delete 200** (reader → 403)
```powershell
'{"name":"auth_probe"}' | Set-Content $env:TEMP\p.json -Encoding ascii -NoNewline
curl.exe -s -k -w "create=%{http_code}`n" -X POST --oauth2-bearer $WR -H "Content-Type: application/json" --data "@$env:TEMP\p.json" $COL
curl.exe -s -k -w "delete=%{http_code}`n" -X DELETE --oauth2-bearer $WR "$COL/auth_probe"
```

`--oauth2-bearer` builds the `Authorization: Bearer …` header for you (avoids quoting the space); `-H "Authorization: Bearer $WR"` is equivalent. To confirm the deny path, repeat the create with `$RD` — expect `create=403`.

---

## 3. Python stdlib (`urllib`)

No third-party install. Same contract — set the header, (here) skip verify with an unverified context.

**READ — reader → 200**
```powershell
python -c "import urllib.request,ssl; ctx=ssl._create_unverified_context(); r=urllib.request.Request('https://127.0.0.1:8000/api/v2/heartbeat', headers={'Authorization':'Bearer '+'$RD'}); print(urllib.request.urlopen(r,context=ctx).status)"
```

**WRITE — writer → 200** (reader raises `HTTPError 403`)
```powershell
python -c "import urllib.request,ssl,json; ctx=ssl._create_unverified_context(); r=urllib.request.Request('$COL', data=json.dumps({'name':'auth_probe'}).encode(), headers={'Authorization':'Bearer '+'$WR','Content-Type':'application/json'}, method='POST'); print(urllib.request.urlopen(r,context=ctx).status)"
# cleanup:
curl.exe -s -k -o NUL -w "delete=%{http_code}`n" -X DELETE --oauth2-bearer $WR "$COL/auth_probe"
```

---

## 4. Chroma client (`chromadb.HttpClient`)

Verified with chromadb 1.5.9. `HttpClient` has **no** `verify=` param, so trust the gateway CA via `SSL_CERT_FILE` **before** constructing the client (see gotchas).

```python
import os, chromadb
os.environ["SSL_CERT_FILE"] = r"C:\path\to\gw_cert.pem"   # gateway CA (SAN must match 127.0.0.1)

def client(tok):
    return chromadb.HttpClient(host="127.0.0.1", port=8000, ssl=True,
                               headers={"Authorization": f"Bearer {tok}"})

# READ  (reader or writer) -> nanosecond int
print(client(os.environ["SORCERYPUNK_DEV_CHROMA_R"]).heartbeat())

# WRITE (writer) -> count 1 -> deleted
wc  = client(os.environ["SORCERYPUNK_DEV_CHROMA_RW"])
col = wc.create_collection("auth_probe", get_or_create=True)
col.add(ids=["1"], embeddings=[[0.1, 0.2, 0.3, 0.4]], documents=["hello brain"])  # explicit embeddings = no model download
print(col.count())                    # -> 1
wc.delete_collection("auth_probe")    # cleanup

# NEGATIVE: reader create_collection -> raises {"status":403,"message":"forbidden"}
```

### Two gotchas (both real, found while verifying)
1. **`SSL_CERT_FILE` *replaces* the public CA bundle** for chromadb's HTTP client. So if you do client-side embedding — `col.add(documents=[...])` **without** passing `embeddings=` — Chroma tries to download its default embedding model over the internet on first use, and that TLS handshake fails (`CERTIFICATE_VERIFY_FAILED`) because only the gateway cert is trusted. Fixes: **(a)** pass explicit `embeddings=` (as above — the write proof needs no model), or **(b)** trust a **combined** bundle:
   ```powershell
   python -c "import certifi,shutil; shutil.copy(certifi.where(),'combined.pem')"
   Get-Content C:\path\to\gw_cert.pem | Add-Content combined.pem     # append gateway cert
   $env:SSL_CERT_FILE = 'combined.pem'                               # trusts internet AND gateway
   ```
   or **(c)** install a real-SAN gateway cert and skip `SSL_CERT_FILE` entirely.
2. **Client init issues several reads** (heartbeat / version / tenant+db / auth identity). Those are all GETs and are allow-listed for readers, so a reader client constructs fine — it only fails at the first *mutating* call.

---

## 5. Verified result matrix

reader read **200** · reader write **403** · writer read **200** · writer write **200** · no-token **403**.

If any cell disagrees, confirm the gateway is in mode C and that the token is live for the role/path you are hitting.
