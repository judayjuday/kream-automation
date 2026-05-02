#!/bin/bash
# Step 28 — 메뉴 클릭 방식으로 진입
#
# 진단 (Step 27):
#   - /business/asks 직접 접속 → /c2c로 리다이렉트
#   - 메인 페이지 메뉴: "재고별 입찰 관리" "일반 판매 입찰" "통합 입찰 관리" 3개 보임
#   - 판매자 등급: Level 1
#
# 가설: 직접 URL 접속 차단, 메뉴 클릭으로만 이동 가능한 SPA 라우팅
#
# 해결: 메인 페이지 → 입찰 메뉴 클릭 → 실제 도달 URL 캡처 → 거기서 셀렉터 매핑

set -e
exec > >(tee -a pipeline_step28.log) 2>&1
cd ~/Desktop/kream_automation

PIPELINE_START=$(date +%s)
TS=$(date '+%Y%m%d_%H%M%S')

echo "================================================================"
echo "🚀 Step 28 Pipeline — $(date '+%Y-%m-%d %H:%M:%S')"
echo "   메뉴 클릭 방식 진입 + 모든 입찰 메뉴 시도"
echo "================================================================"
echo ""

# ==========================================
# [STAGE 0] 사전 점검
# ==========================================
echo "════════════════════ [STAGE 0] 사전 점검 ════════════════════"
echo "  현재 커밋: $(git log --oneline -1)"
echo ""

# ==========================================
# [STAGE 1] 메뉴 클릭 방식 진단 (작업 폴더에서 실행)
# ==========================================
echo "════════════════════ [STAGE 1] 메뉴 클릭 진단 ════════════════════"
echo ""
echo "  목적: 사이드바의 입찰 관련 메뉴 3개를 차례로 클릭해서"
echo "        실제 데이터가 보이는지 + 진짜 URL 확인"
echo ""

# 작업 폴더에 임시 진단 스크립트 (sys.path 문제 회피)
cat > _step28_menu_click.py <<'PYEOF'
"""사이드바 메뉴 클릭으로 입찰 페이지 진입."""
import asyncio
import json
import sys
from pathlib import Path
from datetime import datetime

sys.path.insert(0, str(Path(__file__).resolve().parent))

