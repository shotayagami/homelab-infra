#!/usr/bin/env bash
#
# Provision Puter on Proxmox as an LXC container and publish it via Cloudflare Tunnel.
#
# Run from a machine that can SSH to the Proxmox host as root.
#
# Optional config file:
#   .env
#   or set ENV_FILE=/path/to/custom.env
#
# Required env vars:
#   PUTER_DOMAIN      e.g. puter.example.com
#   CF_TUNNEL_TOKEN   Cloudflare Tunnel token (remote-managed tunnel)
#
# Optional env vars:
#   PVE_HOST=192.168.11.11
#   VMID=102
#   CT_HOSTNAME=puter
#   CT_STORAGE=local-lvm
#   CT_TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst
#   CT_CORES=4
#   CT_MEMORY=8192
#   CT_SWAP=1024
#   CT_DISK_GB=64
#   CT_BRIDGE=vmbr0
#   CT_IP=dhcp
#   CT_NAMESERVER=1.1.1.1
#
# Optional env vars for Cloudflare API automation (recommended):
#   CF_API_TOKEN               API token used for DNS/Access/Tunnel config
#   CF_DNS_API_TOKEN           optional token only for Zone DNS APIs
#                              use when CF_API_TOKEN lacks Zone DNS permissions
#   CF_ACCOUNT_ID              Cloudflare account ID
#   CF_ZONE_ID                 Cloudflare zone ID
#   CF_TUNNEL_ID               Tunnel UUID (same tunnel as CF_TUNNEL_TOKEN)
#   CF_ACCESS_INCLUDE_EMAILS   comma-separated emails for allow policy
#   CF_ACCESS_INCLUDE_EMAIL_DOMAINS
#                              comma-separated email domains for allow policy
#                              e.g. nekomin.jp,yagamin.net (or with leading @)
#   PROTECT_PUTER_SITE_DOMAIN=0
#                              set to 1 to protect site domain with Access
#   PROTECT_PUTER_API_DOMAIN=0
#                              set to 1 to protect api domain with Access
#   ENABLE_CF_API_AUTOCONFIG=1 set to 0 to skip API automation
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"

load_env_file() {
  local env_file="$1"

  if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
  fi
}

require_env() {
  local key="$1"
  if [[ -z "${!key:-}" ]]; then
    echo "ERROR: missing required env var: ${key}" >&2
    exit 1
  fi
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: command not found: ${cmd}" >&2
    exit 1
  }
}

require_cmd ssh
require_cmd curl
require_cmd jq
load_env_file "$ENV_FILE"
require_env PUTER_DOMAIN
require_env CF_TUNNEL_TOKEN

PVE_HOST="${PVE_HOST:-192.168.11.11}"
VMID="${VMID:-102}"
CT_HOSTNAME="${CT_HOSTNAME:-puter}"
CT_STORAGE="${CT_STORAGE:-local-lvm}"
CT_TEMPLATE="${CT_TEMPLATE:-local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst}"
CT_CORES="${CT_CORES:-4}"
CT_MEMORY="${CT_MEMORY:-8192}"
CT_SWAP="${CT_SWAP:-1024}"
CT_DISK_GB="${CT_DISK_GB:-64}"
CT_BRIDGE="${CT_BRIDGE:-vmbr0}"
CT_IP="${CT_IP:-dhcp}"
CT_NAMESERVER="${CT_NAMESERVER:-1.1.1.1}"

PUTER_BASE_DOMAIN="${PUTER_BASE_DOMAIN:-${PUTER_DOMAIN#*.}}"
if [[ "$PUTER_BASE_DOMAIN" == "$PUTER_DOMAIN" ]]; then
  echo "ERROR: PUTER_DOMAIN must be a subdomain (example: puter.example.com)" >&2
  exit 1
fi

PUTER_SITE_DOMAIN="${PUTER_SITE_DOMAIN:-site.${PUTER_BASE_DOMAIN}}"
PUTER_HOST_DOMAIN="${PUTER_HOST_DOMAIN:-host.${PUTER_BASE_DOMAIN}}"
PUTER_APP_DOMAIN="${PUTER_APP_DOMAIN:-app.${PUTER_BASE_DOMAIN}}"
PUTER_DEV_DOMAIN="${PUTER_DEV_DOMAIN:-dev.${PUTER_BASE_DOMAIN}}"
PUTER_API_DOMAIN="${PUTER_API_DOMAIN:-api.${PUTER_BASE_DOMAIN}}"
ENABLE_PUTER_WILDCARD_ROUTES="${ENABLE_PUTER_WILDCARD_ROUTES:-0}"

