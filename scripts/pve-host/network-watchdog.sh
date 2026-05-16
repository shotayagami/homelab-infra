#!/bin/bash
# network-watchdog.sh - NIC障害検知・段階的自動復旧
# Proxmoxホスト用。ゲートウェイと外部DNSにpingし、連続失敗時にエスカレーション復旧を試みる。

set -euo pipefail

GATEWAY="192.168.11.1"
EXTERNAL_DNS="8.8.8.8"
NIC="eno1"
CHECK_INTERVAL=30
LOG_FILE="/var/log/network-watchdog.log"
REBOOT_REASON_FILE="/var/log/network-watchdog-reboot-reason"

# エスカレーション閾値（連続失敗回数）
LEVEL1_THRESHOLD=3   # NICリンクリセット
LEVEL2_THRESHOLD=6   # networking再起動
LEVEL3_THRESHOLD=12  # ホスト再起動

fail_count=0

log_msg() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG_FILE"
    logger -t network-watchdog "$1"
}

check_network() {
    # ゲートウェイと外部DNSの両方にping（どちらか1つ通ればOK）
    if ping -c 1 -W 3 "$GATEWAY" &>/dev/null || ping -c 1 -W 3 "$EXTERNAL_DNS" &>/dev/null; then
        return 0
    fi
    return 1
}

level1_recovery() {
    log_msg "LEVEL1: NICリンクリセット実行 (fail_count=$fail_count)"
    ip link set "$NIC" down
    sleep 2
    ip link set "$NIC" up
    sleep 5
}

level2_recovery() {
    log_msg "LEVEL2: networking再起動実行 (fail_count=$fail_count)"
    systemctl restart networking
    sleep 10
}

level3_recovery() {
    log_msg "LEVEL3: ホスト再起動実行 (fail_count=$fail_count)"
    echo "$(date '+%Y-%m-%d %H:%M:%S') network-watchdog: $fail_count回連続失敗によりリブート" >> "$REBOOT_REASON_FILE"
    sync
    systemctl reboot
}

log_msg "network-watchdog 起動 (gateway=$GATEWAY, external=$EXTERNAL_DNS, nic=$NIC)"

while true; do
    if check_network; then
        if [ "$fail_count" -gt 0 ]; then
            log_msg "ネットワーク復旧 (${fail_count}回失敗後)"
            fail_count=0
        fi
    else
        fail_count=$((fail_count + 1))
        log_msg "ping失敗 ($fail_count回連続)"

        if [ "$fail_count" -eq "$LEVEL1_THRESHOLD" ]; then
            level1_recovery
        elif [ "$fail_count" -eq "$LEVEL2_THRESHOLD" ]; then
            level2_recovery
        elif [ "$fail_count" -ge "$LEVEL3_THRESHOLD" ]; then
            level3_recovery
            # rebootが実行されるためここには到達しないが念のため
            break
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
