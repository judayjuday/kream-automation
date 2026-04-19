#!/bin/bash
# KREAM 자동화 DB 일일 백업 스크립트
# - sqlite3 .backup 명령 사용 (안전한 핫 백업)
# - 7일 이상 된 백업 자동 삭제
# - 성공/실패 로그 기록

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB_FILE="$SCRIPT_DIR/price_history.db"
BACKUP_DIR="$HOME/Desktop/kream_backups"
LOG_FILE="$SCRIPT_DIR/backup.log"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="$BACKUP_DIR/price_history_${TIMESTAMP}.db"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo "$1"
}

# 백업 디렉토리 확인
if [ ! -d "$BACKUP_DIR" ]; then
    mkdir -p "$BACKUP_DIR"
    if [ $? -ne 0 ]; then
        log "FAIL: 백업 디렉토리 생성 실패: $BACKUP_DIR"
        exit 1
    fi
fi

# 디스크 용량 체크 (최소 100MB)
AVAIL_KB=$(df -k "$BACKUP_DIR" | tail -1 | awk '{print $4}')
if [ "$AVAIL_KB" -lt 102400 ] 2>/dev/null; then
    log "FAIL: 디스크 용량 부족 (${AVAIL_KB}KB 남음)"
    exit 1
fi

# DB 파일 존재 확인
if [ ! -f "$DB_FILE" ]; then
    log "FAIL: DB 파일 없음: $DB_FILE"
    exit 1
fi

# sqlite3 .backup 명령으로 안전한 백업
sqlite3 "$DB_FILE" ".backup '$BACKUP_FILE'"
if [ $? -ne 0 ]; then
    log "FAIL: sqlite3 .backup 실패"
    rm -f "$BACKUP_FILE"
    exit 1
fi

# 백업 파일 크기 확인
BACKUP_SIZE=$(ls -lh "$BACKUP_FILE" | awk '{print $5}')
log "OK: 백업 완료 → $BACKUP_FILE ($BACKUP_SIZE)"

# 7일 이상 된 백업 삭제
DELETED=$(find "$BACKUP_DIR" -name "price_history_*.db" -mtime +7 -print -delete 2>/dev/null | wc -l | tr -d ' ')
if [ "$DELETED" -gt 0 ]; then
    log "INFO: 오래된 백업 ${DELETED}건 삭제"
fi

exit 0
