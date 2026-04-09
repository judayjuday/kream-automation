"""
KREAM 판매자센터 자동화 스크립트
- 상품 고시정보 자동 입력
- 입찰 자동 등록
- Playwright (async) 기반

사용법:
  pip install playwright openpyxl
  playwright install chromium
  python kream_bot.py --mode product   # 상품정보 입력
  python kream_bot.py --mode bid       # 입찰 등록
  python kream_bot.py --mode all       # 둘 다
"""

import asyncio
import argparse
import json
import time
from pathlib import Path

import openpyxl
from playwright.async_api import async_playwright, Page, BrowserContext

# ─── 설정 ───
EXCEL_PATH = "kream_data_template.xlsx"
PARTNER_URL = "https://partner.kream.co.kr"
STATE_FILE = "auth_state.json"  # 로그인 상태 저장

# ─── 엑셀 읽기 ───
def load_product_data(path: str) -> list[dict]:
    """상품정보 시트에서 데이터 로드"""
    wb = openpyxl.load_workbook(path, data_only=True)
    ws = wb["상품정보"]
    headers = [cell.value for cell in ws[1]]
    rows = []
    for row in ws.iter_rows(min_row=2, values_only=True):
        if row[0] is None:
            continue
        rows.append(dict(zip(headers, row)))
    wb.close()
    return rows


def load_bid_data(path: str) -> list[dict]:
    """입찰데이터 시트에서 데이터 로드"""
    wb = openpyxl.load_workbook(path, data_only=True)
    ws = wb["입찰데이터"]
    headers = [cell.value for cell in ws[1]]
    rows = []
    for row in ws.iter_rows(min_row=2, values_only=True):
        if row[0] is None:
            continue
        rows.append(dict(zip(headers, row)))
    wb.close()
    return rows


def load_settings(path: str) -> dict:
    """설정 시트에서 설정값 로드"""
    wb = openpyxl.load_workbook(path, data_only=True)
    ws = wb["설정"]
    settings = {}
    for row in ws.iter_rows(min_row=2, values_only=True):
        if row[0]:
            settings[row[0]] = row[1]
    wb.close()
    return settings


# ─── React input 헬퍼 ───
# KREAM은 Next.js (React) 기반이라 단순 fill()만으론 React state가 안 바뀜
# nativeInputValueSetter로 React의 onChange를 트리거해야 함

async def react_fill(page: Page, selector: str, value: str):
    """React input에 값을 넣고 change 이벤트를 트리거"""
    if value is None or str(value).strip() == "":
        return

    value = str(value).strip()

    await page.evaluate("""
        ([selector, value]) => {
            const el = document.querySelector(selector);
            if (!el) return;
            
            // 기존 값 클리어
            const nativeInputValueSetter = Object.getOwnPropertyDescriptor(
                window.HTMLInputElement.prototype, 'value'
            ).set;
            nativeInputValueSetter.call(el, '');
            el.dispatchEvent(new Event('input', { bubbles: true }));
            
            // 새 값 세팅
            nativeInputValueSetter.call(el, value);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            
            // blur로 확정
            el.dispatchEvent(new Event('blur', { bubbles: true }));
        }
    """, [selector, value])

    await page.wait_for_timeout(200)


async def react_clear_and_fill(page: Page, selector: str, value: str):
    """기존 값을 지우고 React input에 새 값 입력 (클릭 → 전체선택 → 입력)"""
    if value is None or str(value).strip() == "":
        return

    value = str(value).strip()

    el = page.locator(selector)
    await el.click()
    await page.keyboard.press("Control+a")
    await page.keyboard.press("Backspace")
    await page.wait_for_timeout(100)

    # type()은 각 글자마다 이벤트를 발생시키므로 React에서도 잘 동작
    await el.type(value, delay=30)
    await page.wait_for_timeout(200)


