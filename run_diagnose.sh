#!/bin/bash
# 데이터 정합성 진단 - 5분 안에 끝
# 1. my_bids_local.json 상태
# 2. sync 실제 동작 여부
# 3. bid_cost ↔ sales_history 매칭 분석
# 4. 결과는 진단 리포트로 저장 (수정 X, 진단 O)

set -e
exec > >(tee -a pipeline_diagnose.log) 2>&1
cd ~/Desktop/kream_automation

TS=$(date '+%Y%m%d_%H%M%S')

echo "================================================================"
echo "🔍 데이터 정합성 진단 — $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================"
echo ""

# ==========================================
# [1] my_bids_local.json 상태
# ==========================================
echo "════════════════════ [1] my_bids_local.json ════════════════════"

if [ -f my_bids_local.json ]; then
    SIZE=$(wc -c < my_bids_local.json)
    LINES=$(wc -l < my_bids_local.json)
    MTIME=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" my_bids_local.json)
    echo "  파일 크기: ${SIZE} bytes"
    echo "  수정 시각: ${MTIME}"
    echo "  라인 수: ${LINES}"
    
    BID_COUNT=$(python3 -c "
import json
try:
    with open('my_bids_local.json') as f:
        d = json.load(f)
    bids = d.get('bids', [])
    print(len(bids))
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null)
    echo "  bids 배열 길이: ${BID_COUNT}"
    
    if [ "${BID_COUNT}" == "0" ]; then
        echo "  ⚠️  bids가 0건 — sync 실패 또는 캐시 손상 가능성"
    fi
    
    # 마지막 sync 시각
    LAST_SYNC=$(python3 -c "
import json
try:
    with open('my_bids_local.json') as f:
        d = json.load(f)
    print(d.get('last_sync') or d.get('updated_at') or 'NONE')
except: print('ERROR')
" 2>/dev/null)
    echo "  last_sync: ${LAST_SYNC}"
else
    echo "  ❌ my_bids_local.json 파일 없음"
fi
echo ""

# ==========================================
# [2] sync 실제 호출
# ==========================================
echo "════════════════════ [2] 강제 sync 시도 ════════════════════"
echo "  현재 상태에서 /api/my-bids/sync 호출..."

SYNC_RAW=$(curl -s -X POST http://localhost:5001/api/my-bids/sync)
echo "$SYNC_RAW" | python3 -m json.tool 2>/dev/null | head -10

SYNC_TASK=$(echo "$SYNC_RAW" | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('taskId') or json.load(sys.stdin).get('task_id') or '')
except: print('')
" 2>/dev/null)

if [ -n "$SYNC_TASK" ]; then
    echo ""
    echo "  ⏳ sync task 폴링: $SYNC_TASK"
    for i in {1..40}; do
        sleep 3
        STATUS_RAW=$(curl -s "http://localhost:5001/api/task/$SYNC_TASK")
        STATUS=$(echo "$STATUS_RAW" | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('status','unknown'))
except: print('error')
" 2>/dev/null)
        echo "    [$i/40] status=$STATUS"
        case "$STATUS" in
            "done"|"completed"|"success")
                echo ""
                echo "  📋 태스크 결과:"
                echo "$STATUS_RAW" | python3 -m json.tool 2>/dev/null | head -30
                break
                ;;
            "failed"|"error")
                echo ""
                echo "  ❌ sync 실패"
                echo "$STATUS_RAW" | python3 -m json.tool 2>/dev/null | head -30
                break
                ;;
        esac
    done
fi

# sync 후 다시 확인
echo ""
echo "  📊 sync 후 my_bids_local.json:"
sleep 3
NEW_COUNT=$(python3 -c "
import json
try:
    with open('my_bids_local.json') as f:
        d = json.load(f)
    bids = d.get('bids', [])
    print(len(bids))
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null)
echo "    bids 배열 길이: ${NEW_COUNT}"

