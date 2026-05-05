"""
KREAM 가격 자동 조정 모듈
1) 내 입찰 목록 수집 (partner.kream.co.kr/business/asks)
2) 시장 가격 수집 (kream.co.kr/products/상품번호)
3) 추천 조정가 계산
4) 승인된 건만 실제 가격 수정
"""

import asyncio
import json
import sys
from datetime import datetime
from pathlib import Path

from playwright.async_api import async_playwright, Page
from playwright_stealth import Stealth

STATE_FILE_PARTNER = "auth_state.json"
STATE_FILE_KREAM = "auth_state_kream.json"
PARTNER_URL = "https://partner.kream.co.kr"
KREAM_URL = "https://kream.co.kr"


# ═══════════════════════════════════════════
# 브라우저
# ═══════════════════════════════════════════

async def launch_browser(playwright, headless=True):
    browser = await playwright.chromium.launch(
        channel="chrome", headless=headless,
        args=['--disable-blink-features=AutomationControlled',
              '--no-sandbox', '--disable-dev-shm-usage'],
    )
    return browser


async def make_context(browser, storage=None):
    return await browser.new_context(
        storage_state=storage if storage and Path(storage).exists() else None,
        viewport={"width": 1440, "height": 900}, locale="ko-KR",
        user_agent=(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/120.0.0.0 Safari/537.36"
        ),
    )


async def stealth(page):
    await Stealth().apply_stealth_async(page)


async def save_state_with_localstorage(page, context, path, origin_url):
    """storage_state에 localStorage 데이터를 병합하여 저장"""
    try:
        local_storage_data = await page.evaluate('() => JSON.stringify(localStorage)')
        ls_items = json.loads(local_storage_data) if local_storage_data else {}
        ls_entries = [{"name": k, "value": v} for k, v in ls_items.items()]
    except Exception:
        ls_entries = []

    state = await context.storage_state()

    if ls_entries:
        origin_found = False
        for origin in state.get("origins", []):
            if origin.get("origin") == origin_url:
                origin["localStorage"] = ls_entries
                origin_found = True
                break
        if not origin_found:
            state.setdefault("origins", []).append({
                "origin": origin_url,
                "localStorage": ls_entries,
            })

    with open(path, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2)


# ═══════════════════════════════════════════
# 1단계: 내 입찰 목록 수집
# ═══════════════════════════════════════════

# DEPRECATED 2026-05-05: collect_my_bids_via_menu 사용 권장
# Step 34 v4 이후 size 추출 깨짐. 롤백 옵션으로만 보존.
async def collect_my_bids(headless=True) -> list:
    """partner.kream.co.kr/business/asks 에서 현재 입찰 중인 내역 수집"""
    async with async_playwright() as p:
        browser = await launch_browser(p, headless)
        context = await make_context(browser, STATE_FILE_PARTNER)
        page = await context.new_page()
        await stealth(page)

        # 다중 URL 시도 (KREAM이 URL 경로를 바꿨을 가능성 대응)
        BID_URLS_FALLBACK = [
            f"{PARTNER_URL}/business/asks",                                          # PRIMARY: 실제 데이터 URL (kream_adjuster docstring 명시)
            f"{PARTNER_URL}/business/ask-sales",                                     # NEW: Step 24 진단으로 확인 (재고별 입찰 관리)
            f"{PARTNER_URL}/business/asks?page=1&perPage=100&startDate=&endDate=",  # 기존
            f"{PARTNER_URL}/business/asks",                                          # 변형 1
            f"{PARTNER_URL}/c2c/sell/bid",                                           # 변형 2 (구 가설)
            f"{PARTNER_URL}/c2c/sell",                                               # 변형 3
            f"{PARTNER_URL}/c2c/bid",                                                # 변형 4
            f"{PARTNER_URL}/c2c",                                                    # 메인 (메뉴 클릭으로 이동)
        ]

        bid_page_loaded = False
        for url in BID_URLS_FALLBACK:
            try:
                await page.goto(url, wait_until="domcontentloaded", timeout=20000)
                await page.wait_for_timeout(2000)

                if "/sign-in" in page.url:
                    print(f"[SYNC] {url} → 로그인 필요 (다음 시도)")
                    continue

                table_count = await page.evaluate("""
                    () => {
                        const tables = document.querySelectorAll('table tbody tr, .bid-list-item, [class*="bid-row"]');
                        return tables.length;
                    }
                """)

                if table_count > 0:
                    print(f"[SYNC] 입찰 페이지 로드 성공: {url} ({table_count}건)")
                    bid_page_loaded = True
                    break
                else:
                    print(f"[SYNC] {url} → 0건 (다음 시도)")
            except Exception as e:
                print(f"[SYNC] {url} 실패: {e}")
                continue

        # 메인 페이지 도달했지만 입찰 메뉴가 다른 곳에 있는 경우
        if not bid_page_loaded:
            try:
                await page.goto(f"{PARTNER_URL}/c2c", timeout=20000)
                await page.wait_for_timeout(2000)

                clicked = await page.evaluate("""
                    () => {
                        const candidates = [
                            'a[href*="bid"]', 'a[href*="sell"]',
                            '[role="link"]', 'button'
                        ];
                        for (const sel of candidates) {
                            const els = document.querySelectorAll(sel);
                            for (const el of els) {
                                const text = (el.textContent || '').trim();
                                if (text.includes('입찰') || text.includes('내 입찰') || text.includes('판매')) {
                                    el.click();
                                    return text;
                                }
                            }
                        }
                        return null;
                    }
                """)
                if clicked:
                    print(f"[SYNC] 메뉴 클릭: {clicked}")
                    await page.wait_for_timeout(3000)
                    bid_page_loaded = True
            except Exception as e:
                print(f"[SYNC] 메뉴 클릭 실패: {e}")

        if "/sign-in" in page.url:
            print("판매자센터 로그인 필요")
            await browser.close()
            return []

        # "입찰 중" 탭 클릭 (기본 활성이지만 확실하게)
        try:
            tab = page.locator('button:has-text("입찰 중"), [class*="tab"]:has-text("입찰 중")').first
            if await tab.is_visible(timeout=2000):
                await tab.click()
                await page.wait_for_timeout(2000)
        except Exception:
            pass

        # 다중 셀렉터 시도 (구버전/신버전 호환 검증)
        ROW_SELECTORS = [
            # NEW: ask-sales 페이지 추정 셀렉터들 (Step 25)
            '[class*="ask-sales"] tbody tr',
            '[class*="AskSales"] tbody tr',
            'div[class*="askRow"]',
            'div[class*="ask-item"]',
            # 기존
            'table tbody tr',
            '.bid-list-item',
            '[class*="bid-row"]',
            '[class*="bid_row"]',
            '[data-testid*="bid"]',
            'div[class*="row"][class*="bid"]',
            '.bid-table-body > div',
        ]
        rows = []
        for selector in ROW_SELECTORS:
            try:
                rows = await page.query_selector_all(selector)
                if rows and len(rows) > 0:
                    print(f"[SYNC] 행 추출 셀렉터: {selector} → {len(rows)}건")
                    break
            except Exception:
                continue

        if not rows:
            print("[SYNC] 모든 셀렉터 0건 — 페이지 구조 변경 가능성")

        bids = await parse_asks_page(page)

        await save_state_with_localstorage(page, context, STATE_FILE_PARTNER, PARTNER_URL)
        await browser.close()

    return bids