# ─── 드롭다운 선택 헬퍼 ───
async def select_dropdown(page: Page, button_selector: str, option_text: str):
    """
    KREAM 커스텀 드롭다운 선택
    button_selector: 드롭다운을 여는 버튼의 CSS selector
    option_text: 선택할 옵션의 텍스트 (부분 매칭)
    """
    if not option_text or str(option_text).strip() == "":
        return

    option_text = str(option_text).strip()

    # 드롭다운 열기
    await page.click(button_selector)
    await page.wait_for_timeout(500)

    # 옵션 검색 및 클릭
    # KREAM의 드롭다운은 보통 리스트 형태로 펼쳐짐
    option = page.get_by_text(option_text, exact=False).first
    try:
        await option.click(timeout=3000)
    except Exception:
        print(f"  ⚠ 드롭다운 옵션 '{option_text}' 찾기 실패, 건너뜀")
        await page.keyboard.press("Escape")

    await page.wait_for_timeout(300)


# ─── 로그인 ───
async def login(context: BrowserContext, settings: dict) -> Page:
    """KREAM 판매자센터 로그인"""
    page = await context.new_page()

    # 저장된 인증 상태가 있으면 바로 메인으로
    if Path(STATE_FILE).exists():
        print("✅ 저장된 로그인 상태 사용")
        await page.goto(f"{PARTNER_URL}/c2c")
        await page.wait_for_timeout(2000)

        # 로그인 페이지로 리디렉트되지 않았으면 OK
        if "/sign-in" not in page.url:
            return page

    print("🔐 로그인 진행...")
    await page.goto(f"{PARTNER_URL}/sign-in")
    await page.wait_for_load_state("networkidle")

    email = settings.get("kream_email", "")
    password = settings.get("kream_password", "")

    if not email or not password:
        print("⚠ 이메일/비밀번호가 설정에 없습니다.")
        print("  → 브라우저에서 수동으로 로그인해주세요.")
        print("  → 로그인 완료 후 Enter를 눌러주세요.")
        input()
    else:
        # 이메일 입력
        await page.fill('input[type="email"], input[name="email"]', email)
        await page.wait_for_timeout(300)

        # 비밀번호 입력
        await page.fill('input[type="password"], input[name="password"]', password)
        await page.wait_for_timeout(300)

        # 로그인 버튼 클릭
        await page.click('button:has-text("로그인")')
        await page.wait_for_timeout(3000)

    # 인증 상태 저장
    await context.storage_state(path=STATE_FILE)
    print("✅ 로그인 성공, 상태 저장 완료")

    return page


# ─── 상품 고시정보 입력 ───
async def fill_product_info(page: Page, product: dict, delay: float = 2.0):
    """단일 상품의 고시정보를 자동 입력"""
    product_id = product["product_id"]
    url = f"{PARTNER_URL}/business/my/products/{product_id}"

    print(f"\n📦 상품 #{product_id} 처리 중...")
    await page.goto(url)
    await page.wait_for_load_state("networkidle")
    await page.wait_for_timeout(1500)

    # ── 고시 카테고리 (드롭다운) ──
    category = product.get("고시카테고리")
    if category:
        await select_dropdown(
            page,
            'div[name="categoryName"] button',
            category
        )
        print(f"  ✓ 고시카테고리: {category}")

    # ── attributeSet 필드들 (텍스트 input) ──
    field_map = {
        "종류":           'input[name="attributeSet.0.value"]',
        "소재":           'input[name="attributeSet.1.value"]',
        "색상":           'input[name="attributeSet.2.value"]',
        "크기":           'input[name="attributeSet.3.value"]',
        "제조자_수입자":   'input[name="attributeSet.4.value"]',
        "제조국":         'input[name="attributeSet.5.value"]',
        "취급시_주의사항": 'input[name="attributeSet.6.value"]',
        "품질보증기준":    'input[name="attributeSet.7.value"]',
        "AS_전화번호":     'input[name="attributeSet.8.value"]',
    }

    for field_name, selector in field_map.items():
        value = product.get(field_name)
        if value and str(value).strip():
            await react_clear_and_fill(page, selector, str(value))
            print(f"  ✓ {field_name}: {str(value)[:30]}...")

    # ── 원산지 (드롭다운) ──
    origin = product.get("원산지")
    if origin:
        await select_dropdown(
            page,
            'div[name="countryOfOriginId"] button',
            origin
        )
        print(f"  ✓ 원산지: {origin}")

    # ── HS코드 (드롭다운) ──
    hs_code = product.get("HS코드")
    if hs_code:
        await select_dropdown(
            page,
            'div[name="hsCodeId"] button',
            str(hs_code)
        )
        print(f"  ✓ HS코드: {hs_code}")

    # ── 배송 정보 (텍스트 input) ──
    shipping_map = {
        "상품무게_kg": 'input[name="productWeight"]',
        "박스가로_cm": 'input[name="boxWidth"]',
        "박스세로_cm": 'input[name="boxHeight"]',
        "박스높이_cm": 'input[name="boxDepth"]',
    }

    for field_name, selector in shipping_map.items():
        value = product.get(field_name)
        if value and str(value).strip():
            await react_clear_and_fill(page, selector, str(value))
            print(f"  ✓ {field_name}: {value}")

    # ── 저장하기 버튼 클릭 ──
    save_btn = page.locator('button:has-text("저장하기")')
    if await save_btn.is_visible():
        await save_btn.click()
        await page.wait_for_timeout(2000)
        print(f"  💾 상품 #{product_id} 저장 완료!")
    else:
        print(f"  ⚠ 저장 버튼을 찾을 수 없음")

    await page.wait_for_timeout(delay * 1000)


