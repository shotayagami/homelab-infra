#!/usr/bin/env bash
#
# Push cloudflared/tunnel-config.yaml as the remote-managed tunnel
# configuration via the Cloudflare API.
#
# Required env (from ENV_FILE / shell):
#   CF_API_TOKEN     token with Account:Cloudflare Tunnel:Edit
#   CF_ACCOUNT_ID
#   CF_TUNNEL_ID
#
# Usage:
#   scripts/cloudflared-push-tunnel-config.sh                   # apply
#   DRY_RUN=1 scripts/cloudflared-push-tunnel-config.sh         # show plan
#   CONFIG_FILE=path/to/other.yaml scripts/cloudflared-...sh    # alternate file
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
CONFIG_FILE="${CONFIG_FILE:-${REPO_ROOT}/cloudflared/tunnel-config.yaml}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
fi

: "${CF_API_TOKEN:?CF_API_TOKEN is required}"
: "${CF_ACCOUNT_ID:?CF_ACCOUNT_ID is required}"
: "${CF_TUNNEL_ID:?CF_TUNNEL_ID is required}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: config file not found: $CONFIG_FILE" >&2
  exit 1
fi

# PyYAML is required to parse tunnel-config.yaml. Fail early with an install
# hint if it's missing rather than letting the python heredoc spit
# `ModuleNotFoundError` in the middle of the run.
if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "ERROR: PyYAML is required (python3 -c 'import yaml' failed)." >&2
  echo "  apt-based: sudo apt install python3-yaml" >&2
  echo "  pip:       python3 -m pip install --user pyyaml" >&2
  exit 1
fi

# Convert YAML -> JSON via python (avoid yq dep)
DESIRED=$(python3 - <<PY
import json, yaml, sys
with open("$CONFIG_FILE") as f:
    data = yaml.safe_load(f)
print(json.dumps(data, separators=(",", ":")))
PY
)

LIVE_RAW=$(curl -sS -H "Authorization: Bearer $CF_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations")

LIVE_OK=$(echo "$LIVE_RAW" | jq -r '.success // false')
if [[ "$LIVE_OK" != "true" ]]; then
  echo "FAIL: GET tunnel configurations did not return success=true." >&2
  echo "$LIVE_RAW" | jq . >&2 2>/dev/null || echo "$LIVE_RAW" >&2
  exit 1
fi

LIVE=$(echo "$LIVE_RAW" | jq -c '.result.config // {}')

# Normalize both sides for comparison (sorted keys, drop nulls)
DESIRED_NORM=$(echo "$DESIRED" | jq -S -c 'del(.. | nulls?)')
LIVE_NORM=$(echo "$LIVE" | jq -S -c 'del(.. | nulls?)')

if [[ "$DESIRED_NORM" == "$LIVE_NORM" ]]; then
  echo "ok: tunnel config already matches"
  exit 0
fi

echo "--- diff (live vs desired) ---"
diff <(echo "$LIVE" | jq -S .) <(echo "$DESIRED" | jq -S .) || true
echo "------------------------------"

if [[ "${DRY_RUN:-}" == "1" ]]; then
  echo "DRY_RUN=1: not applying"
  exit 0
fi

PAYLOAD=$(jq -nc --argjson cfg "$DESIRED" '{config:$cfg}')
RESP=$(curl -sS -X PUT \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data "$PAYLOAD" \
  "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations")

OK=$(echo "$RESP" | jq -r '.success')
if [[ "$OK" != "true" ]]; then
  echo "FAIL: $RESP" >&2
  exit 1
fi
echo "applied."