async def parse_asks_page(page: Page) -> list:
    """입찰 내역 관리 페이지에서 입찰 데이터 파싱"""
    data = await page.evaluate(r"""() => {
        const results = [];
        const body = document.body.innerText;

        // 주문번호 패턴으로 각 입찰건 분리
        const orderPattern = /A-[A-Z]{2}\d{9,}/g;
        const orders = [];
        let m;
        while ((m = orderPattern.exec(body)) !== null) {
            orders.push({id: m[0], pos: m.index});
        }

        for (let i = 0; i < orders.length; i++) {
            const start = orders[i].pos;
            const end = i + 1 < orders.length ? orders[i + 1].pos : body.length;
            const chunk = body.substring(start, end);
            const lines = chunk.split('\n').map(s => s.trim()).filter(s => s.length > 0);

            const bid = {orderId: orders[i].id};

            // 모델번호 (상품번호)
            const modelMatch = chunk.match(/([A-Z0-9-]+)\s*\((\d+)\)/);
            if (modelMatch) {
                bid.model = modelMatch[1];
                bid.productId = modelMatch[2];
            }

            // 상품명
            for (const line of lines) {
                if (/^[A-Z]/.test(line) && line.length > 15 && !line.startsWith('A-')
                    && !/^\d/.test(line) && !line.includes('(') && !line.includes('ONE')) {
                    bid.nameEn = line;
                    break;
                }
            }
            for (const line of lines) {
                if (/[\uAC00-\uD7AF]/.test(line) && line.length > 5
                    && !line.includes('\uC218\uC815') && !line.includes('\uC0AD\uC81C')
                    && !line.includes('\uBCF4\uAD00') && !line.includes('\uD574\uC678')
                    && !line.includes('\uC785\uCC30')) {
                    bid.nameKr = line;
                    break;
                }
            }

            // 사이즈 (ONE SIZE 또는 신발 사이즈 220~320)
            if (chunk.includes('ONE SIZE')) {
                bid.size = 'ONE SIZE';
            } else {
                const sizeMatch = chunk.match(/\n(2[0-9]{2}|3[0-2][0-9])(\.\d)?\n/);
                if (sizeMatch) bid.size = sizeMatch[1] + (sizeMatch[2] || '');
            }

            // 판매 희망가 + 입찰 순번
            const priceMatch = chunk.match(/([0-9,]+)\uC6D0\n\uC785\uCC30 \uC21C\uBC88 (\d+)/);
            if (priceMatch) {
                bid.bidPrice = parseInt(priceMatch[1].replace(/,/g, ''));
                bid.bidRank = parseInt(priceMatch[2]);
            }

            // 해외배송 최근거래가 (패턴: 가격 다음에 +/-금액)
            // 해외 배송 즉시구매가 근처의 가격
            const allPrices = [];
            const pricePattern = /([0-9,]+)\uC6D0/g;
            let pm;
            while ((pm = pricePattern.exec(chunk)) !== null) {
                allPrices.push(parseInt(pm[1].replace(/,/g, '')));
            }

            // 판매유형
            if (chunk.includes('\uD574\uC678')) bid.saleType = '해외';
            else if (chunk.includes('\uC77C\uBC18')) bid.saleType = '일반';
            else bid.saleType = '기타';

            // 만료일 (YYYY/MM/DD 또는 YY/MM/DD 패턴)
            const deadlineMatch = chunk.match(/(\d{4})[\/\-.](\d{1,2})[\/\-.](\d{1,2})\s*\uB9CC\uB8CC/) ||
                                  chunk.match(/\uB9CC\uB8CC[:\s]*(\d{4})[\/\-.](\d{1,2})[\/\-.](\d{1,2})/) ||
                                  chunk.match(/(\d{4})[\/\-.](\d{1,2})[\/\-.](\d{1,2})\s*\uAE4C\uC9C0/);
            if (deadlineMatch) {
                bid.deadline = `${deadlineMatch[1]}-${deadlineMatch[2].padStart(2,'0')}-${deadlineMatch[3].padStart(2,'0')}`;
            }

            if (bid.productId && bid.bidPrice) {
                results.push(bid);
            }
        }

        return results;
    }""")

    return data