async def main():
    from playwright.async_api import async_playwright
    from kream_bot import create_browser, create_context, ensure_logged_in, dismiss_popups
    
    async with async_playwright() as p:
        browser = await create_browser(p, headless=True)
        context = await create_context(browser, storage='auth_state.json')
        page = await context.new_page()
        
        # 메인 페이지로 이동
        print(">>> goto /c2c (메인)")
        await page.goto('https://partner.kream.co.kr/c2c', wait_until='domcontentloaded', timeout=30000)
        await page.wait_for_timeout(3000)
        
        await ensure_logged_in(page, context)
        try: await dismiss_popups(page)
        except: pass
        await page.wait_for_timeout(2000)
        
        # 시도할 메뉴 텍스트들
        MENU_TEXTS = [
            '재고별 입찰 관리',
            '일반 판매 입찰',
            '통합 입찰 관리',
            '입찰 내역 관리',
        ]
        
        results = []
        
        for menu_text in MENU_TEXTS:
            print(f"\n>>> 메뉴 클릭 시도: '{menu_text}'")
            
            # 메인으로 다시 (각 시도마다 초기화)
            try:
                await page.goto('https://partner.kream.co.kr/c2c', wait_until='domcontentloaded', timeout=20000)
                await page.wait_for_timeout(2000)
            except: pass
            
            # 텍스트 매칭으로 클릭 시도
            clicked_info = await page.evaluate(f"""
                (targetText) => {{
                    const candidates = Array.from(document.querySelectorAll('a, button, [role="link"], [role="menuitem"], .menu-item, [class*="menu"], [class*="Menu"]'));
                    for (const el of candidates) {{
                        const text = (el.textContent || '').trim();
                        if (text === targetText || text.includes(targetText)) {{
                            const rect = el.getBoundingClientRect();
                            return {{
                                text: text.substring(0, 50),
                                tag: el.tagName,
                                href: el.href || el.getAttribute('href') || el.getAttribute('data-href') || '',
                                visible: rect.width > 0 && rect.height > 0,
                                onclick_attr: el.getAttribute('onclick') || ''
                            }};
                        }}
                    }}
                    return null;
                }}
            """, menu_text)
            
            print(f"  매칭 결과: {clicked_info}")
            
            if not clicked_info:
                results.append({'menu': menu_text, 'status': 'not_found'})
                continue
            
            # 실제 클릭
            try:
                # href가 있으면 그쪽으로 이동, 없으면 클릭
                if clicked_info.get('href'):
                    print(f"  → href로 직접 이동: {clicked_info['href']}")
                    await page.goto(clicked_info['href'], wait_until='domcontentloaded', timeout=20000)
                else:
                    # 클릭
                    print(f"  → 텍스트 매칭 클릭")
                    await page.evaluate(f"""
                        (targetText) => {{
                            const candidates = Array.from(document.querySelectorAll('a, button, [role="link"], [role="menuitem"], .menu-item, [class*="menu"], [class*="Menu"]'));
                            for (const el of candidates) {{
                                const text = (el.textContent || '').trim();
                                if (text === targetText || text.includes(targetText)) {{
                                    el.click();
                                    return true;
                                }}
                            }}
                            return false;
                        }}
                    """, menu_text)
                
                await page.wait_for_timeout(5000)
                
                final_url = page.url
                
                # 셀렉터 매칭 — 입찰 데이터를 닮은 셀렉터 (가격/사이즈 패턴 텍스트 검사)
                detail_check = await page.evaluate("""
                    () => {
                        // 가격 패턴 (숫자,000원) 검색
                        const allText = document.body.innerText;
                        const pricePattern = /[0-9,]+원/g;
                        const priceMatches = (allText.match(pricePattern) || []).length;
                        
                        // 데이터 행 후보 셀렉터 매칭
                        const sels = {};
                        for (const sel of [
                            'table tbody tr',
                            'div[class*="ListItem"]',
                            'div[class*="ask-row"]',
                            'div[class*="bid-row"]',
                            'div[class*="ask-item"]',
                            'tbody > tr',
                            '[data-testid*="ask"]',
                            '[data-testid*="bid"]',
                            'tr[class*="row"]',
                        ]) {
                            sels[sel] = document.querySelectorAll(sel).length;
                        }
                        
                        return {
                            url: location.href,
                            title: document.title,
                            price_count: priceMatches,
                            selectors: sels,
                            body_len: allText.length,
                            body_preview: allText.substring(0, 800)
                        };
                    }
                """)
                
                print(f"  최종 URL: {detail_check.get('url')}")
                print(f"  가격 패턴 수: {detail_check.get('price_count')}건")
                print(f"  셀렉터: {detail_check.get('selectors')}")
                
                # 스크린샷
                ts = datetime.now().strftime('%Y%m%d_%H%M%S')
                slug = menu_text.replace(' ', '_')
                dump_dir = Path('diagnostics')
                dump_dir.mkdir(exist_ok=True)
                png = dump_dir / f'menu_{slug}_{ts}.png'
                await page.screenshot(path=str(png), full_page=True)
                
                # body 일부
                preview = detail_check.get('body_preview', '')
                
                results.append({
                    'menu': menu_text,
                    'status': 'clicked',
                    'final_url': detail_check.get('url'),
                    'price_count': detail_check.get('price_count'),
                    'selectors': detail_check.get('selectors'),
                    'screenshot': str(png),
                    'body_preview': preview[:500]
                })
                
                # 입찰 데이터처럼 보이는 페이지면 (가격 패턴 5개+) 자세히 출력
                if detail_check.get('price_count', 0) >= 5:
                    print(f"  💰 가격 패턴 많음 — 입찰 데이터 페이지일 가능성 높음")
                    print(f"  body preview: {preview[:400]}")
            except Exception as e:
                print(f"  ERROR: {e}")
                results.append({'menu': menu_text, 'status': 'error', 'error': str(e)})
        
        await browser.close()
        
        # JSON 저장
        with open('menu_click_results.json', 'w', encoding='utf-8') as f:
            json.dump(results, f, ensure_ascii=False, indent=2, default=str)
        print(f"\n>>> 결과 저장: menu_click_results.json")
        
        # 요약
        print("\n" + "="*60)
        print("최종 요약:")
        for r in results:
            if r.get('status') == 'clicked':
                pc = r.get('price_count', 0)
                marker = '💰' if pc >= 5 else '⚪'
                print(f"  {marker} {r['menu']:<20} → URL={r.get('final_url','?')[-40:]:<40} 가격={pc}건")
            else:
                print(f"  ❌ {r['menu']:<20} → {r['status']}")

asyncio.run(main())
PYEOF

echo "  🚀 메뉴 클릭 진단 시작 (3분 정도)..."
python3 _step28_menu_click.py 2>&1 | tail -80
echo ""

# ==========================================
# [STAGE 2] 결과 분석
# ==========================================
echo "════════════════════ [STAGE 2] 분석 ════════════════════"

