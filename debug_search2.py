"""검색 카드에서 모델번호 위치 파악"""
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

        await page.goto("https://kream.co.kr/search?keyword=%ED%86%A0%EC%BF%A0%ED%85%90&tab=products", wait_until="domcontentloaded")
        await page.wait_for_timeout(5000)

        # 첫 3개 카드의 완전한 HTML + 텍스트 + 속성 분석
        detail = await page.evaluate(r"""() => {
            const results = [];
            const cards = document.querySelectorAll('a[href*="/products/"]');
            for (let i = 0; i < Math.min(3, cards.length); i++) {
                const card = cards[i];
                const pidMatch = card.href.match(/\/products\/(\d+)/);
                if (!pidMatch) continue;

                // data-sdui-id 속성
                const sduiId = card.getAttribute('data-sdui-id') || '';

                // 카드 내 모든 텍스트 요소
                const allTexts = [];
                const walker = document.createTreeWalker(card, NodeFilter.SHOW_TEXT);
                let node;
                while (node = walker.nextNode()) {
                    const t = node.textContent.trim();
                    if (t) allTexts.push(t);
                }

                // 카드 내 모든 요소의 클래스와 텍스트
                const elements = [];
                card.querySelectorAll('*').forEach(el => {
                    const t = el.innerText ? el.innerText.trim() : '';
                    const directText = Array.from(el.childNodes)
                        .filter(n => n.nodeType === 3)
                        .map(n => n.textContent.trim())
                        .filter(s => s).join('');
                    if (directText) {
                        elements.push({
                            tag: el.tagName,
                            class: (el.className || '').substring(0, 80),
                            text: directText.substring(0, 100),
                            dataAttr: Object.keys(el.dataset || {}).join(','),
                        });
                    }
                });

                // img alt (이미 확인함 - 한글(영문) 형태)
                const img = card.querySelector('img');

                results.push({
                    productId: pidMatch[1],
                    sduiId: sduiId,
                    imgAlt: img ? img.alt : '',
                    allTexts: allTexts,
                    elements: elements,
                    fullHTML: card.outerHTML.substring(0, 2000),
                });
            }
            return results;
        }""")

        for d in detail:
            print(f"\n=== 상품 #{d['productId']} ===")
            print(f"sdui-id: {d['sduiId']}")
            print(f"imgAlt: {d['imgAlt']}")
            print(f"텍스트 노드:")
            for t in d['allTexts']:
                print(f"  '{t}'")
            print(f"요소:")
            for e in d['elements']:
                print(f"  <{e['tag']} class='{e['class'][:40]}'> {e['text'][:60]}")

        # 상품 상세 페이지에서 모델번호 확인 (첫 번째 상품)
        if detail:
            pid = detail[0]['productId']
            print(f"\n=== 상세 페이지 #{pid} 모델번호 확인 ===")
            await page.goto(f"https://kream.co.kr/products/{pid}", wait_until="domcontentloaded")
            await page.wait_for_timeout(3000)

            model = await page.evaluate(r"""() => {
                const body = document.body.innerText;
                const m = body.match(/모델번호\s*([A-Z0-9][A-Z0-9_-]+)/i);
                return m ? m[1] : null;
            }""")
            print(f"모델번호: {model}")

        await context.storage_state(path="auth_state_kream.json")
        await browser.close()

asyncio.run(main())
