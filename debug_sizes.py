"""사이즈별 가격 구조 디버깅 - 멀티사이즈 상품 (신발)"""
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

        # 멀티사이즈 상품 (토쿠텐 신발)
        pid = "385777"
        await page.goto(f"https://kream.co.kr/products/{pid}", wait_until="domcontentloaded")
        await page.wait_for_timeout(5000)

        # 1) 사이즈 선택 버튼들 확인
        sizes = await page.evaluate(r"""() => {
            const results = [];
            // 사이즈 버튼/옵션 찾기
            const btns = document.querySelectorAll('[class*="size"], [class*="option"]');
            for (const btn of btns) {
                if (btn.offsetParent === null) continue;
                const text = (btn.innerText || '').trim();
                if (text && (text.match(/^\d{3}/) || text.includes('ONE'))) {
                    results.push({
                        text: text.substring(0, 50),
                        tag: btn.tagName,
                        class: (btn.className || '').substring(0, 80),
                    });
                }
            }
            return results;
        }""")
        print(f"사이즈 버튼: {len(sizes)}개")
        for s in sizes[:20]:
            print(f"  '{s['text']}' <{s['tag']}> class={s['class'][:40]}")

        # 2) 사이즈 선택 영역 전체 텍스트
        size_area = await page.evaluate(r"""() => {
            // "모든 사이즈" 또는 사이즈 선택 영역
            const body = document.body.innerText;
            const lines = body.split('\n').map(s => s.trim()).filter(s => s);
            // 사이즈 패턴이 있는 줄 전후
            const sizeLines = [];
            for (let i = 0; i < lines.length; i++) {
                if (/^\d{3}(\.\d)?$/.test(lines[i]) || lines[i].includes('ONE SIZE') || lines[i] === '모든 사이즈') {
                    const start = Math.max(0, i-2);
                    const end = Math.min(lines.length, i+3);
                    for (let j = start; j < end; j++) {
                        sizeLines.push({line: j, text: lines[j]});
                    }
                }
            }
            return sizeLines;
        }""")
        print(f"\n사이즈 관련 텍스트:")
        for s in size_area[:30]:
            print(f"  [{s['line']}] {s['text']}")

        # 3) "모든 사이즈" 또는 사이즈 선택 버튼 클릭 시도
        try:
            all_size_btn = page.locator('text="모든 사이즈"').first
            if await all_size_btn.is_visible(timeout=2000):
                await all_size_btn.click()
                await page.wait_for_timeout(2000)
                await page.screenshot(path="debug_screenshots/all_sizes.png", full_page=False)
                print("\n'모든 사이즈' 클릭 후 스크린샷 저장")

                # 사이즈별 가격 목록
                size_prices = await page.evaluate(r"""() => {
                    const results = [];
                    const body = document.body.innerText;
                    const lines = body.split('\n').map(s => s.trim()).filter(s => s);
                    for (let i = 0; i < lines.length; i++) {
                        if (/^\d{3}(\.\d)?$/.test(lines[i]) || lines[i] === 'ONE SIZE') {
                            const size = lines[i];
                            // 다음 줄이 가격이면 수집
                            if (i+1 < lines.length) {
                                const next = lines[i+1];
                                const pm = next.match(/([0-9,]+)원/);
                                if (pm) {
                                    results.push({size, price: parseInt(pm[1].replace(/,/g,''))});
                                } else if (next === '구매 입찰') {
                                    results.push({size, price: null, note: '구매입찰'});
                                } else {
                                    results.push({size, price: null, note: next.substring(0, 30)});
                                }
                            }
                        }
                    }
                    return results;
                }""")
                print(f"\n사이즈별 가격: {len(size_prices)}개")
                for sp in size_prices[:25]:
                    print(f"  {sp.get('size','?'):>8} → {sp.get('price','?') or sp.get('note','?')}")
        except Exception as e:
            print(f"모든 사이즈 클릭 실패: {e}")

        # 4) 판매입찰 탭에서 사이즈별 데이터 확인
        try:
            sell_tab = page.locator('a.item_link:has-text("판매 입찰")').last
            await sell_tab.click()
            await page.wait_for_timeout(2000)
            await page.screenshot(path="debug_screenshots/sell_bids_sizes.png", full_page=False)

            sell_data = await page.evaluate(r"""() => {
                const items = document.querySelectorAll('[class*="transaction_history_summary__content__item_price"]');
                const results = [];
                for (const el of items) {
                    if (!el || el.offsetParent === null) continue;
                    const priceText = (el.innerText || '').trim();
                    const m = priceText.match(/([0-9,]+)/);
                    if (!m) continue;
                    const entry = {price: parseInt(m[1].replace(/,/g, ''))};
                    const row = el.parentElement;
                    if (row) {
                        const children = Array.from(row.children);
                        for (const child of children) {
                            if (child === el) continue;
                            const t = (child.innerText || '').trim();
                            if (!t) continue;
                            if (/^\d{1,3}$/.test(t) && parseInt(t) < 1000) entry.quantity = parseInt(t);
                            else if (!/[0-9,]+\uC6D0/.test(t) && t.length < 20) entry.size = t;
                        }
                    }
                    results.push(entry);
                }
                return results;
            }""")
            print(f"\n판매입찰 (사이즈별): {len(sell_data)}건")
            for d in sell_data[:15]:
                print(f"  {d.get('size','?'):>8} {d['price']:>8,}원 ×{d.get('quantity','?')}")
        except Exception as e:
            print(f"판매입찰 탭 실패: {e}")

        await context.storage_state(path="auth_state_kream.json")
        await browser.close()

asyncio.run(main())
