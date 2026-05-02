#!/bin/bash
# Step 24 — sync 자동 복구 (시나리오 A/B 모두 처리)
#   1. 판매자센터 메뉴 자동 탐색 (URL 변경 감지)
#   2. 새 URL로 sync 함수 자동 패치
#   3. 셀렉터 다중 fallback (구버전/신버전 호환)
#   4. 결과에 따라 사장에게 다음 액션 명시

set -e
exec > >(tee -a pipeline_step24.log) 2>&1
cd ~/Desktop/kream_automation

PIPELINE_START=$(date +%s)
TS=$(date '+%Y%m%d_%H%M%S')

echo "================================================================"
echo "🚀 Step 24 Pipeline — $(date '+%Y-%m-%d %H:%M:%S')"
echo "   sync 자동 복구 (URL 탐지 + 셀렉터 보강)"
echo "================================================================"
echo ""

fail_and_restore() {
    echo ""
    echo "❌ [$1] FAIL — 백업 복원"
    [ -f "kream_server.py.step24_pre.bak" ] && cp "kream_server.py.step24_pre.bak" kream_server.py
    [ -f "kream_bot.py.step24_pre.bak" ] && cp "kream_bot.py.step24_pre.bak" kream_bot.py
    
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
cp kream_server.py "kream_server.py.step24_pre.bak"
cp kream_bot.py "kream_bot.py.step24_pre.bak"
echo "  ✅ 백업 완료"
echo ""

# ==========================================
# [STAGE 2] 작업지시서
# ==========================================
echo "════════════════════ [STAGE 2] 작업지시서 ════════════════════"

cat > "작업지시서_Step24.md" <<'MDEOF'
# 작업지시서 — Step 24: sync 자동 복구

> 의존: Step 23 (커밋 0ca8662)
> 진단: /c2c/sell/bid 접근 시 /c2c 루트로 리다이렉트됨 (URL 변경 추정)

## 작업 #1: 판매자센터 메뉴 탐색 라우트

URL이 변경됐다면 메인 페이지에서 메뉴 링크를 찾아낸다.

### 신규 라우트: /api/diagnostics/explore-menu

```python
@app.route('/api/diagnostics/explore-menu', methods=['POST'])
def api_explore_menu():
    """판매자센터 메인에서 입찰 관련 링크 자동 탐색."""
    try:
        import asyncio
        
        async def explore():
            from playwright.async_api import async_playwright
            from kream_bot import create_browser, create_context, ensure_logged_in, dismiss_popups
            
            async with async_playwright() as p:
                browser = await create_browser(p, headless=True)
                context = await create_context(browser, storage='auth_state.json')
                page = await context.new_page()
                
                await page.goto('https://partner.kream.co.kr/c2c', wait_until='domcontentloaded', timeout=30000)
                await page.wait_for_timeout(3000)
                
                logged_in = await ensure_logged_in(page, context)
                try: 
                    await dismiss_popups(page)
                except: pass
                
                await page.wait_for_timeout(2000)
                
                # 모든 링크 수집
                links = await page.evaluate("""
                    () => {
                        const allLinks = Array.from(document.querySelectorAll('a, [role="link"], button'));
                        return allLinks.map(el => ({
                            text: (el.textContent || '').trim().slice(0, 50),
                            href: el.href || el.getAttribute('data-href') || '',
                            classes: el.className || ''
                        })).filter(l => l.text.length > 0).slice(0, 100);
                    }
                """)
                
                # 입찰/판매 관련 키워드 매칭
                bid_keywords = ['입찰', '판매', 'bid', 'sell', '내 입찰', '입찰 관리', '판매 관리', 'C2C', 'P2P']
                bid_links = []
                for link in links:
                    text_lower = link['text'].lower()
                    href_lower = link['href'].lower()
                    if any(kw.lower() in text_lower for kw in bid_keywords) or \
                       any(kw in href_lower for kw in ['bid', 'sell', 'c2c']):
                        bid_links.append(link)
                
                # 페이지 정보
                page_info = {
                    'url': page.url,
                    'title': await page.title(),
                    'logged_in': logged_in,
                }
                
                # 스크린샷
                from datetime import datetime
                from pathlib import Path
                ts = datetime.now().strftime('%Y%m%d_%H%M%S')
                dump_dir = Path(__file__).parent / 'diagnostics'
                dump_dir.mkdir(exist_ok=True)
                screenshot_path = dump_dir / f'menu_explore_{ts}.png'
                await page.screenshot(path=str(screenshot_path), full_page=True)
                
                await browser.close()
                
                return {
                    'page_info': page_info,
                    'all_links_count': len(links),
                    'bid_related_links': bid_links,
                    'all_links_sample': links[:30],
                    'screenshot': str(screenshot_path)
                }
        
        result = asyncio.run(explore())
        return jsonify({'ok': True, **result})
    except Exception as e:
        import traceback
        return jsonify({'ok': False, 'error': str(e), 'trace': traceback.format_exc()}), 500
```

## 작업 #2: 다중 URL 시도 sync

기존 sync 함수가 어떤 URL로 가는지 코드에서 찾아서, 여러 URL을 순차 시도하도록 변경:

### kream_bot.py — collect_my_bids (또는 sync 함수) 강화

기존 함수 안의 `await page.goto(...)` 부분을 다음 패턴으로 교체:

```python
# 다중 URL 시도 (KREAM이 URL 경로를 바꿨을 가능성 대응)
BID_URLS_FALLBACK = [
    'https://partner.kream.co.kr/c2c/sell/bid',     # 기존
    'https://partner.kream.co.kr/c2c/sell',          # 변형 1
    'https://partner.kream.co.kr/c2c/bid',           # 변형 2
    'https://partner.kream.co.kr/business/bid',      # 변형 3
    'https://partner.kream.co.kr/c2c',               # 메인 (메뉴 클릭으로 이동)
]

bid_page_loaded = False
for url in BID_URLS_FALLBACK:
    try:
        await page.goto(url, wait_until='domcontentloaded', timeout=20000)
        await page.wait_for_timeout(2000)
        
        # 입찰 테이블이 실제로 있는지 검증
        table_count = await page.evaluate("""
            () => {
                const tables = document.querySelectorAll('table tbody tr, .bid-list-item, [class*="bid-row"]');
                return tables.length;
            }
        """)
        
        if table_count > 0:
            print(f"[SYNC] 입찰 페이지 로드 성공: {url} ({table_count}건)")
            bid_page_loaded = True
            break
        else:
            print(f"[SYNC] {url} → 0건 (다음 시도)")
    except Exception as e:
        print(f"[SYNC] {url} 실패: {e}")
        continue

# 메인 페이지 도달했지만 입찰 메뉴가 다른 곳에 있는 경우
if not bid_page_loaded:
    try:
        # 메뉴 클릭으로 이동 시도
        await page.goto('https://partner.kream.co.kr/c2c', timeout=20000)
        await page.wait_for_timeout(2000)
        
        # 입찰 관련 링크 찾아서 클릭
        clicked = await page.evaluate("""
            () => {
                const candidates = [
                    'a[href*="bid"]', 'a[href*="sell"]', 
                    '[role="link"]', 'button'
                ];
                for (const sel of candidates) {
                    const els = document.querySelectorAll(sel);
                    for (const el of els) {
                        const text = (el.textContent || '').trim();
                        if (text.includes('입찰') || text.includes('내 입찰') || text.includes('판매')) {
                            el.click();
                            return text;
                        }
                    }
                }
                return null;
            }
        """)
        if clicked:
            print(f"[SYNC] 메뉴 클릭: {clicked}")
            await page.wait_for_timeout(3000)
            bid_page_loaded = True
    except Exception as e:
        print(f"[SYNC] 메뉴 클릭 실패: {e}")
```

기존 함수의 첫 goto만 위 블록으로 교체. 이후 파싱 로직(셀 추출 등)은 그대로 유지.

이미 `BID_URLS_FALLBACK` 리스트가 있으면 스킵 (멱등성).

## 작업 #3: 셀렉터 fallback

기존 행 추출 부분(보통 `await page.query_selector_all('table tbody tr')` 같은)을 다중 셀렉터로 교체:

```python
# 다중 셀렉터 시도
ROW_SELECTORS = [
    'table tbody tr',
    '.bid-list-item',
    '[class*="bid-row"]',
    '[class*="bid_row"]',
    '[data-testid*="bid"]',
    'div[class*="row"][class*="bid"]',
    '.bid-table-body > div',  # 카드형 레이아웃
]

rows = []
for selector in ROW_SELECTORS:
    try:
        rows = await page.query_selector_all(selector)
        if rows and len(rows) > 0:
            print(f"[SYNC] 행 추출 셀렉터: {selector} → {len(rows)}건")
            break
    except: continue

if not rows:
    print("[SYNC] 모든 셀렉터 0건 — 페이지 구조 변경")
```

기존 selector 한 줄을 위 블록으로 교체. 변수명(rows)은 기존과 일치시킴.

## 검증

1. python3 -m py_compile kream_server.py
2. python3 -m py_compile kream_bot.py
3. 서버 재시작
4. /api/diagnostics/explore-menu POST → ok=true, bid_related_links 배열 (시간 걸림)
5. /api/my-bids/sync POST → 새 코드로 동작 (입찰 발견되면 추가될 것)
6. 회귀: health, capital-status, daily-summary

## 절대 규칙
- 기존 sync 결과 파싱 로직 변경 금지 (URL/셀렉터만 변경)
- DB 스키마 변경 금지
- 자동 토글 ON 변경 금지

## 커밋
```
feat(Step 24): sync URL/셀렉터 자동 복구

- /api/diagnostics/explore-menu: 판매자센터 링크 자동 탐색
- kream_bot.py sync 함수에 다중 URL fallback 추가
- 행 추출 셀렉터 다중 fallback (구버전/신버전 호환)
- 메뉴 클릭 fallback (URL 직접 접근 실패 시)

배경: /c2c/sell/bid → /c2c 리다이렉트 진단됨. URL 변경 추정.
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
작업지시서_Step24.md 읽고 끝까지 진행. 질문 절대 금지. 사용자 개입 요청 금지.

순서:
1. 작업지시서 읽기

2. kream_server.py에 /api/diagnostics/explore-menu POST 라우트 추가
   (이미 있으면 스킵)

3. kream_bot.py 수정 (멱등성):
   a. 내 입찰 sync 함수 찾기 (보통 collect_my_bids, sync_my_bids, fetch_my_bids 등)
   b. 함수 안 첫 page.goto 부분을 BID_URLS_FALLBACK 리스트 + 순차 시도로 교체
      - 이미 BID_URLS_FALLBACK 변수 있으면 스킵
   c. 행 추출 셀렉터 부분을 ROW_SELECTORS fallback으로 교체
      - 이미 ROW_SELECTORS 변수 있으면 스킵
   d. URL 시도 모두 실패 시 메인 페이지 → 메뉴 클릭 fallback 추가

4. 문법:
   python3 -m py_compile kream_server.py
   python3 -m py_compile kream_bot.py

5. 서버 재시작:
   lsof -ti:5001 | xargs kill -9 || true
   sleep 2
   nohup python3 kream_server.py > server.log 2>&1 & disown
   sleep 8

6. 메뉴 탐색 실행 (시간 걸림, max-time 90초):
   curl -s --max-time 90 -X POST http://localhost:5001/api/diagnostics/explore-menu | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if d.get('ok'):
        pi = d.get('page_info', {})
        bl = d.get('bid_related_links', [])
        print(f'logged_in={pi.get(\"logged_in\")} url={pi.get(\"url\")} title={pi.get(\"title\")}')
        print(f'total links={d.get(\"all_links_count\")} bid_related={len(bl)}')
        for link in bl[:10]:
            print(f'  • {link[\"text\"]} → {link[\"href\"]}')
    else:
        print('FAIL:', d.get('error', '')[:200])
except Exception as e:
    print('ERROR:', e)
"
   
   메뉴 탐색이 실패해도 진행 (작업 #1은 진단용)

7. 새 sync 동작 확인:
   curl -s --max-time 60 -X POST http://localhost:5001/api/my-bids/sync | python3 -m json.tool
   sleep 30
   # task 폴링
   for i in 1 2 3 4 5; do
       TASK_RESULT=$(curl -s "http://localhost:5001/api/task/task_$(($(curl -s http://localhost:5001/api/auto-bid/status | python3 -c "import sys,json; print(json.load(sys.stdin).get('lastTaskId','1').replace('task_',''))" 2>/dev/null || echo 1)))")
       sleep 5
   done
   
   # 최종 입찰 수
   curl -s http://localhost:5001/api/my-bids/local | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'sync 후 bids:', len(d.get('bids', [])))"

8. server.log에서 [SYNC] 로그 추출 (어느 URL이 통했는지):
   tail -200 server.log | grep -E "\[SYNC\]" | tail -20

9. 회귀:
   curl -s -o /dev/null -w "%{http_code}" http://localhost:5001/api/health → 200
   curl -s http://localhost:5001/api/capital-status | grep -q '"ok": true'
   curl -s http://localhost:5001/api/daily-summary | grep -q '"ok": true'

10. 모두 PASS면 단일 커밋 + push:
    git add -A
    git commit -m "feat(Step 24): sync URL/셀렉터 자동 복구

    - /api/diagnostics/explore-menu: 판매자센터 메뉴 자동 탐색
    - kream_bot.py sync 함수: 다중 URL fallback (5개 변형)
    - 행 추출 셀렉터 fallback (구/신 버전 호환)
    - 메뉴 클릭 fallback

    배경: /c2c/sell/bid → /c2c 리다이렉트 진단됨"
    git push origin main

11. 끝.

질문/확인 절대 금지. 검증 FAIL 시 즉시 종료.
CLAUDE_PROMPT

echo ""
echo "🔍 최종 검증..."
verify_server || fail_and_restore "최종 검증"

echo ""
echo "  📋 메뉴 탐색 실행 (90초 제한)..."
EXPLORE=$(curl -s --max-time 90 -X POST http://localhost:5001/api/diagnostics/explore-menu)
echo "$EXPLORE" | python3 -m json.tool 2>/dev/null | head -50
echo ""

# 입찰 관련 링크 추출
BID_LINKS=$(echo "$EXPLORE" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    bl = d.get('bid_related_links', [])
    print(len(bl))
except: print(0)
" 2>/dev/null)
echo "  📊 발견된 입찰 관련 링크: ${BID_LINKS}개"

# sync 재실행
echo ""
echo "  🔄 새 sync 실행..."
SYNC_RAW=$(curl -s -X POST http://localhost:5001/api/my-bids/sync)
SYNC_TASK=$(echo "$SYNC_RAW" | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('taskId') or '')
except: print('')
" 2>/dev/null)

if [ -n "$SYNC_TASK" ]; then
    echo "    task: $SYNC_TASK"
    for i in {1..30}; do
        sleep 3
        STATUS=$(curl -s "http://localhost:5001/api/task/$SYNC_TASK" | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('status','unknown'))
except: print('error')
" 2>/dev/null)
        echo "    [$i/30] $STATUS"
        [ "$STATUS" == "done" ] || [ "$STATUS" == "completed" ] || [ "$STATUS" == "success" ] && break
        [ "$STATUS" == "failed" ] || [ "$STATUS" == "error" ] && break
    done
fi

sleep 3
NEW_BIDS=$(curl -s http://localhost:5001/api/my-bids/local | python3 -c "
import sys,json
try: print(len(json.load(sys.stdin).get('bids',[])))
except: print('ERROR')
" 2>/dev/null)
echo "  📊 sync 후 입찰: ${NEW_BIDS}건"

echo ""
echo "  📜 [SYNC] 로그 마지막 20줄:"
tail -300 server.log 2>/dev/null | grep "\[SYNC\]" | tail -20 || echo "    (로그 없음)"

FINAL_HASH=$(git log -1 --format=%h)
echo ""
echo "  ✅ 커밋: $FINAL_HASH"
echo ""

# ==========================================
# [STAGE 4] 결론 + 컨텍스트 v18
# ==========================================
echo "════════════════════ [STAGE 4] 결론 ════════════════════"

if [ "${NEW_BIDS:-0}" -gt 0 ]; then
    echo "  ✅ sync 복구 성공! 입찰 ${NEW_BIDS}건 복원"
    echo "     → KREAM URL 변경 → 자동 fallback 적용"
    SUMMARY="✅ ${NEW_BIDS}건 복원"
else
    echo "  ⚠️  sync 후에도 0건"
    if [ "${BID_LINKS:-0}" -gt 0 ]; then
        echo "     → 메뉴는 존재함. 셀렉터 매칭 실패 가능성"
        echo "     → diagnostics/menu_explore_*.png 직접 확인"
    else
        echo "     → 메뉴에 입찰 관련 링크 없음"
        echo "     → 판매자센터에 진짜 입찰 0건이거나 페이지 전체 변경"
    fi
    SUMMARY="⚠️ 여전히 0건 — 사장 직접 판매자센터 확인 필요"
fi

echo ""

cat > "다음세션_시작_컨텍스트_v18.md" <<MDEOF
# 다음 세션 시작 컨텍스트 v18

> 작성일: $(date '+%Y-%m-%d %H:%M:%S') (자동 생성)
> 직전 커밋: $(git log -1 --format='%h %s')

## 1. Step 24 sync 복구 시도 결과

- $SUMMARY
- 메뉴 탐색: ${BID_LINKS}개 입찰 관련 링크 발견
- sync 후 입찰: ${NEW_BIDS}건

## 2. 다음 액션

$([ "${NEW_BIDS:-0}" -gt 0 ] && echo "### 정상 복구 — Step 25 후속 자동화로 진행" || echo "### 사장 직접 확인 필요
1. open ~/Desktop/kream_automation/diagnostics/ → 최근 PNG 열기
2. 판매자센터 직접 로그인해서 입찰 메뉴 클릭
3. 화면 보고:
   - 입찰 진짜 0건 → 새 입찰 시작
   - 입찰 있는데 다른 URL → URL 추가 패치
   - 로그인 자체 깨짐 → \`python3 kream_bot.py --mode auto-login-partner\`")

## 3. 누적 (Step 18~24)

| Step | 커밋 |
|---|---|
| 18-A/B/C/D ~ 22 | ff97377 → 5d36225 |
| 23 (진단) | 0ca8662 |
| **24 (복구)** | **$FINAL_HASH** |

## 4. 다음 채팅 첫 메시지

\`\`\`
다음세션_시작_컨텍스트_v18.md 읽고 현재 상태 파악.

판매자센터 직접 확인 결과: [입찰 N건 / 없음 / 로그인 깨짐]

오늘 작업: [기획 / 구체 지시]
\`\`\`

## 5. 절대 규칙

7대 규칙 + 자동 토글 ON 금지.
MDEOF

echo "  ✅ 다음세션_시작_컨텍스트_v18.md 생성"
git add 다음세션_시작_컨텍스트_v18.md pipeline_step24.log 2>/dev/null
git commit -m "docs: 다음세션 컨텍스트 v18 (Step 24 복구 시도)" 2>/dev/null || echo "  (변경 없음)"
git push origin main 2>/dev/null || echo "  (push 스킵)"
echo ""

PIPELINE_END=$(date +%s)
ELAPSED=$((PIPELINE_END - PIPELINE_START))
ELAPSED_MIN=$((ELAPSED / 60))

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🎉 Step 24 완료 — ${ELAPSED_MIN}분 ${ELAPSED}초"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "결과: $SUMMARY"
echo ""
echo "📋 사장 액션:"
echo "  1. 메뉴 탐색 결과 + sync 결과 채팅에 붙여넣기"
echo "  2. 필요 시 diagnostics/ 폴더 열어서 스크린샷 확인"
echo ""
echo "📜 로그: pipeline_step24.log"
echo ""
