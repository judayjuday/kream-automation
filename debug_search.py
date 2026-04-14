"""KREAM 검색 페이지 구조 디버깅"""
import asyncio, json
from pathlib import Path
from playwright.async_api import async_playwright
from playwright_stealth import Stealth

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(
            channel="chrome", headless=False,
            args=['--disable-blink-features=AutomationControlled']
        )
        context = await browser.new_context(
            storage_state="auth_state_kream.json" if Path("auth_state_kream.json").exists() else None,
            viewport={"width": 1440, "height": 900}, locale="ko-KR",
            user_agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        )
        page = await context.new_page()
        await Stealth().apply_stealth_async(page)

        url = "https://kream.co.kr/search?keyword=%ED%86%A0%EC%BF%A0%ED%85%90&tab=products"
        print(f"Opening: {url}")
        await page.goto(url, wait_until="domcontentloaded")
        await page.wait_for_timeout(5000)

        await page.screenshot(path="debug_screenshots/search_page.png", full_page=False)
        print(f"URL: {page.url}")

        # 상품 카드 구조 분석
        cards = await page.evaluate(r"""() => {
            const results = [];
            // 상품 링크 찾기
            const links = document.querySelectorAll('a[href*="/products/"]');
            for (const link of links) {
                const href = link.href;
                const pidMatch = href.match(/\/products\/(\d+)/);
                if (!pidMatch) continue;

                const card = link.closest('[class*="product"]') || link;
                const text = card.innerText.trim();
                const img = card.querySelector('img');

                results.push({
                    productId: pidMatch[1],
                    href: href,
                    text: text.substring(0, 300),
                    class: (card.className || '').substring(0, 100),
                    imgAlt: img ? img.alt : '',
                    html: card.outerHTML.substring(0, 500),
                });
            }
            return results;
        }""")

        print(f"\n상품 카드 {len(cards)}개:")
        for c in cards[:5]:
            print(f"  #{c['productId']}: {c['text'][:80]}")
            print(f"    class: {c['class'][:60]}")

        with open("debug_screenshots/search_cards.json", "w", encoding="utf-8") as f:
            json.dump(cards, f, ensure_ascii=False, indent=2)

        # 페이지네이션 확인
        paging = await page.evaluate(r"""() => {
            const els = document.querySelectorAll('[class*="paging"], [class*="pagination"], [class*="page"]');
            return Array.from(els).map(e => ({
                class: (e.className||'').substring(0, 80),
                text: e.innerText.trim().substring(0, 100),
            })).filter(x => x.text.length > 0).slice(0, 10);
        }""")
        print(f"\n페이지네이션: {json.dumps(paging, ensure_ascii=False)}")

        # 스크롤 후 추가 로딩 확인
        await page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
        await page.wait_for_timeout(3000)
        cards2 = await page.evaluate("""() => document.querySelectorAll('a[href*="/products/"]').length""")
        print(f"\n스크롤 후 상품 수: {cards2}")

        await context.storage_state(path="auth_state_kream.json")
        await browser.close()

asyncio.run(main())
