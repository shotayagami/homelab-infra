#!/bin/bash
# step-ca が発行する PEM cert を Technitium DNS が読める PFX に再パッケージし、
# dns.service を再起動する。step ca renew の --exec フックから呼ばれる前提。
# hostname (dns / dns2) を見て対応する cert / pfx を扱う。
set -euo pipefail

HOST="$(hostname)"
CRT="/etc/ssl/step/${HOST}.crt"
KEY="/etc/ssl/step/${HOST}.key"
PFX="/etc/dns/certs/${HOST}.pfx"
PASS_FILE="/root/.dns-cert-password"

PASS=$(grep -oP '(?<=DNS_CERT_PASSWORD=).+' "$PASS_FILE")

# 原子的入れ替え: 同一ディレクトリ内で mktemp → rename
TMP=$(mktemp -p /etc/dns/certs ".${HOST}.pfx.new.XXXXXX")
trap 'rm -f "$TMP"' EXIT

openssl pkcs12 -export \
  -out "$TMP" \
  -inkey "$KEY" \
  -in "$CRT" \
  -name "${HOST}.home.yagamin.net" \
  -passout "pass:$PASS"
chmod 600 "$TMP"
mv "$TMP" "$PFX"
trap - EXIT

systemctl restart dns
