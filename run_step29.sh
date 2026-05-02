#!/bin/bash
# Step 29 — Playwright Codegen + API 자동 캡처
#
# 접근법 변경: 자동 진단(20번 시도) → 인간 인터랙션(1번)
#
# 사장 액션 (5분):
#   1. 자동으로 브라우저 창 뜸 (Codegen + Network 캡처)
#   2. 사이드바에서 "재고별 입찰 관리" 또는 입찰 보이는 메뉴 직접 클릭
#   3. 페이지 보고 입찰 데이터 보이면 그대로 두고 창 닫기
#
# 결과: 정답 URL + 셀렉터 + API 호출 자동 기록됨

set -e
exec > >(tee -a pipeline_step29.log) 2>&1
cd ~/Desktop/kream_automation

PIPELINE_START=$(date +%s)
TS=$(date '+%Y%m%d_%H%M%S')

echo "================================================================"
echo "🚀 Step 29 — Playwright Codegen + API 캡처"
echo "   사장이 5분만 직접 클릭하면 정답 자동 추출"
echo "================================================================"
echo ""

# ==========================================
# [STAGE 0] 안내
# ==========================================
echo "════════════════════ 사장 액션 안내 ════════════════════"
echo ""
echo "  곧 Chrome 창이 뜹니다 (headless=false)."
echo ""
echo "  📋 화면 뜨면 5분 안에 다음 진행:"
echo "    1. 사이드바 메뉴 중 '재고별 입찰 관리' 또는"
echo "       입찰 보이는 메뉴를 직접 클릭"
echo "    2. 페이지 로드되면 '입찰 데이터'가 보이는지 확인"
echo "    3. 다른 입찰 메뉴 한두 개 더 클릭해봐도 OK"
echo "    4. 다 본 후 그냥 브라우저 창 닫기 (X 클릭)"
echo ""
echo "  자동으로 기록되는 것:"
echo "    - 클릭한 메뉴/버튼"
echo "    - 이동한 URL"
echo "    - API 요청/응답 (HAR 파일)"
echo "    - 페이지 HTML"
echo ""
echo "  📂 결과 저장 위치: codegen_capture/"
echo ""
read -p "  ⏎ Enter 눌러서 시작..." dummy
echo ""

# ==========================================
# [STAGE 1] 캡처 스크립트 실행
# ==========================================
echo "════════════════════ [STAGE 1] 캡처 시작 ════════════════════"

mkdir -p codegen_capture

cat > _step29_capture.py <<'PYEOF'
"""Playwright Codegen + Network 캡처."""
import asyncio
import json
import sys
from pathlib import Path
from datetime import datetime

sys.path.insert(0, str(Path(__file__).resolve().parent))

