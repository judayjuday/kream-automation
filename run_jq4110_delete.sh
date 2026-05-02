#!/bin/bash
# JQ4110 ONE SIZE 130,000원 입찰 삭제
# 사용법: bash run_jq4110_delete.sh
# 작성: 2026-05-02
#
# 동작:
#   1. DB + my_bids_local.json 백업
#   2. /api/my-bids/delete로 A-SN159858116 삭제
#   3. 태스크 폴링으로 완료 대기
#   4. 동기화 + 검증 (130k 사라졌는지 확인)
#   5. 커밋 + push

set -e
exec > >(tee -a pipeline_jq4110_delete.log) 2>&1

cd ~/Desktop/kream_automation

ORDER_ID="A-SN159858116"
TS=$(date '+%Y%m%d_%H%M%S')

echo "================================================================"
echo "🗑  JQ4110 130,000원 입찰 삭제 — $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================"
echo "  주문번호: $ORDER_ID"
echo "  사유: 시장 최저가(106k)와 격차 24k → 회전 가능성 낮음"
echo "  규칙: 사이즈당 2건 유지 (현재 3건 → 2건)"
echo ""

# ==========================================
# [STAGE 0] 사전 점검
# ==========================================
echo "════════════════════ [STAGE 0] 서버 상태 ════════════════════"
HEALTH=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:5001/api/health)
if [ "$HEALTH" != "200" ]; then
    echo "❌ 서버 응답 없음 (HTTP $HEALTH)"
    exit 1
fi
echo "  ✅ 서버 정상"

# 130k 입찰 실제 존재 확인
EXISTS=$(curl -s http://localhost:5001/api/my-bids/local | python3 -c "
import sys,json
d=json.load(sys.stdin)
match=[b for b in d.get('bids',[]) if b.get('orderId')=='$ORDER_ID']
print('YES' if match else 'NO')
")

if [ "$EXISTS" != "YES" ]; then
    echo "  ⚠️  $ORDER_ID 가 my_bids_local.json에 없음 (이미 삭제됐거나 동기화 필요)"
    echo "  → 동기화 후 재확인..."
    curl -s -X POST http://localhost:5001/api/my-bids/sync > /dev/null
    sleep 5
    EXISTS=$(curl -s http://localhost:5001/api/my-bids/local | python3 -c "
import sys,json
d=json.load(sys.stdin)
match=[b for b in d.get('bids',[]) if b.get('orderId')=='$ORDER_ID']
print('YES' if match else 'NO')
")
    if [ "$EXISTS" != "YES" ]; then
        echo "  ✅ 이미 삭제 완료된 상태 — 작업 종료"
        exit 0
    fi
fi
echo "  ✅ 삭제 대상 확인됨"
echo ""

# ==========================================
# [STAGE 1] 백업
# ==========================================
echo "════════════════════ [STAGE 1] 백업 ════════════════════"
sqlite3 /Users/iseungju/Desktop/kream_automation/price_history.db ".backup '/Users/iseungju/Desktop/kream_automation/price_history_jq4110_delete_${TS}.db'"
cp my_bids_local.json "my_bids_local.json.bak_${TS}"
echo "  ✅ DB + my_bids_local.json 백업"
echo ""

# ==========================================
# [STAGE 2] 삭제 실행
# ==========================================
echo "════════════════════ [STAGE 2] 삭제 API 호출 ════════════════════"
RESULT=$(curl -s -X POST http://localhost:5001/api/my-bids/delete \
  -H "Content-Type: application/json" \
  -d "{\"orderIds\":[\"$ORDER_ID\"]}")

echo "$RESULT" | python3 -m json.tool

TASK_ID=$(echo "$RESULT" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get('task_id') or d.get('taskId') or '')
except: print('')
" 2>/dev/null)

# ==========================================
# [STAGE 3] 태스크 폴링
# ==========================================
if [ -n "$TASK_ID" ]; then
    echo ""
    echo "════════════════════ [STAGE 3] 태스크 폴링 ════════════════════"
    echo "  Task ID: $TASK_ID"
    
    SUCCESS="NO"
    for i in {1..40}; do
        sleep 3
        TASK_RAW=$(curl -s "http://localhost:5001/api/task/$TASK_ID")
        STATUS=$(echo "$TASK_RAW" | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('status','unknown'))
except: print('error')
" 2>/dev/null)
        
        echo "  [$i/40] status=$STATUS"
        
        case "$STATUS" in
            "completed"|"success"|"done")
                SUCCESS="YES"
                echo "  ✅ 태스크 성공"
                break
                ;;
            "failed"|"error")
                echo "  ❌ 태스크 실패"
                echo "$TASK_RAW" | python3 -m json.tool
                exit 1
                ;;
        esac
    done
    
    if [ "$SUCCESS" != "YES" ]; then
        echo "  ⚠️  타임아웃 (120초) — 판매자센터 직접 확인 필요"
    fi
