# OpenBao vs. Infisical

> Deliverable for the **Secrets Management** task (ClickUp, created 2026-07-07).
> Structured around the six questions on that task: differences, HA, KMS, mounting,
> secret structure, licensing/commercial use.
>
> The Infisical mounting/structure details reflect a typical production self-hosted
> Infisical deployment (agent sidecars → tmpfs, `dev`/`stage`/`prod` projects).
>
> Companion doc: `vault-vs-openbao-analysis.md` (OpenBao vs. HashiCorp Vault + Amfileon
> adoption approach). Status: analysis / decision-support — not an implemented system.
> Last updated: 2026-07-15.

---

## TL;DR

| | **OpenBao** | **Infisical** |
|---|---|---|
| What it fundamentally is | A security **infrastructure primitive** — identity-based secrets *engine* (dynamic secrets, PKI, encryption-as-a-service), sealed at rest | A developer-first **secrets-management product** — store, organize, and distribute secrets with great UX |
| Sweet spot | Ephemeral/dynamic credentials, PKI, being the root of trust | Killing `.env` sprawl; static secrets with environments + a good UI |
| Origin | Fork of HashiCorp Vault (1.14), Linux Foundation | Independent product (YC-backed), Node/TypeScript |
| Operational weight | Heavy (seal/unseal, cluster, root-of-trust) | Light (deploy an app + Postgres/Redis) |
| License | MPL 2.0 — fully OSS, no feature gating | MIT core + separately-licensed enterprise (`ee`) features |

They **overlap** in the middle (both can store static secrets and distribute them via a
sidecar) but come from opposite ends: OpenBao is "secrets as security infrastructure,"
Infisical is "secrets as developer tooling." The overlap is growing — Infisical has added
dynamic secrets, PKI, and KMS; OpenBao has KV for static secrets — but each is strongest
at its origin.

---

## 1. Differences (openbao vs. Infisical)

**OpenBao** treats secrets as an infrastructure concern. Its defining features *generate
and destroy* secrets rather than just store them:
- **Dynamic secrets** — mints short-lived DB/cloud/SSH credentials on demand, with a lease,
  and revokes them on expiry (e.g. a 1h Postgres role created via `CREATE ROLE`).
- **PKI** — runs as an internal CA issuing short-lived certs.
- **Transit** — encryption-as-a-service; keys never leave the vault.
- **Sealed at rest** — the store is encrypted with a key OpenBao doesn't hold at rest;
  it must be *unsealed* on startup before any secret is readable.
- Access is identity-based (AppRole, OIDC, TLS, cloud IAM) with fine-grained path policies,
  and every request is audited.

**Infisical** treats secrets as a developer-experience and distribution problem:
- A polished **web UI**, per-environment scoping, secret **versioning/rollback**, secret
  **referencing**, **PR-style change requests / approvals**, and **secret scanning** of
  repos.
- **Integrations** that push secrets into GitHub Actions, Vercel, Kubernetes, etc.
- A CLI that injects secrets into a process (`infisical run -- <cmd>`).
- Increasingly: dynamic secrets, a PKI product, and a KMS product — but these are younger
  than OpenBao's equivalents (which are the mature Vault lineage).

**One-line difference:** OpenBao is the tool you reach for when secrets must be *ephemeral,
revocable, and cryptographically brokered*; Infisical is the tool you reach for when the
problem is *"our static secrets are a mess and we want a good UI + environments."*

---

## 2. HA (high availability)

**OpenBao — self-contained HA via Raft.**
- Uses **integrated Raft storage**: a 3- or 5-node cluster with leader election and
  replicated storage built in. No external database required.
- Each node comes up **sealed** and must be unsealed (manual key shares or auto-unseal)
  before it can serve — so HA planning must include an **auto-unseal** strategy or a node
  restart leaves capacity offline until someone unseals it.
- This is the mature Vault HA model; well-battle-tested.
- Note: cross-site/DR **replication** (active-active across locations) is a Vault
  *Enterprise* feature; OpenBao OSS gives you single-cluster Raft HA, not multi-cluster
  replication.

**Infisical — HA is delegated to its data tier.**
- Infisical is a (largely) **stateless app** backed by **PostgreSQL + Redis**. HA means:
  run multiple app replicas behind a load balancer, and make **Postgres and Redis
  themselves HA** (primary/replica, Patroni, managed service, etc.).
- So Infisical's availability rides on *your database HA*, not on a consensus protocol
  inside the product. There's no seal/unseal step.