async def main():
    from playwright.async_api import async_playwright
    from kream_bot import create_browser, create_context
    
    ts = datetime.now().strftime('%Y%m%d_%H%M%S')
    capture_dir = Path('codegen_capture')
    capture_dir.mkdir(exist_ok=True)
    
    har_path = capture_dir / f'network_{ts}.har'
    
    async with async_playwright() as p:
        browser = await create_browser(p, headless=False)
        # HAR 캡처 활성화
        context = await browser.new_context(
            storage_state='auth_state.json',
            viewport={'width': 1440, 'height': 900},
            locale='ko-KR',
            record_har_path=str(har_path),
            record_har_content='embed',
        )
        
        page = await context.new_page()
        
        # 모든 네비게이션 추적
        nav_log = []
        async def on_frame_navigated(frame):
            if frame == page.main_frame:
                nav_log.append({
                    'url': frame.url,
                    'time': datetime.now().isoformat(),
                })
        page.on('framenavigated', on_frame_navigated)
        
        # 모든 클릭 추적 (window 레벨)
        await page.add_init_script("""
            window.__clickLog = [];
            document.addEventListener('click', (e) => {
                const el = e.target;
                window.__clickLog.push({
                    tag: el.tagName,
                    text: (el.textContent || '').trim().slice(0, 60),
                    classes: el.className || '',
                    href: el.href || el.getAttribute('href') || '',
                    time: new Date().toISOString()
                });
            }, true);
        """)
        
        # 메인 페이지로 이동
        print(">>> 판매자센터 메인으로 이동...")
        await page.goto('https://partner.kream.co.kr/c2c', wait_until='domcontentloaded', timeout=30000)
        await page.wait_for_timeout(3000)
        
        print(">>> 브라우저 창에서 직접 클릭하세요")
        print(">>> 입찰 메뉴 → 입찰 데이터 확인 → 창 닫기")
        print(">>> (창 닫으면 자동으로 결과 저장)")
        
        # 사장이 창 닫을 때까지 대기
        try:
            # 최대 10분 대기, 페이지 닫히면 종료
            for i in range(600):  # 10분
                if page.is_closed():
                    break
                await asyncio.sleep(1)
        except: pass
        
        # 클릭 로그 추출 시도 (페이지 살아있을 때만)
        click_log = []
        try:
            if not page.is_closed():
                click_log = await page.evaluate("() => window.__clickLog || []")
        except: pass
        
        # HTML 캡처 시도
        try:
            if not page.is_closed():
                final_url = page.url
                final_html = await page.content()
                final_title = await page.title()
                html_path = capture_dir / f'final_page_{ts}.html'
                html_path.write_text(final_html, encoding='utf-8')
                
                # 셀렉터 매핑
                selectors = await page.evaluate("""
                    () => {
                        const sels = {};
                        for (const sel of [
                            'table tbody tr', 'tbody > tr', 
                            'div[class*="row"]', 'div[class*="Row"]',
                            'div[class*="item"]', 'div[class*="Item"]',
                            'div[class*="ask"]', 'div[class*="Ask"]',
                            'div[class*="bid"]', 'div[class*="Bid"]',
                            '[role="row"]',
                        ]) {
                            sels[sel] = document.querySelectorAll(sel).length;
                        }
                        // 가격 패턴 텍스트
                        const allText = document.body.innerText;
                        const prices = (allText.match(/[0-9,]+원/g) || []).length;
                        return { selectors: sels, price_count: prices, body_len: allText.length };
                    }
                """)
                
                # 마지막 스크린샷
                png_path = capture_dir / f'final_page_{ts}.png'
                await page.screenshot(path=str(png_path), full_page=True)
                
                final_capture = {
                    'url': final_url,
                    'title': final_title,
                    'html_path': str(html_path),
                    'screenshot_path': str(png_path),
                    'selectors': selectors,
                }
            else:
                final_capture = {'note': '페이지 이미 닫힘'}
        except Exception as e:
            final_capture = {'error': str(e)}
        
        try:
            await context.close()
            await browser.close()
        except: pass
        
        # 결과 저장
        result = {
            'timestamp': ts,
            'navigations': nav_log,
            'click_log': click_log,
            'final': final_capture,
            'har_file': str(har_path),
        }
        
        result_path = capture_dir / f'result_{ts}.json'
        result_path.write_text(json.dumps(result, ensure_ascii=False, indent=2, default=str), encoding='utf-8')
        
        print(f"\n>>> 캡처 결과:")
        print(f"  네비게이션: {len(nav_log)}회")
        print(f"  클릭: {len(click_log)}회")
        print(f"  HAR: {har_path}")
        print(f"  결과: {result_path}")
        
        # API 요청 추출 (HAR에서)
        if har_path.exists():
            try:
                with open(har_path) as f:
                    har = json.load(f)
                entries = har.get('log', {}).get('entries', [])
                api_calls = [
                    e for e in entries
                    if 'kream.co.kr' in e['request']['url']
                    and any(p in e['request']['url'] for p in ['/api/', '/business/', 'json'])
                    and e['response']['status'] == 200
                ]
                print(f"  API 호출 (200 OK): {len(api_calls)}건")
                
                # 입찰 관련 추정 API
                bid_apis = [
                    e for e in api_calls
                    if any(kw in e['request']['url'].lower() for kw in ['ask', 'bid', 'sale', 'order'])
                ]
                if bid_apis:
                    print(f"\n>>> 입찰 관련 API (상위 5개):")
                    for e in bid_apis[:5]:
                        print(f"  {e['request']['method']} {e['request']['url'][:120]}")
                        # 응답 일부
                        try:
                            content = e['response']['content'].get('text', '')
                            if content:
                                print(f"     응답 일부: {content[:200]}")
                        except: pass
                
                # API 정보 별도 저장
                api_summary = {
                    'all_kream_apis': [
                        {'method': e['request']['method'], 
                         'url': e['request']['url'],
                         'status': e['response']['status']}
                        for e in api_calls
                    ],
                    'bid_related': [
                        {'method': e['request']['method'],
                         'url': e['request']['url'],
                         'response_preview': e['response']['content'].get('text', '')[:500]}
                        for e in bid_apis
                    ]
                }
                api_path = capture_dir / f'api_summary_{ts}.json'
                api_path.write_text(json.dumps(api_summary, ensure_ascii=False, indent=2, default=str), encoding='utf-8')
                print(f"  API 요약: {api_path}")
            except Exception as e:
                print(f"  HAR 파싱 에러: {e}")