NEW_RANK=$(curl -s http://localhost:5001/api/my-bids/rank-changes | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(f\"total={d.get('total_bids',0)} rank_lost={d.get('rank_lost_count',0)}\")
except: print('ERROR')
" 2>/dev/null)
echo "    /api/my-bids/rank-changes: ${NEW_RANK}"
echo ""

# ==========================================
# [3] bid_cost ↔ sales_history 매칭 분석
# ==========================================
echo "════════════════════ [3] bid_cost ↔ sales_history 매칭 ════════════════════"

python3 <<'PYEOF'
import sqlite3
DB = '/Users/iseungju/Desktop/kream_automation/price_history.db'
conn = sqlite3.connect(DB)
c = conn.cursor()

# bid_cost 통계
c.execute("SELECT COUNT(*) FROM bid_cost")
bc_total = c.fetchone()[0]
c.execute("SELECT COUNT(DISTINCT order_id) FROM bid_cost")
bc_unique = c.fetchone()[0]
print(f"  bid_cost: 총 {bc_total}행 / order_id 고유 {bc_unique}개")

# sales_history 통계
c.execute("SELECT COUNT(*) FROM sales_history")
sh_total = c.fetchone()[0]
c.execute("SELECT COUNT(DISTINCT order_id) FROM sales_history WHERE order_id IS NOT NULL")
sh_unique = c.fetchone()[0]
print(f"  sales_history: 총 {sh_total}행 / order_id 고유 {sh_unique}개")

# 매칭 분석
c.execute("""
    SELECT s.order_id, s.model, s.size, s.sale_price, s.trade_date,
           CASE WHEN b.order_id IS NOT NULL THEN 'matched' ELSE 'unmatched' END as match_status
    FROM sales_history s
    LEFT JOIN bid_cost b ON s.order_id = b.order_id
    ORDER BY s.trade_date DESC
""")
rows = c.fetchall()

matched = [r for r in rows if r[5] == 'matched']
unmatched = [r for r in rows if r[5] == 'unmatched']

print(f"\n  매칭: {len(matched)}건 / 미매칭: {len(unmatched)}건")
print(f"\n  미매칭 sales (bid_cost 누락):")
for r in unmatched[:10]:
    oid = r[0] or 'NULL'
    print(f"    {oid:<25} {r[1]:<15} {r[2] or '-':<10} {r[3]:>8}원  {r[4]}")

# bid_cost 입찰 내역 일부 (참고)
print(f"\n  bid_cost 샘플 (최근 5건):")
c.execute("SELECT order_id, model, size, cny_price FROM bid_cost ORDER BY rowid DESC LIMIT 5")
for r in c.fetchall():
    print(f"    {r[0]:<25} {r[1]:<15} {r[2] or '-':<10} CNY {r[3] or '-'}")

conn.close()
PYEOF

echo ""

# ==========================================
# [4] 결론
# ==========================================
echo "════════════════════ [4] 진단 결론 ════════════════════"

if [ "${NEW_COUNT:-0}" == "0" ] || [ "${NEW_COUNT}" == "ERROR" ]; then
    echo "  🔴 sync 후에도 my_bids_local.json 비어있음"
    echo "     → 판매자센터 sync 자체가 깨졌거나 인증 문제"
    echo "     → 판매자센터 직접 접속해서 입찰 51건 그대로 있는지 확인 필요"
elif [ "${NEW_COUNT:-0}" -gt 0 ]; then
    echo "  ✅ sync 정상 — 입찰 ${NEW_COUNT}건 복구됨"
    echo "     → Step 22 시작 시점에 일시적으로 캐시 비어있었던 것"
fi

echo ""
echo "  📋 데이터 정합성 권장 액션:"
echo "    A. sync 결과에 따라 후속 결정"
echo "    B. bid_cost 미매칭 sales 건 진단 — order_id 형식 다른지 확인"
echo "    C. 미매칭이 정상이면 (구매대행 모델에서 다른 데이터로 매칭해야 하는지) 매칭 키 재설계"
echo ""
echo "📜 진단 로그: pipeline_diagnose.log"
echo ""
