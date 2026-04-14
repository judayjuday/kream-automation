"""KREAM 내부 API 탐색 - 네트워크 요청 캡처"""
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

        # 네트워크 요청 캡처
        api_calls = []
        async def on_response(response):
            url = response.url
            if '/api/' in url or 'kream.co.kr/api' in url or '/v2/' in url or '/graphql' in url:
                try:
                    ct = response.headers.get('content-type', '')
                    body = None
                    if 'json' in ct:
                        body = await response.json()
                    api_calls.append({
                        'url': url[:200],
                        'status': response.status,
                        'method': response.request.method,
                        'body_preview': json.dumps(body, ensure_ascii=False)[:500] if body else None,
                    })
                except:
                    api_calls.append({'url': url[:200], 'status': response.status, 'method': response.request.method})

        page.on('response', on_response)

        # 상품 페이지 로드
        print("=== 상품 페이지 로드 ===")
        await page.goto("https://kream.co.kr/products/385777", wait_until="domcontentloaded")
        await page.wait_for_timeout(6000)

        print(f"\nAPI 호출 {len(api_calls)}건:")
        for c in api_calls:
            print(f"  [{c['method']}] {c['status']} {c['url']}")
            if c.get('body_preview'):
                print(f"    body: {c['body_preview'][:300]}")

        # 사이즈 클릭 시 API 호출 확인
        print("\n=== 사이즈 클릭 후 API ===")
        api_calls.clear()

        # 사이즈 버튼 클릭 (판매 버튼 클릭)
        try:
            sell_btn = page.locator('text="판매"').last
            if await sell_btn.is_visible(timeout=2000):
                await sell_btn.click()
                await page.wait_for_timeout(3000)
                print(f"판매 버튼 클릭 후 API {len(api_calls)}건:")
                for c in api_calls:
                    print(f"  [{c['method']}] {c['status']} {c['url']}")
                    if c.get('body_preview'):
                        print(f"    body: {c['body_preview'][:400]}")
        except Exception as e:
            print(f"판매 버튼 클릭 실패: {e}")

        # 구매하기 버튼 클릭
        print("\n=== 구매하기 버튼 클릭 후 API ===")
        api_calls.clear()
        await page.go_back()
        await page.wait_for_timeout(3000)

        try:
            buy_btn = page.locator('text="구매하기"').last
            if await buy_btn.is_visible(timeout=2000):
                await buy_btn.click()
                await page.wait_for_timeout(3000)
                print(f"구매하기 클릭 후 API {len(api_calls)}건:")
                for c in api_calls:
                    print(f"  [{c['method']}] {c['status']} {c['url']}")
                    if c.get('body_preview'):
                        print(f"    body: {c['body_preview'][:500]}")

                await page.screenshot(path="debug_screenshots/buy_modal.png", full_page=False)
        except Exception as e:
            print(f"구매 버튼 클릭 실패: {e}")

        with open("debug_screenshots/api_calls.json", "w", encoding="utf-8") as f:
            json.dump(api_calls, f, ensure_ascii=False, indent=2)

        await context.storage_state(path="auth_state_kream.json")
        await browser.close()

asyncio.run(main())
