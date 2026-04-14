"""size-table 구조 정확히 파악"""
import asyncio, json
from pathlib import Path
from playwright.async_api import async_playwright
from playwright_stealth import Stealth

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(channel="chrome", headless=False,
            args=['--disable-blink-features=AutomationControlled'])
        context = await browser.new_context(
            storage_state="auth_state_kream.json" if Path("auth_state_kream.json").exists() else None,
            viewport={"width": 1440, "height": 900}, locale="ko-KR",
            user_agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        )
        page = await context.new_page()
        await Stealth().apply_stealth_async(page)

        await page.goto("https://kream.co.kr/products/385777", wait_until="domcontentloaded")
        await page.wait_for_timeout(5000)

        # size-table 완전 분석
        data = await page.evaluate(r"""() => {
            const r = {};
            // size-table 전체 HTML
            const table = document.querySelector('.size-table');
            if (table) {
                r.tableHTML = table.outerHTML.substring(0, 3000);
                r.headers = Array.from(table.querySelectorAll('th')).map(th => ({
                    text: th.innerText.trim(),
                    class: th.className,
                }));
                r.cells = Array.from(table.querySelectorAll('td')).map(td => ({
                    text: td.innerText.trim(),
                    class: td.className,
                }));
                r.rows = Array.from(table.querySelectorAll('tr')).map(tr => ({
                    text: tr.innerText.trim().substring(0, 200),
                    class: tr.className,
                }));
            } else {
                r.noTable = true;
                // 대안 셀렉터 탐색
                const sizeEls = document.querySelectorAll('[class*="size"]');
                r.sizeEls = Array.from(sizeEls).slice(0, 10).map(el => ({
                    tag: el.tagName,
                    class: (el.className||'').substring(0, 80),
                    text: el.innerText.trim().substring(0, 100),
                    visible: el.offsetParent !== null,
                }));
            }
            return r;
        }""")

        print(json.dumps(data, ensure_ascii=False, indent=2)[:3000])

        await context.storage_state(path="auth_state_kream.json")
        await browser.close()

asyncio.run(main())