if [ -f menu_click_results.json ]; then
    BEST_MENU=$(python3 -c "
import json
try:
    with open('menu_click_results.json') as f:
        results = json.load(f)
    # 가격 패턴 가장 많은 메뉴
    clicked = [r for r in results if r.get('status') == 'clicked']
    clicked.sort(key=lambda x: -x.get('price_count', 0))
    if clicked and clicked[0].get('price_count', 0) >= 5:
        r = clicked[0]
        print(f\"FOUND|{r['menu']}|{r['final_url']}|{r['price_count']}\")
    else:
        print('NONE')
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null)
    
    echo "  📊 최적 메뉴: $BEST_MENU"
    
    if [[ "$BEST_MENU" == FOUND* ]]; then
        IFS='|' read -r STATUS MENU_NAME REAL_URL PRICE_CNT <<< "$BEST_MENU"
        echo ""
        echo "  ✅ 입찰 데이터 페이지 발견!"
        echo "    메뉴: $MENU_NAME"
        echo "    실제 URL: $REAL_URL"
        echo "    가격 패턴: ${PRICE_CNT}개"
        echo ""
        
        # 셀렉터 정보 추출
        echo "  📋 그 페이지의 셀렉터 결과:"
        python3 -c "
import json
with open('menu_click_results.json') as f:
    results = json.load(f)
for r in results:
    if r.get('menu') == '$MENU_NAME' and r.get('status') == 'clicked':
        sels = r.get('selectors', {})
        # 0이 아닌 것만
        non_zero = {k:v for k,v in sels.items() if v > 0}
        for k, v in sorted(non_zero.items(), key=lambda x: -x[1]):
            print(f'    {k}: {v}건')
        break
" 2>/dev/null
    else
        echo ""
        echo "  ⚠️ 어느 메뉴도 가격 패턴 5개 이상 발견 못함"
        echo "     → 진짜 입찰 0건이거나 추가 인터랙션(검색 버튼 등) 필요"
    fi
fi
echo ""

echo "  📂 저장된 스크린샷:"
ls -lt diagnostics/menu_*.png 2>/dev/null | head -5 | awk '{print "    "$NF}'
echo ""

# 임시 스크립트 제거
rm -f _step28_menu_click.py 2>/dev/null

# ==========================================
# [STAGE 3] 커밋 + 컨텍스트
# ==========================================
echo "════════════════════ [STAGE 3] 커밋 ════════════════════"

git add menu_click_results.json pipeline_step28.log diagnostics/ 2>/dev/null
git commit -m "diag(Step 28): 메뉴 클릭 방식으로 입찰 페이지 진입 진단

- 4개 입찰 관련 메뉴 차례로 클릭
- 각 메뉴의 실제 도달 URL + 가격 패턴 카운트 + 셀렉터 매핑
- 가격 패턴 5개 이상 = 진짜 데이터 페이지 추정" 2>/dev/null || echo "  (커밋 변경 없음)"
git push origin main 2>/dev/null || echo "  (push 스킵)"

FINAL_HASH=$(git log -1 --format=%h)
echo "  ✅ 커밋: $FINAL_HASH"
echo ""

cat > "다음세션_시작_컨텍스트_v22.md" <<MDEOF
# 다음 세션 시작 컨텍스트 v22

> 작성일: $(date '+%Y-%m-%d %H:%M:%S') (자동 생성)
> 직전 커밋: $(git log -1 --format='%h %s')

## 1. Step 28 진단 결과

목적: /business/asks 직접 접속이 /c2c로 튕기는 문제 → 메뉴 클릭 방식으로 우회.

진단 4개 메뉴: 재고별 입찰 관리 / 일반 판매 입찰 / 통합 입찰 관리 / 입찰 내역 관리

## 2. 발견

$([ -f menu_click_results.json ] && python3 -c "
import json
try:
    with open('menu_click_results.json') as f:
        results = json.load(f)
    for r in results:
        if r.get('status') == 'clicked':
            pc = r.get('price_count', 0)
            marker = '💰 데이터 있음' if pc >= 5 else '⚪ 데이터 없음'
            print(f'- **{r[\"menu\"]}**: URL={r.get(\"final_url\",\"?\")} / 가격패턴={pc}건 / {marker}')
        else:
            print(f'- **{r[\"menu\"]}**: {r.get(\"status\")}')
except: print('- 결과 파일 없음')
" 2>/dev/null)

## 3. 다음 액션

$([[ "$BEST_MENU" == FOUND* ]] && echo "### 정답 발견 — 셀렉터 패치만 하면 끝
- 진짜 데이터 URL: $REAL_URL  
- 메뉴: $MENU_NAME
- kream_adjuster.py에 이 URL + 셀렉터 적용하면 sync 정상화" || echo "### 진짜 입찰 0건 가능성
- 어느 메뉴도 가격 패턴 5개+ 못 찾음
- 메모리상 51건은 옛날 데이터일 수 있음
- diagnostics/menu_*.png 직접 열어서 확인 필요")

## 4. 다음 채팅 첫 메시지

\`\`\`
다음세션_시작_컨텍스트_v22.md 읽고 진단 분석.

스크린샷 결과: [메뉴별 화면 묘사]

오늘 작업: [정답 셀렉터 패치 / 다른 방향]
\`\`\`

## 5. 절대 규칙

7대 규칙 + 자동 토글 ON 금지.
MDEOF

git add 다음세션_시작_컨텍스트_v22.md 2>/dev/null
git commit -m "docs: 다음세션 컨텍스트 v22 (Step 28)" 2>/dev/null || echo "  (변경 없음)"
git push origin main 2>/dev/null || echo "  (push 스킵)"

PIPELINE_END=$(date +%s)
ELAPSED=$((PIPELINE_END - PIPELINE_START))

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🎉 Step 28 진단 완료 — ${ELAPSED}초"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "📋 다음 액션:"
echo "  1. 결과 채팅에 붙여주면 정확한 셀렉터 패치 만들어줌"
echo "  2. 또는 diagnostics/menu_*.png 직접 열어보기"
echo ""
echo "📜 로그: pipeline_step28.log"
echo ""