# ═══════════════════════════════════════════
# 2단계: 시장 가격 수집
# ═══════════════════════════════════════════

async def collect_market_data(product_ids: list, headless=True) -> dict:
    """각 상품의 시장 데이터 수집 (판매입찰, 구매입찰, 최근거래가)"""
    from kream_collector import (
        collect_from_kream,
        create_browser as col_browser,
        create_context as col_context,
        apply_stealth as col_stealth,
    )

    kream_session = STATE_FILE_KREAM if Path(STATE_FILE_KREAM).exists() else None
    market = {}

    async with async_playwright() as p:
        browser = await col_browser(p, headless)
        context = await col_context(browser, kream_session)
        page = await context.new_page()
        await col_stealth(page)

        for pid in product_ids:
            print(f"  시장 데이터 수집: #{pid}")
            data = await collect_from_kream(page, pid)
            market[pid] = data
            await page.wait_for_timeout(2000)

        if kream_session:
            await save_state_with_localstorage(page, context, STATE_FILE_KREAM, KREAM_URL)
        await browser.close()

    return market


# ═══════════════════════════════════════════
# 3단계: 추천 조정가 계산
# ═══════════════════════════════════════════

def calc_recommendation(bid: dict, market: dict) -> dict:
    """
    추천가 계산 규칙:
    - 기존 입찰가보다 낮추는 건 절대 안 됨 (올리거나 유지만)
    - 최근 거래가 근처로 조정
    - 구매입찰 가격 위
    - 물량벽 고려
    """
    result = {
        "orderId": bid["orderId"],
        "productId": bid.get("productId"),
        "nameKr": bid.get("nameKr", ""),
        "nameEn": bid.get("nameEn", ""),
        "size": bid.get("size", "ONE SIZE"),
        "currentPrice": bid["bidPrice"],
        "currentRank": bid.get("bidRank"),
        "recommendPrice": bid["bidPrice"],  # 기본: 유지
        "recommendRank": bid.get("bidRank"),
        "reason": "유지",
        "action": "keep",
    }

    mkt = market.get(bid.get("productId"), {})
    if not mkt:
        result["reason"] = "시장 데이터 없음"
        return result

    sell_bids = mkt.get("sell_bids", [])
    buy_bids = mkt.get("buy_bids", [])
    recent = mkt.get("recent_trade_price") or mkt.get("display_price") or 0
    current_price = bid["bidPrice"]

    if not sell_bids:
        result["reason"] = "판매입찰 데이터 없음"
        return result

    # 판매입찰 가격 오름차순 정렬
    sell_sorted = sorted(sell_bids, key=lambda x: x["price"])
    market_low = sell_sorted[0]["price"] if sell_sorted else 0

    # 구매입찰 최고가
    buy_high = max((b["price"] for b in buy_bids), default=0)

    # 물량벽: 가장 수량 많은 가격대
    wall_bid = max(sell_sorted, key=lambda x: x.get("quantity", 0)) if sell_sorted else None
    wall_price = wall_bid["price"] if wall_bid and wall_bid.get("quantity", 0) >= 3 else None

    # ── 추천 로직 ──

    # Case 1: 내 가격이 최저가보다 높음 → 최저가 근처로 내리고 싶지만, 낮출 수 없음
    # 규칙: 기존 입찰가보다 낮추지 않음
    if current_price <= market_low:
        # 이미 최저가 또는 그 이하 → 유지
        new_rank = _calc_rank(sell_sorted, current_price)
        result["recommendRank"] = new_rank
        result["reason"] = f"이미 최저가({market_low:,}원) 이하 → 유지"
        result["action"] = "keep"
        return result

    # Case 2: 최근 거래가가 내 가격보다 높음 → 최근 거래가 근처로 올림
    if recent > current_price:
        target = recent
        # 물량벽이 있으면 그 아래로
        if wall_price and wall_price > current_price and wall_price < target:
            target = wall_price - 1000

        target = max(target, current_price)  # 절대 낮추지 않음
        target = (target // 1000) * 1000  # 1000원 단위

        if target > current_price:
            new_rank = _calc_rank(sell_sorted, target)
            result["recommendPrice"] = target
            result["recommendRank"] = new_rank
            result["reason"] = f"최근거래가({recent:,}원) 근처로 상향"
            result["action"] = "raise"
            return result

    # Case 3: 내 순번이 너무 뒤 → 최저가 매칭 (올림만)
    if bid.get("bidRank", 0) > 5 and market_low >= current_price:
        target = market_low
        target = max(target, current_price)
        if target > current_price:
            new_rank = _calc_rank(sell_sorted, target)
            result["recommendPrice"] = target
            result["recommendRank"] = new_rank
            result["reason"] = f"순번 {bid['bidRank']}위 → 최저가 매칭으로 상향"
            result["action"] = "raise"
            return result

    # Case 4: 이미 적정가
    new_rank = _calc_rank(sell_sorted, current_price)
    result["recommendRank"] = new_rank
    result["reason"] = "적정가 → 유지"
    result["action"] = "keep"
    return result


def _calc_rank(sell_sorted: list, price: int) -> int:
    """주어진 가격의 예상 순번 계산"""
    rank = 1
    for bid in sell_sorted:
        if bid["price"] < price:
            rank += bid.get("quantity", 1)
        elif bid["price"] == price:
            # 같은 가격이면 뒤에 추가
            rank += bid.get("quantity", 1)
    return rank


# ═══════════════════════════════════════════
# 5단계: 실제 가격 수정
# ═══════════════════════════════════════════

async def modify_bid_price(order_id: str, new_price: int, headless=True) -> bool:
    """판매자센터에서 기존 입찰의 가격을 수정"""
    async with async_playwright() as p:
        browser = await launch_browser(p, headless)
        context = await make_context(browser, STATE_FILE_PARTNER)
        page = await context.new_page()
        await stealth(page)

        # 입찰 내역 페이지
        url = f"{PARTNER_URL}/business/asks?page=1&perPage=50&startDate=&endDate="
        await page.goto(url, wait_until="domcontentloaded")
        await page.wait_for_timeout(5000)

        if "/sign-in" in page.url:
            print("  로그인 필요")
            await browser.close()
            return False

        success = await _click_modify_and_change(page, order_id, new_price)

        await save_state_with_localstorage(page, context, STATE_FILE_PARTNER, PARTNER_URL)
        await browser.close()

    return success


async def _click_modify_and_change(page: Page, order_id: str, new_price: int) -> bool:
    """해당 주문번호의 '수정' 버튼을 클릭하고 가격 변경"""
    print(f"  수정 시도: {order_id} → {new_price:,}원")

    # 주문번호 텍스트 찾기
    order_el = page.locator(f'text="{order_id}"').first
    try:
        await order_el.wait_for(state="visible", timeout=5000)
    except Exception:
        print(f"  주문번호 {order_id} 을 찾을 수 없음")
        return False

    # 해당 행의 "수정" 버튼 찾기
    # 주문번호와 같은 행(부모 컨테이너)에서 수정 버튼 클릭
    modify_btn = await page.evaluate("""(orderId) => {
        // 주문번호 텍스트를 포함하는 요소 찾기
        const allText = document.querySelectorAll('*');
        for (const el of allText) {
            const direct = Array.from(el.childNodes)
                .filter(n => n.nodeType === 3)
                .map(n => n.textContent.trim())
                .join('');
            if (direct === orderId) {
                // 부모 행에서 수정 버튼 찾기
                let parent = el;
                for (let i = 0; i < 15; i++) {
                    parent = parent.parentElement;
                    if (!parent) break;
                    const btn = parent.querySelector('button');
                    if (btn && btn.innerText.includes('수정')) {
                        return true;  // 존재 확인
                    }
                }
            }
        }
        return false;
    }""", order_id)

    if not modify_btn:
        print(f"  수정 버튼 찾기 실패: {order_id}")
        return False

    # 수정 버튼 클릭 (JS 방식)
    clicked = await page.evaluate("""(orderId) => {
        const allText = document.querySelectorAll('*');
        for (const el of allText) {
            const direct = Array.from(el.childNodes)
                .filter(n => n.nodeType === 3)
                .map(n => n.textContent.trim())
                .join('');
            if (direct === orderId) {
                let parent = el;
                for (let i = 0; i < 15; i++) {
                    parent = parent.parentElement;
                    if (!parent) break;
                    const btn = parent.querySelector('button');
                    if (btn && btn.innerText.includes('수정')) {
                        btn.click();
                        return true;
                    }
                }
            }
        }
        return false;
    }""", order_id)

    if not clicked:
        print(f"  수정 버튼 클릭 실패: {order_id}")
        return False

    await page.wait_for_timeout(2000)

    # 가격 수정 모달/인풋이 나타남
    # 가격 입력 필드 찾기
    price_input = page.locator('input[type="text"], input[type="number"]').filter(
        has_text=""
    )

    # 모달에서 가격 입력 필드 찾기 (여러 시도)
    filled = False
    for selector in [
        'input[placeholder*="희망가"]',
        'input[placeholder*="가격"]',
        'input[name*="price"]',
        'input[name*="amount"]',
        '[class*="modal"] input[type="text"]',
        '[class*="dialog"] input[type="text"]',
        '[class*="popup"] input',
    ]:
        try:
            inp = page.locator(selector).first
            if await inp.is_visible(timeout=1000):
                await inp.click()
                await page.keyboard.press("Meta+a")
                await page.keyboard.press("Backspace")
                await inp.type(str(new_price), delay=50)
                filled = True
                print(f"  가격 입력 완료: {new_price}")
                break
        except Exception:
            continue

    if not filled:
        # fallback: 보이는 모든 input 중 숫자 입력 가능한 것
        try:
            inputs = page.locator('input:visible')
            count = await inputs.count()
            for i in range(count):
                inp = inputs.nth(i)
                val = await inp.input_value()
                # 현재 가격이 들어있는 input 찾기
                if val and val.replace(",", "").isdigit():
                    await inp.click()
                    await page.keyboard.press("Meta+a")
                    await page.keyboard.press("Backspace")
                    await inp.type(str(new_price), delay=50)
                    filled = True
                    print(f"  가격 입력 완료 (fallback): {new_price}")
                    break
        except Exception:
            pass

    if not filled:
        print("  가격 입력 필드를 찾을 수 없음")
        await page.screenshot(path="debug_screenshots/modify_fail.png")
        return False

    # 확인/저장 버튼 클릭
    await page.wait_for_timeout(500)
    for btn_text in ["확인", "저장", "수정", "적용"]:
        try:
            btn = page.locator(f'button:has-text("{btn_text}")').last
            if await btn.is_visible(timeout=1000):
                await btn.click()
                await page.wait_for_timeout(2000)
                print(f"  '{btn_text}' 클릭")
                break
        except Exception:
            continue

    # 확인 팝업 처리
    try:
        confirm = page.locator('button:has-text("확인")').last
        if await confirm.is_visible(timeout=2000):
            await confirm.click()
            await page.wait_for_timeout(1000)
    except Exception:
        pass

    print(f"  수정 완료: {order_id} → {new_price:,}원")
    return True


# ═══════════════════════════════════════════
# 통합: 전체 플로우
# ═══════════════════════════════════════════

async def full_adjust_flow(headless=True):
    """1→2→3단계 실행 (수집+분석+제안)"""
    # 1) 내 입찰 수집 — Step 34 v5: collect_my_bids_via_menu 사용 (sync API와 동일)
    print("=" * 50)
    print("  1단계: 내 입찰 목록 수집")
    my_bids = await collect_my_bids_via_menu(headless)
    print(f"  입찰 {len(my_bids)}건 수집")

    if not my_bids:
        return {"bids": [], "market": {}, "recommendations": []}

    # 어댑터: via_menu는 productId를 반환하지 않으므로 rawText에서 추출
    # rawText 패턴 예: "MODEL (12345)" → productId="12345"
    import re as _re
    for _b in my_bids:
        if not _b.get("productId"):
            _rt = _b.get("rawText", "") or ""
            _m = _re.search(r"\((\d+)\)", _rt)
            if _m:
                _b["productId"] = _m.group(1)

    # 2) 시장 데이터 수집 (중복 상품 제거)
    product_ids = list(set(b["productId"] for b in my_bids if b.get("productId")))
    print(f"\n  2단계: 시장 데이터 수집 ({len(product_ids)}개 상품)")
    market = await collect_market_data(product_ids, headless)

    # 3) 추천 계산
    print(f"\n  3단계: 추천 조정가 계산")
    recommendations = []
    for bid in my_bids:
        pid = bid.get("productId")
        rec = calc_recommendation(bid, market)
        recommendations.append(rec)
        action = "⬆ 상향" if rec["action"] == "raise" else "✓ 유지"
        print(f"  #{pid} {bid['bidPrice']:,}원 → {rec['recommendPrice']:,}원 ({action}: {rec['reason']})")

    return {
        "bids": my_bids,
        "market": {k: _serialize_market(v) for k, v in market.items()},
        "recommendations": recommendations,
    }


def _serialize_market(mkt):
    """market dict를 JSON 직렬화 가능한 형태로"""
    return {
        "product_name": mkt.get("product_name"),
        "recent_trade_price": mkt.get("recent_trade_price"),
        "display_price": mkt.get("display_price"),
        "instant_buy_price": mkt.get("instant_buy_price"),
        "instant_sell_price": mkt.get("instant_sell_price"),
        "sell_bids": mkt.get("sell_bids", []),
        "buy_bids": mkt.get("buy_bids", []),
        "total_trades": mkt.get("total_trades"),
    }


if __name__ == "__main__":
    import sys
    result = asyncio.run(full_adjust_flow(headless="--headless" in sys.argv))
    print(json.dumps(result, ensure_ascii=False, indent=2, default=str))


async def collect_my_bids_via_menu(headless=True) -> list:
    """메뉴 클릭 방식으로 입찰 내역 관리 페이지 진입 → 데이터 수집.
    
    Step 30: 사장 스크린샷 분석 결과 정확한 메뉴 경로 + 컬럼 확정.
    경로: 메인 → '통합 입찰 관리' 클릭 → '입찰 내역 관리' 클릭
    
    화면 컬럼:
      주문/보관번호 | 판매유형 | 상품정보 | 옵션 | 자동조정 | 판매희망가 |
      매입가 | 예상마진 | 마진율 | 발매가 | 일반판매최근가 | 보관(100) | 보관(95)
    """
    from playwright.async_api import async_playwright
    from kream_bot import create_browser, create_context, ensure_logged_in, dismiss_popups, apply_stealth
    import re

    bids = []

    async with async_playwright() as p:
        browser = await create_browser(p, headless=headless)
        context = await create_context(browser, storage='auth_state.json')
        page = await context.new_page()
        await apply_stealth(page)
        
        # 1. 메인 페이지 진입
        print("[SYNC-V2] 메인 페이지 이동...", flush=True, file=sys.stderr)
        await page.goto('https://partner.kream.co.kr/c2c', wait_until='domcontentloaded', timeout=30000)
        await page.wait_for_timeout(3000)
        
        await ensure_logged_in(page, context)
        try: await dismiss_popups(page)
        except: pass
        await page.wait_for_timeout(2000)
        
        # 2. '통합 입찰 관리' 메뉴 클릭 (확장)
        # 사이드바 안의 정확한 a/button만 노림 — ASIDE 자체 클릭 회피
        print("[SYNC-V2] '통합 입찰 관리' 메뉴 확장...", flush=True, file=sys.stderr)
        clicked = await page.evaluate("""
            () => {
                // a, button, [role="link"]만 대상
                const cands = Array.from(document.querySelectorAll(
                    'aside a, aside button, aside [role="link"], aside [role="menuitem"], aside [role="button"]'
                ));
                for (const el of cands) {
                    const text = (el.textContent || '').trim();
                    if (text === '통합 입찰 관리' || text === '입찰 내역 관리') {
                        el.click();
                        return text;
                    }
                }
                return null;
            }
        """)
        print(f"[SYNC-V2] 1차 클릭: {clicked}", flush=True, file=sys.stderr)
        await page.wait_for_timeout(2000)
        
        # 3. '입찰 내역 관리' 메뉴 클릭 (서브메뉴)
        if clicked != '입찰 내역 관리':
            print("[SYNC-V2] '입찰 내역 관리' 서브메뉴 클릭...", flush=True, file=sys.stderr)
            clicked2 = await page.evaluate("""
                () => {
                    const cands = Array.from(document.querySelectorAll(
                        'aside a, aside button, aside [role="link"], aside [role="menuitem"]'
                    ));
                    for (const el of cands) {
                        const text = (el.textContent || '').trim();
                        if (text === '입찰 내역 관리') {
                            el.click();
                            return text;
                        }
                    }
                    return null;
                }
            """)
            print(f"[SYNC-V2] 2차 클릭: {clicked2}", flush=True, file=sys.stderr)
        
        # 4. 페이지 로드 대기
        await page.wait_for_timeout(5000)
        
        # 데이터 행이 나타날 때까지 대기 (최대 15초)
        try:
            await page.wait_for_function("""
                () => {
                    const text = document.body.innerText;
                    return /A-SN\d|A-AC\d|입찰 순번/.test(text);
                }
            """, timeout=15000)
            print("[SYNC-V2] 데이터 감지됨", flush=True, file=sys.stderr)
        except:
            print("[SYNC-V2] 데이터 대기 timeout (계속 진행)", flush=True, file=sys.stderr)
        
        await page.wait_for_timeout(2000)
        print(f"[SYNC-V2] 최종 URL: {page.url}", flush=True, file=sys.stderr)
        
        # 5. 페이지네이션 — '10개씩 보기' → '100개씩 보기' 변경 시도 (정확한 셀렉터만)
        # select 우선: 옵션에 '개씩 보기' 텍스트가 있는 select만 페이지 사이즈 셀렉터로 인정
        size_changed = False
        try:
            size_changed = await page.evaluate("""
                () => {
                    const selects = document.querySelectorAll('select');
                    for (const s of selects) {
                        const opts = Array.from(s.options || []);
                        const isPageSize = opts.some(o => /개씩 보기|per page|\\/page/i.test(o.text || ''));
                        if (!isPageSize) continue;
                        const opt = opts.find(o => /100/.test(o.text)) || opts.find(o => /50/.test(o.text));
                        if (opt) {
                            s.value = opt.value;
                            s.dispatchEvent(new Event('change', { bubbles: true }));
                            return 'select:' + opt.text;
                        }
                    }
                    return false;
                }
            """)
        except Exception as e:
            print(f"[SYNC-V2] select 페이지 사이즈 변경 에러: {e}", flush=True, file=sys.stderr)
        # 클릭 기반 드롭다운 (정확한 패턴만): '10개씩 보기' 텍스트 버튼
        if not size_changed:
            try:
                opened = await page.evaluate("""
                    () => {
                        const cands = Array.from(document.querySelectorAll('button, [role="button"], [role="combobox"], div'));
                        for (const el of cands) {
                            const t = (el.textContent || '').trim();
                            if (/^(10|20)개씩 보기$/.test(t)) {
                                el.click();
                                return t;
                            }
                        }
                        return null;
                    }
                """)
                if opened:
                    await page.wait_for_timeout(700)
                    size_changed = await page.evaluate("""
                        () => {
                            const cands = Array.from(document.querySelectorAll('li, [role="option"], button, a, div'));
                            for (const target of ['100개씩 보기', '50개씩 보기']) {
                                for (const el of cands) {
                                    const t = (el.textContent || '').trim();
                                    if (t === target) {
                                        el.click();
                                        return 'click:' + target;
                                    }
                                }
                            }
                            return false;
                        }
                    """)
            except Exception as e:
                print(f"[SYNC-V2] 클릭 페이지 사이즈 변경 에러: {e}", flush=True, file=sys.stderr)
        print(f"[SYNC-V2] 페이지 사이즈 변경: {size_changed}", flush=True, file=sys.stderr)
        if size_changed:
            await page.wait_for_timeout(3000)

        # 5-1. 페이지네이션 영역 디버그 dump (1회만)
        try:
            pag_debug = await page.evaluate("""
                () => {
                    const out = [];
                    // pagination 후보 영역
                    const sels = ['[class*="pagination"]', '[class*="Pagination"]', 'nav', 'ul[class*="pag"]'];
                    for (const sel of sels) {
                        const els = Array.from(document.querySelectorAll(sel));
                        for (const el of els) {
                            const txt = (el.innerText || '').replace(/\\s+/g, ' ').trim().substring(0, 200);
                            if (txt.length < 3) continue;
                            out.push(`[${sel}] ${txt}`);
                        }
                    }
                    // 본문 하단 button/a 중 숫자/화살표 텍스트
                    const all = Array.from(document.querySelectorAll('button, a, [role="button"]'));
                    const arrows = all.filter(b => {
                        const t = (b.textContent || '').trim();
                        return t === '›' || t === '〉' || t === '>' || t === '다음' || t === 'Next' || /^\\d{1,2}$/.test(t);
                    }).map(b => {
                        return `${b.tagName}|cls=${(b.className||'').toString().substring(0,60)}|aria=${b.getAttribute('aria-label')||''}|text=${(b.textContent||'').trim()}`;
                    });
                    return { boxes: out.slice(0, 5), arrows: arrows.slice(0, 30) };
                }
            """)
            print(f"[SYNC-V2-DBG] pagination boxes: {pag_debug.get('boxes')}", flush=True, file=sys.stderr)
            print(f"[SYNC-V2-DBG] pagination arrows: {pag_debug.get('arrows')}", flush=True, file=sys.stderr)
        except Exception as e:
            print(f"[SYNC-V2-DBG] dump 에러: {e}", flush=True, file=sys.stderr)
        
        # 6. 데이터 추출 (모든 페이지 순회)
        all_rows = []
        page_num = 1
        max_pages = 10
        
        while page_num <= max_pages:
            print(f"[SYNC-V2] 페이지 {page_num} 추출 중...", flush=True, file=sys.stderr)
            
            # 행 데이터 추출 (텍스트 기반 파싱 — HTML 구조 변경에 강함)
            rows_data = await page.evaluate("""
                () => {
                    // 주문번호 패턴이 있는 모든 element 찾기
                    const orderPattern = /A-(SN|AC|BK)\d{5,}/;
                    const allText = document.body.innerText;
                    const matches = [...allText.matchAll(/(A-(?:SN|AC|BK)\d{5,})/g)];
                    const orderIds = [...new Set(matches.map(m => m[1]))];
                    
                    // 각 주문번호 주변 텍스트로 입찰 정보 추출
                    const rows = [];
                    for (const oid of orderIds) {
                        // 주문번호 포함하는 행 element 찾기
                        const xpath = `//*[contains(text(), "${oid}")]`;
                        const result = document.evaluate(xpath, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null);
                        const node = result.singleNodeValue;
                        if (!node) continue;
                        
                        // 가장 가까운 row element 추적
                        let rowEl = node;
                        let depth = 0;
                        while (rowEl && depth < 10) {
                            const txt = rowEl.innerText || '';
                            if (txt.includes('원') && (txt.match(/입찰 순번/) || txt.length > 100)) {
                                break;
                            }
                            rowEl = rowEl.parentElement;
                            depth++;
                        }
                        if (!rowEl) continue;
                        
                        const rowText = rowEl.innerText || '';
                        
                        // 모델번호 (예: 1183B938-100, JQ4110, IX7693)
                        const modelMatch = rowText.match(/([A-Z0-9]{4,}[-]?[A-Z0-9]*)\s*\(\d+\)/) 
                                          || rowText.match(/^([A-Z]{2,}[0-9]+)/m);
                        const model = modelMatch ? modelMatch[1] : '';
                        
                        // 사이즈 (예: 260, 245, ONE SIZE, W215)
                        // Step34-v4: 사이즈는 단독 라인 + 다음 줄 '-' + 다음 줄 가격 컨텍스트로 식별.
                        // \\n은 Python에서 LF로 escape되지 않도록 더블 백슬래시 필수.
                        const sizeMatch = rowText.match(/\\n\\s*(\\d{2,3}(?:\\.\\d)?|ONE SIZE|W\\d{2,3}|[A-Z]{1,3})\\s*\\n\\s*-\\s*\\n\\s*[\\d,]+\\s*원/);
                        const size = sizeMatch ? sizeMatch[1] : '';
                        
                        // 판매희망가 (입찰가)
                        const priceMatches = [...rowText.matchAll(/([\d,]+)\s*원/g)];
                        const prices = priceMatches.map(m => parseInt(m[1].replace(/,/g, '')));
                        const myPrice = prices.find(p => p > 10000 && p < 10000000) || 0;
                        
                        // 입찰 순번
                        const rankMatch = rowText.match(/입찰 순번\s*(\d+)/);
                        const rank = rankMatch ? parseInt(rankMatch[1]) : null;
                        
                        // 상품명
                        const nameMatch = rowText.match(/Onitsuka|New Balance|Mizuno|Adidas|Nike|[가-힣]{3,}/);
                        const nameKr = nameMatch ? nameMatch[0] : '';
                        
                        rows.push({
                            orderId: oid,
                            model: model,
                            size: size,
                            bidPrice: myPrice,
                            bidRank: rank,
                            nameKr: nameKr,
                            rawText: rowText.substring(0, 300)
                        });
                    }
                    return rows;
                }
            """)
            
            print(f"[SYNC-V2] 페이지 {page_num}: {len(rows_data)}건 추출", flush=True, file=sys.stderr)
            all_rows.extend(rows_data)

            # 다음 페이지 클릭 — KREAM Base_ 클래스 + 숫자 텍스트 패턴
            target_page = page_num + 1
            has_next = await page.evaluate(f"""
                () => {{
                    const targetPage = {target_page};
                    const all = Array.from(document.querySelectorAll('button, a, [role="button"]'));
                    // (1) KREAM 페이지 버튼: className에 'Base_' 포함 + 텍스트가 정확한 숫자
                    for (const b of all) {{
                        const txt = (b.textContent || '').trim();
                        const cls = (b.className || '').toString();
                        const disabled = b.disabled || b.getAttribute('aria-disabled') === 'true' || cls.includes('disabled');
                        if (disabled) continue;
                        if (cls.includes('Base_') && txt === String(targetPage)) {{
                            b.click(); return 'kream-num:' + txt;
                        }}
                    }}
                    // (2) aria-label 기반 next
                    for (const b of all) {{
                        const aria = (b.getAttribute('aria-label') || '').toLowerCase();
                        const cls = (b.className || '').toString();
                        const disabled = b.disabled || b.getAttribute('aria-disabled') === 'true' || cls.includes('disabled');
                        if (disabled) continue;
                        if (aria.includes('next') || aria.includes('다음 페이지') || aria === '다음') {{
                            b.click(); return 'aria:' + aria;
                        }}
                    }}
                    // (3) 텍스트 ›, >, 다음, Next, 〉
                    for (const b of all) {{
                        const txt = (b.textContent || '').trim();
                        const cls = (b.className || '').toString();
                        const disabled = b.disabled || b.getAttribute('aria-disabled') === 'true' || cls.includes('disabled');
                        if (disabled) continue;
                        if (txt === '›' || txt === '>' || txt === '다음' || txt === 'Next' || txt === '〉') {{
                            b.click(); return 'text:' + txt;
                        }}
                    }}
                    // (4) 일반 숫자 버튼 (Base_ 미보유)
                    for (const b of all) {{
                        const txt = (b.textContent || '').trim();
                        const cls = (b.className || '').toString();
                        const disabled = b.disabled || b.getAttribute('aria-disabled') === 'true' || cls.includes('disabled');
                        if (disabled) continue;
                        if (txt === String(targetPage)) {{
                            b.click(); return 'num:' + txt;
                        }}
                    }}
                    return false;
                }}
            """)

            print(f"[SYNC-V2] 다음 페이지 클릭: {has_next}", flush=True, file=sys.stderr)
            if not has_next:
                print(f"[SYNC-V2] 마지막 페이지 도달 (page {page_num})", flush=True, file=sys.stderr)
                break

            await page.wait_for_timeout(3000)
            page_num += 1
        
        # 중복 제거
        seen = set()
        unique_rows = []
        for r in all_rows:
            key = r.get('orderId')
            if key and key not in seen:
                seen.add(key)
                unique_rows.append(r)
        
        bids = unique_rows
        print(f"[SYNC-V2] 총 {len(bids)}건 (중복 제거 후)", flush=True, file=sys.stderr)
        
        await browser.close()
    
    return bids

