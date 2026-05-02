#!/bin/bash
# Step 25 — sync URL 핀포인트 패치
# 진단 결과: 실제 입찰 관리 URL = /business/ask-sales
# 이 URL을 BID_URLS_FALLBACK 맨 앞에 추가

set -e
exec > >(tee -a pipeline_step25.log) 2>&1
cd ~/Desktop/kream_automation

PIPELINE_START=$(date +%s)
TS=$(date '+%Y%m%d_%H%M%S')

echo "================================================================"
echo "🚀 Step 25 Pipeline — $(date '+%Y-%m-%d %H:%M:%S')"
echo "   /business/ask-sales URL 핀포인트 패치"
echo "================================================================"
echo ""

fail_and_restore() {
    echo ""
    echo "❌ [$1] FAIL — 백업 복원"
    [ -f "kream_adjuster.py.step25_pre.bak" ] && cp "kream_adjuster.py.step25_pre.bak" kream_adjuster.py
    [ -f "kream_bot.py.step25_pre.bak" ] && cp "kream_bot.py.step25_pre.bak" kream_bot.py
    
    lsof -ti:5001 | xargs kill -9 2>/dev/null || true
    sleep 2
    nohup python3 kream_server.py > server.log 2>&1 & disown
    sleep 5
    exit 1
}

verify_server() {
    sleep 3
    local code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:5001/api/health)
    [ "$code" == "200" ] && echo "  ✅ 서버 정상" && return 0
    echo "  ❌ HTTP $code" && return 1
}

# ==========================================
# [STAGE 0] 사전 점검
# ==========================================
echo "════════════════════ [STAGE 0] 사전 점검 ════════════════════"
verify_server || fail_and_restore "사전 점검"
echo "  현재 커밋: $(git log --oneline -1)"
echo ""

# ==========================================
# [STAGE 1] 백업
# ==========================================
echo "════════════════════ [STAGE 1] 백업 ════════════════════"
[ -f kream_adjuster.py ] && cp kream_adjuster.py "kream_adjuster.py.step25_pre.bak"
[ -f kream_bot.py ] && cp kream_bot.py "kream_bot.py.step25_pre.bak"
echo "  ✅ 백업 완료"
echo ""

# ==========================================
# [STAGE 2] 작업지시서
# ==========================================
echo "════════════════════ [STAGE 2] 작업지시서 ════════════════════"

cat > "작업지시서_Step25.md" <<'MDEOF'
# 작업지시서 — Step 25: sync URL 핀포인트 패치

> 의존: Step 24 (커밋 5e45fc4)
> 진단 결과: 실제 입찰 관리 URL = /business/ask-sales (재고별 입찰 관리)

## 진단 증거 (Step 24에서 확보)

탐색 결과 다음 링크 발견:
```
"text": "재고별 입찰 관리",
"href": "https://partner.kream.co.kr/business/ask-sales"
```

기존 BID_URLS_FALLBACK 5개에 이 URL 누락.

## 작업

### kream_adjuster.py + kream_bot.py 모두 점검

1. 두 파일 모두에서 BID_URLS_FALLBACK 변수 또는 sync 함수 내 page.goto URL을 찾는다
2. https://partner.kream.co.kr/business/ask-sales 가 **첫 번째**로 시도되도록 추가
3. 이미 추가되어 있으면 스킵

권장 순서:
```python
BID_URLS_FALLBACK = [
    'https://partner.kream.co.kr/business/ask-sales',  # NEW: 진단으로 확인된 정확한 URL
    'https://partner.kream.co.kr/c2c/sell/bid',
    'https://partner.kream.co.kr/c2c/sell',
    'https://partner.kream.co.kr/c2c/bid',
    'https://partner.kream.co.kr/business/bid',
    'https://partner.kream.co.kr/c2c',
]
```

### 셀렉터 보강

`/business/ask-sales` 페이지의 입찰 행 셀렉터도 확인 필요.
다음 셀렉터를 ROW_SELECTORS 리스트 앞쪽에 추가 (없으면 스킵):

```python
ROW_SELECTORS = [
    # NEW: ask-sales 페이지 추정 셀렉터들
    '[class*="ask-sales"] tbody tr',
    '[class*="AskSales"] tbody tr',
    'div[class*="askRow"]',
    'div[class*="ask-item"]',
    # 기존
    'table tbody tr',
    '.bid-list-item',
    # ...
]
```

## 검증

1. python3 -m py_compile kream_adjuster.py
2. python3 -m py_compile kream_bot.py  
3. 서버 재시작
4. /api/my-bids/sync POST → task 폴링 → 입찰 수 확인
5. server.log [SYNC] 로그에서 어느 URL이 통했는지 확인
6. 회귀: health, capital-status, daily-summary