asyncio.run(main())
PYEOF

python3 _step29_capture.py 2>&1
echo ""

# 임시 스크립트 정리
rm -f _step29_capture.py 2>/dev/null

# ==========================================
# [STAGE 2] 결과 요약
# ==========================================
echo "════════════════════ [STAGE 2] 결과 요약 ════════════════════"

LATEST_RESULT=$(ls -t codegen_capture/result_*.json 2>/dev/null | head -1)
LATEST_API=$(ls -t codegen_capture/api_summary_*.json 2>/dev/null | head -1)

if [ -n "$LATEST_RESULT" ]; then
    echo ""
    echo "  📊 캡처 결과:"
    python3 -c "
import json
with open('$LATEST_RESULT') as f:
    r = json.load(f)

navs = r.get('navigations', [])
clicks = r.get('click_log', [])
final = r.get('final', {})

print(f'  네비게이션 {len(navs)}회:')
for n in navs[:10]:
    print(f'    → {n[\"url\"]}')

print(f'')
print(f'  클릭 {len(clicks)}회 (입찰 관련만):')
for c in clicks[:20]:
    text = c.get('text', '')
    if any(kw in text for kw in ['입찰', '판매', 'ask', 'bid']):
        print(f'    🖱  [{c.get(\"tag\",\"?\")}] \"{text}\" href={c.get(\"href\",\"\")[:60]}')

print(f'')
print(f'  최종 페이지:')
print(f'    URL: {final.get(\"url\",\"?\")}')
print(f'    제목: {final.get(\"title\",\"?\")}')
sels = final.get('selectors', {}).get('selectors', {}) if isinstance(final.get('selectors'), dict) else final.get('selectors', {})
if isinstance(sels, dict):
    non_zero = {k:v for k,v in sels.items() if isinstance(v,int) and v > 0}
    sorted_sels = sorted(non_zero.items(), key=lambda x: -x[1])[:5]
    print(f'    유망 셀렉터:')
    for k, v in sorted_sels:
        print(f'      {k}: {v}건')
prices = final.get('selectors', {}).get('price_count', '?') if isinstance(final.get('selectors'), dict) else '?'
print(f'    가격 패턴: {prices}건')
" 2>/dev/null
fi

if [ -n "$LATEST_API" ]; then
    echo ""
    echo "  🌐 API 호출 분석:"
    python3 -c "
import json
with open('$LATEST_API') as f:
    a = json.load(f)
all_apis = a.get('all_kream_apis', [])
bids = a.get('bid_related', [])
print(f'    전체 API 호출: {len(all_apis)}건')
print(f'    입찰 관련 API: {len(bids)}건')
print(f'')
if bids:
    print(f'    주요 입찰 API (상위 3개):')
    for b in bids[:3]:
        print(f'      {b[\"method\"]} {b[\"url\"][:100]}')
        rp = b.get('response_preview', '')
        if rp:
            print(f'        응답: {rp[:200]}')