- Infisical **Cloud** is HA managed for you; self-hosted HA is your responsibility at the
  DB layer.

**For Amfileon:** if the Postgres HA cluster work already in flight matures, Infisical HA
essentially comes "for free" on top of it (it's just another Postgres consumer). OpenBao
brings its *own* HA (Raft) and doesn't lean on your Postgres — but adds the unseal problem.

---

## 3. KMS (key management / encryption-as-a-service)

> Note: "KMS" here = **Key Management Service** (managing encryption keys / doing
> encrypt-decrypt on behalf of apps) — distinct from the `kms/` *folder* these docs live in.

**OpenBao — Transit engine (mature).**
- **Transit** is full encryption-as-a-service: `encrypt`, `decrypt`, `sign`, `verify`,
  `hmac`, **datakey generation**, **key rotation**, convergent encryption. Plaintext goes
  in, ciphertext comes out, and **the key never leaves OpenBao**.
- This is the same Transit engine apps use to encrypt DB fields without ever handling a key,
  and it's what OpenBao can use for its own **auto-unseal** (transit or PKCS#11/HSM).
- Deep, battle-tested (Vault lineage), many key types and operations.

**Infisical — Infisical KMS (newer).**
- Infisical ships a **KMS** product: create/manage encryption keys and do encrypt/decrypt
  via API, plus envelope encryption used internally to protect secrets at rest.
- Functionally covers the common "encrypt/decrypt a blob, manage the key centrally" case
  with a friendly API/UI, but is **younger and narrower** than Transit (fewer operations —
  e.g. signing/HMAC/convergent-encryption/datakeys are Transit's strengths).

**Verdict:** both have a KMS story. If KMS is a primary requirement (signing, HMAC, wide
key-type support, proven at scale), **OpenBao Transit is the stronger, more mature choice**.
If it's occasional encrypt/decrypt with a nice API, Infisical KMS is adequate.

---

## 4. How does the mounting work? (like the agent in Infisical?)

**Yes — the pattern is nearly identical.** Both use a sidecar that authenticates, then
renders secrets into a file the app reads.

**Infisical (typical self-hosted deployment):**
```
Infisical server ──(Machine Identity token, poll ~10s)──▶ infisical-agent-<service>
                                                              │ atomic write (.env.tmp → .env)
                                                              ▼
                                                    tmpfs volume (secrets-ram-<service>)
                                                              │ read-only bind mount
                                                              ▼
                                                    service reads /run/secrets/.env
```
Other Infisical delivery modes: `infisical run -- <cmd>` (env injection), a **Kubernetes
operator** (`InfisicalSecret` CRD → native k8s Secret), and direct SDK/API.

**OpenBao — Vault Agent (`bao agent`):**
- `auto_auth` authenticates the sidecar (via **AppRole** on Docker/Compose; k8s SA on k8s).
- A `template` stanza renders secrets to a destination file (point it at the **same tmpfs**
  volume the service mounts). The agent also **auto-renews leases** and re-renders when a
  dynamic secret rotates.
- Other modes: a **k8s Agent Injector** (mutating webhook adds the sidecar), a **CSI
  provider**, and direct API/SDK.

**Difference in the mounting:** mechanically the same (sidecar → file → app reads at
startup). The meaningful gap is *what* gets rendered: OpenBao's agent can render and manage
**dynamic, leased** secrets (renew/rotate/revoke); Infisical's agent primarily distributes
**static** secrets (with its newer dynamic-secret support catching up). Both share the same
caveat — a service that reads env vars at startup needs a **restart** to pick up changed
values; neither tool hot-reloads the process.

**On Compose (Amfileon):** either is "an agent container + a shared tmpfs volume" — the
same sidecar-plus-shared-volume shape in both cases.

---

## 5. Structure of secrets (environments / JSON)

**Infisical — opinionated, environment-first hierarchy:**
```
Organization
  └─ Project (e.g. "registry")
       └─ Environment (dev / stage / prod)
            └─ Folder (/database, /minio, …)
                 └─ Secret (KEY = value)   ← versioned, with cross-references
```
- **Environments (`dev`/`stage`/`prod`) are a first-class, built-in concept.** You pick the
  env per agent (`INFISICAL_ENV`) and it pulls that env's values.
- Secrets are key/value with per-environment overrides, **secret referencing**
  (`${OTHER_SECRET}`), per-secret **versioning/rollback**, and import/export.
- Very aligned with "app config per environment."

**OpenBao — paths + mounts, structure is yours to design:**
```
mount: kv/        (KV-v2 engine)
  path: kv/data/prod/registry   → arbitrary JSON { "REGISTRY_DB_PASSWORD": "…", … }  (versioned)
  path: kv/data/dev/registry    → { … }
mount: database/  (dynamic engine)  → database/creds/<role>
mount: pki/       (PKI engine)      → pki/issue/<role>
```
- No built-in `dev`/`stage`/`prod` concept — **environments are a convention** you impose
  via path prefixes (`kv/data/prod/…`) or, in OpenBao, **namespaces** for harder isolation.
- KV-v2 stores **arbitrary JSON** at a path, versioned. Access is governed by
  **path-scoped policies**.
- More flexible and more powerful (paths can address engines, not just static values), but
  **less opinionated** — you own the layout and governance.

**Difference:** Infisical hands you environments + folders as a product feature (structured
JSON per env, minimal design work). OpenBao hands you a path namespace + policy engine and
you *design* the environment model. Infisical is faster to structure; OpenBao is more
flexible and unifies static + dynamic + PKI under one path/policy scheme.

---

## 6. Licensing — can we use both commercially? Limitations

**Short answer: yes, both are usable commercially** — with different shapes of "free."

**OpenBao — MPL 2.0.**
- Fully open source. Commercial use is unrestricted; **no feature gating** — everything is
  in the OSS build (including HSM/PKCS#11 auto-unseal, which is Enterprise-only in Vault).
- No paid tier from a single vendor → **you own all operations and support** (community
  support, or a third party like IBM/Red Hat if they package it).
- No BUSL "no-compete" clause (that restriction is HashiCorp **Vault's**, and Vault is not
  in this comparison).

**Infisical — dual-licensed (MIT core + commercial `ee`).**
- The **core is MIT-licensed** and self-hostable/commercially usable for free.
- Certain **enterprise features live under a separate commercial license** (the `ee/`
  code) and require a paid plan — historically things like SAML/OIDC SSO, advanced RBAC,
  longer audit-log retention, and similar. So the community edition is commercial-friendly,
  but **some capabilities are gated** behind a paid license.
- Infisical **Cloud** is SaaS (free + paid tiers) as an alternative to self-hosting.
- ⚠️ Exact feature-gating and license terms shift release to release — **verify the current
  `ee` boundary** against Infisical's license docs before relying on a specific gated
  feature being free.

**"Can we use both commercially?"** Yes. OpenBao: no restrictions or gating at all, but no
paid support tier either. Infisical: free for the MIT core commercially, but budget for a
paid license if you need the enterprise-gated features (SSO, advanced RBAC, audit
retention).

**Limitations to weigh:**
- OpenBao — no commercial support/replication/FIPS from a vendor; smaller ecosystem;
  operationally heavy (seal/unseal, root-of-trust).
- Infisical — enterprise features cost money; dynamic-secrets/PKI/KMS are younger than
  OpenBao's; self-hosted HA depends on you running Postgres/Redis HA.

---

## Recommendation for Amfileon

- If the need is **static secret hygiene + environments + good DX** (get the weak
  `.env` creds like `REGISTRY_DB_PASSWORD` and the exposed SMTP/LDAP/root secrets under
  control, with `dev`/`stage`/`prod`): **Infisical** is the lighter, faster win — the
  agent/tmpfs distribution pattern is well-proven.
- If the need is **ephemeral credentials, internal PKI (retire the manual `amf` CA), or
  encryption-as-a-service**: **OpenBao** is in a different class; Infisical's equivalents
  are younger.
- A common end state is **both**: OpenBao as the root of trust for dynamic creds + PKI +
  Transit, a lighter tool for developer-facing static config — at the cost of running two
  systems.
- Same governing caution as the companion doc: whichever is chosen, **don't make it a hard
  dependency of the real-money trade path until HA + (for OpenBao) auto-unseal + tested
  backup are proven.** Start with low-blast-radius static secrets, expand toward the money
  path only as trust is earned.

---

## Open questions / to verify
- Does Amfileon already run a secrets manager (Infisical, OpenBao, Vault, or other)?
- Is KMS (encryption-as-a-service) an actual requirement, or just a checklist item? Decides
  how much the Transit-vs-Infisical-KMS maturity gap matters.
- Current Infisical `ee` license boundary — which features are gated today?
- Is an HSM available? (OpenBao OSS can use it for auto-unseal; relevant if OpenBao wins.)
- Target: self-hosted only, or is Infisical Cloud acceptable for any environment?
