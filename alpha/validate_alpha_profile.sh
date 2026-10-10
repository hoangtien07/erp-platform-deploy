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
# operator-set values win — defaults only fill what is unset
for kv in ERPNEXT_IMAGE=erpnext:v15 MARIADB_IMAGE=mariadb:11.8 \
          REDIS_IMAGE=redis:7-alpine SITE_NAME=ewcp-dev.localhost \
          DB_ROOT_PASSWORD=synth ADMIN_PASSWORD=synth HTTP_PORT=8080 \
          COMPOSE_PROJECT_NAME=ewcp-erp-alpha; do
  name="${kv%%=*}"; [ -z "${!name+x}" ] && export "$name=${kv#*=}"
done
ENVFILE_ARG=(); [ -f "${DEPLOY_ENV_FILE:-}" ] && ENVFILE_ARG=(--env-file "$DEPLOY_ENV_FILE")
if cfg=$(docker compose -f "$DEPLOY_DIR/docker-compose.yml" \
      -f "$HERE/docker-compose.alpha.yml" "${ENVFILE_ARG[@]}" \
      config --format json 2>/dev/null) && [ -n "$cfg" ]; then
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
else
  fail "ports" "docker compose config failed — nothing audited"
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
  # `exec env -u …` — exec replaces the subshell so $! is the uvicorn pid
  # (kill $p actually reaps it). The earlier `env … exec` could never work:
  # env can't exec a shell builtin → exit 127 → dark port → vacuous pass.
  ( cd "$KERNEL_DIR" && exec env -u EWCP_SEAL_KEY -u EWCP_SEAL_KEY_ID \
      EWCP_REQUIRE_AUTH=1 EWCP_TENANT_KEYS='k1:tenant-a' \
      EWCP_STORE_DIR="$KD/s" EWCP_WORK_DIR="$KD/w" \
      "$KV" app.main:app --port 8210 ) >"$KD/nokey.log" 2>&1 &
  p=$!
  # Proof is "refused", not merely "unreachable": the kernel must EXIT
  # (require_auth without seal key aborts create_app) while the port stays
  # dark. A still-running process that never answered would be a slow
  # import, not a proven refusal.
  t0=$(date +%s); died=0
  while [ $(( $(date +%s) - t0 )) -lt 20 ]; do
    kill -0 $p 2>/dev/null || { died=1; break; }; sleep 1
  done
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
    "http://127.0.0.1:8210/outcomes" -H 'X-Ewcp-Api-Key: k1' 2>/dev/null)
  kill $p 2>/dev/null; wait $p 2>/dev/null
  if [ "$died" = 1 ] && [ "$code" = "000" ]; then
    pass "kernel:deny" "no SEAL_KEY → process refused boot, port dark"
  elif [ "$code" = "000" ]; then
    fail "kernel:deny" "alive but silent after 20s — refusal not proven (see $KD/nokey.log)"
  else
    fail "kernel:deny" "served without SEAL_KEY (→$code)"
  fi
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
  # Ambient env must never change the verdict: the product spawn strips
  # GEMINI_API_KEY and injects the validator's own synthetic placeholder.
  # config.yaml requires the variable PRESENT (unset → resolve_env_variables
  # raises and create_app dies), but the boot path never calls the model, so
  # a deliberately wrong key still boots. Real deploys supply it via
  # alpha/product.env — see README "Model key handling".
  ( cd "$PRODUCT_DIR/backend" && exec env -u GEMINI_API_KEY \
      GEMINI_API_KEY=alpha-validator-synthetic \
      PYTHONPATH=. DEER_FLOW_HOME="$PD/home" \
      DEER_FLOW_CONFIG_PATH="$PD/config.yaml" \
      EWCP_KERNEL_URL=http://127.0.0.1:8210 EWCP_KERNEL_API_KEY=k1 \
      "$PV" app.gateway.app:app --port 8211 ) >"$PD/gw.log" 2>&1 &
  p=$!; t0=$(date +%s); up=0
  while [ $(( $(date +%s) - t0 )) -lt 40 ]; do
    curl -sf "http://127.0.0.1:8211/api/v1/auth/setup-status" \
      >/dev/null 2>&1 && { up=1; break; }; sleep 2
  done
  if [ "$up" = 1 ] && ! kill -0 $p 2>/dev/null; then
    fail "product:boot" "our spawn died yet :8211 answers — a stale gateway holds the port (kill it and rerun)"
    up=0
  fi
  if [ "$up" = 1 ]; then
    pass "product:boot" "gateway boots on alpha config (ewcp_core required → mount proven)"
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8211/api/v1/auth/me")
    [ "$code" = "401" ] && pass "product:auth" "anonymous /me → 401 (auth on)" \
      || fail "product:auth" "anonymous → $code"
    # Registration denial — asserted over HTTP, not read off the YAML: the
    # profile ships auth.local.allow_registration:false, so the booted
    # gateway must answer POST /register with 403 REGISTRATION_DISABLED.
    reg=$(curl -s -w '\n%{http_code}' -X POST \
      "http://127.0.0.1:8211/api/v1/auth/register" \
      -H 'Content-Type: application/json' \
      -d '{"email":"alpha-validator-probe@ewcp.dev","password":"synth-val-pw-9c4e7a21"}')
    rcode=$(printf '%s\n' "$reg" | tail -1)
    rbody=$(printf '%s\n' "$reg" | head -n -1)
    if [ "$rcode" = "403" ] && printf '%s' "$rbody" | grep -qi registration_disabled; then
      pass "product:register-deny" "POST /register → 403 REGISTRATION_DISABLED (allow_registration:false enforced)"
    else
      fail "product:register-deny" "POST /register → $rcode ${rbody:0:140}"
    fi
    # Mutation check (kernel AGENTS.md DoD): flip the knob on this throwaway
    # config copy — get_app_config() reloads per request on content-signature
    # change and auth.* is NOT in the startup-only set — then the identical
    # probe must stop answering 403, and restoring it must re-deny. Proves
    # the denial above is the knob's doing, not a hard-coded response.
    python3 - "$PD/config.yaml" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
