"""得物(dewu.com) + 识货(shihuo.com) 검색 구조 디버깅"""
import asyncio, json
from pathlib import Path
from playwright.async_api import async_playwright
from playwright_stealth import Stealth

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(channel="chrome", headless=False,
            args=['--disable-blink-features=AutomationControlled'])
        context = await browser.new_context(
            viewport={"width": 1440, "height": 900}, locale="zh-CN",
            user_agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        )
        page = await context.new_page()
        await Stealth().apply_stealth_async(page)

        model = "1183C431-020"  # 토쿠텐

        # ── 得物 dewu.com ──
        print("=== 得物 (dewu.com) ===")
        try:
            url = f"https://www.dewu.com/search/result?keyword={model}"
            print(f"URL: {url}")
            await page.goto(url, wait_until="domcontentloaded", timeout=15000)
            await page.wait_for_timeout(5000)
            await page.screenshot(path="debug_screenshots/dewu_search.png", full_page=False)
            print(f"Current URL: {page.url}")

            body = await page.evaluate("() => document.body.innerText.substring(0, 2000)")
            print(f"Body preview: {body[:500]}")

            # 가격 요소 찾기
            prices = await page.evaluate(r"""() => {
                const results = [];
                const els = document.querySelectorAll('*');
                for (const el of els) {
                    const t = (el.innerText || '').trim();
                    if (/¥\s*\d+/.test(t) && t.length < 30) {
                        results.push(t);
                    }
                }
                return results.slice(0, 20);
            }""")
            print(f"Price elements: {prices}")
        except Exception as e:
            print(f"得物 실패: {e}")

        # ── 识货 shihuo.com ──
        print("\n=== 识货 (shihuo.com) ===")
        try:
            url2 = f"https://www.shihuo.com/search?keyword={model}"
            print(f"URL: {url2}")
            await page.goto(url2, wait_until="domcontentloaded", timeout=15000)
            await page.wait_for_timeout(5000)
            await page.screenshot(path="debug_screenshots/shihuo_search.png", full_page=False)
            print(f"Current URL: {page.url}")

            body2 = await page.evaluate("() => document.body.innerText.substring(0, 2000)")
            print(f"Body preview: {body2[:500]}")

            prices2 = await page.evaluate(r"""() => {
                const results = [];
                const els = document.querySelectorAll('*');
                for (const el of els) {
                    const t = (el.innerText || '').trim();
                    if (/¥\s*\d+/.test(t) && t.length < 30) {
                        results.push(t);
                    }
                }
                return results.slice(0, 20);
            }""")
            print(f"Price elements: {prices2}")
        except Exception as e:
            print(f"识货 실패: {e}")

        # ── poizon.com (得物 글로벌) ──
        print("\n=== Poizon (得物 글로벌) ===")
        try:
            url3 = f"https://www.poizon.com/search?keyword={model}"
            print(f"URL: {url3}")
            await page.goto(url3, wait_until="domcontentloaded", timeout=15000)
            await page.wait_for_timeout(5000)
            await page.screenshot(path="debug_screenshots/poizon_search.png", full_page=False)
            print(f"Current URL: {page.url}")

            body3 = await page.evaluate("() => document.body.innerText.substring(0, 2000)")
            print(f"Body preview: {body3[:500]}")
        except Exception as e:
            print(f"Poizon 실패: {e}")

        await browser.close()

asyncio.run(main())
