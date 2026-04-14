"""로그인 상태에서 판매입찰/구매입찰 탭 디버깅 v2"""
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
            storage_state="auth_state_kream.json",
            viewport={"width": 1440, "height": 900}, locale="ko-KR",
            user_agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        )
        page = await context.new_page()
        await Stealth().apply_stealth_async(page)

        await page.goto("https://kream.co.kr/products/299954")
        await page.wait_for_load_state("domcontentloaded")
        await page.wait_for_timeout(5000)

        # 모든 item_link 탭 정보 수집
        tabs_info = await page.evaluate(r"""() => {
            const links = document.querySelectorAll('a.item_link');
            return Array.from(links).map((el, i) => ({
                index: i,
                text: el.innerText.trim(),
                href: el.href,
                visible: el.offsetParent !== null,
                rect: el.getBoundingClientRect(),
            }));
        }""")
        print("=== 모든 a.item_link 요소 ===")
        for t in tabs_info:
            print(f"  [{t['index']}] '{t['text']}' visible={t['visible']} y={t['rect']['y']:.0f}")

        # visible한 '판매 입찰' 탭 찾아서 JS로 클릭
        sell_idx = None
        for t in tabs_info:
            if '판매 입찰' in t['text'] and t['visible']:
                sell_idx = t['index']
                break

        if sell_idx is not None:
            print(f"\n판매 입찰 탭 클릭 (index={sell_idx})")
            await page.evaluate(f"document.querySelectorAll('a.item_link')[{sell_idx}].click()")
            await page.wait_for_timeout(3000)
            await page.screenshot(path="debug_screenshots/sell_bid_tab.png", full_page=False)
            print("Screenshot saved")

            # 현재 보이는 입찰 테이블 데이터
            bid_data = await page.evaluate(r"""() => {
                const items = document.querySelectorAll(
                    '[class*="transaction_history_summary__content__item_price"]'
                );
                return Array.from(items).map(el => ({
                    text: el.innerText.trim(),
                    parentText: (el.parentElement || {}).innerText || '',
                    visible: el.offsetParent !== null,
                })).filter(x => x.visible);
            }""")
            print(f"\n판매입찰 가격요소 {len(bid_data)}개:")
            for d in bid_data[:15]:
                print(f"  {d['text']} | parent: {d['parentText'][:80]}")
        else:
            print("\n판매 입찰 탭 (visible) 없음")
            # 모든 탭 텍스트가 있는 영역 스크롤해서 찾기
            await page.evaluate("window.scrollTo(0, document.body.scrollHeight * 0.4)")
            await page.wait_for_timeout(2000)
            await page.screenshot(path="debug_screenshots/scrolled_page.png", full_page=False)

        # 구매 입찰 탭
        buy_idx = None
        for t in tabs_info:
            if '구매 입찰' in t['text'] and t['visible']:
                buy_idx = t['index']
                break

        if buy_idx is not None:
            print(f"\n구매 입찰 탭 클릭 (index={buy_idx})")
            await page.evaluate(f"document.querySelectorAll('a.item_link')[{buy_idx}].click()")
            await page.wait_for_timeout(3000)
            await page.screenshot(path="debug_screenshots/buy_bid_tab.png", full_page=False)
            print("Screenshot saved")

            bid_data = await page.evaluate(r"""() => {
                const items = document.querySelectorAll(
                    '[class*="transaction_history_summary__content__item_price"]'
                );
                return Array.from(items).map(el => ({
                    text: el.innerText.trim(),
                    parentText: (el.parentElement || {}).innerText || '',
                    visible: el.offsetParent !== null,
                })).filter(x => x.visible);
            }""")
            print(f"\n구매입찰 가격요소 {len(bid_data)}개:")
            for d in bid_data[:15]:
                print(f"  {d['text']} | parent: {d['parentText'][:80]}")

        await context.storage_state(path="auth_state_kream.json")
        await browser.close()

asyncio.run(main())