# anchored to a real YAML line — nearby comments mention the same string
s2, n = re.subn(r"(?m)^(\s*)allow_registration:\s*false\s*$",
                r"\1allow_registration: true", s, count=1)
if n != 1:
    sys.exit("knob allow_registration:false not found in config copy")
open(p, "w").write(s2)
PY
    mut=$(curl -s -w '\n%{http_code}' -X POST \
      "http://127.0.0.1:8211/api/v1/auth/register" \
      -H 'Content-Type: application/json' \
      -d '{"email":"alpha-validator-mutation@ewcp.dev","password":"synth-val-pw-9c4e7a21"}')
    mcode=$(printf '%s\n' "$mut" | tail -1)
    python3 - "$PD/config.yaml" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s2 = re.sub(r"(?m)^(\s*)allow_registration:\s*true\s*$",
            r"\1allow_registration: false", s, count=1)
open(p, "w").write(s2)
PY
    red=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
      "http://127.0.0.1:8211/api/v1/auth/register" \
      -H 'Content-Type: application/json' \
      -d '{"email":"alpha-validator-redeny@ewcp.dev","password":"synth-val-pw-9c4e7a21"}')
    if [ "$mcode" != "403" ] && [ "$red" = "403" ]; then
      pass "product:register-mutation" "knob mutated→accepted ($mcode), restored→403 — denial tracks the config"
    else
      fail "product:register-mutation" "mutated→$mcode (want ≠403), restored→$red (want 403)"
    fi
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
  git -C "$DEPLOY_DIR" check-ignore -q "$f" || { gi=0; break; }
done
# templates must stay committable
git -C "$DEPLOY_DIR" check-ignore -q alpha/kernel.env.example && gi=0
git -C "$DEPLOY_DIR" check-ignore -q alpha/product.env.example && gi=0
[ "$gi" = 1 ] \
  && pass "gitignore:env" "alpha/*.env ignored, *.example committable" \
  || fail "gitignore:env" "secret env files not git-ignored (git check-ignore)"

# ── 5. ERP developer_mode pinned off for Alpha ─────────────────────────
grep -q 'set-config developer_mode 0' "$HERE/docker-compose.alpha.yml" \
  && pass "erp:devmode" "alpha create-site pins developer_mode 0 (dev's '1' overridden)" \
  || fail "erp:devmode" "no developer_mode 0 pin in alpha overlay"

