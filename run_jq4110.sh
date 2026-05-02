#!/bin/bash
# JQ4110 자동 파이프라인 — 한 번 실행으로 끝까지
# 사용법: bash run_jq4110.sh
# 작성: 2026-05-02
#
# 동작:
#   1. JQ4110 현재 상태 자동 진단 (사이즈/입찰/카테고리/gosi)
#   2. ONE SIZE / 사이즈별 시나리오 자동 분기
#   3. Claude Code 자동 호출 — bid_cost 누락 확인 + 마진 계산 + 중복 검증 + 모니터링
#   4. 검증 → 실패 시 백업 자동 복원
#   5. PASS 시 커밋 + push
#   6. 다음세션 컨텍스트 v8 자동 생성
#
# 사용자 개입: 없음. 끝나면 jq4110_report_*.json 확인.

set -e
exec > >(tee -a pipeline_jq4110.log) 2>&1

cd ~/Desktop/kream_automation

PIPELINE_START=$(date +%s)
TS=$(date '+%Y%m%d_%H%M%S')

echo "================================================================"
echo "🚀 JQ4110 Pipeline 시작 — $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================"
echo ""

# ==========================================
# 공통 함수
# ==========================================
fail_and_restore() {
    local stage=$1
    echo ""
    echo "❌ [$stage] FAIL — 백업 복원"
    [ -f "kream_server.py.jq4110_pre.bak" ] && cp "kream_server.py.jq4110_pre.bak" kream_server.py
    [ -f "kream_bot.py.jq4110_pre.bak" ] && cp "kream_bot.py.jq4110_pre.bak" kream_bot.py
    
    echo "🔄 서버 재시작..."
    lsof -ti:5001 | xargs kill -9 2>/dev/null || true
    sleep 2
    nohup python3 kream_server.py > server.log 2>&1 & disown
    sleep 5
    
    echo "❌ Pipeline 중단 — $stage 단계 실패"
    echo "📋 진행 로그: pipeline_jq4110.log"
    exit 1
}

verify_server() {
    sleep 5
    local code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:5001/api/health)
    if [ "$code" != "200" ]; then
        echo "❌ 서버 응답 없음 (HTTP $code)"
        return 1
    fi
    echo "✅ 서버 응답 정상"
    return 0
}

# ==========================================
# [STAGE 0] 사전 진단
# ==========================================
echo "════════════════════ [STAGE 0] 사전 진단 ════════════════════"

# 서버 살아있는지
verify_server || fail_and_restore "사전 진단"

# 현재 커밋
echo "  현재 커밋: $(git log --oneline -1)"

