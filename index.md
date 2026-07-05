---
okf_version: "0.1"
---

# Lightweight Chroma Proxy

* [Overview (README)](README.md) - A reverse-proxy configuration pattern that adds TLS termination and role-based admission control in front of ChromaDB, with no application code and no Chroma RBAC.

# Design

* [Architecture & Design](docs/ARCHITECTURE.md) - The design of the pattern — the reverse-proxy contract, endpoint allow-list, credential injection, access tiers, cert model, hardening, and threat model. Also covers the multi-service front (Chroma + a model server such as Ollama, each with its own role-based allow-list), the authorization-filtering mechanism (the generalized, provider-agnostic POC of imposing bearer-token use/admin roles on an auth-free upstream — two path maps + two token maps + one default-deny composite, management never reachable by a use token), and the unified token registry (one source of truth → generated per-service maps).

# Sample

* [Sample — Docker Compose + nginx](sample/README.md) - A self-contained, runnable demonstration of the pattern using Docker Compose and OSS nginx, with instructions to run, verify, and adapt it.
