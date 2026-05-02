"""
KREAM 가격 자동 조정 모듈
1) 내 입찰 목록 수집 (partner.kream.co.kr/business/asks)
2) 시장 가격 수집 (kream.co.kr/products/상품번호)
3) 추천 조정가 계산
4) 승인된 건만 실제 가격 수정
"""

import asyncio
import json
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

async def collect_my_bids(headless=True) -> list:
    """partner.kream.co.kr/business/asks 에서 현재 입찰 중인 내역 수집"""
    async with async_playwright() as p:
        browser = await launch_browser(p, headless)
        context = await make_context(browser, STATE_FILE_PARTNER)
        page = await context.new_page()
        await stealth(page)

        # 다중 URL 시도 (KREAM이 URL 경로를 바꿨을 가능성 대응)
        BID_URLS_FALLBACK = [
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
    # 1) 내 입찰 수집
    print("=" * 50)
    print("  1단계: 내 입찰 목록 수집")
    my_bids = await collect_my_bids(headless)
    print(f"  입찰 {len(my_bids)}건 수집")

    if not my_bids:
        return {"bids": [], "market": {}, "recommendations": []}

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
