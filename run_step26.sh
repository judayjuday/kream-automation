#!/bin/bash
# Step 26 — 진짜 sync 함수 추적 + ask-sales 페이지 직접 검증
#
# 문제: Step 25에서 BID_URLS_FALLBACK에 ask-sales 추가했지만 sync 0건
#        [SYNC] 로그가 안 찍힘 = 새 코드 안 거침
#
# 해결:
#   1. /api/my-bids/sync 라우트 → 실제 호출하는 함수 추적
#   2. ask-sales 페이지를 직접 Playwright로 열어서 입찰 보이는지 확인
#   3. HTML 구조를 캡처해서 정확한 셀렉터 확보
#   4. 그 정보로 정확한 패치 만들 수 있게 함

set -e
exec > >(tee -a pipeline_step26.log) 2>&1
cd ~/Desktop/kream_automation

PIPELINE_START=$(date +%s)
TS=$(date '+%Y%m%d_%H%M%S')

echo "================================================================"
echo "🚀 Step 26 Pipeline — $(date '+%Y-%m-%d %H:%M:%S')"
echo "   진짜 sync 함수 추적 + ask-sales 직접 검증"
echo "================================================================"
echo ""

fail_and_restore() {
    echo ""
    echo "❌ [$1] FAIL — 백업 복원"
    [ -f "kream_server.py.step26_pre.bak" ] && cp "kream_server.py.step26_pre.bak" kream_server.py
    
    lsof -ti:5001 | xargs kill -9 2>/dev/null || true
    sleep 2
    nohup python3 kream_server.py > server.log 2>&1 & disown
    sleep 5
    exit 1
}

# ==========================================
# [STAGE 0] sync 함수 코드 추적 (Claude Code 안 씀, 직접 grep)
# ==========================================
echo "════════════════════ [STAGE 0] sync 함수 추적 ════════════════════"

echo ""
echo "  🔍 /api/my-bids/sync 라우트 위치:"
grep -n "my-bids/sync" kream_server.py | head -5
echo ""

echo "  🔍 sync 라우트가 호출하는 함수 (라우트 정의 + 다음 30줄):"
grep -A 30 "@app.route.*my-bids/sync" kream_server.py | head -35
echo ""

echo "  🔍 'my_bids' / 'collect_my_bids' / 'sync_my_bids' 정의 위치:"
grep -rn "^def collect_my_bids\|^def sync_my_bids\|^async def collect_my_bids\|^async def sync_my_bids" *.py 2>/dev/null
echo ""

echo "  🔍 'partner.kream.co.kr' URL 사용처 전체:"
grep -rn "partner.kream.co.kr" *.py 2>/dev/null | head -20
echo ""

echo "  🔍 BID_URLS_FALLBACK 정의/사용:"
grep -rn "BID_URLS_FALLBACK" *.py 2>/dev/null
echo ""

echo "  🔍 'ask-sales' 사용처:"
grep -rn "ask-sales" *.py 2>/dev/null
echo ""

# ==========================================
# [STAGE 1] 백업
# ==========================================
echo "════════════════════ [STAGE 1] 백업 ════════════════════"
cp kream_server.py "kream_server.py.step26_pre.bak"
echo "  ✅ 백업 완료"
echo ""

# ==========================================
# [STAGE 2] ask-sales 페이지 직접 검증 (Playwright)
# ==========================================
echo "════════════════════ [STAGE 2] ask-sales 페이지 직접 검증 ════════════════════"

cat > /tmp/test_ask_sales.py <<'PYEOF'
"""ask-sales 페이지를 직접 열어서 무엇이 보이는지 확인."""
import asyncio
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

