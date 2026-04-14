"""partner.kream.co.kr/business/asks 페이지 구조 디버깅"""
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
            storage_state="auth_state.json" if Path("auth_state.json").exists() else None,
            viewport={"width": 1440, "height": 900}, locale="ko-KR",
            user_agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        )
        page = await context.new_page()
        await Stealth().apply_stealth_async(page)

        # 판매자센터 입찰 목록
        url = "https://partner.kream.co.kr/business/asks"
        print(f"Opening: {url}")
        await page.goto(url, wait_until="domcontentloaded")
        await page.wait_for_timeout(5000)

        print(f"Current URL: {page.url}")

        # 스크린샷
        await page.screenshot(path="debug_screenshots/asks_page.png", full_page=True)
        print("Screenshot saved")

        # body text
        body = await page.evaluate("() => document.body.innerText")
        with open("debug_screenshots/asks_body.txt", "w", encoding="utf-8") as f:
            f.write(body)

        # 테이블 구조 분석
        table_info = await page.evaluate(r"""() => {
            const results = {headers: [], rows: [], selectors: []};

            // thead
            const ths = document.querySelectorAll('table thead th, [class*="header"] [class*="cell"]');
            results.headers = Array.from(ths).map(th => th.innerText.trim());

            // tbody rows
            const trs = document.querySelectorAll('table tbody tr');
            for (const tr of trs) {
                const tds = tr.querySelectorAll('td');
                const row = Array.from(tds).map(td => ({
                    text: td.innerText.trim().substring(0, 100),
                    class: td.className,
                }));
                if (row.length > 0) results.rows.push(row);
            }

            // 없으면 div 기반 리스트 탐색
            if (results.rows.length === 0) {
                const items = document.querySelectorAll('[class*="list"] [class*="item"], [class*="row"]');
                for (const item of items) {
                    if (item.offsetParent === null) continue;
                    const text = item.innerText.trim();
                    if (text.length > 5 && text.length < 500) {
                        results.selectors.push({
                            tag: item.tagName,
                            class: item.className.substring(0, 100),
                            text: text.substring(0, 200),
                        });
                    }
                }
            }

            // 페이지네이션
            const pages = document.querySelectorAll('[class*="paging"], [class*="pagination"]');
            results.pagination = Array.from(pages).map(p => p.innerText.trim().substring(0, 100));

            // 필터/탭
            const tabs = document.querySelectorAll('[class*="tab"], [class*="filter"]');
            results.tabs = Array.from(tabs).map(t => ({
                text: t.innerText.trim().substring(0, 50),
                class: t.className.substring(0, 80),
            })).filter(t => t.text.length > 0).slice(0, 20);

            return results;
        }""")

        with open("debug_screenshots/asks_table.json", "w", encoding="utf-8") as f:
            json.dump(table_info, f, ensure_ascii=False, indent=2)
        print(f"Headers: {table_info['headers']}")
        print(f"Rows: {len(table_info['rows'])}")
        print(f"Selectors: {len(table_info.get('selectors', []))}")

        # URL 패턴 탐색 (perPage 크게)
        url2 = "https://partner.kream.co.kr/business/asks?page=1&perPage=50"
        await page.goto(url2, wait_until="domcontentloaded")
        await page.wait_for_timeout(3000)
        await page.screenshot(path="debug_screenshots/asks_page_50.png", full_page=True)

        await context.storage_state(path="auth_state.json")
        await browser.close()

asyncio.run(main())
