"""KREAM 페이지 구조 디버깅 - 스크린샷 + DOM 분석"""
import asyncio
from pathlib import Path
from playwright.async_api import async_playwright
from playwright_stealth import Stealth

STATE_FILE = "auth_state.json"

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(
            channel="chrome", headless=False,
            args=['--disable-blink-features=AutomationControlled']
        )
        context = await browser.new_context(
            storage_state=STATE_FILE if Path(STATE_FILE).exists() else None,
            viewport={"width": 1440, "height": 900},
            locale="ko-KR",
            user_agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        )
        page = await context.new_page()
        await Stealth().apply_stealth_async(page)

        # 상품 페이지 열기
        url = "https://kream.co.kr/products/299954"
        print(f"Opening: {url}")
        await page.goto(url, wait_until="domcontentloaded")
        await page.wait_for_timeout(5000)

        # 스크린샷
        await page.screenshot(path="debug_screenshots/product_page.png", full_page=True)
        print("Screenshot saved: debug_screenshots/product_page.png")

        # 현재 URL 확인
        print(f"Current URL: {page.url}")

        # body 전체 텍스트
        body_text = await page.evaluate("() => document.body.innerText")
        with open("debug_screenshots/body_text.txt", "w", encoding="utf-8") as f:
            f.write(body_text)
        print("Body text saved: debug_screenshots/body_text.txt")

        # __NEXT_DATA__ 확인
        next_data = await page.evaluate("""() => {
            const el = document.getElementById('__NEXT_DATA__');
            if (el) return el.textContent.substring(0, 5000);
            return 'NOT FOUND';
        }""")
        with open("debug_screenshots/next_data.txt", "w", encoding="utf-8") as f:
            f.write(next_data)
        print("NEXT_DATA saved: debug_screenshots/next_data.txt")

        # 가격 관련 요소들의 클래스명 수집
        price_elements = await page.evaluate("""() => {
            const results = [];
            // 모든 요소에서 가격 패턴 찾기
            const allEls = document.querySelectorAll('*');
            for (const el of allEls) {
                const text = el.innerText || '';
                // 직접 텍스트만 (자식 제외)
                const directText = Array.from(el.childNodes)
                    .filter(n => n.nodeType === 3)
                    .map(n => n.textContent.trim())
                    .join('');

                if (/[0-9,]+원/.test(directText) || /구매|판매|거래/.test(directText)) {
                    results.push({
                        tag: el.tagName,
                        class: el.className,
                        id: el.id,
                        text: directText.substring(0, 100),
                        fullText: el.innerText.substring(0, 200),
                    });
                }
            }
            return results.slice(0, 50);
        }""")
        with open("debug_screenshots/price_elements.json", "w", encoding="utf-8") as f:
            import json
            json.dump(price_elements, f, ensure_ascii=False, indent=2)
        print(f"Price elements: {len(price_elements)} found")

        # 구매/판매 버튼 영역 HTML
        btn_html = await page.evaluate("""() => {
            const results = [];
            // buy/sell 관련 요소
            const sels = [
                '[class*="buy"]', '[class*="sell"]', '[class*="price"]',
                '[class*="trade"]', '[class*="market"]', '[class*="bid"]',
                '[class*="detail_price"]', '[class*="product_info"]',
                '[class*="wrap_btn"]', '[class*="btn_wrap"]',
                'a[href*="buy"]', 'a[href*="sell"]',
            ];
            for (const sel of sels) {
                const els = document.querySelectorAll(sel);
                for (const el of els) {
                    results.push({
                        selector: sel,
                        tag: el.tagName,
                        class: el.className,
                        text: el.innerText.substring(0, 300),
                        html: el.outerHTML.substring(0, 500),
                    });
                }
            }
            return results.slice(0, 80);
        }""")
        with open("debug_screenshots/btn_elements.json", "w", encoding="utf-8") as f:
            import json
            json.dump(btn_html, f, ensure_ascii=False, indent=2)
        print(f"Button elements: {len(btn_html)} found")

        await context.storage_state(path=STATE_FILE)
        await browser.close()
        print("Done!")

asyncio.run(main())