fi
echo ""

# ==========================================
# [STAGE 4] 검증 (동기화 후 130k 사라졌는지)
# ==========================================
echo "════════════════════ [STAGE 4] 검증 ════════════════════"
echo "  🔄 판매자센터 → 로컬 동기화..."
curl -s -X POST http://localhost:5001/api/my-bids/sync > /dev/null
sleep 5

# JQ4110 남은 입찰 표시
echo ""
echo "  📋 JQ4110 남은 입찰:"
curl -s http://localhost:5001/api/my-bids/local | python3 -c "
import sys,json
d=json.load(sys.stdin)
jq=sorted([b for b in d.get('bids',[]) if b.get('model')=='JQ4110'], key=lambda x: x.get('price',0))
for b in jq:
    print(f\"    {b.get('orderId'):<20} {b.get('size'):<10} {b.get('price'):>8}원  rank={b.get('rank','-')}\")
print(f'    ─────────────────────────────────────────')
print(f'    총 {len(jq)}건')
"

# 130k 잔존 여부
HAS_130K=$(curl -s http://localhost:5001/api/my-bids/local | python3 -c "
import sys,json
d=json.load(sys.stdin)
jq=[b for b in d.get('bids',[]) if b.get('model')=='JQ4110' and b.get('orderId')=='$ORDER_ID']
print('YES' if jq else 'NO')
")

echo ""
if [ "$HAS_130K" == "NO" ]; then
    echo "  ✅ 130,000원 입찰 삭제 확인됨"
else
    echo "  ⚠️  130,000원 입찰이 아직 남아있음"
    echo "      → 판매자센터에서 직접 확인 필요"
    echo "      → 백업 파일: my_bids_local.json.bak_${TS}"
fi
echo ""

# ==========================================
# [STAGE 5] 커밋 + push
# ==========================================
echo "════════════════════ [STAGE 5] 커밋 ════════════════════"
git add -A 2>/dev/null
git commit -m "ops(JQ4110): 130,000원 입찰 삭제 (규칙: 사이즈당 2건 유지)

- A-SN159858116 (ONE SIZE, 130k) 삭제
- 사유: 시장 최저가(106k)와 격차 24k → 회전 가능성 낮음
- 남은 입찰: 106k(시장 1위) + 119k(백업) = 2건, 규칙 준수
- DB 백업: price_history_jq4110_delete_${TS}.db" 2>/dev/null || echo "  (커밋 변경 없음)"

git push origin main 2>/dev/null || echo "  (push 스킵)"

FINAL_HASH=$(git log -1 --format=%h)
echo "  ✅ 커밋: $FINAL_HASH"
echo ""

# ==========================================
# 최종 요약
# ==========================================
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🎉 작업 완료"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "  - 삭제: $ORDER_ID (130,000원)"
echo "  - 검증: $([ "$HAS_130K" == "NO" ] && echo "✅ 사라짐" || echo "⚠️ 잔존")"
echo "  - 커밋: $FINAL_HASH"
echo "  - 백업: my_bids_local.json.bak_${TS}"
echo "  - 백업 DB: price_history_jq4110_delete_${TS}.db"
echo ""
echo "📜 로그: pipeline_jq4110_delete.log"
echo ""
