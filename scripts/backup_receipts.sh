#!/bin/bash
# receipts/ 외장 SSD 동기화 스크립트
# Step 48-H: 사장님이 주 1회 실행 권장
#
# 사용법:
#   ./scripts/backup_receipts.sh /Volumes/MyBackupSSD
#   ./scripts/backup_receipts.sh ~/iCloud_Drive/kream_backups
#
# 인자 없이 실행하면 가능한 외장 디스크 목록 표시

set -e

PROJECT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
RECEIPTS_DIR="${PROJECT_DIR}/receipts"
TODAY=$(date +%Y%m%d)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 색상
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== KREAM receipts/ 외장 백업 ===${NC}"
echo "프로젝트: $PROJECT_DIR"
echo "원본: $RECEIPTS_DIR"
echo ""

# receipts/ 존재 확인
if [ ! -d "$RECEIPTS_DIR" ]; then
    echo -e "${RED}❌ receipts/ 폴더가 없습니다.${NC}"
    exit 1
fi

# 파일 통계
FILE_COUNT=$(find "$RECEIPTS_DIR" -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
SIZE=$(du -sh "$RECEIPTS_DIR" 2>/dev/null | cut -f1)
echo "📊 통계: ${FILE_COUNT}개 파일 / ${SIZE}"
echo ""

# 인자 처리
if [ -z "$1" ]; then
    echo -e "${YELLOW}대상 경로를 지정해주세요.${NC}"
    echo ""
    echo "사용 가능한 외장 디스크:"
    ls -d /Volumes/* 2>/dev/null | grep -v "Macintosh HD" || echo "  (없음)"
    echo ""
    echo "iCloud Drive 경로:"
    ls -d "$HOME/Library/Mobile Documents/com~apple~CloudDocs" 2>/dev/null || echo "  (iCloud Drive 없음)"
    echo ""
    echo "사용법:"
    echo "  $0 /Volumes/MyBackupSSD"
    echo "  $0 \"$HOME/Library/Mobile Documents/com~apple~CloudDocs/kream_backups\""
    exit 1
fi

DEST_BASE="$1"
DEST_DIR="${DEST_BASE}/kream_receipts_backup"

# 대상 디스크 확인
if [ ! -d "$DEST_BASE" ]; then
    echo -e "${RED}❌ 대상 경로를 찾을 수 없음: $DEST_BASE${NC}"
    echo "외장 디스크가 연결되어 있는지 확인하세요."
    exit 1
fi

# 대상 디스크 공간 확인
DEST_FREE=$(df -h "$DEST_BASE" | tail -1 | awk '{print $4}')
echo "💾 대상 가용 공간: $DEST_FREE ($DEST_BASE)"
echo ""

# 대상 디렉토리 준비
mkdir -p "$DEST_DIR"

# rsync 실행
echo -e "${GREEN}🚀 rsync 동기화 시작...${NC}"
rsync -av --progress \
    --exclude='.DS_Store' \
    "$RECEIPTS_DIR/" \
    "$DEST_DIR/$TODAY/"

# 로그 기록
LOG_FILE="$DEST_DIR/backup_log.txt"
echo "[$TIMESTAMP] backup completed: $FILE_COUNT files, $SIZE" >> "$LOG_FILE"

echo ""
echo -e "${GREEN}✅ 백업 완료!${NC}"
echo "위치: $DEST_DIR/$TODAY/"
echo "로그: $LOG_FILE"
echo ""

# 정리 안내 (30일 이상)
OLD_COUNT=$(find "$DEST_DIR" -maxdepth 1 -type d -mtime +30 ! -path "$DEST_DIR" 2>/dev/null | wc -l | tr -d ' ')
if [ "$OLD_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}💡 30일 이상된 백업 ${OLD_COUNT}개가 있습니다.${NC}"
    echo "   정리하려면: find \"$DEST_DIR\" -maxdepth 1 -type d -mtime +30 -exec rm -rf {} +"
fi
