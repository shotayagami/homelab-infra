#!/bin/bash
# PostgreSQL 日次バックアップ。pg-db (LXC 106) 上で cron 起動。
# 出力先 /var/backups/postgresql/、保持 14 日。
#
# 注意 (2026-05-16): myappdb は drop 済み。次回更新時に DB 名リストから外すこと。

set -euo pipefail

BACKUP_DIR="/var/backups/postgresql"
DATE=$(date +%Y-%m-%d_%H%M)
RETENTION_DAYS=14
LOG_FILE="/var/log/postgresql/backup.log"

log() { echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1" | tee -a "$LOG_FILE"; }

log "Starting PostgreSQL backup"

for DB in icsdb myappdb; do
    DUMP_FILE="${BACKUP_DIR}/${DB}_${DATE}.dump"
    log "Backing up ${DB}"
    su - postgres -c "pg_dump -d ${DB} --format=custom" > "${DUMP_FILE}"
    SIZE=$(du -sh "${DUMP_FILE}" | cut -f1)
    log "  ${DB}: ${SIZE}"
done

GLOBALS_FILE="${BACKUP_DIR}/globals_${DATE}.sql"
su - postgres -c "pg_dumpall --globals-only" > "${GLOBALS_FILE}"
log "Globals backup done"

DELETED=$(find "${BACKUP_DIR}" \( -name "*.dump" -o -name "*.sql" \) -mtime +${RETENTION_DAYS} -print -delete | wc -l)
log "Cleaned up ${DELETED} old files"

TOTAL_SIZE=$(du -sh "${BACKUP_DIR}" | cut -f1)
log "Total backup: ${TOTAL_SIZE}"
log "Backup completed"
