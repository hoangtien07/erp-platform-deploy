# REPRO_AUDIT — clean-environment reproducibility sweep (N10)

Audit: EWCP Overnight V2 W8/N10 · session devin-deb68918f0d94c9d8a0add4d15392aca · 2026-10-10
Target: `hoangtien07/erp-platform-deploy` main @ `69f91a3` +
`hoangtien07/ewcp-product` `product/vnext` @ `e0ac3aea` +
`hoangtien07/enterprise-work-control-plane` (read-only reference).
Environment: fresh VM — Docker Engine 29.7.2 / compose v5.4.0, **zero local
images/volumes/containers**, Python 3.12.13, uv 0.13.0. No erp-g1 state
existed to reuse, so the "reuse volumes" shortcut was not exercised.
Method: fresh clones into a scratch dir, docs followed literally; every
deviation needed to proceed is logged as a gap below.

## Verdict

**PARTIAL — the stack reproduces, but not from docs alone.** ERPNext alpha
compose profile, kernel, and product gateway all booted and
`validate_alpha_profile.sh` reported **13/13 PASS** on the clean box. To get
there, three undocumented steps had to be guessed (submodule init, where the
kernel/product checkouts come from + how their venvs are built, and that
`alpha/product.env` must be sourced). Following the docs literally also
yields a stack whose kernel **cannot reach ERP** (`EWCP_ERP_*` envs are never
provisioned) and whose product gateway has **no kernel API key** — both fail
closed, silently, at use time rather than at boot.

## Step-by-step reproduction table

| # | Doc step | Source | Result | Evidence |
|---|---|---|---|---|
| 1 | Clone deploy repo | implicit | PASS | clone @ 69f91a3 |
| 2 | `git submodule update --init` | README.md:49 (G1′ recipe only) | PASS — but had to guess | `alpha/README.md` boot recipe omits this step entirely; without it `vendor/erp-enterprise-app` is an empty dir and `create-site` cannot `pip install -e` + `install-app` (docker-compose.yml:93-94) |
| 3 | `cp .env.example .env` | alpha/README.md:35 | PASS | dev-default values work for repro; `COMPOSE_PROJECT_NAME=ewcp-erp-dev` inside `.env` is overridden by `-p ewcp-erp-alpha` (works, unexplained layering) |
| 4 | `docker compose -f docker-compose.yml -f alpha/docker-compose.alpha.yml --env-file .env -p ewcp-erp-alpha up -d` | alpha/README.md:36-37 | PASS | pulled `mirror.gcr.io/frappe/erpnext:v16.50.0` (**6.66 GB** — doc says ≈2.5 GB, G1_LOCAL_SMOKE.md:16), `mariadb:11.8` 467 MB, `redis:7-alpine` 58 MB |
| 5 | Wait for healthy / `create-site`+`seed` | README.md:53-57 | PASS, faster than doc | `create-site` exited 0 in ~60 s (doc estimate 5–6 min — stale or box-dependent); `seed` correctly absent (alpha `seeds-off` profile); `/api/method/ping` → `{"message":"pong"}` HTTP 200 |
| 6 | Alpha posture on live site | alpha/docker-compose.alpha.yml:61 | PASS | `site_config.json`: `developer_mode: 0`, `installed_apps: [frappe, erpnext, erp_enterprise_app]`; `encryption_key` NOT yet materialized at create-site completion (first-init heal still lazy → G12 race window open, as documented) |
| 7 | Desk login `Administrator`/`$ADMIN_PASSWORD` | README.md:59-60 | PASS | `POST /api/method/login` → HTTP 200 with `.env.example` default |
| 8 | `cp alpha/kernel.env.example alpha/kernel.env`, "fill real values" | alpha/README.md:40 | PASS — had to guess | placeholders `__MINT_PER_DEPLOY__`/`__FROM_SECRET_STORE__` must be minted; no mint command documented (used `openssl rand -hex 32`); `alpha/kernel.env` git-ignored ✓ |
| 9 | `set -a; . alpha/kernel.env; set +a` | alpha/README.md:41 | PASS | — |
| 10 | `cd <kernel checkout> && .venv/bin/uvicorn app.main:app --port 8000` | alpha/README.md:42 | PASS — major guess | `<kernel checkout>` never defined: no repo URL, no branch, no `.venv` bootstrap instructions. Used `~/repos/enterprise-work-control-plane` main + its blueprint-built `.venv`. Booted: `/outcomes` keyed 200, anon 401 |
| 11 | `cp alpha/product.config.yaml <product checkout>/config.yaml` | alpha/README.md:45 | PASS — major guess | `<product checkout>` never defined (repo **or branch**); `config.yaml` at repo root resolves via legacy lookup (`app_config.py:194-196`) — verified live |
| 12 | `cd <product checkout>/backend && PYTHONPATH=. GATEWAY_CORS_ORIGINS=... .venv/bin/uvicorn app.gateway.app:app --port 8001` | alpha/README.md:46-48 | PARTIAL | gateway boots: `setup-status` 200, anon `/api/v1/auth/me` 401 (auth on). But `/api/ewcp/_status` → `api_key_configured: false` — the recipe never copies/sources `alpha/product.env`, so product→kernel calls would 401 at use time. Also `.venv` bootstrap undocumented (guessed `uv sync` — worked) |
| 13 | `alpha/validate_alpha_profile.sh` | alpha/README.md:67 | PASS 13/13 | run from repo root with `KERNEL_DIR`/`PRODUCT_DIR` set; **defaults are tribal `~/repos/...` paths** |
| 14 | Same validator from `alpha/` or outside repo | — | FAIL 12/1 | `FAIL gitignore:env` — `git check-ignore` runs without `-C "$DEPLOY_DIR"` (validate_alpha_profile.sh:162-167); CWD-dependence undocumented |
| 15 | Same validator under ambient `EWCP_SEAL_KEY` | — | FAIL 12/1 | `FAIL kernel:deny — served without SEAL_KEY (→200)` — spawned kernel inherits caller env; false FAIL on a correctly-configured profile |
| 16 | Scoped API creds `secrets/ewcp-agent.env` | README.md:62-74 | NOT REPRODUCIBLE | `seed` is behind `seeds-off` in alpha; `secrets/` never created; docs say creds come "from the secret store" — no store exists on a clean env (honest gap, alpha/README.md:79-81) |
| 17 | Kernel → ERP wiring | kernel.env.example:1-19 | FAIL (silent) | kernel ERP outcomes fail-closed without `EWCP_ERP_BASE_URL`/`EWCP_ERP_API_KEY`/`EWCP_ERP_API_SECRET` (`src/ewcp/outcomes/erp_reads/client.py:31-33`, `erp_writes/client.py:49-51`) — `kernel.env.example` provisions none of them |
| 18 | Product frontend/nginx on :2026 | alpha/README.md:28 | SKIP | boot recipe covers gateway only; full product compose surface out of documented scope |
| 19 | AioSandbox image pull | product.config.yaml:1624 | PASS | `enterprise-public-cn-beijing.cr.volces.com/.../all-in-one-sandbox:1.11.0` pulled on this box; `sandbox:exec` PASS (isolated hostname/fs). Docs do warn it must be pullable (alpha/README.md:82-83) |