async def main():
    from playwright.async_api import async_playwright
    from kream_bot import create_browser, create_context, ensure_logged_in, dismiss_popups
    
    async with async_playwright() as p:
        browser = await create_browser(p, headless=True)
        context = await create_context(browser, storage='/Users/iseungju/Desktop/kream_automation/auth_state.json')
        page = await context.new_page()
        
        # ask-sales 직접 접근
        print(">>> goto /business/ask-sales")
        await page.goto('https://partner.kream.co.kr/business/ask-sales', wait_until='domcontentloaded', timeout=30000)
        await page.wait_for_timeout(5000)
        
        # 로그인 확인
        logged_in = await ensure_logged_in(page, context)
        print(f"logged_in: {logged_in}")
        print(f"final_url: {page.url}")
        print(f"title: {await page.title()}")
        
        try:
            await dismiss_popups(page)
        except: pass
        
        await page.wait_for_timeout(3000)
        
        # 페이지에서 다양한 셀렉터 시도해서 어떤 게 입찰 행인지 찾기
        selectors_to_try = [
            ('table tbody tr', 'table 행'),
            ('tbody tr', '직접 tbody 행'),
            ('div[class*="row"]', 'row 클래스 div'),
            ('div[class*="Row"]', 'Row 클래스 div'),
            ('div[class*="item"]', 'item 클래스 div'),
            ('div[class*="Item"]', 'Item 클래스 div'),
            ('div[class*="ask"]', 'ask 클래스 div'),
            ('div[class*="bid"]', 'bid 클래스 div'),
            ('[role="row"]', 'role=row'),
            ('li', 'li 항목'),
            ('article', 'article'),
            ('[data-testid]', 'data-testid'),
        ]
        
        results = {}
        for sel, desc in selectors_to_try:
            try:
                els = await page.query_selector_all(sel)
                results[sel] = {'desc': desc, 'count': len(els)}
            except Exception as e:
                results[sel] = {'desc': desc, 'error': str(e)[:50]}
        
        # 가장 유망한 후보 (5건 이상)
        promising = [(s, r) for s, r in results.items() if r.get('count', 0) >= 5]
        promising.sort(key=lambda x: -x[1]['count'])
        
        print("\n>>> 셀렉터 결과:")
        for sel, r in results.items():
            cnt = r.get('count', '?')
            print(f"  {sel:<35} ({r['desc']}): {cnt}")
        
        print("\n>>> 유망한 후보 (5건 이상):")
        for sel, r in promising[:5]:
            print(f"  {sel}: {r['count']}건")
        
        # 가장 유망한 셀렉터의 첫 번째 요소 HTML 샘플
        if promising:
            best_sel = promising[0][0]
            first_el = await page.query_selector(best_sel)
            if first_el:
                try:
                    html = await first_el.inner_html()
                    print(f"\n>>> {best_sel} 첫 번째 요소 HTML (처음 1000자):")
                    print(html[:1000])
                except: pass
        
        # body 텍스트 일부 (실제 페이지 내용 파악)
        try:
            body_text = await page.evaluate("() => document.body.innerText.substring(0, 2000)")
            print(f"\n>>> body 텍스트 일부:")
            print(body_text)
        except: pass
        
        # 스크린샷 + HTML 저장
        from datetime import datetime
        ts = datetime.now().strftime('%Y%m%d_%H%M%S')
        dump_dir = Path('/Users/iseungju/Desktop/kream_automation/diagnostics')
        dump_dir.mkdir(exist_ok=True)
        png = dump_dir / f'ask_sales_{ts}.png'
        html_f = dump_dir / f'ask_sales_{ts}.html'
        await page.screenshot(path=str(png), full_page=True)
        html_content = await page.content()
        html_f.write_text(html_content, encoding='utf-8')
        print(f"\n>>> 저장됨:")
        print(f"  스크린샷: {png}")
        print(f"  HTML: {html_f}")
        print(f"  HTML 크기: {len(html_content)} bytes")
        
        await browser.close()
        
        # 결과 JSON으로 저장 (다음 스크립트에서 활용)
        result_data = {
            'logged_in': logged_in,
            'final_url': page.url if False else None,  # closed
            'selectors': results,
            'promising': [(s, r['count']) for s, r in promising],
            'screenshot': str(png),
            'html': str(html_f),
        }
        with open('/tmp/ask_sales_result.json', 'w') as f:
            json.dump(result_data, f, ensure_ascii=False, indent=2, default=str)

asyncio.run(main())
PYEOF

echo "  🚀 ask-sales 페이지 직접 접속..."
python3 /tmp/test_ask_sales.py 2>&1 | head -100 || echo "  실행 실패"
echo ""

# ==========================================
# [STAGE 3] 결과 분석 + 결론
# ==========================================
echo "════════════════════ [STAGE 3] 분석 ════════════════════"

if [ -f /tmp/ask_sales_result.json ]; then
    echo "  ✅ 진단 데이터 저장됨"
    
    PROMISING=$(python3 -c "
import json
try:
    with open('/tmp/ask_sales_result.json') as f:
        d = json.load(f)
    p = d.get('promising', [])
    if p:
        print('YES')
        print(p[0])
    else:
        print('NO')
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null)
    
    echo ""
    echo "  📊 분석 결과:"
    if [[ "$PROMISING" == YES* ]]; then
        echo "  ✅ 유망 셀렉터 발견됨 → 다음 단계: 정확한 셀렉터로 패치"
        echo "$PROMISING" | tail -1
    else
        echo "  ⚠️  5건 이상 잡히는 셀렉터 없음"
        echo "     → 페이지가 진짜 비어있거나 (입찰 0건)"
        echo "     → 또는 페이지가 동적 로딩 (스크롤/대기 필요)"
    fi
