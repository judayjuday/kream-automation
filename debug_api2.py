"""KREAM API 상세 응답 분석"""
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

        # API 응답 캡처
        captured = {}
        async def on_response(response):
            url = response.url
            if 'api.kream.co.kr/api/p/options/display' in url:
                try:
                    body = await response.json()
                    key = 'sell' if 'picker_type=sell' in url else 'buy'
                    captured[key] = body
                except:
                    pass

        page.on('response', on_response)

        await page.goto("https://kream.co.kr/products/385777", wait_until="domcontentloaded")
        await page.wait_for_timeout(6000)

        for key in ['sell', 'buy']:
            if key in captured:
                path = f"debug_screenshots/api_{key}.json"
                with open(path, "w", encoding="utf-8") as f:
                    json.dump(captured[key], f, ensure_ascii=False, indent=2)
                print(f"\n=== {key} API ({path}) ===")
                # 구조 분석
                data = captured[key]
                print(f"top keys: {list(data.keys())[:10]}")

                # options 배열 탐색
                def find_options(obj, depth=0, prefix=""):
                    if depth > 5: return
                    if isinstance(obj, dict):
                        for k, v in obj.items():
                            if k in ('options', 'items', 'sizes', 'variants', 'children'):
                                if isinstance(v, list) and len(v) > 0:
                                    print(f"  {prefix}{k} ({len(v)} items)")
                                    for item in v[:3]:
                                        if isinstance(item, dict):
                                            print(f"    keys: {list(item.keys())[:15]}")
                                            # 가격/사이즈 관련 키 출력
                                            for sk in item:
                                                val = item[sk]
                                                if isinstance(val, (int, float, str)) and val:
                                                    vstr = str(val)[:60]
                                                    print(f"    {sk}: {vstr}")
                                            print()
                            find_options(v, depth+1, prefix + k + ".")
                    elif isinstance(obj, list):
                        for item in obj[:2]:
                            find_options(item, depth+1, prefix)

                find_options(data)

        await context.storage_state(path="auth_state_kream.json")
        await browser.close()

asyncio.run(main())
