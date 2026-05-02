#!/bin/bash
# Step 31 — 4개 도구 일괄 + Step 30 버그 수정
# 환경: 한국 (kream.co.kr 접속 가능), 구매대행

set -e
exec > >(tee -a pipeline_step31.log) 2>&1
cd ~/Desktop/kream_automation

PIPELINE_START=$(date +%s)
TS=$(date '+%Y%m%d_%H%M%S')

echo "================================================================"
echo "🚀 Step 31 — 4개 도구 일괄 + 버그 수정"
echo "   $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================"
echo ""

fail_and_restore() {
    echo ""
    echo "❌ [$1] FAIL — 백업 복원"
    [ -f "kream_server.py.step31_pre.bak" ] && cp "kream_server.py.step31_pre.bak" kream_server.py
    [ -f "kream_dashboard.html.step31_pre.bak" ] && cp "kream_dashboard.html.step31_pre.bak" kream_dashboard.html
    [ -f "tabs/tab_margin.html.step31_pre.bak" ] && cp "tabs/tab_margin.html.step31_pre.bak" tabs/tab_margin.html
    [ -f "kream_adjuster.py.step31_pre.bak" ] && cp "kream_adjuster.py.step31_pre.bak" kream_adjuster.py
    [ -f "help_content.json.step31_pre.bak" ] && cp "help_content.json.step31_pre.bak" help_content.json
    
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
cp kream_server.py "kream_server.py.step31_pre.bak"
cp kream_dashboard.html "kream_dashboard.html.step31_pre.bak"
[ -f tabs/tab_margin.html ] && cp tabs/tab_margin.html "tabs/tab_margin.html.step31_pre.bak"
cp kream_adjuster.py "kream_adjuster.py.step31_pre.bak"
[ -f help_content.json ] && cp help_content.json "help_content.json.step31_pre.bak"
sqlite3 /Users/iseungju/Desktop/kream_automation/price_history.db ".backup '/Users/iseungju/Desktop/kream_automation/price_history_step31_${TS}.db'"
echo "  ✅ 백업 완료"
echo ""

# ==========================================
# [STAGE 2] 작업지시서
# ==========================================
echo "════════════════════ [STAGE 2] 작업지시서 ════════════════════"

cat > "작업지시서_Step31.md" <<'MDEOF'
# Step 31 — 4개 도구 일괄 + 버그 수정

> 환경: 한국, kream.co.kr 접속 가능
> 비즈니스: 구매대행
> 절대 규칙 + 자동 토글 ON 변경 금지

## 버그 수정

### Bug 1: kream_server.py — calc-batch NameError

기존 /api/new-bid/calc-batch 안에서 margin_status_msg 호출하는데 함수가 라우트 _아래_ 정의됨.

해결: 함수를 라우트 _위로_ 이동, 이름을 _calc_margin_status_msg로 변경:

```python
def _calc_margin_status_msg(status, margin, min_margin):
    if status == 'LOW':
        return f'마진 {round(margin):,}원 < {min_margin:,} (단가 협상 필요)'
    if status == 'DEFICIT':
        return f'적자 {round(margin):,}원 (입찰 불가)'
    return ''
```

라우트 안의 호출도 _calc_margin_status_msg(...)로 교체.

### Bug 2: kream_adjuster.py — sync v2 로그 안 보임

collect_my_bids_via_menu 안의 print(...)가 server.log에 안 잡힘.

해결: 모두 다음으로 교체:
```python
import sys  # 파일 상단에 추가 (없으면)
print(..., flush=True, file=sys.stderr)
```

또는 sys.stderr.write("[SYNC-V2] ...\n"); sys.stderr.flush()

## 작업 #1: 신규 입찰 일괄 도구

### POST /api/new-bid/auto-fetch-prices

```python
@app.route('/api/new-bid/auto-fetch-prices', methods=['POST'])
def api_new_bid_auto_fetch():
    data = request.get_json() or {}
    models = data.get('models', [])
    if not models:
        return jsonify({'ok': False, 'error': 'models required'}), 400
    
    results = []
    for model in models[:20]:
        try:
            r = requests.post('http://localhost:5001/api/search', 
                              json={'model': model}, timeout=60)
            if r.status_code == 200:
                d = r.json()
                sizes = d.get('sizes', []) or d.get('size_prices', [])
                results.append({'model': model, 'ok': True, 'sizes': sizes})
            else:
                results.append({'model': model, 'ok': False, 'error': f'HTTP {r.status_code}'})
        except Exception as e:
            results.append({'model': model, 'ok': False, 'error': str(e)})
    
    return jsonify({'ok': True, 'count': len(results), 'results': results})
```

### tabs/tab_new_bid.html 신규 (멱등)

UI 흐름:
1. textarea에 모델/CNY 입력 (한 줄당: 모델 [TAB] CNY숫자)
2. "시장가 수집" 버튼 → /api/new-bid/auto-fetch-prices 호출
3. 받은 시장가로 /api/new-bid/calc-batch 호출 → 결과 테이블 표시
4. GO 항목 자동 체크 → "선택 항목 큐 등록" 버튼

(Claude Code가 이 패턴으로 자유롭게 구현, 사이드바 메뉴 패턴 일치)

## 작업 #2: 마진 계산기 강화

기존 tabs/tab_margin.html 끝에 두 섹션 추가 (id="margin-batch" 있으면 스킵):

1. **margin-batch**: 사이즈별 행 추가 + 일괄 마진 계산
2. **margin-rotation**: 모델 입력 → /api/model/<model>/deep-analysis 호출 → 회전 통계

## 작업 #3: 판매 마진 확정

### GET /api/realized-margin/cumulative

```python
@app.route('/api/realized-margin/cumulative', methods=['GET'])
def api_realized_margin_cumulative():
    try:
        r = requests.get('http://localhost:5001/api/real-margin?days=365', timeout=10)
        rm = r.json()
        if not rm.get('ok'):
            return jsonify({'ok': False, 'error': 'real-margin 호출 실패'}), 500
        
        items = rm.get('items', [])
        from collections import defaultdict
        monthly = defaultdict(lambda: {'count': 0, 'revenue': 0, 'margin': 0, 'unknown_count': 0})
        by_model = defaultdict(lambda: {'count': 0, 'revenue': 0, 'margin': 0, 'has_cost': 0})
        
        for it in items:
            d = it.get('trade_date', '')
            if not d: continue
            month = d[:7]
            monthly[month]['count'] += 1
            monthly[month]['revenue'] += it.get('sale_price', 0)
            if it.get('margin') is not None:
                monthly[month]['margin'] += it['margin']
            else:
                monthly[month]['unknown_count'] += 1
            
            model = it.get('model', '?')
            by_model[model]['count'] += 1
            by_model[model]['revenue'] += it.get('sale_price', 0)
            if it.get('margin') is not None:
                by_model[model]['margin'] += it['margin']
                by_model[model]['has_cost'] += 1
        
        return jsonify({
            'ok': True,
            'monthly': sorted([{'month':k, **v} for k,v in monthly.items()], key=lambda x: x['month']),
            'top_models': sorted(
                [{'model':k, **v, 'avg_margin': round(v['margin']/v['has_cost']) if v['has_cost'] else None} 
                 for k,v in by_model.items()],
                key=lambda x: -x['count']
            )[:10],
            'total_count': len(items),
            'total_revenue': sum(it.get('sale_price', 0) for it in items),
            'total_confirmed_margin': sum(it.get('margin', 0) for it in items if it.get('margin') is not None),
        })
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500
```

### tabs/tab_realized.html 신규 (멱등)

월별 막대 차트 + 모델별 ROI 테이블.

## 작업 #4: 시장 모니터링

### DB 마이그레이션

```python
def _migrate_market_price_history():
    try:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("""
            CREATE TABLE IF NOT EXISTS market_price_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                model TEXT NOT NULL,
                size TEXT,
                buy_price INTEGER,
                recent_price INTEGER,
                collected_at TEXT NOT NULL,
                created_at TEXT DEFAULT CURRENT_TIMESTAMP
            )
        """)
        c.execute("CREATE INDEX IF NOT EXISTS idx_mph_model_collected ON market_price_history(model, collected_at)")
        conn.commit()
        conn.close()
        print("[MIGRATE] market_price_history 확인/생성")
    except Exception as e:
        print(f"[MIGRATE] market_price_history 에러: {e}")
```

if __name__ 블록에서 _migrate_market_price_history() 호출.

### 자동 수집

```python
def _collect_active_models_market_prices():
    try:
        from pathlib import Path
        local_path = Path(__file__).parent / 'my_bids_local.json'
        active_models = []
        if local_path.exists():
            local = json.loads(local_path.read_text(encoding='utf-8'))
            active_models = list(set(b.get('model') for b in local.get('bids', []) if b.get('model')))
        
        if not active_models:
            conn = sqlite3.connect(DB_PATH)
            c = conn.cursor()
            c.execute("SELECT DISTINCT model FROM sales_history WHERE model IS NOT NULL ORDER BY trade_date DESC LIMIT 10")
            active_models = [r[0] for r in c.fetchall()]
            conn.close()
        
        if not active_models:
            print("[MARKET-COLLECT] 수집할 모델 없음")
            return
        
        from datetime import datetime
        now_iso = datetime.now().isoformat()
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        success = 0
        for model in active_models[:30]:
            try:
                r = requests.post('http://localhost:5001/api/search', json={'model': model}, timeout=60)
                if r.status_code != 200: continue
                d = r.json()
                sizes = d.get('sizes', []) or d.get('size_prices', [])
                for sz in sizes:
                    c.execute("""
                        INSERT INTO market_price_history 
                        (model, size, buy_price, recent_price, collected_at)
                        VALUES (?, ?, ?, ?, ?)
                    """, (model, sz.get('size'),
                          sz.get('buy_price') or sz.get('buyPrice'),
                          sz.get('recent_price'), now_iso))
                success += 1
            except Exception as e:
                print(f"[MARKET-COLLECT] {model} 실패: {e}")
        conn.commit()
        conn.close()
        print(f"[MARKET-COLLECT] {success}/{len(active_models)} 모델 수집")
    except Exception as e:
        print(f"[MARKET-COLLECT] 에러: {e}")

# scheduler.add_job 2h interval
try:
    scheduler.add_job(
        _collect_active_models_market_prices,
        'interval', hours=2,
        id='market_price_collect',
        replace_existing=True,
        misfire_grace_time=600
    )
    print("[SCHEDULER] market_price_collect 등록 (2h)")
except Exception as e:
    print(f"[SCHEDULER] market_price_collect 실패: {e}")
```

### GET /api/market/history/<model>, /api/market/alerts, POST /api/market/collect-now

(코드는 작업지시서 본문 또는 Claude Code가 작성)

### tabs/tab_market.html 신규 (멱등)

급변 알림 + 모델별 가격 추이 조회.

## 사이드바 + 도움말

kream_dashboard.html에 메뉴 3개 추가 (멱등):
- 🆕 신규 입찰 (data-tab="new_bid")
- 💰 판매 마진 확정 (data-tab="realized")
- 📈 시장 모니터링 (data-tab="market")

help_content.json에 3개 키 추가 (멱등): new_bid / realized / market

## 검증

1. python3 -m py_compile kream_server.py + kream_adjuster.py
2. 서버 재시작 → server.log에 [MIGRATE] market_price_history + [SCHEDULER] market_price_collect
3. /api/new-bid/calc-batch (NameError 수정 확인)
4. /api/new-bid/auto-fetch-prices (시간 걸려도 OK)
5. /api/realized-margin/cumulative
6. /api/market/alerts, /api/market/history/<model>
7. tabs/ 3개 파일 + 200 OK
8. /api/help/<3개> ok
9. 회귀: capital-status, daily-summary, cleanup/diagnose, portfolio/overview

## 절대 규칙
- 자동 토글 ON 변경 금지
- DB CREATE IF NOT EXISTS만
- 기존 라우트 시그니처 변경 금지

## 커밋
```
feat(Step 31): 4개 도구 일괄 + 버그 수정

도구:
- 🆕 신규 입찰 일괄 도구 (모델/CNY → 시장가 자동 → 마진 → 큐)
- 💰 마진 계산기 강화 (사이즈 일괄 + 회전 시간)
- 📊 판매 마진 확정 (월별 + 모델 ROI)
- 📈 시장 모니터링 (DB + 2h 자동 수집 + 알림 + 차트)

버그:
- /api/new-bid/calc-batch margin_status_msg NameError 수정
- collect_my_bids_via_menu 로그 stderr로 (가시성 확보)

배경: 한국 환경 + 구매대행
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
작업지시서_Step31.md 읽고 끝까지 진행. 질문 절대 금지. 사용자 개입 요청 금지.

순서:
1. 작업지시서 읽기

2. 버그 수정:
   a. kream_server.py에서 margin_status_msg 함수 정의 위치 찾기 (보통 라우트 아래)
   b. 그 함수 정의 삭제, /api/new-bid/calc-batch 라우트 _바로 위에_ _calc_margin_status_msg 새 이름으로 다시 정의
   c. 라우트 안의 margin_status_msg(...) 호출을 _calc_margin_status_msg(...)로 교체
   d. kream_adjuster.py 상단에 import sys 없으면 추가
   e. collect_my_bids_via_menu 안의 모든 print(...)를 print(..., flush=True, file=sys.stderr)로 교체

3. kream_server.py 신규 라우트 추가 (멱등):
   - POST /api/new-bid/auto-fetch-prices
   - GET /api/realized-margin/cumulative
   - GET /api/market/history/<path:model>
   - GET /api/market/alerts
   - POST /api/market/collect-now

4. kream_server.py 신규 헬퍼 (멱등):
   - _migrate_market_price_history() 함수 + 서버 시작 시 호출
   - _collect_active_models_market_prices() 함수
   - scheduler.add_job market_price_collect 2h interval 등록

5. tabs/ 신규 파일 3개 (이미 있으면 스킵):
   - tab_new_bid.html — 모델/CNY 입력 → 시장가 자동 수집 → 마진 테이블 → 큐 등록 UI
   - tab_realized.html — 월별 막대 차트 + 모델별 ROI 테이블
   - tab_market.html — 급변 알림 + 모델별 가격 추이

6. tabs/tab_margin.html 끝에 추가 (id="margin-batch" 있으면 스킵):
   - margin-batch 섹션 (사이즈별 일괄 입력 + 마진)
   - margin-rotation 섹션 (모델 입력 → deep-analysis 호출)

7. kream_dashboard.html 사이드바에 3개 메뉴 추가:
   - 🆕 신규 입찰 (data-tab="new_bid")
   - 💰 판매 마진 확정 (data-tab="realized")
   - 📈 시장 모니터링 (data-tab="market")
   기존 다른 탭 메뉴 패턴 동일. 이미 있으면 스킵.

8. help_content.json에 3개 키 추가 (멱등):
   "new_bid", "realized", "market"

9. 문법:
   python3 -m py_compile kream_server.py
   python3 -m py_compile kream_adjuster.py

10. 서버 재시작:
    lsof -ti:5001 | xargs kill -9 || true
    sleep 2
    nohup python3 kream_server.py > server.log 2>&1 & disown
    sleep 8

11. API 검증:
    - curl -s -o /dev/null -w "%{http_code}" http://localhost:5001/api/health → 200
    - curl -s -X POST http://localhost:5001/api/new-bid/calc-batch -H 'Content-Type: application/json' -d '{"items":[{"model":"TEST","size":"260","sale_price":150000,"cny":350}]}' | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'), d; print('calc OK status=', d['items'][0]['status'])"
    - curl -s http://localhost:5001/api/realized-margin/cumulative | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'); print('realized OK total=', d.get('total_count'))"
    - curl -s http://localhost:5001/api/market/alerts | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'); print('alerts OK count=', d.get('count'))"
    - curl -s http://localhost:5001/api/market/history/JQ4110 | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'); print('history OK')"

12. 파일/HTML:
    - test -f tabs/tab_new_bid.html
    - test -f tabs/tab_realized.html
    - test -f tabs/tab_market.html
    - curl -s -o /dev/null -w "%{http_code}" http://localhost:5001/tabs/tab_new_bid.html → 200
    - curl -s -o /dev/null -w "%{http_code}" http://localhost:5001/tabs/tab_realized.html → 200
    - curl -s -o /dev/null -w "%{http_code}" http://localhost:5001/tabs/tab_market.html → 200

13. 도움말:
    - curl -s http://localhost:5001/api/help/new_bid | grep -q '"ok": true'
    - curl -s http://localhost:5001/api/help/realized | grep -q '"ok": true'
    - curl -s http://localhost:5001/api/help/market | grep -q '"ok": true'

14. 스케줄러 등록 + 마이그레이션 로그:
    tail -200 server.log | grep -E "(market_price_collect|MIGRATE.*market)"

15. 회귀 (모두 OK):
    - curl -s http://localhost:5001/api/capital-status | grep -q '"ok": true'
    - curl -s http://localhost:5001/api/daily-summary | grep -q '"ok": true'
    - curl -s http://localhost:5001/api/cleanup/diagnose | grep -q '"ok": true'
    - curl -s http://localhost:5001/api/portfolio/overview | grep -q '"ok": true'

16. 모두 PASS면 단일 커밋 + push:
    git add -A
    git commit -m "feat(Step 31): 4개 도구 일괄 + Step 30 버그 수정

    도구:
    - 🆕 신규 입찰 일괄 도구
    - 💰 마진 계산기 강화 (사이즈 일괄 + 회전)
    - 📊 판매 마진 확정 (월별 누적 + 모델 ROI)
    - 📈 시장 모니터링 (DB + 2h 자동 수집 + 알림 + 차트)

    버그:
    - /api/new-bid/calc-batch margin_status_msg NameError 수정
    - collect_my_bids_via_menu print → stderr (로그 가시성)

    배경: 한국 환경 + 구매대행"
    git push origin main

17. 끝.

질문/확인 절대 금지. 검증 FAIL 시 즉시 종료.
CLAUDE_PROMPT

echo ""
echo "🔍 최종 검증..."
verify_server || fail_and_restore "최종 검증"

echo ""
echo "  📋 핵심 검증:"

CALC_OK=$(curl -s -X POST http://localhost:5001/api/new-bid/calc-batch \
  -H 'Content-Type: application/json' \
  -d '{"items":[{"model":"TEST","size":"260","sale_price":150000,"cny":350}]}' | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    if d.get('ok'):
        items=d.get('items',[])
        if items: print(f\"OK status={items[0].get('status')} margin={items[0].get('margin','?')}\")
        else: print('FAIL no items')
    else: print(f'FAIL {str(d.get(\"error\",\"\"))[:60]}')
except: print('ERROR')
" 2>/dev/null)
echo "    new-bid/calc-batch: $CALC_OK"
[[ "$CALC_OK" != OK* ]] && fail_and_restore "calc-batch 실패"

REALIZED=$(curl -s http://localhost:5001/api/realized-margin/cumulative | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(f\"total={d.get('total_count')} revenue={d.get('total_revenue',0):,} margin={d.get('total_confirmed_margin',0):,}\")
except: print('ERROR')
" 2>/dev/null)
echo "    realized-margin: $REALIZED"

ALERTS=$(curl -s http://localhost:5001/api/market/alerts | python3 -c "
import sys,json
try: print(f\"count={json.load(sys.stdin).get('count','?')}\")
except: print('ERROR')
" 2>/dev/null)
echo "    market alerts: $ALERTS"

[ -f tabs/tab_new_bid.html ] && echo "    ✅ tab_new_bid.html" || fail_and_restore "tab_new_bid 누락"
[ -f tabs/tab_realized.html ] && echo "    ✅ tab_realized.html" || fail_and_restore "tab_realized 누락"
[ -f tabs/tab_market.html ] && echo "    ✅ tab_market.html" || fail_and_restore "tab_market 누락"

echo ""
echo "  📅 시장 수집 로그:"
tail -200 server.log 2>/dev/null | grep -E "(market_price_collect|MIGRATE.*market|MARKET-COLLECT)" | tail -5 || echo "    (로그 없음)"

FINAL_HASH=$(git log -1 --format=%h)
echo ""
echo "  ✅ 커밋: $FINAL_HASH"
echo ""

# ==========================================
# [STAGE 4] 컨텍스트 v25
# ==========================================
echo "════════════════════ [STAGE 4] 컨텍스트 v25 ════════════════════"

PA_PENDING=$(sqlite3 price_history.db "SELECT COUNT(*) FROM price_adjustments WHERE status='pending'" 2>/dev/null || echo "?")
SALES_COUNT=$(sqlite3 price_history.db "SELECT COUNT(*) FROM sales_history" 2>/dev/null || echo "?")
BID_COST=$(sqlite3 price_history.db "SELECT COUNT(*) FROM bid_cost" 2>/dev/null || echo "?")

cat > "다음세션_시작_컨텍스트_v25.md" <<MDEOF
# 다음 세션 시작 컨텍스트 v25

> 작성일: $(date '+%Y-%m-%d %H:%M:%S')
> 직전 커밋: $(git log -1 --format='%h %s')

## 환경

- 위치: **한국** (kream.co.kr + partner.kream.co.kr 모두 접속 가능)
- 작업: 맥북, 사무실 iMac 원격 안 함
- 비즈니스: **구매대행** (입찰 ≠ 자본 지출, 체결 시점에 매입)

## Step 31 — 4개 도구 일괄

### 신규 탭 3개 + 1개 강화

| 탭 | 사이드바 | 기능 |
|---|---|---|
| tab_new_bid.html | 🆕 신규 입찰 | 모델/CNY → 시장가 자동 → 마진 → 큐 |
| tab_realized.html | 💰 판매 마진 확정 | 월별 누적 + 모델별 ROI |
| tab_market.html | 📈 시장 모니터링 | 가격 추이 + 급변 알림 |
| tab_margin.html | 💰 마진 계산기 | + 사이즈별 일괄 + 회전 시간 |

### 신규 API

- POST /api/new-bid/calc-batch (NameError 수정됨)
- POST /api/new-bid/auto-fetch-prices
- GET /api/realized-margin/cumulative
- GET /api/market/history/<model>
- GET /api/market/alerts
- POST /api/market/collect-now

### 신규 자동 스케줄러

| 작업 | 주기 |
|---|---|
| 시장가 수집 (NEW Step 31) | 2h |
| sync health check | 35분 |
| 자본 스냅샷 | 1h |
| 입찰 sync + rank | 30분 |
| 사전 갱신 | 12h |
| 일지 자동 저장 | 23:55 |
| 주간 리포트 | 월 0:05 |

### 신규 DB

- market_price_history (model, size, buy_price, recent_price, collected_at)

### 버그 수정

- /api/new-bid/calc-batch margin_status_msg NameError → _calc_margin_status_msg (라우트 위로)
- collect_my_bids_via_menu print → stderr (로그 가시성)

## 측정값

- /api/new-bid/calc-batch: $CALC_OK
- /api/realized-margin: $REALIZED
- /api/market alerts: $ALERTS
- DB: pa_pending=$PA_PENDING / sales=$SALES_COUNT / bid_cost=$BID_COST

## 미해결

### sync 0건 (Step 25-30 시도 후)
- collect_my_bids_via_menu 로그 stderr 수정으로 다음 sync 시 server.log에 보일 것
- 사장 스크린샷에서 60+건 입찰 확인됨, 진단/실제 수집 사이 어디서 끊기는지 추적 필요

## 다음 작업 후보

### 1순위 — 신규 입찰 도구 실전 사용
- 🆕 새 탭에서 신규 모델 등록 워크플로우 시도
- 마진 계산 → GO 항목 → 큐 등록 → 자동 입찰 검증

### 2순위 — sync 디버깅 (재시도)
- 다음 sync 결과 server.log [SYNC-V2] 로그 확인
- 어느 단계에서 0건 반환하는지 정확히 추적

### 3순위 — 시장 모니터링 누적
- 2시간마다 자동 → 24시간 후 의미 있는 데이터

## 다음 채팅 첫 메시지

\`\`\`
다음세션_시작_컨텍스트_v25.md 읽고 현재 상태.
직전 커밋 $FINAL_HASH (Step 31).
환경: 한국, 구매대행

오늘 작업: [구체 지시]
\`\`\`

## 절대 규칙

7대 규칙 + 자동 토글 ON 금지.
MDEOF

git add 다음세션_시작_컨텍스트_v25.md pipeline_step31.log 2>/dev/null
git commit -m "docs: 다음세션 컨텍스트 v25 (Step 31)" 2>/dev/null || echo "  (변경 없음)"
git push origin main 2>/dev/null || echo "  (push 스킵)"

PIPELINE_END=$(date +%s)
ELAPSED=$((PIPELINE_END - PIPELINE_START))
ELAPSED_MIN=$((ELAPSED / 60))

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🎉 Step 31 완료 — ${ELAPSED_MIN}분 ${ELAPSED}초"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "✅ 결과:"
echo "  - 신규 탭 3개: 🆕 신규 입찰 / 💰 판매 마진 확정 / 📈 시장 모니터링"
echo "  - 마진 계산기 강화 (사이즈 일괄 + 회전)"
echo "  - 시장가 자동 수집 시작 (2h 간격)"
echo "  - calc-batch NameError 수정"
echo "  - sync v2 로그 가시성 확보"
echo "  - 커밋: $FINAL_HASH"
echo ""
echo "📋 활용:"
echo "  - 사이드바 → 🆕 신규 입찰: 모델/CNY 입력 → 자동 마진 계산 → 큐"
echo "  - 사이드바 → 💰 판매 마진 확정: 월별 매출/수익"
echo "  - 사이드바 → 📈 시장 모니터링: 24h 후 의미"
echo ""
echo "📜 로그: pipeline_step31.log"
echo ""