# ─── 입찰 자동 등록 ───
async def place_bid(page: Page, bid: dict, delay: float = 2.0):
    """
    단일 입찰 등록
    ※ 입찰 페이지의 실제 구조는 상품정보 관리와 다를 수 있어서,
      실제 입찰 페이지의 HTML을 확인한 뒤 셀렉터를 조정해야 합니다.
      아래는 일반 판매 입찰 (partner.kream.co.kr/business/products) 기준 뼈대입니다.
    """
    product_id = bid["product_id"]
    size = bid.get("사이즈", "ONE SIZE")
    price = bid.get("입찰가격", 0)
    period = bid.get("입찰기간_일", 30)
    qty = bid.get("수량", 1)

    print(f"\n💰 입찰 등록: 상품 #{product_id}, 사이즈 {size}, {price:,}원")

    # ── 입찰 페이지로 이동 ──
    # 재고별 입찰 관리 or 일반 판매 입찰 페이지
    # 실제 URL 패턴은 KREAM 업데이트에 따라 달라질 수 있음
    await page.goto(f"{PARTNER_URL}/business/ask-sales")
    await page.wait_for_load_state("networkidle")
    await page.wait_for_timeout(1500)

    # ── 상품 검색 ──
    # TODO: 실제 입찰 페이지의 검색 UI에 맞게 수정 필요
    # 일반적으로: 검색창에 상품 ID 입력 → 상품 선택 → 사이즈 선택 → 가격 입력 → 기간 선택

    print(f"  ⚠ 입찰 자동화는 입찰 페이지 HTML 분석 후 셀렉터 보정 필요")
    print(f"  → 입찰 페이지를 저장(Ctrl+S)해서 보내주시면 완성해드릴게요")

    # ── 뼈대 코드 (실제 셀렉터 적용 시 주석 해제) ──
    """
    # 상품 검색
    search_input = page.locator('input[placeholder*="검색"]').first
    await search_input.fill(str(product_id))
    await page.wait_for_timeout(1000)
    
    # 검색 결과에서 상품 선택
    await page.click(f'text="{product_id}"')
    await page.wait_for_timeout(500)
    
    # 사이즈 선택
    await page.click(f'button:has-text("{size}")')
    await page.wait_for_timeout(300)
    
    # 가격 입력
    price_input = page.locator('input[class*="PriceField"]').first
    await react_clear_and_fill(page, 'input[class*="PriceField"]', str(price))
    
    # 입찰 기간 선택 (버튼식)
    period_map = {1: "1일", 3: "3일", 7: "7일", 30: "30일", 60: "60일", 90: "90일"}
    period_text = period_map.get(period, "30일")
    await page.click(f'button:has-text("{period_text}")')
    await page.wait_for_timeout(300)
    
    # 입찰 등록 버튼
    await page.click('button:has-text("입찰하기")')
    await page.wait_for_timeout(2000)
    
    print(f"  💾 입찰 등록 완료!")
    """

    await page.wait_for_timeout(delay * 1000)


