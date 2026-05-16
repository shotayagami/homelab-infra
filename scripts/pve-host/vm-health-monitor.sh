#!/bin/bash
# vm-health-monitor.sh - VM/LXC死活監視・自動復旧
# Proxmoxホスト上で動作。設定ファイルのターゲットをpingし、連続失敗時に自動リスタートする。

set -euo pipefail

CONFIG_FILE="/etc/vm-health-monitor/targets.conf"
CHECK_INTERVAL=60
FAIL_THRESHOLD=3          # 連続失敗回数で障害判定
MAX_RESTARTS_PER_HOUR=2   # 1時間あたりの最大リスタート回数/ターゲット
LOG_FILE="/var/log/vm-health-monitor.log"
RESTART_HISTORY_DIR="/var/run/vm-health-monitor"

mkdir -p "$RESTART_HISTORY_DIR"

# fail_count連想配列 (VMID -> 連続失敗回数)
declare -A fail_counts

log_msg() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG_FILE"
    logger -t vm-health-monitor "$1"
}

get_restart_count_last_hour() {
    local vmid="$1"
    local history_file="$RESTART_HISTORY_DIR/${vmid}.restarts"
    local one_hour_ago
    one_hour_ago=$(date -d '1 hour ago' '+%s')
    local count=0

    if [ -f "$history_file" ]; then
        while IFS= read -r ts; do
            if [ "$ts" -ge "$one_hour_ago" ] 2>/dev/null; then
                count=$((count + 1))
            fi
        done < "$history_file"
    fi
    echo "$count"
}

record_restart() {
    local vmid="$1"
    local history_file="$RESTART_HISTORY_DIR/${vmid}.restarts"
    date '+%s' >> "$history_file"

    # 古いエントリを削除（24時間以上前）
    local one_day_ago
    one_day_ago=$(date -d '1 day ago' '+%s')
    if [ -f "$history_file" ]; then
        local tmp
        tmp=$(mktemp)
        while IFS= read -r ts; do
            if [ "$ts" -ge "$one_day_ago" ] 2>/dev/null; then
                echo "$ts"
            fi
        done < "$history_file" > "$tmp"
        mv "$tmp" "$history_file"
    fi
}

restart_guest() {
    local vmid="$1"
    local gtype="$2"
    local name="$3"

    local restart_count
    restart_count=$(get_restart_count_last_hour "$vmid")

    if [ "$restart_count" -ge "$MAX_RESTARTS_PER_HOUR" ]; then
        log_msg "WARNING: $name (VMID $vmid) 1時間に${restart_count}回リスタート済み。上限(${MAX_RESTARTS_PER_HOUR})到達のためスキップ"
        return
    fi

    if [ "$gtype" = "vm" ]; then
        log_msg "ACTION: $name (VM $vmid) をリセット"
        qm reset "$vmid" 2>&1 | while IFS= read -r line; do log_msg "  qm: $line"; done || true
    elif [ "$gtype" = "lxc" ]; then
        log_msg "ACTION: $name (LXC $vmid) をリスタート"
        pct restart "$vmid" 2>&1 | while IFS= read -r line; do log_msg "  pct: $line"; done || true
    fi

    record_restart "$vmid"
}

log_msg "vm-health-monitor 起動 (config=$CONFIG_FILE)"

while true; do
    while IFS=' ' read -r vmid gtype ip name; do
        # コメント行と空行をスキップ
        [[ "$vmid" =~ ^#.*$ ]] && continue
        [[ -z "$vmid" ]] && continue

        if ping -c 1 -W 3 "$ip" &>/dev/null; then
            # 復旧検出
            if [ "${fail_counts[$vmid]:-0}" -gt 0 ]; then
                log_msg "$name ($ip) 復旧 (${fail_counts[$vmid]}回失敗後)"
            fi
            fail_counts[$vmid]=0
        else
            fail_counts[$vmid]=$(( ${fail_counts[$vmid]:-0} + 1 ))
            local_count=${fail_counts[$vmid]}
            log_msg "$name ($ip) ping失敗 (${local_count}回連続)"

            if [ "$local_count" -ge "$FAIL_THRESHOLD" ]; then
                restart_guest "$vmid" "$gtype" "$name"
                fail_counts[$vmid]=0
            fi
        fi
    done < "$CONFIG_FILE"

    sleep "$CHECK_INTERVAL"
done
