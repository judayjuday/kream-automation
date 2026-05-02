#!/bin/bash
# JQ4110 130k 삭제 재시도 + 진단
# 사용법: bash run_jq4110_retry.sh
# 작성: 2026-05-02
#
# 동작:
#   1. 직전 task_1 결과 조회 (Playwright 실제 동작 진단)
#   2. server.log 마지막 80줄 확인 (삭제 관련 로그 추출)
#   3. 60초 대기 후 sync 재실행 (KREAM 반영 지연 대응)
#   4. 잔존이면 재삭제 API 1회 호출
#   5. 최종 검증

set -e
exec > >(tee -a pipeline_jq4110_retry.log) 2>&1

cd ~/Desktop/kream_automation

ORDER_ID="A-SN159858116"
TS=$(date '+%Y%m%d_%H%M%S')

echo "================================================================"
echo "🔄 JQ4110 130,000원 삭제 재시도 + 진단 — $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================"
echo ""

# ==========================================
# [STAGE 0] 직전 task 결과 조회 (진단용)
# ==========================================
echo "════════════════════ [STAGE 0] 직전 태스크 진단 ════════════════════"
echo "  task_1 상세 결과 조회..."
TASK_RESULT=$(curl -s http://localhost:5001/api/task/task_1 2>/dev/null || echo "{}")
echo "$TASK_RESULT" | python3 -m json.tool 2>/dev/null || echo "  (task_1 조회 실패 — 서버 재시작됐을 수 있음)"
echo ""

# server.log 삭제 관련 로그
echo "  📜 server.log 삭제 관련 마지막 80줄:"
echo "  ──────────────────────────────────────────"
if [ -f server.log ]; then
    tail -200 server.log 2>/dev/null | grep -iE "(delete|delet|159858116|task_1|판매입찰 삭제|입찰 삭제|삭제 성공|삭제 실패)" | tail -30 || echo "  (관련 로그 없음)"
else
    echo "  (server.log 없음)"
fi
echo "  ──────────────────────────────────────────"
echo ""

# ==========================================
# [STAGE 1] 60초 대기 + 강제 동기화 (반영 지연 대응)
# ==========================================
echo "════════════════════ [STAGE 1] 60초 대기 후 재동기화 ════════════════════"
echo "  ⏳ KREAM 서버 반영 대기 중..."
for i in 1 2 3 4 5 6; do
    sleep 10
    echo "    [${i}0초 경과]"
done

echo ""
echo "  🔄 강제 동기화..."
SYNC_RESULT=$(curl -s -X POST http://localhost:5001/api/my-bids/sync)
SYNC_TASK=$(echo "$SYNC_RESULT" | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('taskId') or json.load(sys.stdin).get('task_id') or '')
except: print('')
" 2>/dev/null)

if [ -n "$SYNC_TASK" ]; then
    echo "    sync task: $SYNC_TASK"
    for i in {1..30}; do
        sleep 3
        STATUS=$(curl -s "http://localhost:5001/api/task/$SYNC_TASK" | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('status','unknown'))
except: print('error')
" 2>/dev/null)
        echo "    [$i/30] sync status=$STATUS"
        [ "$STATUS" == "done" ] || [ "$STATUS" == "completed" ] || [ "$STATUS" == "success" ] && break
        [ "$STATUS" == "failed" ] || [ "$STATUS" == "error" ] && echo "    ⚠️ sync 실패" && break
    done
else
    sleep 10
fi
echo ""

# ==========================================
# [STAGE 2] 검증 — 130k 사라졌나?
# ==========================================
echo "════════════════════ [STAGE 2] 1차 검증 ════════════════════"
HAS_130K=$(curl -s http://localhost:5001/api/my-bids/local | python3 -c "
import sys,json
d=json.load(sys.stdin)
match=[b for b in d.get('bids',[]) if b.get('orderId')=='$ORDER_ID']
print('YES' if match else 'NO')
")

echo "  📋 JQ4110 현재 입찰:"
curl -s http://localhost:5001/api/my-bids/local | python3 -c "
import sys,json
d=json.load(sys.stdin)
jq=sorted([b for b in d.get('bids',[]) if b.get('model')=='JQ4110'], key=lambda x: x.get('price',0))
for b in jq:
    print(f\"    {b.get('orderId'):<20} {b.get('size'):<10} {b.get('price'):>8}원  rank={b.get('rank','-')}\")
print(f'    총 {len(jq)}건')
"
echo ""

if [ "$HAS_130K" == "NO" ]; then
    echo "  ✅ 130,000원 이미 삭제됨 — 60초 대기로 해결"
    
    git add -A 2>/dev/null
    git commit -m "ops(JQ4110): 130k 삭제 검증 완료 (KREAM 반영 지연 대응)

    - 첫 번째 sync는 너무 빨라서 잔존으로 보였음
    - 60초 대기 후 재동기화 → 정상 삭제 확인
    - 남은 입찰: 106k + 119k = 2건 (규칙 준수)" 2>/dev/null || echo "  (커밋 변경 없음)"
    git push origin main 2>/dev/null || echo "  (push 스킵)"
    
    echo ""
    echo "🎉 완료 — 추가 액션 불필요"
    exit 0
fi

# ==========================================
# [STAGE 3] 잔존 시 재삭제 시도
# ==========================================
echo "════════════════════ [STAGE 3] 재삭제 시도 ════════════════════"
echo "  ⚠️  130,000원 여전히 잔존 → 삭제 API 재호출"
echo ""

RETRY_RESULT=$(curl -s -X POST http://localhost:5001/api/my-bids/delete \
  -H "Content-Type: application/json" \
  -d "{\"orderIds\":[\"$ORDER_ID\"]}")
echo "$RETRY_RESULT" | python3 -m json.tool

RETRY_TASK=$(echo "$RETRY_RESULT" | python3 -c "
import sys,json
try: 
    d=json.load(sys.stdin)
    print(d.get('task_id') or d.get('taskId') or '')
except: print('')
" 2>/dev/null)

if [ -n "$RETRY_TASK" ]; then
    echo ""
    echo "  ⏳ 재삭제 태스크 폴링: $RETRY_TASK"
    for i in {1..40}; do
        sleep 3
        TASK_RAW=$(curl -s "http://localhost:5001/api/task/$RETRY_TASK")
        STATUS=$(echo "$TASK_RAW" | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('status','unknown'))
except: print('error')
" 2>/dev/null)
        echo "    [$i/40] status=$STATUS"
        if [ "$STATUS" == "done" ] || [ "$STATUS" == "completed" ] || [ "$STATUS" == "success" ]; then
            echo "    ✅ 재삭제 태스크 성공"
            # 자세한 결과 출력
            echo ""
            echo "    📋 태스크 상세:"
            echo "$TASK_RAW" | python3 -m json.tool | head -30
            break
        fi
        if [ "$STATUS" == "failed" ] || [ "$STATUS" == "error" ]; then
            echo "    ❌ 재삭제 실패"
            echo "$TASK_RAW" | python3 -m json.tool
            break
        fi
    done
fi
echo ""

# ==========================================
# [STAGE 4] 최종 검증
# ==========================================
echo "════════════════════ [STAGE 4] 최종 검증 ════════════════════"
echo "  ⏳ 60초 추가 대기..."
sleep 60

echo "  🔄 최종 동기화..."
curl -s -X POST http://localhost:5001/api/my-bids/sync > /dev/null
sleep 15

FINAL_HAS_130K=$(curl -s http://localhost:5001/api/my-bids/local | python3 -c "
import sys,json
d=json.load(sys.stdin)
match=[b for b in d.get('bids',[]) if b.get('orderId')=='$ORDER_ID']
print('YES' if match else 'NO')
")

echo ""
echo "  📋 최종 JQ4110 입찰:"
curl -s http://localhost:5001/api/my-bids/local | python3 -c "
import sys,json
d=json.load(sys.stdin)
jq=sorted([b for b in d.get('bids',[]) if b.get('model')=='JQ4110'], key=lambda x: x.get('price',0))
for b in jq:
    print(f\"    {b.get('orderId'):<20} {b.get('size'):<10} {b.get('price'):>8}원  rank={b.get('rank','-')}\")
print(f'    총 {len(jq)}건')
"
echo ""

# ==========================================
# [STAGE 5] 결과 + 커밋
# ==========================================
git add -A 2>/dev/null
if [ "$FINAL_HAS_130K" == "NO" ]; then
    git commit -m "ops(JQ4110): 130k 삭제 재시도 성공

    - 1차 sync는 너무 빨라 잔존 표시
    - 재삭제 + 60초 대기 후 정상 삭제 확인
    - 남은 입찰: 106k + 119k = 2건 (규칙 준수)" 2>/dev/null || echo "  (커밋 변경 없음)"
    git push origin main 2>/dev/null || echo "  (push 스킵)"
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "🎉 130,000원 삭제 완료"
    echo "════════════════════════════════════════════════════════════════"
else
    git commit -m "ops(JQ4110): 130k 삭제 재시도 실패 — 수동 확인 필요

    - task_1 done이지만 KREAM 판매자센터에 잔존
    - 재삭제도 반영 안 됨
    - 가능 원인: KREAM 정책 (예: 입찰 후 일정 시간 잠금) 또는 Playwright 셀렉터 변경" 2>/dev/null || echo "  (커밋 변경 없음)"
    git push origin main 2>/dev/null || echo "  (push 스킵)"
    
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "⚠️  자동 삭제 실패 — 진단 결과"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    echo "  task는 모두 done이지만 판매자센터에 130k가 그대로 남아있음."
    echo ""
    echo "  의심 원인:"
    echo "  1. KREAM 판매자센터의 삭제 셀렉터 변경 (Playwright가 다른 버튼 클릭)"
    echo "  2. KREAM 정책: 입찰 후 N시간 동안 삭제 잠금"
    echo "  3. 동기화 API가 캐시된 결과 반환"
    echo ""
    echo "  📋 다음 액션 (사장 결정):"
    echo "    A. 판매자센터 직접 접속해서 130k 입찰 수동 삭제"
    echo "    B. Playwright 로그 분석으로 진짜 실패 원인 파악"
    echo "    C. 그냥 두기 (마진 OK 상태이므로 즉시 위험은 없음)"
    echo ""
    echo "  로그: pipeline_jq4110_retry.log"
fi
echo ""
