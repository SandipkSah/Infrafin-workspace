# Secrets Management: Vault vs OpenBao — Analysis & Adoption Approach for Amfileon

> Working note for the freelance DevOps engagement at Amfileon. Captures the
> Vault/OpenBao comparison, how it maps onto Amfileon's on-prem estate, and a
> phased approach to adopting one **if** the firm chooses to.
>
> Status: analysis / proposal draft — not an implemented system.
> Last updated: 2026-07-15.

---

## 0. TL;DR

- **OpenBao is a fork of HashiCorp Vault** (forked from Vault 1.14, now under the
  Linux Foundation). For the deployment shapes Amfileon would use — dynamic DB
  credentials, PKI, AppRole, agent sidecars — they are **API- and config-compatible**;
  you swap the image and the CLI name (`vault` → `bao`), not the design.
- **The only substantive difference is licensing** (Vault = BUSL / source-available
  with a no-compete clause; OpenBao = MPL 2.0, true OSS) plus **Vault's paid
  Enterprise tier** (support, replication, FIPS, HSM auto-unseal).
- **For Amfileon specifically**, the decision tips on two firm-specific facts:
  air-gapped on-prem (favours OpenBao's OSS HSM auto-unseal) vs. real-money
  reliability needs (the one scenario where Vault Enterprise's support/replication/FIPS
  can be worth paying for).
- **The hard part is not the tool — it's the operational commitment** of making it a
  root of trust in a real-money environment. Approach it as a trust-building sequence
  that starts far from the trade path.

---

## 1. What OpenBao is, and why it exists

In August 2023 HashiCorp relicensed its products from MPL 2.0 (fully open source) to
the **Business Source License 1.1** (BUSL) — source-available, forbids competitive use,
converts to MPL only after four years. The community forked: **OpenTofu** for Terraform,
**OpenBao** for Vault. OpenBao was forked from Vault 1.14.x, started largely by
IBM/community contributors, and now lives under the Linux Foundation. IBM subsequently
acquired HashiCorp (closed early 2025); this did **not** reverse the licensing — Vault is
still BUSL.

## 2. Generic differences (provider-neutral)

| Dimension | HashiCorp Vault | OpenBao |
|---|---|---|
| License | BUSL 1.1 (source-available, no competitive use) | MPL 2.0 (true OSS) |
| Governance | HashiCorp / IBM | Linux Foundation |
| CLI binary | `vault` | `bao` |
| Env prefix | `VAULT_ADDR`, … | `BAO_ADDR`, … (broad Vault compat retained) |
| API paths / storage format | — | Same (forked at 1.14) |
| Secrets/auth engines (kv, database, pki, approle, oidc, transit, …) | Present | Present (core parity) |
| Enterprise tier (support, DR/perf replication, FIPS builds, namespaces) | Yes (paid) | No single-vendor commercial tier |
| HSM / PKCS#11 auto-unseal | **Enterprise only** | **Included in OSS** |
| Ecosystem / community size | Much larger | Smaller but growing |

**Compatibility is high but drifting** — two-plus years of independent development means
you should not assume parity on anything newer than the 1.14 fork point. For the
database + PKI + AppRole + agent feature set, parity is effectively complete.

---

## 3. How it maps onto Amfileon's estate

### Relevant facts (from project memory, ~2026-07-07, verify before acting)
- On-prem, privately-networked / air-gapped-ish: `.amf` internal domain, bare-metal hosts
  (db1/db2, cpu1/cpu2, gpu1, prod3/prod4), DNS/gateway at 10.10.10.1. No cloud provider
  externally discoverable.
- Own internal CA (`amf` CA, `CA.pem`); self-signed certs currently copied between hosts
  **by hand** (this is actively blocking the registry TLS cutover).
- Secrets today = raw `.env` files. Known-weak `REGISTRY_DB_PASSWORD` (`registry_password`)
  and exposed SMTP/LDAP/root creds flagged for rotation.
- Stack: Python, Dagster, ClickHouse + PostgreSQL, Docker + nginx-proxy.
- **Real money in the trade path — reliability is critical.**
- Office IT is Microsoft-365 / Entra-centric (identity likely federates to Entra ID).
- Secrets tooling is listed as **unconfirmed** — Amfileon may already run something.

### How each firm-specific fact re-weights the choice

| Factor | Which way it tips | Why |
|---|---|---|
| License | **Neutral** | Amfileon uses secrets internally, doesn't distribute/compete → BUSL doesn't bite |
| Air-gapped, no cloud KMS | **OpenBao** | HSM/PKCS#11 auto-unseal is OSS in OpenBao; Enterprise-only in Vault. Cloud-KMS auto-unseal isn't available air-gapped |
| Real-money reliability / support / FIPS | **Vault Enterprise** | Support contract, DR/perf replication, FIPS-validated builds — justifiable at a trading firm |
| Manual cert toil | Neutral (both win) | PKI engine automates the `amf` CA identically in both |
| Entra ID identity | Neutral | OIDC auth against Entra works identically in both |

**Net:** If Amfileon wants a self-hosted, no-license-cost, HSM-unsealable store and is
comfortable on community support → **OpenBao** fits the air-gapped reality especially well.
If the firm's instinct is "real money means we buy supported, replicated, FIPS-validated
infra" → that's the one scenario where **Vault Enterprise** earns its price. The license
itself is not the deciding factor for Amfileon; support-vs-cost is.

---

## 4. What Vault/OpenBao would actually do here

Three concrete use cases, in rough priority for Amfileon:

1. **Dynamic database credentials for Dagster** — instead of a static ClickHouse/Postgres
   password in `.env`, each Dagster job fetches a short-lived (e.g. 1h) role minted on
   demand via the database engine; auto-revoked on lease expiry. Per-job identity in the
   audit trail; central revocation.
2. **PKI to retire the manual `amf` CA** — the PKI engine becomes the internal CA and
   issues/renews certs on demand, ending the hand-copying of `registry2.amf.{crt,key}`
   that is currently blocking the registry cutover. (Do this *after* the migration, not
   during it.)
3. **Consolidate/rotate the flagged static secrets** — move the weak
   `REGISTRY_DB_PASSWORD` and exposed SMTP/LDAP/root creds out of `.env` into KV.

### Deployment shape (identical Vault/OpenBao except image + binary name)
- Runs as a Docker Compose stack (mirrors the existing `/srv/docker/*` layout), on a
  network that reaches the target DB host so it can run `CREATE ROLE`.
- **AppRole** auth (not Kubernetes — Amfileon is Compose/bare-metal), analogous to
  Infisical's Machine Identity tokens.
- An **agent sidecar per service** renders secrets into a tmpfs `.env` the service reads
  at startup — the same sidecar pattern Infisical's agents use.
- One-time steps Vault/OpenBao add over a plain secrets store: `operator init`, **unseal**
  (3-of-5 key shares, or auto-unseal), enable engines.

---

## 5. Complexity — honest split

| Layer | Effort | Note |
|---|---|---|
| Install + one engine (spike) | Hours | Trivial; not where the work is |
| Static-secret consolidation | Days | Real first win, survivable blast radius |
| Dynamic DB creds (non-prod) | Days | The interesting part; keep off the money path |
| HA (3-node Raft) + auto-unseal + tested backup/restore | 1–2 weeks | The actual cost of being root-of-trust |
| Trusted in the trade path | Months of runtime | Earned by track record, not installed |

**The binary is easy; becoming the root of trust is not.**

---

## 6. The governing risk

The moment a service fetches its credential from Vault at startup, **Vault becomes a hard
dependency** of that service — if Vault is down or sealed, the service can't start. For a
live trading system that is a new single point of failure. Governing principle:

> **Earn trust in low-stakes roles first; never put Vault in the critical path until its
> HA / unseal / backup story is proven.**

Two concrete "don'ts" from the current topology:
- **Don't entangle Vault with the in-flight registry migration.** Finish that on the
  existing manual CA; add Vault PKI as a follow-up.
- **Don't spike on db2** — it's a shared host (`preview.dagster.amf`); use the least
  consequential host for throwaway learning.

---

## 7. Recommended phased approach

- **Phase 0 — Confirm, don't assume.** Verify whether Amfileon already runs
  Vault/OpenBao/other (memory flags it unconfirmed and is >1 week old). Get explicit
  team buy-in on scope — this is a change to shared infra at a firm that expects tight
  access provisioning. This is a proposal, not a quiet stand-up.
- **Phase 1 — Throwaway spike, zero prod contact.** OpenBao/Vault in `-dev` mode on a
  scratch host. Mint a dynamic DB credential by hand, watch it expire. Delete after.
- **Phase 2 — Lowest-blast-radius real win.** Consolidate the flagged static secrets
  (`REGISTRY_DB_PASSWORD`, SMTP/LDAP/root) into KV. Build the production muscle
  (storage, unseal, a backup you've actually restored) while stakes are survivable.
- **Phase 3 — Dynamic DB creds, non-prod only.** Point one Dagster job on
  `preview.dagster.amf` at a 1h minted role. Prove sidecar, lease renewal, revocation.
- **Phase 4 — PKI to retire the manual CA** (after the registry migration is done).
- **Phase 5 — Only now consider the trade path**, and only once HA + auto-unseal +
  tested restore + a runbook exist. If the firm isn't ready to own that load, keep static
  secrets in Vault and leave the trade path on its current mechanism — a half-adopted
  root-of-trust is worse than none.

**The single most important call is not Vault-vs-OpenBao — it's not letting it become a
critical dependency before it's earned that.**

---

## 8. Open questions / to verify
- Does Amfileon already run a secrets manager? (blocks everything else)
- Is there an HSM available? (decides whether OpenBao's OSS HSM auto-unseal is a real edge)
- Does compliance require FIPS-validated builds? (would pull toward Vault Enterprise)
- Cloud vs on-prem vs colo for any part of the estate? (affects auto-unseal options)
- Appetite/budget for a paid support contract? (Vault Enterprise vs OpenBao community)
