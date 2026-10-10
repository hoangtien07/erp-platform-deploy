# G1′ — smoke test record (local Docker ERPNext dev site)

Verified live on this box, 2026-10-09. Site `ewcp-dev.localhost` behind the
frontend container at `http://localhost:8080` (127.0.0.1 only, no TLS — dev).

Stack: `frappe/erpnext:v16.50.0` (via `mirror.gcr.io` — Docker Hub anonymous
pulls were rate-limited on this box), `mariadb:11.8`, `redis:7-alpine`.
Custom app `erp_enterprise_app` installed from `vendor/erp-enterprise-app`
(submodule @ `ebc4140`). `frappe.get_installed_apps()` →
`['frappe', 'erpnext', 'erp_enterprise_app']` (verified, live query).

Boot timing (measured here, images already local):
`docker compose up -d` → first `ping` 200 ≈ **5–6 min**. `create-site`
(`bench new-site` + `install-app erpnext` + `install-app erp_enterprise_app`)
is the bulk (~4–5 min); `seed` adds ~30 s. First boot on a cold host adds
image pull time (ERPNext image ≈ 6.7 GB unpacked — re-measured 2026-10-10,
`mirror.gcr.io/frappe/erpnext:v16.50.0`).

## 1. Guest liveness — `ping`

```sh
$ curl -s -w '\nHTTP %{http_code}\n' http://localhost:8080/api/method/ping
{"message":"pong"}
HTTP 200
```

## 2. Scoped user, customer list — User Permission enforced

Scoped user `ewcp-agent@ewcp.dev` (roles `Accounts User` + `EWCP Write` —
the A5b draft-PO write role installed by `erp_enterprise_app` fixtures) with
`User Permission: Company → EWCP Dev Company A` (apply_to_all_doctypes=1) and
`User Permission: Customer → EWCP Dev Customer A1`;
`System Settings.apply_strict_user_permissions=1`.
DB contains TWO customers (A1, B1) and TWO companies (A, B) — verified via
`frappe.get_all` in a bench console.

```sh
$ source secrets/ewcp-agent.env
$ curl -s -w '\nHTTP %{http_code}\n' \
    -H "Authorization: token $ERPNEXT_API_KEY:$ERPNEXT_API_SECRET" \
    "http://localhost:8080/api/resource/Customer?limit_page_length=5"
{"data":[{"name":"EWCP Dev Customer A1"}]}
HTTP 200
```

v2 surface, same user:

```sh
$ curl -s -w '\nHTTP %{http_code}\n' \
    -H "Authorization: token $ERPNEXT_API_KEY:$ERPNEXT_API_SECRET" \
    "http://localhost:8080/api/v2/document/Customer?limit=5"
{"has_next_page":false,"data":[{"name":"EWCP Dev Customer A1"}]}
HTTP 200
```

→ B1 filtered out by User Permission on BOTH v1 and v2. F2 (Company scope) is
the same mechanism — Company list also returns only A:

```sh
$ curl -s -H "Authorization: token $ERPNEXT_API_KEY:$ERPNEXT_API_SECRET" \
    "http://localhost:8080/api/resource/Company?limit_page_length=10"
{"data":[{"name":"EWCP Dev Company A"}]}
```

## 3. Direct-doc denial (F10 surface shape)

```sh
$ curl -s -w '\nHTTP %{http_code}\n' \
    -H "Authorization: token $ERPNEXT_API_KEY:$ERPNEXT_API_SECRET" \
    "http://localhost:8080/api/resource/Customer/EWCP%20Dev%20Customer%20B1"
{"exception":"frappe.exceptions.PermissionError","exc_type":"PermissionError",
"exc":"[...traceback...doc.check_permission(\"read\")...]",
"_server_messages":"[{\"message\":\"Not allowed for Customer: EWCP Dev Customer B1\"...}]",
"_error_message":"You need the 'read' permission on <strong>Customer</strong>
EWCP Dev Customer B1 to perform this action."}
HTTP 403
```

→ HTTP 403. NOTE for the contract: the 403 body **leaks the doc's existence**
(traceback + `Not allowed for Customer: ...` string). Deny is 403, not 404 —
record as observed v16 behavior for F10.

Allowed doc, same user:

```sh
$ curl -s -H "Authorization: token $ERPNEXT_API_KEY:$ERPNEXT_API_SECRET" \
    "http://localhost:8080/api/resource/Customer/EWCP%20Dev%20Customer%20A1" | head -c 400
{"data":{"name":"EWCP Dev Customer A1","owner":"Administrator",
"creation":"2026-10-09 16:48:50.570279",...,"customer_type":"Company",
"customer_group":"Commercial","territory":"Rest Of The World",...}}
HTTP 200
```

## 4. Unauthenticated request

```sh
$ curl -s -w '\nHTTP %{http_code}\n' http://localhost:8080/api/resource/Customer
{"exc_type":"PermissionError","_server_messages":"[{\"message\":\"Insufficient
Permission for <strong>Customer</strong>\"...}]"}
HTTP 403
```

→ Guest cannot list Customer (F9 holds at REST layer on this site).

## 5. Scoped user sees posted invoice fixture

```sh
$ curl -s -w '\nHTTP %{http_code}\n' \
    -H "Authorization: token $ERPNEXT_API_KEY:$ERPNEXT_API_SECRET" \
    "http://localhost:8080/api/v2/document/Sales%20Invoice?limit=5"
{"has_next_page":false,"data":[{"name":"ACC-SINV-2026-00001"}]}
HTTP 200
```

Backend facts (bench console, Administrator):
`Sales Invoice ACC-SINV-2026-00001 docstatus=1 grand_total=300.0
outstanding=300.0` with **2 GL Entry rows** and **1 Payment Ledger Entry row**
(receivables exposure is real — an earlier seed pass left a half-posted SI
with `docstatus=1` but 0 GL rows; the seed now deletes stale/partial SIs and
rebuilds, and asserts gl/ple counts in its log).

## What is NOT verified here

- [giả định] Kernel/pack wiring against these endpoints — this site only
  proves the Frappe-side contract surface; A4a pack code is out of scope.
- [giả định] `token` auth works the same for write verbs — only GETs exercised.
- Fixture caveat: `erpnext.setup.install_fixtures.install()` throws
  `NestedSetRecursionError` on a site created without the setup wizard
  (nested-set roots already exist); seed works around it by creating only the
  leaf groups it needs (`Commercial`, `Rest Of The World`, `Services`,
  `Products`). Records landed, but the full wizard fixture set (UOMs, etc.)
  is partially installed — anything the contract needs beyond the seeded
  masters may be missing.
- [giả định] Token permission surfaces beyond `Accounts User` read scope —
  role coverage checked statically from DocType JSONs, not every DocType curl'd.

## Reproduce

```sh
git submodule update --init
mkdir -p secrets
cp .env.example .env
docker compose up -d          # ~5-6 min to healthy on warm images
docker compose logs -f create-site seed
source secrets/ewcp-agent.env
curl -H "Authorization: token $ERPNEXT_API_KEY:$ERPNEXT_API_SECRET" \
     http://localhost:8080/api/resource/Customer
```