## Doc gaps (severity · fix)

**HIGH**

1. **Alpha recipe misses `git submodule update --init`** — `alpha/README.md:33-37`.
   Empty `vendor/erp-enterprise-app` → `create-site` fails → stack never reaches
   healthy. *Fixed in this PR (recipe step added).*
2. **Checkout sources undefined** — `alpha/README.md:42,45`. `<kernel checkout>`
   and `<product checkout>` name no repo, branch, or ref; `releases/bootstrap.yaml`
   still has `ewcp_product`/`ewcp_kernel` = `TBD`. A literal follower cloning
   `ewcp-product` default branch gets a tree **without `backend/extensions/ewcp-core`**
   → product boot fails closed (`required: true`). *Fix: pin refs in
   bootstrap.yaml and state repo+branch+venv recipe in the Prereqs block —
   partially fixed in this PR (Prereqs note added); the manifest pins remain
   TBD by design.*
3. **Kernel↔ERP leg undocumented** — `alpha/kernel.env.example` lacks
   `EWCP_ERP_BASE_URL` / `EWCP_ERP_API_KEY` / `EWCP_ERP_API_SECRET`; the kernel
   boots but every ERP outcome fails closed at invoke time (reads →
   `ErpConfigError`, writes → 404 via the empty allowlist anyway). *Fix: add
   commented `EWCP_ERP_*` placeholders to `kernel.env.example` + a line in the
   recipe explaining where creds come from (`secrets/ewcp-agent.env` dev-side /
   secret store alpha-side). Not applied — needs founder decision on which
   creds the alpha kernel should hold.*

**MEDIUM**