fi

# 진단 파일 위치 안내
echo ""
echo "  📂 사장이 직접 확인할 파일:"
ls -lt diagnostics/ask_sales_*.png 2>/dev/null | head -1 | awk '{print "    "$NF}'
ls -lt diagnostics/ask_sales_*.html 2>/dev/null | head -1 | awk '{print "    "$NF}'

# JSON 결과 저장
cp /tmp/ask_sales_result.json "ask_sales_diagnosis_${TS}.json" 2>/dev/null || true
echo "    ask_sales_diagnosis_${TS}.json"

echo ""

# ==========================================
# [STAGE 4] 컨텍스트 v20
# ==========================================
echo "════════════════════ [STAGE 4] 컨텍스트 v20 ════════════════════"

cat > "다음세션_시작_컨텍스트_v20.md" <<MDEOF
# 다음 세션 시작 컨텍스트 v20

> 작성일: $(date '+%Y-%m-%d %H:%M:%S') (자동 생성)
> 직전 커밋: $(git log -1 --format='%h %s')

## 1. Step 26 진단 결과

ask-sales 페이지 직접 접속 + 셀렉터 매핑.

### 진단 산출물
- diagnostics/ask_sales_${TS}.png — 페이지 스크린샷
- diagnostics/ask_sales_${TS}.html — 전체 HTML
- ask_sales_diagnosis_${TS}.json — 셀렉터별 매칭 수

### 핵심 발견
$([ -f /tmp/ask_sales_result.json ] && python3 -c "
import json
try:
    with open('/tmp/ask_sales_result.json') as f:
        d = json.load(f)
    p = d.get('promising', [])
    print(f'- logged_in: {d.get(\"logged_in\")}')
    print(f'- 유망 셀렉터: {p[:3] if p else \"없음 (페이지가 비어있거나 동적 로딩)\"}')
except: print('- 진단 파일 읽기 실패')
" 2>/dev/null)

## 2. 다음 액션 (사장 직접 확인 우선)

1. **스크린샷 직접 열어보기:**
   \`\`\`
   open ~/Desktop/kream_automation/diagnostics/ask_sales_${TS}.png
   \`\`\`
   
2. **화면에 뭐가 보이는지 결정:**
   - **입찰이 보이면** → 셀렉터만 패치하면 끝
   - **빈 페이지/리다이렉트** → 진짜 입찰 0건이거나 다른 메뉴 필요
   - **로그인 화면** → \`python3 kream_bot.py --mode auto-login-partner\`

3. **결과 알려주면 정확한 패치 만들어줌**

## 3. 누적 (Step 18~26)

| Step | 커밋 |
|---|---|
| 25 | bf214f5 |
| **26 (진단만)** | (no commit) |

## 4. 다음 채팅 첫 메시지

\`\`\`
다음세션_시작_컨텍스트_v20.md 읽고 진단 결과 분석.

ask_sales_${TS}.png 직접 보고 결과:
- [입찰 N건 보임 / 빈 페이지 / 로그인 화면 / 다른 메시지]
- 유망 셀렉터 결과: [위 진단 참조]

오늘 작업: 정확한 패치 또는 다른 방향
\`\`\`

## 5. 절대 규칙

7대 규칙 + 자동 토글 ON 금지.
MDEOF

echo "  ✅ 다음세션_시작_컨텍스트_v20.md 생성"
git add 다음세션_시작_컨텍스트_v20.md pipeline_step26.log "ask_sales_diagnosis_${TS}.json" 2>/dev/null
git commit -m "diag(Step 26): ask-sales 페이지 직접 진단 + 셀렉터 매핑" 2>/dev/null || echo "  (변경 없음)"
git push origin main 2>/dev/null || echo "  (push 스킵)"
echo ""

PIPELINE_END=$(date +%s)
ELAPSED=$((PIPELINE_END - PIPELINE_START))

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🎉 Step 26 진단 완료 — ${ELAPSED}초"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "📋 사장 액션 (5초):"
echo "  open ~/Desktop/kream_automation/diagnostics/ask_sales_${TS}.png"
echo ""
echo "  화면 보고 결과 알려주면 → 정확한 패치 다음 채팅에서"
echo ""
echo "📜 로그: pipeline_step26.log"
echo ""