" 2>/dev/null
fi

echo ""
echo "  📂 모든 캡처 파일:"
ls -la codegen_capture/ 2>/dev/null | tail -15

echo ""

# ==========================================
# [STAGE 3] 커밋
# ==========================================
echo "════════════════════ [STAGE 3] 커밋 ════════════════════"

# .gitignore에 codegen_capture 추가 (HAR 파일이 큼)
if ! grep -q "codegen_capture" .gitignore 2>/dev/null; then
    echo "" >> .gitignore
    echo "# Step 29 codegen capture (HAR 파일이 큼)" >> .gitignore
    echo "codegen_capture/*.har" >> .gitignore
fi

# JSON만 커밋 (HAR은 무거우니 제외)
git add .gitignore pipeline_step29.log codegen_capture/result_*.json codegen_capture/api_summary_*.json 2>/dev/null
git commit -m "diag(Step 29): Playwright Codegen + API 캡처

사장 직접 클릭으로 정답 URL/셀렉터/API 자동 추출.
- 네비게이션/클릭 로그 + 최종 페이지 셀렉터 매핑
- HAR로 모든 API 요청 캡처
- 입찰 관련 API 자동 분류" 2>/dev/null || echo "  (커밋 변경 없음)"
git push origin main 2>/dev/null || echo "  (push 스킵)"

FINAL_HASH=$(git log -1 --format=%h)
echo "  ✅ 커밋: $FINAL_HASH"
echo ""

cat > "다음세션_시작_컨텍스트_v23.md" <<MDEOF
# 다음 세션 시작 컨텍스트 v23

> 작성일: $(date '+%Y-%m-%d %H:%M:%S') (자동 생성)
> 직전 커밋: $(git log -1 --format='%h %s')

## Step 29: Codegen + API 캡처 결과

직접 클릭으로 캡처된 정보:
- codegen_capture/result_*.json — 네비게이션 + 클릭 로그
- codegen_capture/api_summary_*.json — API 요청 (200 OK만)
- codegen_capture/final_page_*.png — 마지막 화면 스크린샷
- codegen_capture/network_*.har — 전체 네트워크 (큰 파일, gitignore)

## 다음 액션

캡처 결과 보면 두 시나리오 중 하나:

### A. 입찰 데이터 페이지 발견됨
- 정답 URL 확인 → kream_adjuster.py 패치
- 또는 API 직접 호출 (HTML 파싱 안 거치고)

### B. 사장이 입찰 메뉴 클릭해도 데이터 0건
- 진짜로 활성 입찰 0건 — 새로 시작하는 게 답
- 모든 입찰이 어느 시점에 다 처리되거나 만료됨

## 다음 채팅 첫 메시지

\`\`\`
다음세션_시작_컨텍스트_v23.md 읽고 결과 분석.

캡처 결과: [입찰 보임 / 안 보임]
직접 클릭한 메뉴: [재고별 / 일반판매 / 통합 / 입찰내역]
페이지에서 본 것: [입찰 N건 / 빈 페이지 / 에러]

오늘 작업: [API 직접 호출 패치 / 새 입찰 시작 / 다른 방향]
\`\`\`

## 절대 규칙

7대 규칙 + 자동 토글 ON 금지.
MDEOF

git add 다음세션_시작_컨텍스트_v23.md 2>/dev/null
git commit -m "docs: 다음세션 컨텍스트 v23" 2>/dev/null || echo "  (변경 없음)"
git push origin main 2>/dev/null || echo "  (push 스킵)"

PIPELINE_END=$(date +%s)
ELAPSED=$((PIPELINE_END - PIPELINE_START))

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🎉 Step 29 캡처 완료 — ${ELAPSED}초"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "📋 다음 액션:"
echo "  1. 위 결과(네비게이션/클릭/API) 채팅에 붙여주기"
echo "  2. → 시나리오에 맞는 정확한 패치 (이번엔 진단 없이 한 번에)"
echo ""
echo "📜 로그: pipeline_step29.log"
echo ""
