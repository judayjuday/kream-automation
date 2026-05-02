#!/bin/bash
# Step 23 — 데이터 정합성 복구
#   1. sync 진단: 판매자센터 페이지 직접 확인 (스크린샷 + HTML 덤프)
#   2. bid_cost 매칭 키 보강 (model+size+price fuzzy)
#   3. sync 0건 자동 경고
#   4. 판매 마진 fallback 추정 (옛날 판매도 추정 마진 표시)

set -e
exec > >(tee -a pipeline_step23.log) 2>&1
cd ~/Desktop/kream_automation

PIPELINE_START=$(date +%s)
TS=$(date '+%Y%m%d_%H%M%S')

echo "================================================================"
echo "🚀 Step 23 Pipeline — $(date '+%Y-%m-%d %H:%M:%S')"
echo "   1) sync 진단  2) 매칭 보강  3) 0건 경고  4) fallback 마진"
echo "================================================================"
echo ""

fail_and_restore() {
    echo ""
    echo "❌ [$1] FAIL — 백업 복원"
    [ -f "kream_server.py.step23_pre.bak" ] && cp "kream_server.py.step23_pre.bak" kream_server.py
    
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
cp kream_server.py "kream_server.py.step23_pre.bak"
[ -f kream_bot.py ] && cp kream_bot.py "kream_bot.py.step23_pre.bak"
sqlite3 /Users/iseungju/Desktop/kream_automation/price_history.db ".backup '/Users/iseungju/Desktop/kream_automation/price_history_step23_${TS}.db'"
echo "  ✅ 백업 완료"
echo ""

# ==========================================
# [STAGE 2] 작업지시서
# ==========================================
echo "════════════════════ [STAGE 2] 작업지시서 ════════════════════"

cat > "작업지시서_Step23.md" <<'MDEOF'
# 작업지시서 — Step 23: 데이터 정합성 복구

> 환경: macbook_overseas (kream.co.kr 차단, partner 정상)
> 비즈니스: 구매대행
> 절대 규칙 (CLAUDE.md) + 자동 토글 ON 변경 금지

## 진단 결과 (2026-05-02 19:19)

1. **sync 0건 반환** — 태스크 success인데 bids 빈 배열
   - 판매자센터에 진짜 입찰 없거나
   - 페이지 구조 변경으로 셀렉터 안 잡힘
   
2. **bid_cost 48건 ↔ sales_history 8건 매칭 0건**
   - 판매 8건은 옛날 입찰 (bid_cost 도입 전)
   - bid_cost 48건은 최근 신규 입찰
   - order_id 시기 자체가 다름

## 작업 #1: sync 진단 라우트 (페이지 덤프)

### 신규 라우트: /api/diagnostics/sync-page-dump

```python
@app.route('/api/diagnostics/sync-page-dump', methods=['POST'])
def api_sync_page_dump():
    """판매자센터 입찰 페이지를 직접 열어서 HTML + 스크린샷 저장.
    sync가 0건 반환할 때 페이지 상태를 사장이 직접 확인."""
    try:
        import asyncio
        from pathlib import Path
        from datetime import datetime
        
        ts = datetime.now().strftime('%Y%m%d_%H%M%S')
        dump_dir = Path(__file__).parent / 'diagnostics'
        dump_dir.mkdir(exist_ok=True)
        
        html_path = dump_dir / f'sync_page_{ts}.html'
        png_path = dump_dir / f'sync_page_{ts}.png'
        
        async def dump():
            from playwright.async_api import async_playwright
            from kream_bot import create_browser, create_context, ensure_logged_in, dismiss_popups
            
            async with async_playwright() as p:
                browser = await create_browser(p, headless=True)
                context = await create_context(browser, storage='auth_state.json')
                page = await context.new_page()
                
                # 입찰 페이지 직접 이동
                await page.goto('https://partner.kream.co.kr/c2c/sell/bid', wait_until='domcontentloaded', timeout=30000)
                await page.wait_for_timeout(3000)
                
                # 로그인 상태 확인
                logged_in = await ensure_logged_in(page, context)
                
                # 팝업 닫기
                try:
                    await dismiss_popups(page)
                except: pass
                
                await page.wait_for_timeout(2000)
                
                # HTML 덤프
                html = await page.content()
                html_path.write_text(html, encoding='utf-8')
                
                # 스크린샷
                await page.screenshot(path=str(png_path), full_page=True)
                
                # 페이지 내 입찰 카운트 추출 시도 (여러 셀렉터 fallback)
                count_info = {}
                for selector_desc, selector in [
                    ('table_rows', 'table tbody tr'),
                    ('list_items', '.bid-item, .list-item, [class*="bid"]'),
                    ('total_text', '[class*="total"], [class*="count"]'),
                ]:
                    try:
                        elements = await page.query_selector_all(selector)
                        count_info[selector_desc] = len(elements)
                    except: 
                        count_info[selector_desc] = -1
                
                # URL 확인 (리다이렉트됐는지)
                final_url = page.url
                title = await page.title()
                
                await browser.close()
                
                return {
                    'logged_in': logged_in,
                    'final_url': final_url,
                    'title': title,
                    'count_info': count_info,
                    'html_size': len(html),
                }
        
        result = asyncio.run(dump())
        
        return jsonify({
            'ok': True,
            'timestamp': ts,
            'html_path': str(html_path),
            'screenshot_path': str(png_path),
            **result,
            'note': '스크린샷 + HTML 저장됨. 직접 열어서 입찰 보이는지 확인'
        })
    except Exception as e:
        import traceback
        return jsonify({'ok': False, 'error': str(e), 'trace': traceback.format_exc()}), 500
```

## 작업 #2: bid_cost 매칭 키 보강

### 신규 라우트: /api/real-margin (강화 버전)

기존 /api/real-margin이 있으면, fuzzy 매칭 추가하여 fallback 마진 계산.

기존 함수 안에서 매칭 로직 강화:

```python
# 기존 코드의 c.execute("SELECT s.order_id ... LEFT JOIN bid_cost b ON s.order_id = b.order_id ...") 
# 이 부분 다음에 fuzzy 매칭 추가:

# 1차: order_id exact 매칭 (기존)
# 2차: model + size 매칭 (fuzzy)
# 3차: model 평균 (last resort)

# 기존 처리 후, unmatched(confirmed=False)인 건들에 대해 추가 매칭 시도
fuzzy_matched_count = 0

for item in items:
    if not item.get('confirmed'):
        # model + size로 bid_cost 검색 (가장 최근 또는 평균)
        c.execute("""
            SELECT AVG(cny_price), AVG(exchange_rate), AVG(COALESCE(overseas_shipping, ?))
            FROM bid_cost
            WHERE model = ? AND (size = ? OR size = ?)
        """, (overseas_ship_default, item['model'], item.get('size'), 'ONE SIZE' if not item.get('size') else item.get('size')))
        row = c.fetchone()
        
        if row and row[0] is not None:
            cny, fx, ship = row
            est_cost = float(cny) * float(fx) * 1.03 + float(ship)
            settlement = item['sale_price'] * (1 - fee_rate * 1.1) - fixed_fee
            est_margin = settlement - est_cost
            item['cost'] = round(est_cost)
            item['margin'] = round(est_margin)
            item['confirmed'] = False  # 추정값임을 명시
            item['estimation_source'] = 'fuzzy_model_size'
            fuzzy_matched_count += 1
        else:
            # 3차: model만으로
            c.execute("""
                SELECT AVG(cny_price), AVG(exchange_rate), AVG(COALESCE(overseas_shipping, ?))
                FROM bid_cost
                WHERE model = ?
            """, (overseas_ship_default, item['model']))
            row2 = c.fetchone()
            if row2 and row2[0] is not None:
                cny, fx, ship = row2
                est_cost = float(cny) * float(fx) * 1.03 + float(ship)
                settlement = item['sale_price'] * (1 - fee_rate * 1.1) - fixed_fee
                est_margin = settlement - est_cost
                item['cost'] = round(est_cost)
                item['margin'] = round(est_margin)
                item['estimation_source'] = 'fuzzy_model_only'
                fuzzy_matched_count += 1

# 응답에 추가:
# 'estimated': {'count': fuzzy_matched_count, 'note': 'model+size 또는 model 평균치로 추정'}
```

기존 confirmed/unknown_cost 분류 유지하되, 새로운 estimated 카테고리 추가.

## 작업 #3: sync 0건 자동 경고

기존 my_bids_sync_monitor 스케줄러 또는 sync 결과 처리 부분에 추가:

```python
def _check_sync_health():
    """sync 결과가 0건이면 알림."""
    try:
        from pathlib import Path
        local_path = Path(__file__).parent / 'my_bids_local.json'
        if not local_path.exists():
            return
        
        local = json.loads(local_path.read_text(encoding='utf-8'))
        bids_count = len(local.get('bids', []))
        last_sync = local.get('last_sync') or local.get('updated_at')
        
        # 마지막 sync가 최근 1시간 이내인데 0건이면 경고
        if bids_count == 0:
            from datetime import datetime, timedelta
            try:
                if last_sync:
                    last_sync_dt = datetime.strptime(last_sync, '%Y/%m/%d %H:%M') if '/' in last_sync else datetime.fromisoformat(last_sync)
                    if datetime.now() - last_sync_dt < timedelta(hours=1):
                        # 최근 sync인데 0건 = 비정상
                        try:
                            safe_send_alert(
                                subject='[KREAM] sync 0건 경고',
                                body=f'판매자센터 sync 결과 0건. 페이지 파싱 깨졌을 가능성.\n\n/api/diagnostics/sync-page-dump 호출하여 확인 필요.',
                                alert_type='sync_zero'
                            )
                        except: pass
            except Exception:
                pass
    except Exception:
        pass
```

기존 scheduler에 추가:

```python
try:
    scheduler.add_job(
        _check_sync_health,
        'interval', minutes=35,  # sync 후 5분 후
        id='sync_health_check',
        replace_existing=True,
        misfire_grace_time=300
    )
    print("[SCHEDULER] sync_health_check 등록 (35분 간격)")
except Exception as e:
    print(f"[SCHEDULER] sync_health_check 등록 실패: {e}")
```

## 작업 #4: 진단 페이지 (대시보드)

### 신규 라우트: /api/diagnostics/list-dumps

```python
@app.route('/api/diagnostics/list-dumps', methods=['GET'])
def api_diagnostics_list_dumps():
    """저장된 진단 덤프 목록."""
    try:
        from pathlib import Path
        dump_dir = Path(__file__).parent / 'diagnostics'
        if not dump_dir.exists():
            return jsonify({'ok': True, 'dumps': []})
        
        dumps = []
        for f in sorted(dump_dir.glob('sync_page_*.png'), reverse=True)[:20]:
            html_f = f.with_suffix('.html')
            dumps.append({
                'timestamp': f.stem.replace('sync_page_', ''),
                'screenshot': f.name,
                'html': html_f.name if html_f.exists() else None,
                'size_mb': round(f.stat().st_size / 1024 / 1024, 2),
            })
        
        return jsonify({'ok': True, 'dumps': dumps})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


# 정적 파일 서빙용
@app.route('/diagnostics/<path:filename>', methods=['GET'])
def serve_diagnostics(filename):
    """진단 파일 (스크린샷, HTML) 직접 접근."""
    from pathlib import Path
    from flask import send_from_directory
    dump_dir = Path(__file__).parent / 'diagnostics'
    return send_from_directory(str(dump_dir), filename)
```

## 검증

1. python3 -m py_compile kream_server.py → 0
2. 서버 재시작
3. /api/diagnostics/list-dumps → ok=true (빈 배열이라도 OK)
4. /api/real-margin?days=30 → 응답에 estimated 또는 confirmed 정보 (구조 변경 OK, 매칭 보강)
5. /api/diagnostics/sync-page-dump POST → 비동기로 실행되므로 결과는 시간 걸림
   - 첫 호출만 검증: 응답 ok=true, html_path/screenshot_path 키 존재 여부
6. 회귀: capital-status, daily-summary, cleanup/diagnose, conversion-rate

## 절대 규칙
- sync 동작 자체 변경 금지 (진단만 추가)
- 기존 라우트 시그니처 변경 금지 (real-margin은 응답에 키 추가만)
- DB 스키마 변경 금지

## 커밋 메시지
```
feat(Step 23): 데이터 정합성 복구

- /api/diagnostics/sync-page-dump: 판매자센터 페이지 직접 캡처
  HTML + 스크린샷 저장 (sync 0건 시 진단)
- /api/diagnostics/list-dumps + /diagnostics/<file> 서빙
- /api/real-margin 매칭 보강:
  1차 order_id exact, 2차 model+size fuzzy, 3차 model 평균
  estimated 분류 추가
- _check_sync_health 스케줄러: sync 0건 자동 경고

배경: sync 0건 반환 + bid_cost 시기 미스매치 진단/복구
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
작업지시서_Step23.md 읽고 끝까지 진행. 질문 절대 금지. 사용자 개입 요청 금지.

순서:
1. 작업지시서 읽기

2. kream_server.py 수정 (멱등성):
   a. /api/diagnostics/sync-page-dump POST 라우트 신규
      - asyncio + playwright로 partner.kream.co.kr/c2c/sell/bid 직접 접속
      - HTML + 스크린샷을 diagnostics/ 폴더에 저장
   b. /api/diagnostics/list-dumps GET 라우트 신규
   c. /diagnostics/<filename> 정적 파일 서빙 라우트 신규
   d. 기존 /api/real-margin 라우트의 unmatched 처리 후, fuzzy 매칭 추가
      (model+size → model 순서. estimation_source 키로 출처 표시)
      응답에 estimated 분류 추가
   e. _check_sync_health() 함수 + scheduler 35분 간격 등록
   
3. 문법:
   python3 -m py_compile kream_server.py

4. 서버 재시작:
   lsof -ti:5001 | xargs kill -9 || true
   sleep 2
   nohup python3 kream_server.py > server.log 2>&1 & disown
   sleep 8

5. API 검증:
   - curl -s http://localhost:5001/api/diagnostics/list-dumps | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'); print('list OK')"
   - curl -s 'http://localhost:5001/api/real-margin?days=30' | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'); cf=d.get('confirmed',{}); est=d.get('estimated') or {}; un=d.get('unknown_cost',{}); print(f'real-margin confirmed={cf.get(\"count\",0)} estimated={est.get(\"count\",0)} unknown={un.get(\"count\",0)}')"

6. 스케줄러 등록 확인:
   tail -100 server.log | grep -E "(sync_health_check)" || echo "(검색 결과 없음 — 등록 확인 필요)"

7. 페이지 덤프 실행 (시간 걸림, timeout 60초):
   - curl -s --max-time 90 -X POST http://localhost:5001/api/diagnostics/sync-page-dump | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'dump ok={d.get(\"ok\")} logged_in={d.get(\"logged_in\")} url={d.get(\"final_url\")} count_info={d.get(\"count_info\")}')"
   
   덤프 실패해도 진행 (인증 등 외부 요인 가능)

8. 회귀:
   - curl -s -o /dev/null -w "%{http_code}" http://localhost:5001/api/health → 200
   - curl -s http://localhost:5001/api/capital-status | grep -q '"ok": true'
   - curl -s http://localhost:5001/api/conversion-rate | grep -q '"ok": true'
   - curl -s http://localhost:5001/api/daily-summary | grep -q '"ok": true'
   - curl -s http://localhost:5001/api/cleanup/diagnose | grep -q '"ok": true'

9. 모두 PASS면 단일 커밋:
   git add -A
   git commit -m "feat(Step 23): 데이터 정합성 복구

   - /api/diagnostics/sync-page-dump: 판매자센터 페이지 직접 캡처
   - /api/diagnostics/list-dumps + /diagnostics/<file> 서빙
   - /api/real-margin 매칭 보강 (order_id → model+size → model 평균)
     estimated 분류 추가, estimation_source 키
   - _check_sync_health 35분 스케줄러 (sync 0건 자동 경고)

   배경: sync 0건 + bid_cost 시기 미스매치 진단/복구"
   git push origin main

10. 끝.

질문/확인 요청 절대 금지. 검증 FAIL 시 즉시 종료.
CLAUDE_PROMPT

echo ""
echo "🔍 최종 검증..."
verify_server || fail_and_restore "최종 검증"

echo ""
echo "  📋 핵심 검증:"

# real-margin 매칭 결과
RM_RESULT=$(curl -s 'http://localhost:5001/api/real-margin?days=30' | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    if d.get('ok'):
        cf=d.get('confirmed',{}).get('count',0)
        est=(d.get('estimated') or {}).get('count',0)
        un=d.get('unknown_cost',{}).get('count',0)
        print(f\"confirmed={cf} estimated={est} unknown={un}\")
    else: print('FAIL')
except: print('ERROR')
" 2>/dev/null)
echo "    real-margin 매칭: $RM_RESULT"

# 페이지 덤프 시도
echo ""
echo "  📸 판매자센터 페이지 덤프 시도 (최대 90초)..."
DUMP_RESULT=$(curl -s --max-time 90 -X POST http://localhost:5001/api/diagnostics/sync-page-dump | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    if d.get('ok'):
        print(f\"logged_in={d.get('logged_in')} url={d.get('final_url')} count_info={d.get('count_info')}\")
    else: print(f'FAIL: {d.get(\"error\")[:100]}')
except Exception as e: print(f'ERROR: {e}')
" 2>/dev/null)
echo "    dump: $DUMP_RESULT"

# 덤프 파일 확인
DUMPS=$(curl -s http://localhost:5001/api/diagnostics/list-dumps | python3 -c "
import sys,json
try: print(len(json.load(sys.stdin).get('dumps',[])))
except: print('ERROR')
" 2>/dev/null)
echo "    저장된 덤프 파일: ${DUMPS}개"

FINAL_HASH=$(git log -1 --format=%h)
echo ""
echo "  ✅ 커밋: $FINAL_HASH"
echo ""

# ==========================================
# [STAGE 4] 진단 결과 + 컨텍스트 v17
# ==========================================
echo "════════════════════ [STAGE 4] 진단 결과 + 컨텍스트 v17 ════════════════════"

# count_info 분석
LOGGED_IN=$(echo "$DUMP_RESULT" | sed -n 's/.*logged_in=\(True\|False\).*/\1/p')
FINAL_URL=$(echo "$DUMP_RESULT" | sed -n "s/.*url=\([^ ]*\).*/\1/p")

echo ""
echo "  🔍 진단 결과 해석:"
if [ "$LOGGED_IN" == "True" ] && [[ "$FINAL_URL" == *"/c2c/sell/bid"* ]]; then
    echo "    로그인 OK + URL 정상 → 페이지 진짜로 입찰 0건일 가능성 높음"
    echo "    또는 페이지 셀렉터 변경 (스크린샷으로 확인 필요)"
elif [ "$LOGGED_IN" == "False" ]; then
    echo "    🔴 로그인 실패 → auth_state.json 만료. 재로그인 필요"
    echo "    명령: python3 kream_bot.py --mode auto-login-partner"
fi
echo ""
echo "  📂 덤프 파일 확인:"
echo "    open ~/Desktop/kream_automation/diagnostics/  ← 폴더 열기"
echo "    또는 http://localhost:5001/api/diagnostics/list-dumps 호출"
echo ""

PA_PENDING=$(sqlite3 price_history.db "SELECT COUNT(*) FROM price_adjustments WHERE status='pending'" 2>/dev/null || echo "?")
SALES_COUNT=$(sqlite3 price_history.db "SELECT COUNT(*) FROM sales_history" 2>/dev/null || echo "?")

cat > "다음세션_시작_컨텍스트_v17.md" <<MDEOF
# 다음 세션 시작 컨텍스트 v17

> 작성일: $(date '+%Y-%m-%d %H:%M:%S') (자동 생성)
> 직전 커밋: $(git log -1 --format='%h %s')

## 1. Step 23 데이터 정합성 진단 결과

**sync 0건 문제:**
- 페이지 덤프: $DUMP_RESULT
- 로그인 상태: ${LOGGED_IN:-?}
- 최종 URL: ${FINAL_URL:-?}
- → diagnostics/ 폴더 스크린샷 직접 확인 필요

**bid_cost ↔ sales 매칭 보강:**
- $RM_RESULT
- exact 매칭 0건이지만 model+size fuzzy로 일부 추정 가능

## 2. 핵심 미해결 이슈

**A. sync 0건 원인 미확정**
- 인증 OK + 페이지 OK인데 0건이면 셀렉터 변경
- 인증 NG면 재로그인 필요

**B. 옛날 판매 8건은 bid_cost 없음**
- estimated 매칭으로 추정 마진 표시 가능해짐 (Step 23)
- 새로 판매되는 건부터는 자동 매칭

## 3. 누적 (Step 18~23)

| Step | 커밋 |
|---|---|
| 18-A/B/C/D | ff97377 → 0695df0 |
| 19~22 | 358985b → 5d36225 |
| **23** | **$FINAL_HASH** |

## 4. 신규 API (Step 23)

- /api/diagnostics/sync-page-dump (POST)
- /api/diagnostics/list-dumps
- /diagnostics/<filename> 서빙
- /api/real-margin 매칭 보강 (estimated 추가)
- 스케줄러: sync_health_check (35분)

## 5. DB

| 테이블 | 건수 |
|---|---|
| pa_pending | $PA_PENDING |
| sales_history | $SALES_COUNT |
| bid_cost | 48 |
| 매칭 | 0 (옛날 판매 = bid_cost 없음) |

## 6. 환경

- environment: macbook_overseas
- 가격 수집: 차단
- 비즈니스: 구매대행 (입찰 ≠ 자본 지출)

## 7. 다음 작업 후보

### 1순위 — 사장이 직접 확인 필요
1. 판매자센터 직접 로그인 → 입찰 진짜 있는지 보기
2. diagnostics/sync_page_*.png 스크린샷 열어보기
3. 결과 알려주면 다음 액션 결정

### 시나리오별 후속

**A. 입찰 진짜 0건이면**: 판매 다 끝났거나 만료됨 → 새로 입찰 시작
**B. 입찰 있는데 sync 0건이면**: 셀렉터 패치 필요 (kream_bot.py)
**C. 인증 만료면**: python3 kream_bot.py --mode auto-login-partner

## 8. 다음 채팅 첫 메시지

\`\`\`
다음세션_시작_컨텍스트_v17.md 읽고 현재 상태 파악.
직전 커밋 $FINAL_HASH (Step 23 완료, sync 0건 진단).

판매자센터 직접 확인 결과: [입찰 N건 / 입찰 없음 / 인증 깨짐]
스크린샷 결과: [정상 / 비어있음 / 에러]

오늘 작업: [기획 / 구체 지시]
\`\`\`

## 9. 절대 규칙

7대 규칙 + 자동 토글 ON 금지 + 구매대행 모델 반영.
MDEOF

echo "  ✅ 다음세션_시작_컨텍스트_v17.md 생성"
git add 다음세션_시작_컨텍스트_v17.md pipeline_step23.log 2>/dev/null
git commit -m "docs: 다음세션 컨텍스트 v17 (Step 23 완료)" 2>/dev/null || echo "  (변경 없음)"
git push origin main 2>/dev/null || echo "  (push 스킵)"
echo ""

PIPELINE_END=$(date +%s)
ELAPSED=$((PIPELINE_END - PIPELINE_START))
ELAPSED_MIN=$((ELAPSED / 60))

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🎉 Step 23 완료 — ${ELAPSED_MIN}분 ${ELAPSED}초"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "✅ 결과:"
echo "  - real-margin 매칭 보강: $RM_RESULT"
echo "  - 판매자센터 페이지 덤프: ${DUMPS}개 저장됨"
echo "  - sync 0건 자동 경고 스케줄러 등록"
echo "  - 커밋: $FINAL_HASH"
echo ""
echo "📋 다음 액션 (사장):"
echo "  1. open ~/Desktop/kream_automation/diagnostics/ 으로 스크린샷 열기"
echo "  2. 판매자센터에 입찰이 진짜 있는지/없는지 확인"
echo "  3. 결과 알려주면 다음 작업 결정 (셀렉터 패치 vs 새 입찰 vs 재로그인)"
echo ""
echo "📜 로그: pipeline_step23.log"
echo ""