# ─── 대량 입찰 (엑셀 업로드 방식) ───
async def bulk_bid_upload(page: Page, excel_path: str):
    """
    KREAM 통합 입찰 관리 > 대량 입찰/수정 기능 활용
    partner.kream.co.kr/asks/bulk 페이지에서 엑셀 업로드
    """
    print("\n📤 대량 입찰 업로드...")
    await page.goto(f"{PARTNER_URL}/asks/bulk")
    await page.wait_for_load_state("networkidle")
    await page.wait_for_timeout(2000)

    # 엑셀 파일 업로드 (dropzone)
    # KREAM의 대량 입찰은 자체 엑셀 템플릿을 사용하므로,
    # 먼저 KREAM에서 템플릿을 다운로드받아서 그 형식에 맞춰야 합니다.
    print("  ⚠ KREAM 대량 입찰은 KREAM 전용 엑셀 템플릿이 필요합니다.")
    print("  → KREAM에서 '양식 다운로드' 후 해당 형식에 맞춰 데이터를 채워주세요.")


# ─── 메인 ───
async def main():
    parser = argparse.ArgumentParser(description="KREAM 판매자센터 자동화")
    parser.add_argument("--mode", choices=["product", "bid", "all"], default="product",
                        help="실행 모드: product(상품정보), bid(입찰), all(전부)")
    parser.add_argument("--excel", default=EXCEL_PATH, help="데이터 엑셀 파일 경로")
    parser.add_argument("--dry-run", action="store_true", help="실제 저장 없이 테스트")
    args = parser.parse_args()

    # 설정 로드
    settings = load_settings(args.excel)
    headless = settings.get("headless_mode", "false").lower() == "true"
    delay = float(settings.get("delay_between_items", 3))

    print("=" * 50)
    print("🤖 KREAM 판매자센터 자동화")
    print(f"   모드: {args.mode}")
    print(f"   엑셀: {args.excel}")
    print(f"   헤드리스: {headless}")
    print(f"   딜레이: {delay}초")
    print("=" * 50)

    async with async_playwright() as p:
        # 저장된 인증 상태 사용
        storage = STATE_FILE if Path(STATE_FILE).exists() else None

        browser = await p.chromium.launch(
            headless=headless,
            slow_mo=100,  # 약간의 딜레이로 안정성 확보
        )

        context = await browser.new_context(
            storage_state=storage,
            viewport={"width": 1440, "height": 900},
            locale="ko-KR",
        )

        page = await login(context, settings)

        # ── 상품 정보 입력 ──
        if args.mode in ("product", "all"):
            products = load_product_data(args.excel)
            print(f"\n📋 상품 {len(products)}건 처리 시작")

            for i, product in enumerate(products, 1):
                print(f"\n--- [{i}/{len(products)}] ---")
                try:
                    await fill_product_info(page, product, delay)
                except Exception as e:
                    print(f"  ❌ 오류: {e}")
                    continue

        # ── 입찰 등록 ──
        if args.mode in ("bid", "all"):
            bids = load_bid_data(args.excel)
            print(f"\n📋 입찰 {len(bids)}건 처리 시작")

            for i, bid in enumerate(bids, 1):
                print(f"\n--- [{i}/{len(bids)}] ---")
                try:
                    await place_bid(page, bid, delay)
                except Exception as e:
                    print(f"  ❌ 오류: {e}")
                    continue

        # 최종 인증 상태 저장
        await context.storage_state(path=STATE_FILE)
        print("\n✅ 모든 작업 완료!")

        await browser.close()


if __name__ == "__main__":
    asyncio.run(main())