4. **Boot recipe never wires `alpha/product.env`** — `alpha/README.md:44-48` uses
   only `GATEWAY_CORS_ORIGINS`; `product.env` exists in the knob→file map (:109)
   but not in the recipe → measured `api_key_configured: false`. *Fixed in this
   PR (copy + source step added).*
5. **Validator prerequisites undocumented** — needs `uv` on PATH
   (validate_alpha_profile.sh:102), host `python3`+`pyyaml` (:197), docker, and
   `KERNEL_DIR`/`PRODUCT_DIR` checkouts with **prebuilt** venvs (defaults assume
   a `~/repos/` layout). *Fix: prereqs list in alpha/README — partially fixed
   in this PR.*
6. **Validator is CWD-sensitive** — `git check-ignore` has no `-C "$DEPLOY_DIR"`
   (:162-167): measured `FAIL gitignore:env` from `alpha/` or outside the repo.
   Docs don't state the required CWD. *Not fixed here — already fixed on
   held PR #6 (`git -C`, per kernel-repo `PR6_REVIEW.md` validator-hardening
   items); fixing on main would collide with that branch.*
7. **Validator ambient-env leak** — `kernel:deny` inherits the operator env:
   `EWCP_SEAL_KEY=anything` → measured false FAIL "served without SEAL_KEY
   (→200)". *Not fixed here — fixed on held PR #6 (`env -u`, PR6_REVIEW
   BUG-5).*

**LOW**

8. **Stale layout block** — `README.md:12-18` lists `envs/` (doesn't exist) and
   omits `alpha/` + root `docker-compose.yml`. *Fixed in this PR.*
9. **Stale numbers** — `G1_LOCAL_SMOKE.md:16` "ERPNext image ≈ 2.5 GB" vs
   measured **6.66 GB** unpacked; "5–6 min to healthy" vs ~1 min measured here
   (variance, keep a range). *Size fixed in this PR.*
10. **Contradictory devmode note** — `alpha/README.md:71-73` says `developer_mode`
    is "Not enforced by this profile", but the overlay enforces it
    (docker-compose.alpha.yml:61) and `erp:devmode` asserts it; measured
    `developer_mode: 0` on the live site. *Fixed in this PR.* (Same finding as
    `PR6_REVIEW.md` REVISE-3 on the #6 branch — predates it on main.)
11. **Tenant-name alignment undocumented** — [suy luận] committed
    `invoke.tenant_id: alpha` (product.config.yaml) vs the recipe's example
    tenant `tenant-a` (kernel.env.example:7); nothing says the minted
    `key:tenant` pair must match the product's `tenant_id`. *Fix: one comment
    line in kernel.env.example — left for founder wording.*
12. **`mkdir -p secrets` absent from alpha path** — only matters if someone
    activates the `seeds-off` profile (root-owned mount warning is documented
    for dev at README.md:50-51). *Fix: one-line note — left as audit item.*

## Image pulls the docs assume (measured)

| Image | Docs mention | Pulled size (unpacked) |
|---|---|---|
| `mirror.gcr.io/frappe/erpnext:v16.50.0` | `.env.example:10` (smoke doc understates size) | 6.66 GB |
| `mirror.gcr.io/library/mariadb:11.8` | `.env.example:11` | 467 MB |
| `mirror.gcr.io/library/redis:7-alpine` | `.env.example:12` | 57.8 MB |
| `…vefaas-public/all-in-one-sandbox:1.11.0` | alpha/README.md:26,82-83 (pullability caveated) | pulled by validator `sandbox:exec` |

## Related in-flight work (not re-fixed here)

- Deploy PR #6 (`devin/1791657447-alpha-review-fixes`, held for founder
  review) already fixes gaps 6 and 7 and adds validator hardening; its open
  findings are in `PR6_REVIEW.md` (kernel repo, `devin/1791718400-w2-audit-docs`
  branch). Gap 10 is the same stale note it flags on its own README copy.
- G12 `encryption_key` race: documented in alpha/README.md:74-78; observed
  state consistent on this boot (`encryption_key` absent from site_config at
  create-site exit — lazy heal window real). Single-node boot unaffected.
- Deploy #5 validator env-var bug: already fixed at this commit
  (`DEPLOY_ENV_FILE` + synthetic exports, validate_alpha_profile.sh:19-25).

## Cleanup

ERP alpha stack left running under compose project `ewcp-erp-alpha` for
inspection (`docker compose -p ewcp-erp-alpha down -v` to remove). Kernel and
gateway test processes on :8000/:8001 were stopped. No secrets committed —
synthetic values only; `alpha/kernel.env` confirmed git-ignored.
