#!/usr/bin/env bash
#
# Zabbix Server LXC (192.168.11.55 / VMID 190) を Cloudflare Tunnel + Cloudflare Access で
# 外部公開する。Tunnel と Access App/Policy は CF API で冪等に管理する。
#
# Run from a machine that can SSH to the Proxmox host as root.
#
# 前提:
#   - Zabbix 7.0 LTS LXC が既に稼働 (VMID 190, nginx が :80 で listen)
#   - Cloudflare account に zone `yagamin.net` が登録済
#   - .env に CF_API_TOKEN / CF_ACCOUNT_ID / CF_ZONE_ID と
#     CF_ACCESS_INCLUDE_EMAIL_DOMAINS (or _EMAILS) が設定済
#
# 使い方:
#   $ cd ~/homelab-infra
#   $ bash scripts/proxmox-deploy-zabbix-cloudflare-access.sh
#
# 冪等性:
#   - Tunnel: 名前 "zabbix" で検索、無ければ作成
#   - DNS CNAME: 既存 record があれば update、無ければ create
#   - Access App: 名前一致 or domain 一致で update、無ければ create
#   - cloudflared: LXC 内に systemd service が無ければ install + register
#
# 履歴:
#   2026-05-15 初版

set -euo pipefail

# ─────────────────────────────────────────────
# Config (env で override 可)
# ─────────────────────────────────────────────
ENV_FILE="${ENV_FILE:-${HOME}/.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

ZABBIX_DOMAIN="${ZABBIX_DOMAIN:-zabbix.yagamin.net}"
ZABBIX_TUNNEL_NAME="${ZABBIX_TUNNEL_NAME:-zabbix}"
ZABBIX_BACKEND="${ZABBIX_BACKEND:-http://127.0.0.1:80}"
PVE_HOST="${PVE_HOST:-192.168.11.11}"
ZABBIX_VMID="${ZABBIX_VMID:-190}"

CF_API_BASE="https://api.cloudflare.com/client/v4"
CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_DNS_API_TOKEN="${CF_DNS_API_TOKEN:-${CF_API_TOKEN}}"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-}"
CF_ZONE_ID="${CF_ZONE_ID:-}"
CF_ACCESS_INCLUDE_EMAILS="${CF_ACCESS_INCLUDE_EMAILS:-}"
CF_ACCESS_INCLUDE_EMAIL_DOMAINS="${CF_ACCESS_INCLUDE_EMAIL_DOMAINS:-}"

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────
require() { [[ -n "${!1:-}" ]] || { echo "ERROR: env $1 が未設定です" >&2; exit 1; }; }

