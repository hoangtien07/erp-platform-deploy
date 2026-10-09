#!/bin/bash
# ewcp dev wrapper: editable-install the mounted custom app into THIS
# container's bench env (env/ is container-local, so each python service
# does this once at start), then hand off to the stock frappe entrypoint
# which links baked assets into the sites volume and execs "$@".
set -e
APP_DIR=/home/frappe/frappe-bench/apps/erp_enterprise_app
if [ -f "$APP_DIR/pyproject.toml" ]; then
  /home/frappe/frappe-bench/env/bin/pip install -q -e "$APP_DIR" 1>&2
else
  echo "[ewcp-dev-entrypoint] vendor app missing at $APP_DIR" >&2
  echo "  (run 'git submodule update --init' on the host)" >&2
fi
exec /usr/local/bin/entrypoint.sh "$@"