## 절대 규칙
- 기존 파싱 로직 변경 금지
- DB 스키마 변경 금지
- 자동 토글 ON 변경 금지

## 커밋
```
fix(Step 25): sync URL 핀포인트 패치 (/business/ask-sales)

- 진단 결과 발견된 실제 입찰 관리 URL 추가
- BID_URLS_FALLBACK 맨 앞에 우선 시도

배경: Step 24 메뉴 탐색에서 "재고별 입찰 관리" → /business/ask-sales 발견
```
MDEOF

echo "  ✅ 작업지시서 생성"
echo ""

# ==========================================
# [STAGE 3] Claude Code 호출
# ==========================================
echo "════════════════════ [STAGE 3] Claude Code 호출 ════════════════════"
echo ""

claude --dangerously-skip-permissions <<'CLAUDE_PROMPT' || fail_and_restore "Claude Code 실행"
작업지시서_Step25.md 읽고 끝까지 진행. 질문 절대 금지. 사용자 개입 요청 금지.

핵심: kream_adjuster.py와 kream_bot.py 모두에서 BID_URLS_FALLBACK 또는 입찰 페이지 URL을 찾아서 'https://partner.kream.co.kr/business/ask-sales'를 맨 앞에 추가.

순서:
1. kream_adjuster.py에서 BID_URLS_FALLBACK 또는 'partner.kream.co.kr' 패턴 검색
2. /business/ask-sales 가 이미 있으면 스킵, 없으면 리스트 맨 앞에 추가
3. kream_bot.py도 동일하게 처리
4. ROW_SELECTORS에 ask-sales 관련 셀렉터 4개 앞에 추가 (이미 있으면 스킵)

5. 문법 검증:
   python3 -m py_compile kream_adjuster.py
   python3 -m py_compile kream_bot.py

6. 서버 재시작:
   lsof -ti:5001 | xargs kill -9 || true
   sleep 2
   nohup python3 kream_server.py > server.log 2>&1 & disown
   sleep 8

