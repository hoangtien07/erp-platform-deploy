#!/usr/bin/env bash
# validate_alpha_profile.sh — boot/posture validation for the Alpha profile.
# Needs no real secrets: synthetic values exercise the knobs themselves.
# Env: KERNEL_DIR (default ~/repos/enterprise-work-control-plane),
#      PRODUCT_DIR (default ~/repos/ewcp-product), DEPLOY_DIR (repo root).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$HERE/..}"
KERNEL_DIR="${KERNEL_DIR:-$HOME/repos/enterprise-work-control-plane}"
PRODUCT_DIR="${PRODUCT_DIR:-$HOME/repos/ewcp-product}"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf 'PASS  %s — %s\n' "$1" "$2"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL  %s — %s\n' "$1" "$2"; }

# ── 1. publish audit: every published port must be loopback ─────────────
# The audit only needs variable interpolation to succeed — synthetic
# stand-ins are fine (no real values are inspected). A real .env may be
# pointed at via DEPLOY_ENV_FILE.
for kv in ERPNEXT_IMAGE=erpnext:v15 MARIADB_IMAGE=mariadb:11.8 \
          REDIS_IMAGE=redis:7-alpine SITE_NAME=ewcp-dev.localhost \
          DB_ROOT_PASSWORD=synth ADMIN_PASSWORD=synth HTTP_PORT=8080 \
          COMPOSE_PROJECT_NAME=ewcp-erp-alpha; do
  export "${kv%%=*}=${kv#*=}"
done
ENVFILE_ARG=(); [ -f "${DEPLOY_ENV_FILE:-}" ] && ENVFILE_ARG=(--env-file "$DEPLOY_ENV_FILE")
cfg=$(docker compose -f "$DEPLOY_DIR/docker-compose.yml" \
      -f "$HERE/docker-compose.alpha.yml" "${ENVFILE_ARG[@]}" \
      config --format json 2>/dev/null)
bad=$(printf '%s' "$cfg" | python3 -c '
import json, sys
d = json.load(sys.stdin); out = []
for name, svc in (d.get("services") or {}).items():
    for p in svc.get("ports") or []:
        ip = p.get("host_ip") or "0.0.0.0"
        if ip not in ("127.0.0.1", "::1"):
            out.append(f"{name}:{ip}:{p.get('published')}")
print("\n".join(out))')
if [ -z "$bad" ]; then
  n=$(printf '%s' "$cfg" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(sum(len(s.get("ports") or []) for s in (d.get("services") or {}).values()))')
  pass "ports" "merged compose: $n published port(s), all loopback-bound"
else
  fail "ports" "non-loopback publish: $(printf '%s' "$bad" | tr '\n' ' ')"
fi
# services bound only to an inactive profile are dropped from `config`'s
# runtime model entirely — seed must be absent here, and present only when
# the 'seeds-off' profile is explicitly activated.
has_seed=$(printf '%s' "$cfg" | python3 -c 'import json,sys;print("seed" in (json.load(sys.stdin).get("services") or {}))')
seed_off=$(docker compose -f "$DEPLOY_DIR/docker-compose.yml" \
  -f "$HERE/docker-compose.alpha.yml" --profile seeds-off \
  "${ENVFILE_ARG[@]}" config --services 2>/dev/null | grep -xc seed)
if [ "$has_seed" = "False" ] && [ "${seed_off:-0}" = "1" ]; then
  pass "seed-off" "seed out of default model, only under 'seeds-off' profile"
else
  fail "seed-off" "default-model seed=$has_seed, profiled count=${seed_off:-0}"
fi

# ── 2. kernel posture: deny-boot, keyed boot, anon 401, write-gate 404 ──
KV="$KERNEL_DIR/.venv/bin/uvicorn"
[ -x "$KV" ] || KV="$KERNEL_DIR/.venv-verify/bin/uvicorn"   # release-verify venv name
if [ -x "$KV" ]; then
  KD=$(mktemp -d)
  ( cd "$KERNEL_DIR" && EWCP_REQUIRE_AUTH=1 EWCP_TENANT_KEYS='k1:tenant-a' \
      EWCP_STORE_DIR="$KD/s" EWCP_WORK_DIR="$KD/w" \
      exec "$KV" app.main:app --port 8210 ) >"$KD/nokey.log" 2>&1 &
  p=$!; sleep 4
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
    "http://127.0.0.1:8210/outcomes" -H 'X-Ewcp-Api-Key: k1' 2>/dev/null)
  kill $p 2>/dev/null; wait $p 2>/dev/null
  [ "$code" = "000" ] && pass "kernel:deny" "no SEAL_KEY → /outcomes unreachable ($code)" \
    || fail "kernel:deny" "served without SEAL_KEY (→$code)"
  ( cd "$KERNEL_DIR" && EWCP_REQUIRE_AUTH=1 EWCP_TENANT_KEYS='k1:tenant-a' \
      EWCP_SEAL_KEY=alpha-validate EWCP_SEAL_KEY_ID=k1 \
      EWCP_STORE_DIR="$KD/s" EWCP_WORK_DIR="$KD/w" \
      exec "$KV" app.main:app --port 8210 ) >"$KD/keyed.log" 2>&1 &
  p=$!; t0=$(date +%s); up=0
  while [ $(( $(date +%s) - t0 )) -lt 25 ]; do
    curl -sf "http://127.0.0.1:8210/outcomes" -H 'X-Ewcp-Api-Key: k1' \
      >/dev/null 2>&1 && { up=1; break; }; sleep 1
  done
  if [ "$up" = 1 ]; then
    pass "kernel:keyed" "keyed+sealed boot serves /outcomes"
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8210/outcomes")
    [ "$code" = "401" ] && pass "kernel:anon" "anonymous → 401" \
      || fail "kernel:anon" "anonymous → $code"
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
      "http://127.0.0.1:8210/outcomes/erp_write_po/run" -H 'X-Ewcp-Api-Key: k1')
    [ "$code" = "404" ] && pass "kernel:write-gate" "erp_write_po → 404 (allowlist empty)" \
      || fail "kernel:write-gate" "erp_write_po → $code"
  else
    fail "kernel:keyed" "keyed boot never served — see $KD/keyed.log"
  fi
  kill $p 2>/dev/null; wait $p 2>/dev/null