# ── 6. real AioSandbox spawn on the isolated bridge ───────────────────
# The enforcement point is the product's own sandbox backend, not the YAML:
# spawn through LocalContainerBackend fed with the sandbox section of THIS
# config file (same dict AioSandboxProvider hands it), then assert at the
# Docker layer: the spawned container sits on exactly one network, that
# bridge is --internal with gateway_mode ipv4+ipv6=isolated, the sandbox's
# deerflow.network_mode label matches the config, exec works, and a real
# egress attempt from inside is refused. A mutated config (mode: open)
# lands on the default bridge with a working route → this check FAILs.
SB_PY="$PRODUCT_DIR/backend/.venv/bin/python"
if [ -x "$SB_PY" ] && command -v docker >/dev/null 2>&1; then
  sb_json=$(cd "$PRODUCT_DIR/backend" && PYTHONPATH=. \
    "$SB_PY" - "$HERE/product.config.yaml" <<'PY' 2>/dev/null
import json, subprocess, sys
import yaml

cfg = yaml.safe_load(open(sys.argv[1]))["sandbox"]
img = cfg["image"]
if subprocess.run(["docker", "image", "inspect", img],
                  capture_output=True).returncode != 0:
    subprocess.run(["docker", "pull", "-q", img],
                   capture_output=True, timeout=600)

from deerflow.community.aio_sandbox.local_backend import LocalContainerBackend
be = LocalContainerBackend(
    image=img,
    base_port=int(cfg.get("port") or 8390),
    container_prefix=cfg.get("container_prefix") or "deer-flow-sandbox",
    config_mounts=[],
    environment={},
    network_config=cfg.get("network") or {"mode": "open"},
    required_shell_sessions=0,
)
sid = "alpha-validate"
# deterministic resource names — pre-clean leftovers of a crashed prior run
import hashlib
_d = hashlib.sha256(f"{be._container_prefix}:{sid}".encode()).hexdigest()[:16]
for _c in (f"{be._container_prefix}-{sid}", f"deer-flow-netproxy-{_d}"):
    subprocess.run(["docker", "rm", "-f", _c], capture_output=True)
for _n in (f"deer-flow-sandbox-net-{_d}", f"deer-flow-sandbox-egress-{_d}"):
    subprocess.run(["docker", "network", "rm", _n], capture_output=True)
info = None
try:
    info = be.create(None, sid)
    nets = list(json.loads(subprocess.check_output(
        ["docker", "inspect", info.container_id])
    )[0]["NetworkSettings"]["Networks"])
    net = json.loads(subprocess.check_output(
        ["docker", "network", "inspect", nets[0]]))[0] if len(nets) == 1 else {}
    opts = net.get("Options") or {}
    labels = net.get("Labels") or {}
    ex = subprocess.run(["docker", "exec", info.container_id, "hostname"],
                        capture_output=True, text=True, timeout=15)
    eg = subprocess.run(
        ["docker", "exec", info.container_id, "bash", "-c",
         "timeout 5 bash -c '</dev/tcp/1.1.1.1/443' 2>/dev/null && echo OPEN || echo BLOCKED"],
        capture_output=True, text=True, timeout=30)
    print(json.dumps({
        "configured_mode": be.network_mode,
        "nets": nets,
        "internal": net.get("Internal") is True,
        "gw4": opts.get("com.docker.network.bridge.gateway_mode_ipv4"),
        "gw6": opts.get("com.docker.network.bridge.gateway_mode_ipv6"),
        "label_mode": labels.get("deerflow.network_mode"),
        "hostname": ex.stdout.strip(),
        "egress": eg.stdout.strip(),
    }))
finally:
    if info is not None:
        try:
            be.destroy(info)
        except Exception as e:
            print(f"destroy failed: {e}", file=sys.stderr)
PY
)
  if [ -n "$sb_json" ]; then
    sb_eval=$(printf '%s' "$sb_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
ok = (d["configured_mode"] == "isolated"
      and len(d["nets"]) == 1
      and d["internal"] is True
      and d["gw4"] == "isolated" and d["gw6"] == "isolated"
      and d["label_mode"] == "isolated"
      and d["hostname"]
      and d["egress"] == "BLOCKED")
print("yes" if ok else "no:" + json.dumps(d))')
    if [ "$sb_eval" = "yes" ]; then
      net=$(printf '%s' "$sb_json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["nets"][0])')
      pass "sandbox:isolated" "spawned on --internal bridge $net (gateway_mode ipv4/6=isolated); in-container egress BLOCKED"
    else
      fail "sandbox:isolated" "spawn assertions failed — ${sb_eval#no:}"
    fi
  else
    fail "sandbox:isolated" "backend spawn produced no report (image pull/create error — needs Docker ≥28, volces + ghcr images pullable)"
  fi
  # host bash must stay disabled in the alpha product config
  hb=$(python3 -c '
import yaml,sys
c=yaml.safe_load(open(sys.argv[1])); print(c.get("sandbox",{}).get("allow_host_bash"))' "$HERE/product.config.yaml" 2>/dev/null)
  [ "$hb" = "False" ] && pass "sandbox:host-bash" "allow_host_bash: false (host bash disabled)" \
    || fail "sandbox:host-bash" "allow_host_bash=$hb"
else
  fail "sandbox" "no product venv python or docker missing — cannot prove sandbox isolation"
fi

echo "verdict: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
