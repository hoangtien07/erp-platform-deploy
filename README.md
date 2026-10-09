# erp-platform-deploy

Deployment platform cho EWCP + ERPNext stack: Docker Compose, environment
configs, backup/restore, version pins, release manifests.

Governance: `docs/architecture/REPOSITORY_MAP.md` trong
`enterprise-work-control-plane` — repo này sở hữu deploy artifacts, không
chứa business code.

## Layout

```
envs/           # per-environment config (dev, staging, prod)
releases/       # release manifests — pin tested SHAs across repos
docs/           # runbooks (bootstrap, backup, restore, upgrade)
docker/         # compose files + images wiring
scripts/        # operational scripts
```

## Release manifest contract

`releases/<name>.yaml` pin SHA đã test — không `latest`/branch-tip trong
production:

```yaml
release: alpha-0.1
components:
  ewcp_product:        { ref: "<tested-sha>" }   # ewcp-product product/vnext
  ewcp_kernel:         { ref: "<tested-sha>" }   # enterprise-work-control-plane main
  erpnext:             { ref: "<pinned-v16-sha>" }  # vendor mirror
  erp_enterprise_app:  { ref: "<tested-sha>" }   # erp-enterprise-app
```

## G1′ — local ERPNext dev site (WP-A4a un-blocker)

Site dev nội bộ (không TLS, bind loopback, KHÔNG phải staging G1 thật —
G1 production-like vẫn chờ founder infra C01). Mục tiêu: verify Frappe REST
contract + A4a pack dev + FAC-condition fixtures mà không cần infra thật.

**Stack** (adapted từ `frappe_docker` `pwd.yml`): mariadb 11.8 + redis ×2 +
configurator + create-site + backend (gunicorn) + frontend (nginx) +
websocket + queue-short/long + scheduler + `seed` one-shot.
`erp-enterprise-app` mount vào bench như custom app tại
`vendor/erp-enterprise-app` (git submodule — pin SHA, xem `releases/`).

### Boot

```bash
git submodule update --init      # kéo erp-enterprise-app về vendor/
mkdir -p secrets                 # quan trọng: seed ghi credentials vào đây;
                                 # nếu docker tự tạo mount đích thì thành root-owned
cp .env.example .env             # sửa secrets nếu cần (dev-local only)
docker compose up -d             # ~5–6 phút tới healthy (new-site + install apps + seed)
docker compose logs -f create-site seed
```

Site sẵn sàng khi `create-site` + `seed` exit 0. Frontend:
`http://localhost:8080` — site `ewcp-dev.localhost` (nginx pin site qua
header, nên `localhost` cũng được). Desk login: `Administrator` /
`$ADMIN_PASSWORD`.

### API credentials cho scoped user

`seed` tạo service user `ewcp-agent@ewcp.dev` (role **Accounts User** duy
nhất, KHÔNG Administrator) và ghi token vào `secrets/ewcp-agent.env`
(gitignored). Dùng cho kernel/packs:

```bash
source secrets/ewcp-agent.env
curl -s -H "Authorization: token $ERPNEXT_API_KEY:$ERPNEXT_API_SECRET" \
  "$ERPNEXT_BASE_URL/api/resource/Customer?limit_page_length=5"
```

Trỏ kernel/packs: `ERPNEXT_BASE_URL=http://localhost:8080` (loopback only).

### Seeded fixtures (đủ cho FAC conditions của A4a)

| Fixture | Value | Phục vụ |
|---|---|---|
| Companies | `EWCP Dev Company A` (EDA), `EWCP Dev Company B` (EDB) | cross-company UP tests (R1/R2/G1) |
| Customers | `EWCP Dev Customer A1`, `EWCP Dev Customer B1` | v1/v2 list + doc reads |
| Items | `EWCP-ITEM-001`, `EWCP-ITEM-002` (non-stock) | transaction fixtures |
| Sales Invoice | 1 submitted trên Company A (GL 2 rows, PLE 1 row) | receivables fixtures |
| User | `ewcp-agent@ewcp.dev`, role `Accounts User` | F1/F4 — non-admin scoped |
| User Permissions | Company→A (`apply_to_all_doctypes`), Customer→A1 | F2 — scoped user chỉ thấy phía A |
| System Setting | `apply_strict_user_permissions=1` | F3 |

### Reset / teardown

```bash
docker compose down            # giữ data
docker compose down -v         # xoá hẳn site + db (fresh boot lại từ đầu)
```

### Verified vs [giả định]

Đã verify bằng run thật — xem `docs/G1_LOCAL_SMOKE.md` (command + output).
Chưa verify/giả định: hành vi UP `applicable_for`/`hide_descendants` trên
Company tree (G1 trong contract), `permlevel` field filtering trên role
Accounts User (G3), error taxonomy của v1/v2 perm deny (G10).
Fixture caveat: `install_fixtures` của erpnext throw `NestedSetRecursionError`
trên site tạo không qua setup wizard — seed tạo đúng các leaf group cần thiết,
nên bộ masters đầy đủ của wizard (UOMs...) chỉ cài một phần.