7. sync 실행 + 결과 검증:
   curl -s -X POST http://localhost:5001/api/my-bids/sync
   sleep 3
   # task 추출 후 폴링
   TASK_ID=$(curl -s -X POST http://localhost:5001/api/my-bids/sync | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('taskId',''))
except: print('')
")
   for i in {1..40}; do
       sleep 3
       STATUS=$(curl -s "http://localhost:5001/api/task/$TASK_ID" | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('status',''))
except: print('')
")
       echo "[$i/40] task=$STATUS"
       [ "$STATUS" == "done" ] || [ "$STATUS" == "completed" ] || [ "$STATUS" == "success" ] && break
       [ "$STATUS" == "failed" ] || [ "$STATUS" == "error" ] && break
   done
   
   # 최종 입찰 수
   BIDS=$(curl -s http://localhost:5001/api/my-bids/local | python3 -c "
import sys,json
try: print(len(json.load(sys.stdin).get('bids',[])))
except: print(0)
")
   echo "sync 결과: $BIDS 건"

8. server.log [SYNC] 로그 확인:
   tail -200 server.log | grep "\[SYNC\]" | tail -10

9. 회귀:
   - curl -s -o /dev/null -w "%{http_code}" http://localhost:5001/api/health → 200
   - curl -s http://localhost:5001/api/capital-status | grep -q '"ok": true'
   - curl -s http://localhost:5001/api/daily-summary | grep -q '"ok": true'

10. 모두 PASS면 단일 커밋 + push:
    git add -A
    git commit -m "fix(Step 25): sync URL 핀포인트 패치 (/business/ask-sales)

    - 진단으로 발견된 실제 입찰 관리 URL 추가
    - BID_URLS_FALLBACK 맨 앞에 우선 시도
    - ROW_SELECTORS에 ask-sales 관련 셀렉터 추가

    배경: Step 24 메뉴 탐색에서 '재고별 입찰 관리' → /business/ask-sales 발견"
    git push origin main

11. 끝.

질문/확인 절대 금지. 검증 FAIL 시 즉시 종료.
CLAUDE_PROMPT

echo ""
echo "🔍 최종 검증..."
verify_server || fail_and_restore "최종 검증"

echo ""
echo "  🔄 sync 실행 + 결과 확인..."

# sync 실행
SYNC_RAW=$(curl -s -X POST http://localhost:5001/api/my-bids/sync)
SYNC_TASK=$(echo "$SYNC_RAW" | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('taskId',''))
except: print('')
" 2>/dev/null)

if [ -n "$SYNC_TASK" ]; then
    echo "    task: $SYNC_TASK"
    for i in {1..40}; do
        sleep 3
        STATUS_RAW=$(curl -s "http://localhost:5001/api/task/$SYNC_TASK")
        STATUS=$(echo "$STATUS_RAW" | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('status',''))
except: print('')
" 2>/dev/null)
        echo "    [$i/40] $STATUS"
        if [ "$STATUS" == "done" ] || [ "$STATUS" == "completed" ] || [ "$STATUS" == "success" ]; then
            echo ""
            echo "    📋 task 결과:"
            echo "$STATUS_RAW" | python3 -m json.tool 2>/dev/null | head -30
            break
        fi
        [ "$STATUS" == "failed" ] || [ "$STATUS" == "error" ] && echo "    ❌ 실패" && break
    done
fi

sleep 3
NEW_BIDS=$(curl -s http://localhost:5001/api/my-bids/local | python3 -c "
import sys,json
try: print(len(json.load(sys.stdin).get('bids',[])))
except: print('ERROR')
" 2>/dev/null)
echo ""
echo "  📊 sync 후 입찰: ${NEW_BIDS}건"

echo ""
echo "  📜 [SYNC] 로그:"
tail -300 server.log 2>/dev/null | grep "\[SYNC\]" | tail -10 || echo "    (로그 없음)"

# rank 분석
if [ "${NEW_BIDS:-0}" -gt 0 ]; then
    echo ""
    echo "  📊 rank 분포:"
    curl -s http://localhost:5001/api/my-bids/rank-changes | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(f\"    총 {d.get('total_bids')}건 / 1위 {d.get('rank_1_count',0)}건 / 밀린 {d.get('rank_lost_count',0)}건\")
except: pass
" 2>/dev/null
fi

FINAL_HASH=$(git log -1 --format=%h)
echo ""
echo "  ✅ 커밋: $FINAL_HASH"
echo ""

# ==========================================
# [STAGE 4] 컨텍스트 v19
# ==========================================
echo "════════════════════ [STAGE 4] 컨텍스트 v19 ════════════════════"

if [ "${NEW_BIDS:-0}" -gt 0 ]; then
    SUMMARY="✅ 복구 성공 — ${NEW_BIDS}건 sync"
else
    SUMMARY="⚠️ 여전히 0건 — 진짜 입찰 0건이거나 추가 디버깅 필요"
fi

PA_PENDING=$(sqlite3 price_history.db "SELECT COUNT(*) FROM price_adjustments WHERE status='pending'" 2>/dev/null || echo "?")

cat > "다음세션_시작_컨텍스트_v19.md" <<MDEOF
# 다음 세션 시작 컨텍스트 v19

> 작성일: $(date '+%Y-%m-%d %H:%M:%S') (자동 생성)
> 직전 커밋: $(git log -1 --format='%h %s')

## 1. Step 25 sync 복구 결과

- $SUMMARY
- 진단으로 찾은 URL: /business/ask-sales

## 2. 누적

| Step | 커밋 | 핵심 |
|---|---|---|
| 18-24 | ff97377 → 5e45fc4 | 인프라 + 진단 도구 |
| **25** | **$FINAL_HASH** | URL 핀포인트 패치 |

## 3. DB 현황

| 테이블 | 건수 |
|---|---|
| pa_pending | $PA_PENDING |
| 활성 입찰 | ${NEW_BIDS:-?} |

## 4. 다음 작업

$([ "${NEW_BIDS:-0}" -gt 0 ] && echo "### 정상 복구 — 누적된 도구들 의미 있게 동작 시작
- 자본 카드 갱신, cleanup/diagnose 의미 있는 수치
- Step 26: 재고별 입찰 관리 페이지 추가 데이터 추출 (예: 재고 수량)" || echo "### 추가 디버깅 필요
- diagnostics/ 폴더 sync_page_*.png 직접 확인
- /business/ask-sales 페이지 구조 분석
- 또는 사장이 판매자센터 직접 접속해서 입찰 메뉴 화면 캡처")

## 5. 다음 채팅 첫 메시지

\`\`\`
다음세션_시작_컨텍스트_v19.md 읽고 현재 상태 파악.
sync 결과: ${NEW_BIDS:-0}건

오늘 작업: [기획 / 구체 지시]
\`\`\`

## 6. 절대 규칙

7대 규칙 + 자동 토글 ON 금지.
MDEOF

echo "  ✅ 다음세션_시작_컨텍스트_v19.md 생성"
git add 다음세션_시작_컨텍스트_v19.md pipeline_step25.log 2>/dev/null
git commit -m "docs: 다음세션 컨텍스트 v19 (Step 25)" 2>/dev/null || echo "  (변경 없음)"
git push origin main 2>/dev/null || echo "  (push 스킵)"
echo ""

PIPELINE_END=$(date +%s)
ELAPSED=$((PIPELINE_END - PIPELINE_START))

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🎉 Step 25 완료 — ${ELAPSED}초"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "결과: $SUMMARY"
echo ""
echo "📜 로그: pipeline_step25.log"
echo ""