# 자동 토글 OFF 확인
AUTO_ADJUST=$(curl -s http://localhost:5001/api/settings 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('auto_adjust_enabled', '?'))" 2>/dev/null || echo "?")
echo "  자동 조정: $AUTO_ADJUST (False여야 안전)"

# JQ4110 현황 수집
JQ_RAW=$(curl -s http://localhost:5001/api/my-bids/local)
JQ_COUNT=$(echo "$JQ_RAW" | python3 -c "
import sys,json
d=json.load(sys.stdin)
bids=[b for b in d.get('bids',[]) if b.get('model')=='JQ4110']
print(len(bids))
")
JQ_SIZES=$(echo "$JQ_RAW" | python3 -c "
import sys,json
d=json.load(sys.stdin)
bids=[b for b in d.get('bids',[]) if b.get('model')=='JQ4110']
print(','.join(sorted(set(b.get('size','-') for b in bids))) if bids else 'NONE')
")

echo "  JQ4110 입찰: ${JQ_COUNT}건"
echo "  사이즈: ${JQ_SIZES}"

# 시나리오 분기
if [ "$JQ_SIZES" == "ONE SIZE" ]; then
    SCENARIO="ONE_SIZE"
    echo "  📌 시나리오: ONE_SIZE (사이즈별 입찰 불가, 현재 입찰 관리)"
elif [ "$JQ_SIZES" == "NONE" ]; then
    SCENARIO="NO_BIDS"
    echo "  📌 시나리오: NO_BIDS (입찰 없음 — 신규 등록 필요)"
else
    SCENARIO="MULTI_SIZE"
    echo "  📌 시나리오: MULTI_SIZE (사이즈별 관리)"
fi
echo ""

# ==========================================
# [STAGE 1] 백업
# ==========================================
echo "════════════════════ [STAGE 1] 백업 ════════════════════"
cp kream_server.py "kream_server.py.jq4110_pre.bak"
cp kream_bot.py "kream_bot.py.jq4110_pre.bak"
sqlite3 /Users/iseungju/Desktop/kream_automation/price_history.db ".backup '/Users/iseungju/Desktop/kream_automation/price_history_jq4110_${TS}.db'"
echo "  ✅ 백업 완료"
echo ""

# ==========================================
# [STAGE 2] 작업지시서 생성
# ==========================================
echo "════════════════════ [STAGE 2] 작업지시서 ════════════════════"

cat > "작업지시서_JQ4110_${SCENARIO}.md" <<MDEOF
# 작업지시서 — JQ4110 ${SCENARIO} 시나리오

> 작성: ${TS} (자동 생성)
> 모델: JQ4110 — (W) 아디다스 오즈가이아 트리플 블랙
> 시나리오: ${SCENARIO}
> 현재 입찰: ${JQ_COUNT}건, 사이즈: ${JQ_SIZES}

## 환경 제약
- 맥북(해외)에서 실행 중
- kream.co.kr 차단 → 시장 가격 신규 수집 불가
- partner.kream.co.kr만 접속 가능 → 입찰 관리는 가능
- 가격 수집 필요한 작업은 SKIP하고 사유 기록

## 절대 규칙 (CLAUDE.md)
1. 원가 없으면 NULL (가짜 값 금지)
2. 판매 완료 건 수정/삭제 금지
3. price_history.db DROP/DELETE 금지
4. auth_state.json 백업 없이 덮어쓰기 금지
5. git push -f, git reset --hard 금지
6. 테스트 데이터로 실제 입찰 금지
7. 자동 토글 ON 변경 금지 (현재 OFF 유지)

## 진행 작업

### 작업 #1: JQ4110 입찰 종합 진단
\`\`\`python
# Python으로 sqlite3 + my_bids_local.json 분석
import sqlite3, json
from pathlib import Path

mybids = json.loads(Path('my_bids_local.json').read_text())
jq = [b for b in mybids.get('bids', []) if b.get('model') == 'JQ4110']

conn = sqlite3.connect('price_history.db')
c = conn.cursor()

result = {
    'model': 'JQ4110',
    'scenario': '${SCENARIO}',
    'bids': [],
    'missing_cost': [],
    'duplicates_by_size': {},
    'margin_analysis': []
}

# 사이즈별 그룹화 (중복 검증)
from collections import defaultdict
by_size = defaultdict(list)
for b in jq:
    by_size[b.get('size')].append(b)

for size, bids in by_size.items():
    if len(bids) > 2:  # 규칙: 사이즈당 2건
        result['duplicates_by_size'][size] = {
            'count': len(bids),
            'bids': sorted(bids, key=lambda x: -x.get('price', 0)),
            'recommendation': f'가장 비싼 {len(bids)-2}건 삭제 권장 (사용자 확인 후 실행)'
        }

# bid_cost 누락 확인
for b in jq:
    oid = b.get('orderId')
    c.execute('SELECT cny_price, exchange_rate, overseas_shipping FROM bid_cost WHERE order_id=?', (oid,))
    row = c.fetchone()
    if not row:
        result['missing_cost'].append({
            'order_id': oid,
            'size': b.get('size'),
            'price': b.get('price')
        })
    else:
        # 마진 계산
        cny, fx, ship = row
        if cny and fx:
            cost = cny * fx * 1.03 + (ship or 8000)
            settlement = b['price'] * (1 - 0.06 * 1.1) - 2500
            margin = settlement - cost
            result['margin_analysis'].append({
                'order_id': oid,
                'size': b.get('size'),
                'price': b['price'],
                'cost': round(cost),
                'settlement': round(settlement),
                'margin': round(margin),
                'status': 'OK' if margin >= 4000 else 'LOW' if margin >= 0 else 'DEFICIT'
            })
    result['bids'].append(b)

conn.close()

# 저장
out_path = f'jq4110_report_${TS}.json'
Path(out_path).write_text(json.dumps(result, ensure_ascii=False, indent=2))
print(f'리포트 저장: {out_path}')
print(f'입찰: {len(result["bids"])}건')
print(f'원가 누락: {len(result["missing_cost"])}건')
print(f'중복 사이즈: {len(result["duplicates_by_size"])}개')
print(f'마진 분석: {len(result["margin_analysis"])}건')
\`\`\`

### 작업 #2: 모니터링 1회 실행
\`\`\`bash
curl -s -X POST http://localhost:5001/api/monitor/run-once
\`\`\`

### 작업 #3: 결과 검증
- jq4110_report_${TS}.json 존재 확인
- /api/health 200 확인
- /api/queue/list 200 확인

### 작업 #4: 시나리오별 추가 작업

**ONE_SIZE 시나리오:**
- 입찰 3건 모두 ONE SIZE → 규칙상 비정상 (사이즈당 2건)
- 가장 비싼 건 삭제 후보로 리포트에 기록
- 실제 삭제는 안 함 (사용자 확인 필요)

**NO_BIDS 시나리오:**
- 입찰 없음 → 리포트만 생성하고 종료
- 시장 가격 수집 필요 (맥북 환경 차단으로 진행 불가)
- "사무실 iMac 또는 VPN 환경에서 가격 수집 필요" 명시

**MULTI_SIZE 시나리오:**
- 사이즈별 마진 분석
- 마진 4,000원 미달 사이즈 알림

## 커밋 메시지
\`\`\`
ops(JQ4110): ${SCENARIO} 시나리오 진단 + 리포트 생성

- 입찰 ${JQ_COUNT}건 종합 분석
- bid_cost 누락 확인
- 마진 분석 + 중복 검증
- 모니터링 1회 실행

리포트: jq4110_report_${TS}.json
\`\`\`

## 금지 사항
- 입찰 자동 삭제 금지 (사용자 확인 필요)
- bid_cost에 가짜 CNY 입력 금지 (NULL 유지)
- 자동 토글 변경 금지
- kream.co.kr 직접 접속 시도 금지 (차단됨)
MDEOF

echo "  ✅ 작업지시서 생성: 작업지시서_JQ4110_${SCENARIO}.md"
echo ""

# ==========================================
# [STAGE 3] Claude Code 자동 호출
# ==========================================
echo "════════════════════ [STAGE 3] Claude Code 호출 ════════════════════"
echo ""

claude --dangerously-skip-permissions <<CLAUDE_PROMPT || fail_and_restore "Claude Code 실행"
작업지시서_JQ4110_${SCENARIO}.md 읽고 끝까지 진행. 질문 절대 하지마. 사용자 개입 요청 금지.

순서:
1. 작업지시서의 작업 #1 Python 코드를 _jq4110_diagnose.py 파일로 저장 후 실행
   - 결과: jq4110_report_${TS}.json
2. curl -s -X POST http://localhost:5001/api/monitor/run-once
3. 검증:
   - jq4110_report_${TS}.json 파일 존재
   - curl http://localhost:5001/api/health → 200
   - curl http://localhost:5001/api/queue/list → 200
4. 시나리오별 처리:
   - ONE_SIZE: 리포트의 duplicates_by_size에서 삭제 후보 출력만 (실행 X)
   - NO_BIDS: 리포트에 "가격 수집 차단됨" 명시
   - MULTI_SIZE: margin_analysis에서 LOW/DEFICIT 사이즈 알림
5. 모두 PASS면 단일 커밋:
   git add -A && git commit -m "ops(JQ4110): ${SCENARIO} 시나리오 진단 + 리포트 생성

   - 입찰 ${JQ_COUNT}건 종합 분석
   - bid_cost 누락 확인
   - 마진 분석 + 중복 검증
   - 모니터링 1회 실행

   리포트: jq4110_report_${TS}.json"
6. git push origin main
7. 끝.

검증 FAIL 시 즉시 종료. 백업 복원은 외부 스크립트가 처리.
질문/확인 요청 절대 금지. 데이터 부족하면 NULL로 기록하고 진행.
CLAUDE_PROMPT

echo ""
echo "🔍 최종 검증..."
verify_server || fail_and_restore "최종 검증"

# 리포트 파일 생성됐는지 확인
if [ ! -f "jq4110_report_${TS}.json" ]; then
    echo "⚠️  리포트 파일 없음 — Claude Code가 생성 실패한 것으로 보임"
    echo "    수동 확인 필요: ls -la jq4110_report_*.json"
fi

FINAL_HASH=$(git log -1 --format=%h)
echo "✅ 작업 완료 — 커밋 $FINAL_HASH"
echo ""

# ==========================================
# [STAGE 4] 다음세션 컨텍스트 v8 자동 생성
# ==========================================
echo "════════════════════ [STAGE 4] 컨텍스트 v8 ════════════════════"

PA_PENDING=$(sqlite3 price_history.db "SELECT COUNT(*) FROM price_adjustments WHERE status='pending'" 2>/dev/null || echo "?")
PA_DEFICIT=$(sqlite3 price_history.db "SELECT COUNT(*) FROM price_adjustments WHERE status='deficit'" 2>/dev/null || echo "?")
SALES_COUNT=$(sqlite3 price_history.db "SELECT COUNT(*) FROM sales_history" 2>/dev/null || echo "?")
LATEST_SALE=$(sqlite3 price_history.db "SELECT MAX(trade_date) FROM sales_history" 2>/dev/null || echo "?")

cat > "다음세션_시작_컨텍스트_v8.md" <<MDEOF
# 다음 세션 시작 컨텍스트 v8

> 작성일: $(date '+%Y-%m-%d %H:%M:%S') (자동 생성)
> 직전 커밋: $(git log -1 --format='%h %s')

---

## 1. 직전 세션 작업

| 작업 | 결과 |
|---|---|
| JQ4110 ${SCENARIO} 진단 | 리포트 jq4110_report_${TS}.json |
| 입찰 ${JQ_COUNT}건 분석 | 사이즈: ${JQ_SIZES} |
| bid_cost 누락 확인 | 리포트 참조 |
| 마진 분석 + 중복 검증 | 리포트 참조 |
| 모니터링 1회 | 실행됨 |

## 2. 환경 상태

- 작업 환경: 맥북(해외)
- kream.co.kr: 차단 (가격 수집 불가)
- partner.kream.co.kr: 정상 (입찰 관리 가능)
- 자동 토글 6종: 사전 갱신만 ON, 나머지 OFF

## 3. DB 현황

| 테이블 | 건수 |
|---|---|
| pa_pending | $PA_PENDING |
| pa_deficit | $PA_DEFICIT |
| sales_history | $SALES_COUNT |
| 최근 trade_date | $LATEST_SALE |

## 4. 다음 작업 후보

### 1순위 — JQ4110 리포트 결과에 따라
- 원가 누락 건이 있으면 → CNY 원가 일괄 입력 (사용자 1회 알려주면 됨)
- 중복 입찰이 있으면 → 가장 비싼 건 삭제 (사용자 확인 후)
- 마진 미달이면 → 가격 조정 또는 회수

### 2순위 — 가격 수집 환경 복원
- VPN 또는 사무실 iMac 원격 접속 → kream.co.kr 접근
- 시장 가격 신규 수집 → 자동 조정 활성화

### 3순위 — Step 18 자동화 점진 ON
- 24/48/72h 안정성 모니터링

## 5. 다음 채팅 첫 메시지 템플릿

\`\`\`
다음세션_시작_컨텍스트_v8.md 읽고 jq4110_report_*.json 분석.

직전 커밋 ${FINAL_HASH}. JQ4110 ${SCENARIO} 진단 완료.
환경: 맥북(해외) — kream.co.kr 차단, partner만 가능.

오늘 작업: [리포트 결과 후속 조치 / VPN 켜고 가격 수집 / Step 18]

알아서 끝까지. 질문 최소화.
\`\`\`

## 6. 절대 규칙 (CLAUDE.md)

7대 규칙 그대로 유지.
MDEOF

echo "  ✅ 다음세션_시작_컨텍스트_v8.md 생성"
echo ""

git add 다음세션_시작_컨텍스트_v8.md pipeline_jq4110.log "jq4110_report_${TS}.json" 2>/dev/null
git commit -m "docs: 다음세션 컨텍스트 v8 (JQ4110 ${SCENARIO} 진단)" 2>/dev/null || echo "  (컨텍스트 변경 없음)"
git push origin main 2>/dev/null || echo "  (push 스킵)"

# ==========================================
# 최종 요약
# ==========================================
PIPELINE_END=$(date +%s)
ELAPSED=$((PIPELINE_END - PIPELINE_START))
ELAPSED_MIN=$((ELAPSED / 60))

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🎉 Pipeline 완료 — ${ELAPSED_MIN}분 ${ELAPSED}초"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "✅ 결과:"
echo "  - 시나리오: ${SCENARIO}"
echo "  - 커밋: $FINAL_HASH"
echo "  - 리포트: jq4110_report_${TS}.json"
echo "  - 컨텍스트: 다음세션_시작_컨텍스트_v8.md"
echo ""
echo "📋 다음 채팅:"
echo "  다음세션_시작_컨텍스트_v8.md + jq4110_report_${TS}.json 첨부 후 진행"
echo ""
echo "📜 진행 로그: pipeline_jq4110.log"
echo ""