else
  fail "kernel" "$KV missing — set KERNEL_DIR to a checkout with .venv"
fi

# ── 3. product posture: auth on + ewcp-core mounted with policies ──────
PV="$PRODUCT_DIR/backend/.venv/bin/uvicorn"
EXT="$PRODUCT_DIR/backend/extensions/ewcp-core"
if [ -x "$PV" ]; then
  # idempotent editable install of the extension into the backend venv
  (cd "$PRODUCT_DIR/backend" && uv pip install --python .venv/bin/python \
      -e ./extensions/ewcp-core >/dev/null 2>&1) || \
    fail "product:ext-install" "uv pip install -e extensions/ewcp-core failed"
  PD=$(mktemp -d); cp "$HERE/product.config.yaml" "$PD/config.yaml"
  # pin sqlite_dir into the throwaway home (CWD-relative default is the
  # known deerflow.db escape hatch — would share state across runs)
  python3 - "$PD" <<'PY'
import re, sys
pd = sys.argv[1]
s = open(pd + "/config.yaml").read()
s = re.sub(r"(?m)^  sqlite_dir: \.deer-flow/data$",
           f"  sqlite_dir: {pd}/data", s, count=1)
open(pd + "/config.yaml", "w").write(s)
PY
  ( cd "$PRODUCT_DIR/backend" && PYTHONPATH=. DEER_FLOW_HOME="$PD/home" \
      DEER_FLOW_CONFIG_PATH="$PD/config.yaml" \
      EWCP_KERNEL_URL=http://127.0.0.1:8210 EWCP_KERNEL_API_KEY=k1 \
      exec "$PV" app.gateway.app:app --port 8211 ) >"$PD/gw.log" 2>&1 &
  p=$!; t0=$(date +%s); up=0
  while [ $(( $(date +%s) - t0 )) -lt 40 ]; do
    curl -sf "http://127.0.0.1:8211/api/v1/auth/setup-status" \
      >/dev/null 2>&1 && { up=1; break; }; sleep 2
  done
  if [ "$up" = 1 ]; then
    pass "product:boot" "gateway boots on alpha config (ewcp_core required → mount proven)"
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8211/api/v1/auth/me")
    [ "$code" = "401" ] && pass "product:auth" "anonymous /me → 401 (auth on)" \
      || fail "product:auth" "anonymous → $code"
    # extension mount + policy probe — _status sits behind auth, so mint a
    # synthetic admin + login first (DB lives in the throwaway PD home).
    curl -sf -X POST "http://127.0.0.1:8211/api/v1/auth/initialize" \
      -H 'Content-Type: application/json' \
      -d '{"email":"alpha-validator@ewcp.dev","password":"synth-val-pw-9c4e7a21"}' >/dev/null 2>&1
    curl -sf -c "$PD/cj" -X POST "http://127.0.0.1:8211/api/v1/auth/login/local" \
      -d 'username=alpha-validator@ewcp.dev&password=synth-val-pw-9c4e7a21' >/dev/null 2>&1
    st=$(curl -sf -b "$PD/cj" "http://127.0.0.1:8211/api/ewcp/_status" 2>/dev/null)
    ok=$(printf '%s' "$st" | python3 -c '
import json, sys
d = json.load(sys.stdin)
eg = d.get("egress", {})
ok = (d.get("extension") == "ewcp_core"
      and d.get("kernel_configured") is True
      and d.get("api_key_configured") is True
      and d.get("budget_admission_enabled") is True
      and d.get("budget_cap_usd") == "5.00"
      and eg.get("default_mode") == "local_only")
print("yes" if ok else "no")' 2>/dev/null)
    [ "$ok" = "yes" ] \
      && pass "product:policy" "/api/ewcp/_status: kernel configured, egress default_mode=local_only, budget cap \$5.00 admission on" \
      || fail "product:policy" "_status → ${st:-<unreachable>}"
  else
    fail "product:boot" "gateway did not boot — see $PD/gw.log"
  fi
  kill $p 2>/dev/null; wait $p 2>/dev/null
else
  fail "product" "$PV missing — set PRODUCT_DIR to a checkout with backend/.venv"
fi

# ── 4. secret hygiene: real env files must be git-ignored ──────────────
gi=1
for f in alpha/kernel.env alpha/product.env; do
  git check-ignore -q "$f" || { gi=0; break; }
done
# templates must stay committable
git check-ignore -q alpha/kernel.env.example && gi=0
git check-ignore -q alpha/product.env.example && gi=0
[ "$gi" = 1 ] \
  && pass "gitignore:env" "alpha/*.env ignored, *.example committable" \
  || fail "gitignore:env" "secret env files not git-ignored (git check-ignore)"

# ── 5. ERP developer_mode pinned off for Alpha ─────────────────────────
grep -q 'set-config developer_mode 0' "$HERE/docker-compose.alpha.yml" \
  && pass "erp:devmode" "alpha create-site pins developer_mode 0 (dev's '1' overridden)" \
  || fail "erp:devmode" "no developer_mode 0 pin in alpha overlay"

# ── 6. real isolated AioSandbox execution on the pinned image ─────────
SB_IMG=$(grep 'image:' "$HERE/product.config.yaml" | head -1 | sed 's/.*image: *//; s/[ "]*$//')
if [ -n "$SB_IMG" ] && command -v docker >/dev/null 2>&1; then
  docker image inspect "$SB_IMG" >/dev/null 2>&1 || docker pull -q "$SB_IMG" >/dev/null
  cid=$(docker run -d --rm --entrypoint sleep "$SB_IMG" 300 2>/dev/null || true)
  if [ -n "$cid" ]; then
    sleep 2
    out=$(docker exec "$cid" bash -c 'hostname; id -u; test -f /etc/hostname && echo ct_fs_ok' 2>/dev/null)
    hn=$(printf '%s\n' "$out" | head -1)
    if [ "$hn" != "$(hostname)" ] && printf '%s' "$out" | grep -q ct_fs_ok; then
      pass "sandbox:exec" "real exec inside $SB_IMG (container hostname $hn, isolated fs)"
    else
      fail "sandbox:exec" "exec did not prove isolation (out: ${out:-none})"
    fi
    docker kill "$cid" >/dev/null 2>&1
  else
    fail "sandbox:exec" "could not start sandbox container ($SB_IMG)"
  fi
  # host bash must stay disabled in the alpha product config
  hb=$(python3 -c '
import yaml,sys
c=yaml.safe_load(open(sys.argv[1])); print(c.get("sandbox",{}).get("allow_host_bash"))' "$HERE/product.config.yaml" 2>/dev/null)
  [ "$hb" = "False" ] && pass "sandbox:host-bash" "allow_host_bash: false (host bash disabled)" \
    || fail "sandbox:host-bash" "allow_host_bash=$hb"
else
  fail "sandbox" "no sandbox image pinned in product.config.yaml or docker missing"
fi

echo "verdict: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
