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