ENABLE_CF_API_AUTOCONFIG="${ENABLE_CF_API_AUTOCONFIG:-1}"
CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_DNS_API_TOKEN="${CF_DNS_API_TOKEN:-}"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-}"
CF_ZONE_ID="${CF_ZONE_ID:-}"
CF_TUNNEL_ID="${CF_TUNNEL_ID:-}"
CF_ACCESS_INCLUDE_EMAILS="${CF_ACCESS_INCLUDE_EMAILS:-}"
CF_ACCESS_INCLUDE_EMAIL_DOMAINS="${CF_ACCESS_INCLUDE_EMAIL_DOMAINS:-}"
PROTECT_PUTER_SITE_DOMAIN="${PROTECT_PUTER_SITE_DOMAIN:-0}"
PROTECT_PUTER_API_DOMAIN="${PROTECT_PUTER_API_DOMAIN:-0}"

CF_API_BASE="https://api.cloudflare.com/client/v4"

cf_api_token_for_path() {
  local path="$1"
  if [[ -n "$CF_DNS_API_TOKEN" && "$path" == /zones/* ]]; then
    echo "$CF_DNS_API_TOKEN"
  else
    echo "$CF_API_TOKEN"
  fi
}

cf_api() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local response
  local bearer_token
  bearer_token="$(cf_api_token_for_path "$path")"

  if [[ -n "$data" ]]; then
    response="$(curl -fsS -X "$method" "${CF_API_BASE}${path}" \
      -H "Authorization: Bearer ${bearer_token}" \
      -H "Content-Type: application/json" \
      --data "$data")"
  else
    response="$(curl -fsS -X "$method" "${CF_API_BASE}${path}" \
      -H "Authorization: Bearer ${bearer_token}" \
      -H "Content-Type: application/json")"
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

validate_cf_api_env() {
  [[ -n "$CF_API_TOKEN" ]] || return 1
  [[ -n "$CF_ACCOUNT_ID" ]] || return 1
  [[ -n "$CF_ZONE_ID" ]] || return 1
  [[ -n "$CF_TUNNEL_ID" ]] || return 1
  return 0
}

ensure_access_policy() {
  local app_id="$1"

  if [[ -z "$CF_ACCESS_INCLUDE_EMAILS" && -z "$CF_ACCESS_INCLUDE_EMAIL_DOMAINS" ]]; then
    echo "Skipped Access policy creation (CF_ACCESS_INCLUDE_EMAILS and CF_ACCESS_INCLUDE_EMAIL_DOMAINS are empty)."
    return 0
  fi

  echo "==> Ensuring Access allow policy for app ${app_id}"
  IFS=',' read -r -a emails <<<"$CF_ACCESS_INCLUDE_EMAILS"
  IFS=',' read -r -a domains <<<"$CF_ACCESS_INCLUDE_EMAIL_DOMAINS"
  local include_json
  include_json="$({
    printf '%s\n' "${emails[@]}" | awk 'NF' | jq -R '{email:{email:.}}'
    printf '%s\n' "${domains[@]}" | sed 's/^@//' | awk 'NF' | jq -R '{email_domain:{domain:.}}'
  } | jq -s '.')"

  local policies
  if ! policies="$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/access/apps/${app_id}/policies")"; then
    return 1
  fi
  local policy_id
  policy_id="$(jq -r '.result[] | select(.name == "Allow listed emails") | .id' <<<"$policies" | head -n1)"

  local policy_payload
  policy_payload="$(jq -nc \
    --arg decision "allow" \
    --arg name "Allow listed emails" \
    --argjson include "$include_json" \
    '{decision: $decision, name: $name, include: $include}')"

  if [[ -n "$policy_id" ]]; then
    cf_api PUT "/accounts/${CF_ACCOUNT_ID}/access/apps/${app_id}/policies/${policy_id}" "$policy_payload" >/dev/null || return 1
    echo "Updated Access policy: Allow listed emails"
  else
    cf_api POST "/accounts/${CF_ACCOUNT_ID}/access/apps/${app_id}/policies" "$policy_payload" >/dev/null || return 1
    echo "Created Access policy: Allow listed emails"
  fi
}

ensure_access_app() {
  local app_name="$1"
  shift
  local domains=("$@")
  local primary_domain="${domains[0]}"
  local domains_json
  domains_json="$(printf '%s\n' "${domains[@]}" | jq -R . | jq -s .)"

  local app_payload
  app_payload="$(jq -nc \
    --arg name "$app_name" \
    --arg domain "$primary_domain" \
    --argjson domains "$domains_json" \
    '{name: $name, type: "self_hosted", domain: $domain, self_hosted_domains: $domains, session_duration: "24h"}')"

  local apps
  if ! apps="$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/access/apps")"; then
    return 1
  fi
  local app_id
  app_id="$(jq -r --arg n "$app_name" '.result[] | select(.name == $n) | .id' <<<"$apps" | head -n1)"
  if [[ -z "$app_id" ]]; then
    app_id="$(jq -r --arg d "$primary_domain" '.result[] | select(.domain == $d) | .id' <<<"$apps" | head -n1)"
  fi

  if [[ -n "$app_id" ]]; then
    cf_api PUT "/accounts/${CF_ACCOUNT_ID}/access/apps/${app_id}" "$app_payload" >/dev/null || return 1
    echo "Updated Access app: ${app_name}"
  else
    local created
    if ! created="$(cf_api POST "/accounts/${CF_ACCOUNT_ID}/access/apps" "$app_payload")"; then
      return 1
    fi
    app_id="$(jq -r '.result.id' <<<"$created")"
    [[ -n "$app_id" ]] || return 1
    echo "Created Access app: ${app_name}"
  fi

  ensure_access_policy "$app_id"
}

delete_access_app_by_domain() {
  local domain="$1"
  local apps
  if ! apps="$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/access/apps")"; then
    return 1
  fi

  local app_id
  app_id="$(jq -r --arg d "$domain" '.result[] | select(.domain == $d) | .id' <<<"$apps" | head -n1)"
  if [[ -z "$app_id" ]]; then
    echo "No Access app found for ${domain}; nothing to delete"
    return 0
  fi

  cf_api DELETE "/accounts/${CF_ACCOUNT_ID}/access/apps/${app_id}" >/dev/null || return 1
  echo "Deleted Access app for ${domain}"
}

ensure_dns_cname_record() {
  local name="$1"
  local target="${CF_TUNNEL_ID}.cfargotunnel.com"
  local list
  if ! list="$(cf_api GET "/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${name}")"; then
    return 1
  fi
  local record_id
  record_id="$(jq -r '.result[0].id // empty' <<<"$list")"

  if [[ -n "$record_id" ]]; then
    cf_api PUT "/zones/${CF_ZONE_ID}/dns_records/${record_id}" "$(jq -nc \
      --arg type "CNAME" \
      --arg name "$name" \
      --arg content "$target" \
      '{type: $type, name: $name, content: $content, proxied: true}')" >/dev/null || return 1
    echo "Updated DNS CNAME: ${name} -> ${target}"
  else
    cf_api POST "/zones/${CF_ZONE_ID}/dns_records" "$(jq -nc \
      --arg type "CNAME" \
      --arg name "$name" \
      --arg content "$target" \
      '{type: $type, name: $name, content: $content, proxied: true}')" >/dev/null || return 1
    echo "Created DNS CNAME: ${name} -> ${target}"
  fi
}

configure_cf_tunnel_and_access() {
  local hostnames
  hostnames=(
    "${PUTER_DOMAIN}"
    "${PUTER_API_DOMAIN}"
    "${PUTER_SITE_DOMAIN}"
    "${PUTER_HOST_DOMAIN}"
    "${PUTER_APP_DOMAIN}"
    "${PUTER_DEV_DOMAIN}"
  )

  if [[ "$ENABLE_PUTER_WILDCARD_ROUTES" == "1" ]]; then
    hostnames+=(
      "*.${PUTER_BASE_DOMAIN}"
      "*.${PUTER_SITE_DOMAIN}"
      "*.${PUTER_HOST_DOMAIN}"
      "*.${PUTER_APP_DOMAIN}"
      "*.${PUTER_DEV_DOMAIN}"
    )
  fi

  echo "==> Configuring Cloudflare tunnel ingress rules"
  local ingress_json
  ingress_json="$(printf '%s\n' "${hostnames[@]}" \
    | jq -R '{hostname: ., service: "http://127.0.0.1:80"}' \
    | jq -s '. + [{service: "http_status:404"}]')"

  cf_api PUT "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations" "$(jq -nc \
    --argjson ingress "$ingress_json" \
    '{config: {ingress: $ingress}}')" >/dev/null

  echo "==> Ensuring DNS records for tunnel"
  ensure_dns_cname_record "${PUTER_DOMAIN}"
  ensure_dns_cname_record "${PUTER_API_DOMAIN}"
  ensure_dns_cname_record "${PUTER_SITE_DOMAIN}"
  ensure_dns_cname_record "${PUTER_HOST_DOMAIN}"
  ensure_dns_cname_record "${PUTER_APP_DOMAIN}"
  ensure_dns_cname_record "${PUTER_DEV_DOMAIN}"

  echo "==> Ensuring Cloudflare Access applications"
  if [[ "$ENABLE_PUTER_WILDCARD_ROUTES" == "1" ]]; then
    ensure_access_app "Puter (${PUTER_DOMAIN})" "${PUTER_DOMAIN}" "*.${PUTER_BASE_DOMAIN}" || return 1
    if [[ "$PROTECT_PUTER_API_DOMAIN" == "1" ]]; then
      ensure_access_app "Puter API (${PUTER_API_DOMAIN})" "${PUTER_API_DOMAIN}" || return 1
    else
      delete_access_app_by_domain "${PUTER_API_DOMAIN}" || return 1
    fi
    if [[ "$PROTECT_PUTER_SITE_DOMAIN" == "1" ]]; then
      ensure_access_app "Puter site (${PUTER_SITE_DOMAIN})" "${PUTER_SITE_DOMAIN}" "*.${PUTER_SITE_DOMAIN}" || return 1
    else
      delete_access_app_by_domain "${PUTER_SITE_DOMAIN}" || return 1
    fi
    ensure_access_app "Puter host (${PUTER_HOST_DOMAIN})" "${PUTER_HOST_DOMAIN}" "*.${PUTER_HOST_DOMAIN}" || return 1
    ensure_access_app "Puter app (${PUTER_APP_DOMAIN})" "${PUTER_APP_DOMAIN}" "*.${PUTER_APP_DOMAIN}" || return 1
    ensure_access_app "Puter dev (${PUTER_DEV_DOMAIN})" "${PUTER_DEV_DOMAIN}" "*.${PUTER_DEV_DOMAIN}" || return 1
  else
    ensure_access_app "Puter (${PUTER_DOMAIN})" "${PUTER_DOMAIN}" || return 1
    if [[ "$PROTECT_PUTER_API_DOMAIN" == "1" ]]; then
      ensure_access_app "Puter API (${PUTER_API_DOMAIN})" "${PUTER_API_DOMAIN}" || return 1
    else
      delete_access_app_by_domain "${PUTER_API_DOMAIN}" || return 1
    fi
    if [[ "$PROTECT_PUTER_SITE_DOMAIN" == "1" ]]; then
      ensure_access_app "Puter site (${PUTER_SITE_DOMAIN})" "${PUTER_SITE_DOMAIN}" || return 1
    else
      delete_access_app_by_domain "${PUTER_SITE_DOMAIN}" || return 1
    fi
    ensure_access_app "Puter host (${PUTER_HOST_DOMAIN})" "${PUTER_HOST_DOMAIN}" || return 1
    ensure_access_app "Puter app (${PUTER_APP_DOMAIN})" "${PUTER_APP_DOMAIN}" || return 1
    ensure_access_app "Puter dev (${PUTER_DEV_DOMAIN})" "${PUTER_DEV_DOMAIN}" || return 1
  fi

  echo "==> Cloudflare API auto-config complete"
}

echo "==> Checking SSH access to Proxmox (${PVE_HOST})"
ssh -o BatchMode=yes -o ConnectTimeout=8 "root@${PVE_HOST}" "hostname >/dev/null"

echo "==> Ensuring LXC ${VMID} exists"
if ! ssh "root@${PVE_HOST}" "pct config ${VMID} >/dev/null 2>&1"; then
  ssh "root@${PVE_HOST}" "pct create ${VMID} ${CT_TEMPLATE} \
    --hostname ${CT_HOSTNAME} \
    --cores ${CT_CORES} \
    --memory ${CT_MEMORY} \
    --swap ${CT_SWAP} \
    --rootfs ${CT_STORAGE}:${CT_DISK_GB} \
    --net0 name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP} \
    --features nesting=1,keyctl=1 \
    --unprivileged 1 \
    --onboot 1 \
    --nameserver ${CT_NAMESERVER} \
    --ostype ubuntu"
else
  echo "LXC ${VMID} already exists, skipping create."
fi

echo "==> Starting LXC ${VMID}"
ssh "root@${PVE_HOST}" "pct start ${VMID} >/dev/null 2>&1 || true"
sleep 5

echo "==> Installing Docker + dependencies in LXC"
ssh "root@${PVE_HOST}" "pct exec ${VMID} -- bash -lc '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl jq docker.io docker-compose-v2
systemctl enable --now docker
'"

echo "==> Installing Puter stack (official installer)"
ssh "root@${PVE_HOST}" "pct exec ${VMID} -- bash -lc '
set -euo pipefail
mkdir -p /opt
cd /opt
PUTER_DIR=/opt/puter-selfhosted PUTER_DOMAIN=${PUTER_DOMAIN} PUTER_PORT=80 \
  curl -fsSL https://raw.githubusercontent.com/HeyPuter/puter/main/install.sh | sh
'"

echo "==> Fixing Puter healthcheck hostname"
ssh "root@${PVE_HOST}" "pct exec ${VMID} -- bash -lc '
set -euo pipefail
cd /opt/puter-selfhosted
sed -i \"s|http://puter.localhost:4100/test|http://localhost:4100/|\" docker-compose.yml
sed -i \"s|http://localhost:4100/test|http://localhost:4100/|\" docker-compose.yml
docker compose up -d puter
'"

echo "==> Forcing HTTPS upstream scheme + flat API host rewrite in nginx"
ssh "root@${PVE_HOST}" "pct exec ${VMID} -- bash -lc '
set -euo pipefail
cd /opt/puter-selfhosted/nginx
sed -i \"s|proxy_set_header X-Forwarded-Proto .*;|proxy_set_header X-Forwarded-Proto https;|g\" nginx.conf
if ! grep -q \"puter_upstream_host\" nginx.conf; then
  sed -i \"/# Rough size cap/i\\
    map \\\$host \\\$puter_upstream_host {\\
        default \\\$host;\\
        ${PUTER_API_DOMAIN} api.${PUTER_DOMAIN};\\
    }\\
\" nginx.conf
fi
sed -i \"s|proxy_set_header Host \\\$host;|proxy_set_header Host \\\$puter_upstream_host;|g\" nginx.conf
echo \"patched nginx host rewrite for flat API domain\"
cd /opt/puter-selfhosted
docker compose restart nginx
'"

echo "==> Tuning Puter trust_proxy for Cloudflare + nginx (2 hops)"
ssh "root@${PVE_HOST}" "pct exec ${VMID} -- bash -lc '
set -euo pipefail
python3 - <<\"PY\"
import json
path = \"/opt/puter-selfhosted/puter/config/config.json\"
with open(path, \"r\", encoding=\"utf-8\") as f:
    cfg = json.load(f)
cfg[\"domain\"] = \"${PUTER_DOMAIN}\"
cfg[\"protocol\"] = \"https\"
cfg[\"static_hosting_domain\"] = \"${PUTER_SITE_DOMAIN}\"
cfg[\"static_hosting_domain_alt\"] = \"${PUTER_HOST_DOMAIN}\"
cfg[\"private_app_hosting_domain\"] = \"${PUTER_APP_DOMAIN}\"
cfg[\"private_app_hosting_domain_alt\"] = \"${PUTER_DEV_DOMAIN}\"
cfg[\"api_base_url\"] = \"https://${PUTER_API_DOMAIN}\"
cfg[\"trust_proxy\"] = 2
with open(path, \"w\", encoding=\"utf-8\") as f:
    json.dump(cfg, f, indent=4)
print(\"updated domain config, api_base_url and trust_proxy=2\")
PY
docker exec -i puter node <<\"JS\"
const fs = require(\"fs\");
const path = \"/opt/puter/dist/src/backend/server.js\";
const needle = \"        this.#app = (0, express_1.default)();\";
const replacement = needle + \"\\n        this.#app.set(\\\"subdomain offset\\\", Math.max(2, String(this.#config.domain || \\\"\\\").split(\\\":\\\")[0].split(\\\".\\\").filter(Boolean).length));\";
let source = fs.readFileSync(path, \"utf8\");
let updated = false;
if (source.indexOf(\"this.#app.set(\\\"subdomain offset\\\"\") === -1) {
  if (!source.includes(needle)) {
    throw new Error(\"app initialization line not found in \" + path);
  }
  source = source.replace(needle, replacement);
  updated = true;
  console.log(\"patched Puter subdomain offset for nested main domain\");
} else {
  console.log(\"Puter subdomain offset patch already present\");
}

if (source.includes(\"if (isApiOrDav && origin) {\")) {
  source = source.replace(\"if (isApiOrDav && origin) {\", \"if (origin) {\");
  updated = true;
  console.log(\"patched Puter CORS credentials condition for flat API domain\");
} else {
  console.log(\"Puter CORS credentials condition already compatible\");
}

if (updated) {
  fs.writeFileSync(path, source);
}
JS
cd /opt/puter-selfhosted
docker compose restart puter
'"

echo "==> Skipping in-container nginx canonical redirect patch"
echo "    Recommended: add Cloudflare Redirect Rule ${PUTER_SITE_DOMAIN} -> https://${PUTER_DOMAIN}"

echo "==> Deploying cloudflared container"
ssh "root@${PVE_HOST}" "pct exec ${VMID} -- bash -lc '
set -euo pipefail
docker rm -f cloudflared-puter >/dev/null 2>&1 || true
docker run -d --name cloudflared-puter \
  --restart unless-stopped \
  --network host \
  cloudflare/cloudflared:latest \
  tunnel --no-autoupdate run --token "${CF_TUNNEL_TOKEN}"
'"

if [[ "$ENABLE_CF_API_AUTOCONFIG" == "1" ]]; then
  if validate_cf_api_env; then
    if ! configure_cf_tunnel_and_access; then
      echo "==> Cloudflare API auto-config failed; deployment completed without DNS/Access changes"
      echo "    Check CF_API_TOKEN permissions for Zone DNS and Access, or rerun with ENABLE_CF_API_AUTOCONFIG=0"
    fi
  else
    echo "==> Skipping Cloudflare API auto-config"
    echo "    To enable, set: CF_API_TOKEN, CF_ACCOUNT_ID, CF_ZONE_ID, CF_TUNNEL_ID"
  fi
fi

echo "==> Done"
echo
echo "Container info:"
ssh "root@${PVE_HOST}" "pct list | awk 'NR==1 || \$1==${VMID}'"
echo
echo "Next: verify Cloudflare Access app/policy and tunnel routing in dashboard."
echo "Recommended hostnames include:"
echo "  ${PUTER_DOMAIN}"
echo "  ${PUTER_API_DOMAIN}"
echo "  ${PUTER_SITE_DOMAIN}"
echo "  ${PUTER_HOST_DOMAIN}"
echo "  ${PUTER_APP_DOMAIN}"
echo "  ${PUTER_DEV_DOMAIN}"
if [[ "$ENABLE_PUTER_WILDCARD_ROUTES" == "1" ]]; then
  echo "Wildcard routes enabled:"
  echo "  *.${PUTER_BASE_DOMAIN}"
  echo "  *.${PUTER_SITE_DOMAIN}"
  echo "  *.${PUTER_HOST_DOMAIN}"
  echo "  *.${PUTER_APP_DOMAIN}"
  echo "  *.${PUTER_DEV_DOMAIN}"
fi
echo
echo "Cloudflare API token permissions (minimum):"
echo "  Account - Cloudflare Tunnel:Edit"
echo "  Account - Access: Apps and Policies:Edit"
echo "  Zone - DNS:Edit"
echo "  Zone - Zone:Read"
echo "  (optional) set CF_DNS_API_TOKEN to a DNS-only token when CF_API_TOKEN cannot access Zone DNS APIs"
echo
echo "Health checks (run from your admin VM):"
echo "  ssh root@${PVE_HOST} 'pct exec ${VMID} -- bash -lc \"cd /opt/puter-selfhosted && docker compose ps\"'"
echo "  ssh root@${PVE_HOST} 'pct exec ${VMID} -- bash -lc \"cd /opt/puter-selfhosted && docker compose logs --tail=80 puter\"'"
echo "  ssh root@${PVE_HOST} 'pct exec ${VMID} -- docker logs --tail=80 cloudflared-puter'"
