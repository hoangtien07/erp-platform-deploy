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