cf_api_token_for_path() {
  # Zone DNS 系は CF_DNS_API_TOKEN を優先 (Puter スクリプトと同じ規約)
  local path="$1"
  if [[ "$path" == */zones/* ]]; then
    echo "${CF_DNS_API_TOKEN:-${CF_API_TOKEN}}"
  else
    echo "${CF_API_TOKEN}"
  fi
}

cf_api() {
  local method="$1" path="$2" data="${3:-}"
  local bearer response
  bearer="$(cf_api_token_for_path "$path")"
  if [[ -n "$data" ]]; then
    response="$(curl -fsS -X "$method" "${CF_API_BASE}${path}" \
      -H "Authorization: Bearer ${bearer}" \
      -H "Content-Type: application/json" --data "$data")" || {
        echo "ERROR: HTTP $method ${path} failed" >&2
        return 1
      }
  else
    response="$(curl -fsS -X "$method" "${CF_API_BASE}${path}" \
      -H "Authorization: Bearer ${bearer}" \
      -H "Content-Type: application/json")" || {
        echo "ERROR: HTTP $method ${path} failed" >&2
        return 1
      }
  fi
  local ok
  ok="$(jq -r '.success' <<<"$response")"
  if [[ "$ok" != "true" ]]; then
    echo "ERROR: Cloudflare API failed for ${method} ${path}" >&2
    jq '.errors' <<<"$response" >&2 || true
    return 1
  fi
  echo "$response"
}

# ─────────────────────────────────────────────
# Validate
# ─────────────────────────────────────────────
require CF_API_TOKEN
require CF_ACCOUNT_ID
require CF_ZONE_ID
if [[ -z "$CF_ACCESS_INCLUDE_EMAILS" && -z "$CF_ACCESS_INCLUDE_EMAIL_DOMAINS" ]]; then
  echo "ERROR: CF_ACCESS_INCLUDE_EMAILS と CF_ACCESS_INCLUDE_EMAIL_DOMAINS の少なくとも一方を設定してください" >&2
  exit 1
fi

echo "==> Config"
echo "  ZABBIX_DOMAIN       = $ZABBIX_DOMAIN"
echo "  ZABBIX_TUNNEL_NAME  = $ZABBIX_TUNNEL_NAME"
echo "  ZABBIX_BACKEND      = $ZABBIX_BACKEND"
echo "  PVE_HOST            = $PVE_HOST"
echo "  ZABBIX_VMID         = $ZABBIX_VMID"
echo "  Access allow emails = ${CF_ACCESS_INCLUDE_EMAILS:-(none)}"
echo "  Access allow domains= ${CF_ACCESS_INCLUDE_EMAIL_DOMAINS:-(none)}"
echo

# ─────────────────────────────────────────────
# 1. Tunnel (find or create)
# ─────────────────────────────────────────────
echo "==> Resolving Cloudflare tunnel '${ZABBIX_TUNNEL_NAME}'"
tunnel_list="$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?is_deleted=false&name=${ZABBIX_TUNNEL_NAME}")"
TUNNEL_ID="$(jq -r --arg n "$ZABBIX_TUNNEL_NAME" '.result[] | select(.name == $n) | .id' <<<"$tunnel_list" | head -n1)"

if [[ -z "$TUNNEL_ID" ]]; then
  echo "  not found, creating..."
  # tunnel_secret: 32 bytes random, base64-encoded
  TUNNEL_SECRET="$(head -c 32 /dev/urandom | base64 -w0)"
  create_payload="$(jq -nc --arg n "$ZABBIX_TUNNEL_NAME" --arg s "$TUNNEL_SECRET" \
    '{name: $n, tunnel_secret: $s, config_src: "cloudflare"}')"
  created="$(cf_api POST "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel" "$create_payload")"
  TUNNEL_ID="$(jq -r '.result.id' <<<"$created")"
  echo "  created tunnel id=$TUNNEL_ID"
else
  echo "  found existing tunnel id=$TUNNEL_ID"
fi

# Connector token (cloudflared が必要とする bearer 値)
echo "==> Fetching tunnel connector token"
token_resp="$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token")"
TUNNEL_TOKEN="$(jq -r '.result' <<<"$token_resp")"
[[ -n "$TUNNEL_TOKEN" && "$TUNNEL_TOKEN" != "null" ]] || { echo "ERROR: token 取得失敗" >&2; exit 1; }
echo "  token acquired (length=${#TUNNEL_TOKEN})"

# ─────────────────────────────────────────────
# 2. Tunnel ingress
# ─────────────────────────────────────────────
echo "==> Configuring tunnel ingress (${ZABBIX_DOMAIN} -> ${ZABBIX_BACKEND})"
ingress_json="$(jq -nc --arg h "$ZABBIX_DOMAIN" --arg s "$ZABBIX_BACKEND" \
  '[{hostname: $h, service: $s}, {service: "http_status:404"}]')"
cf_api PUT "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
  "$(jq -nc --argjson i "$ingress_json" '{config: {ingress: $i}}')" >/dev/null
echo "  ingress configured"

# ─────────────────────────────────────────────
# 3. DNS CNAME -> <tunnel-id>.cfargotunnel.com
# ─────────────────────────────────────────────
echo "==> Ensuring DNS CNAME ${ZABBIX_DOMAIN} -> ${TUNNEL_ID}.cfargotunnel.com"
existing_dns="$(cf_api GET "/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${ZABBIX_DOMAIN}")"
dns_id="$(jq -r '.result[0].id // empty' <<<"$existing_dns")"
dns_payload="$(jq -nc --arg n "$ZABBIX_DOMAIN" --arg t "${TUNNEL_ID}.cfargotunnel.com" \
  '{type:"CNAME", name:$n, content:$t, proxied:true, ttl:1}')"
if [[ -n "$dns_id" ]]; then
  cf_api PUT "/zones/${CF_ZONE_ID}/dns_records/${dns_id}" "$dns_payload" >/dev/null
  echo "  updated existing DNS record"
else
  cf_api POST "/zones/${CF_ZONE_ID}/dns_records" "$dns_payload" >/dev/null
  echo "  created DNS record"
fi

# ─────────────────────────────────────────────
# 4. Access app + policy
# ─────────────────────────────────────────────
echo "==> Ensuring Cloudflare Access application for ${ZABBIX_DOMAIN}"
app_name="Zabbix (${ZABBIX_DOMAIN})"
app_payload="$(jq -nc --arg name "$app_name" --arg d "$ZABBIX_DOMAIN" \
  '{name:$name, type:"self_hosted", domain:$d, self_hosted_domains:[$d], session_duration:"24h"}')"
apps="$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/access/apps")"
app_id="$(jq -r --arg n "$app_name" '.result[] | select(.name == $n) | .id' <<<"$apps" | head -n1)"
[[ -n "$app_id" ]] || app_id="$(jq -r --arg d "$ZABBIX_DOMAIN" '.result[] | select(.domain == $d) | .id' <<<"$apps" | head -n1)"
if [[ -n "$app_id" ]]; then
  cf_api PUT "/accounts/${CF_ACCOUNT_ID}/access/apps/${app_id}" "$app_payload" >/dev/null
  echo "  updated existing app id=$app_id"
else
  created_app="$(cf_api POST "/accounts/${CF_ACCOUNT_ID}/access/apps" "$app_payload")"
  app_id="$(jq -r '.result.id' <<<"$created_app")"
  echo "  created app id=$app_id"
fi

echo "==> Ensuring Access policy 'Allow listed emails'"
IFS=',' read -r -a emails <<<"$CF_ACCESS_INCLUDE_EMAILS"
IFS=',' read -r -a domains <<<"$CF_ACCESS_INCLUDE_EMAIL_DOMAINS"
include_json="$({
  printf '%s\n' "${emails[@]}" | awk 'NF' | jq -R '{email:{email:.}}'
  printf '%s\n' "${domains[@]}" | sed 's/^@//' | awk 'NF' | jq -R '{email_domain:{domain:.}}'
} | jq -s '.')"

policy_payload="$(jq -nc \
  --arg decision "allow" \
  --arg name "Allow listed emails" \
  --argjson include "$include_json" \
  '{decision:$decision, name:$name, include:$include}')"

policies="$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/access/apps/${app_id}/policies")"
policy_id="$(jq -r '.result[] | select(.name == "Allow listed emails") | .id' <<<"$policies" | head -n1)"
if [[ -n "$policy_id" ]]; then
  cf_api PUT "/accounts/${CF_ACCOUNT_ID}/access/apps/${app_id}/policies/${policy_id}" "$policy_payload" >/dev/null
  echo "  updated policy id=$policy_id"
else
  cf_api POST "/accounts/${CF_ACCOUNT_ID}/access/apps/${app_id}/policies" "$policy_payload" >/dev/null
  echo "  created policy"
fi

# ─────────────────────────────────────────────
# 5. cloudflared install in LXC 190 (idempotent)
# ─────────────────────────────────────────────
echo "==> Checking SSH to Proxmox (${PVE_HOST})"
ssh -o BatchMode=yes -o ConnectTimeout=8 "root@${PVE_HOST}" "hostname >/dev/null"

echo "==> Installing cloudflared in LXC ${ZABBIX_VMID} if missing"
# 既存 service があれば skip
needs_install="$(ssh "root@${PVE_HOST}" "pct exec ${ZABBIX_VMID} -- bash -lc '
if systemctl list-unit-files 2>/dev/null | grep -q cloudflared; then echo no; else echo yes; fi
'" | tail -n1)"

if [[ "$needs_install" == "yes" ]]; then
  ssh "root@${PVE_HOST}" "pct exec ${ZABBIX_VMID} -- bash -lc '
    set -euo pipefail
    cd /tmp
    ARCH=\$(dpkg --print-architecture)
    wget -q -O cloudflared.deb \"https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-\${ARCH}.deb\"
    apt-get install -y ./cloudflared.deb
    rm -f cloudflared.deb
  '"
  echo "  cloudflared installed"
else
  echo "  cloudflared service unit already present"
fi

echo "==> Registering/refreshing cloudflared as service with current tunnel token"
# 既存 service があれば一度 uninstall して入れ直す (token rotation 対応)
ssh "root@${PVE_HOST}" "pct exec ${ZABBIX_VMID} -- bash -lc '
  set -euo pipefail
  systemctl stop cloudflared 2>/dev/null || true
  cloudflared service uninstall 2>/dev/null || true
  cloudflared service install \"${TUNNEL_TOKEN}\"
  systemctl enable --now cloudflared
  sleep 2
  systemctl status cloudflared --no-pager | head -8
'"

echo
echo "=== 完了 ==="
echo "次の確認手順:"
echo "  1. 数十秒待ってブラウザで https://${ZABBIX_DOMAIN}/ にアクセス"
echo "  2. Cloudflare Access のメール入力画面が出る → 許可ドメインのアドレスで PIN 認証"
echo "  3. PIN 経由で Zabbix UI のログイン画面に到達することを確認"
echo "  4. Zabbix Admin で TOTP 2FA を有効化 (Users → Admin → Authentication)"
