"""Poizon 검색 테스트"""
import asyncio, json
from playwright.async_api import async_playwright
from playwright_stealth import Stealth

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(channel="chrome", headless=False,
            args=['--disable-blink-features=AutomationControlled'])
        context = await browser.new_context(
            viewport={"width": 1440, "height": 900}, locale="ko-KR",
            user_agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        )
        page = await context.new_page()
        await Stealth().apply_stealth_async(page)

        model = "1183C431-020"

        # Poizon 검색
        print("=== Poizon 검색 ===")
        await page.goto("https://kr.poizon.com", wait_until="domcontentloaded", timeout=15000)
        await page.wait_for_timeout(3000)

        # 팝업 닫기
        try:
            close = page.locator('[class*="close"], button:has-text("×")').first
            if await close.is_visible(timeout=2000):
                await close.click()
                await page.wait_for_timeout(1000)
        except: pass

        # 검색창에 모델번호 입력
        try:
            search_input = page.locator('input[placeholder*="검색"], input[placeholder*="상품"], input[type="search"]').first
            if await search_input.is_visible(timeout=3000):
                await search_input.click()
                await search_input.fill(model)
                await page.keyboard.press("Enter")
                await page.wait_for_timeout(5000)

                print(f"URL: {page.url}")
                await page.screenshot(path="debug_screenshots/poizon_search2.png", full_page=False)

                body = await page.evaluate("() => document.body.innerText.substring(0, 3000)")
                print(f"Body: {body[:1000]}")

                # 가격 요소
                prices = await page.evaluate(r"""() => {
                    const results = [];
                    const allEls = document.querySelectorAll('*');
                    for (const el of allEls) {
                        const direct = Array.from(el.childNodes)
                            .filter(n => n.nodeType === 3)
                            .map(n => n.textContent.trim()).join('');
                        if (/[¥￥]\s*\d+|[0-9,]+원/.test(direct) && direct.length < 30) {
                            results.push({text: direct, tag: el.tagName, class: (el.className||'').substring(0, 50)});
                        }
                    }
                    return results.slice(0, 20);
                }""")
                print(f"\nPrice elements: {json.dumps(prices, ensure_ascii=False)}")

                # 상품 카드/링크
                cards = await page.evaluate(r"""() => {
                    const links = document.querySelectorAll('a[href*="/detail"]');
                    return Array.from(links).slice(0, 5).map(a => ({
                        href: a.href,
                        text: a.innerText.trim().substring(0, 200),
                    }));
                }""")
                print(f"\nCards: {json.dumps(cards, ensure_ascii=False)}")
        except Exception as e:
            print(f"검색 실패: {e}")

        await browser.close()

asyncio.run(main())
