"""
KREAM 판매자센터 자동화 - Flask 백엔드 서버
- 대시보드 UI 서빙
- 가격 수집 / 입찰 등록 / 고시정보 등록 API
- Playwright 기반 자동화를 비동기 호출

실행: python3 kream_server.py
접속: http://localhost:5001
"""

import asyncio
import json
import math
import re
import threading
import traceback
import urllib.request
import urllib.error
from datetime import datetime
from pathlib import Path

from flask import Flask, request, jsonify, send_file
import openpyxl

# ── 기존 모듈 import ──
from kream_collector import collect_prices
from kream_adjuster import full_adjust_flow, modify_bid_price
from kream_bot import (
    create_browser, create_context, apply_stealth,
    ensure_logged_in, fill_product_info, place_bid, dismiss_popups,
    STATE_FILE, PARTNER_URL,
)
from playwright.async_api import async_playwright

app = Flask(__name__)

BASE_DIR = Path(__file__).parent
HISTORY_FILE = BASE_DIR / "execution_history.json"
BATCH_HISTORY_FILE = BASE_DIR / "batch_history.json"
SETTINGS_FILE = BASE_DIR / "settings.json"
DISCOVERY_FILE = BASE_DIR / "kream_discovery_data.xlsx"
MY_BIDS_FILE = BASE_DIR / "my_bids_local.json"
QUEUE_FILE = BASE_DIR / "queue_data.json"

# ── 실행 상태 관리 ──
tasks = {}  # task_id → { status, logs, result }
task_counter = 0
task_lock = threading.Lock()

# ── 자동 입찰 제어 ──
auto_bid_control = {"state": "idle"}  # idle, running, paused, stopping
auto_bid_lock = threading.Lock()
auto_bid_event = threading.Event()
auto_bid_event.set()  # 초기 상태: 실행 가능

# ── 상품 큐 ──
product_queue = []  # [{id, model, cny, category, ...}, ...]
queue_counter = 0
queue_lock = threading.Lock()


def save_queue():
    """product_queue를 queue_data.json에 저장"""
    try:
        QUEUE_FILE.write_text(json.dumps(
            {"counter": queue_counter, "queue": product_queue},
            ensure_ascii=False, indent=2
        ))
    except Exception:
        pass


def load_queue():
    """서버 시작 시 queue_data.json 복원"""
    global product_queue, queue_counter
    if not QUEUE_FILE.exists():
        return
    try:
        data = json.loads(QUEUE_FILE.read_text())
        product_queue = data.get("queue", [])
        queue_counter = data.get("counter", len(product_queue))
        print(f"[큐 복원] {len(product_queue)}건 로드됨")
    except Exception as e:
        print(f"[큐 복원 실패] {e}")


load_queue()


# ── 환율 캐시 ──
def _load_initial_rates():
    """settings.json에서 마지막으로 저장된 환율 읽기"""
    d = {"cny": 218.12, "usd": 1495.76, "updated_at": None}
    if SETTINGS_FILE.exists():
        try:
            s = json.loads(SETTINGS_FILE.read_text())
            if "cnyRate" in s:
                d["cny"] = float(s["cnyRate"])
            if "usdRate" in s:
                d["usd"] = float(s["usdRate"])
        except Exception:
            pass
    return d


_exchange_rate_cache = _load_initial_rates()
_exchange_rate_lock = threading.Lock()


def fetch_exchange_rates():
    """CNY→KRW, USD→KRW 환율을 외부 API에서 가져와 settings.json에 반영"""
    global _exchange_rate_cache

    cny_rate = None
    usd_rate = None

    # CNY: primary → open.er-api.com, fallback → fawazahmed0 currency-api
    try:
        url = "https://open.er-api.com/v6/latest/CNY"
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
            cny_rate = round(float(data["rates"]["KRW"]), 2)
        print(f"[환율] CNY 조회 성공 (open.er-api): {cny_rate}")
    except Exception as e:
        print(f"[환율] CNY primary 조회 실패: {e}, fallback 시도...")
        try:
            url = "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/cny.json"
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read())
                cny_rate = round(float(data["cny"]["krw"]), 2)
            print(f"[환율] CNY 조회 성공 (fallback): {cny_rate}")
        except Exception as e2:
            print(f"[환율] CNY fallback도 실패: {e2}")

    # USD
    try:
        url = "https://open.er-api.com/v6/latest/USD"
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
            usd_rate = round(float(data["rates"]["KRW"]), 2)
    except Exception as e:
        print(f"[환율] USD 조회 실패: {e}")

    if cny_rate is None and usd_rate is None:
        # 실패 시 기본값 사용
        print("[환율] 모든 API 실패 — 기본값 사용 (CNY=218.12)")
        cny_rate = 218.12
        usd_rate = _exchange_rate_cache.get("usd", 1495.76)

    now = datetime.now().strftime("%m/%d %H:%M")

    with _exchange_rate_lock:
        if cny_rate is not None:
            _exchange_rate_cache["cny"] = cny_rate
        if usd_rate is not None:
            _exchange_rate_cache["usd"] = usd_rate
        _exchange_rate_cache["updated_at"] = now

    try:
        settings = {}
        if SETTINGS_FILE.exists():
            settings = json.loads(SETTINGS_FILE.read_text())
        if cny_rate is not None:
            settings["cnyRate"] = cny_rate
        if usd_rate is not None:
            settings["usdRate"] = usd_rate
        SETTINGS_FILE.write_text(json.dumps(settings, ensure_ascii=False, indent=2))
        print(f"[환율] CNY={_exchange_rate_cache['cny']}, USD={_exchange_rate_cache['usd']} ({now})")
    except Exception as e:
        print(f"[환율] settings 저장 실패: {e}")

    return _exchange_rate_cache.copy()


def get_headless():
    """설정에서 headless 모드 읽기"""
    if SETTINGS_FILE.exists():
        try:
            s = json.loads(SETTINGS_FILE.read_text())
            return s.get("headless", True)
        except Exception:
            pass
    return True


def new_task():
    global task_counter
    with task_lock:
        task_counter += 1
        tid = f"task_{task_counter}"
        tasks[tid] = {"status": "running", "logs": [], "result": None}
        return tid


def add_log(tid, level, msg):
    ts = datetime.now().strftime("%H:%M:%S")
    entry = {"time": ts, "level": level, "msg": msg}
    if tid in tasks:
        tasks[tid]["logs"].append(entry)


def finish_task(tid, result=None, error=None):
    if tid in tasks:
        tasks[tid]["status"] = "error" if error else "done"
        tasks[tid]["result"] = result
        if error:
            add_log(tid, "error", str(error))


# ═══════════════════════════════════════════
# 페이지 서빙
# ═══════════════════════════════════════════

@app.route("/")
def index():
    return send_file(BASE_DIR / "kream_dashboard.html")


# ═══════════════════════════════════════════
# API: 상품 검색 (가격 수집)
# ═══════════════════════════════════════════

@app.route("/api/search", methods=["POST"])
def api_search():
    """모델번호 또는 상품번호로 KREAM 가격 수집"""
    data = request.json or {}
    product_id = str(data.get("productId", "")).strip()
    model = str(data.get("model", "")).strip()

    if not product_id and not model:
        return jsonify({"error": "productId 또는 model 필요"}), 400

    tid = new_task()
    add_log(tid, "info", f"검색 시작: productId={product_id}, model={model}")

    def run():
        try:
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)

            if product_id:
                add_log(tid, "info", f"상품 #{product_id} 가격 수집 중...")
                results = loop.run_until_complete(
                    collect_prices([product_id], headless=get_headless(), include_partner=False)
                )
            else:
                # 모델번호로 검색 → 상품번호 찾기
                add_log(tid, "info", f"모델번호 '{model}' 검색 중...")
                results = loop.run_until_complete(
                    search_by_model(model)
                )

            loop.close()

            if results and len(results) > 0:
                kream = results[0].get("kream", {})
                # 세션 만료 감지
                if kream.get("session_expired"):
                    add_log(tid, "error", f"세션 만료! {kream['session_expired']} 재로그인 필요")
                else:
                    add_log(tid, "success", f"수집 완료: {kream.get('product_name', 'N/A')}")
                finish_task(tid, result=results[0])
            else:
                add_log(tid, "error", "검색 결과 없음")
                finish_task(tid, error="검색 결과 없음")
        except Exception as e:
            traceback.print_exc()
            finish_task(tid, error=str(e))

    thread = threading.Thread(target=run, daemon=True)
    thread.start()

    return jsonify({"taskId": tid})


async def search_by_model(model: str):
    """모델번호로 KREAM 검색 → 상품번호 찾기 → 가격 수집"""
    from playwright.async_api import async_playwright
    from kream_collector import (
        create_browser, create_context, apply_stealth,
        STATE_FILE_KREAM,
    )

    kream_session = STATE_FILE_KREAM if Path(STATE_FILE_KREAM).exists() else None

    async with async_playwright() as p:
        browser = await create_browser(p, headless=get_headless())
        context = await create_context(browser, kream_session)
        page = await context.new_page()
        await apply_stealth(page)

        # KREAM 검색 페이지
        search_url = f"https://kream.co.kr/search?keyword={model}&tab=products"
        await page.goto(search_url, wait_until="domcontentloaded")
        # 스마트 대기: 첫 검색결과 등장 즉시 진행, 없으면 3초 후 실패 처리
        try:
            await page.wait_for_selector('a[href*="/products/"]', timeout=3000)
        except Exception:
            pass  # 결과 없음 → product_id = None → 빈 배열 반환

        # 첫 번째 검색 결과에서 상품번호 + 브랜드 + 카테고리 추출
        search_info = await page.evaluate(r"""() => {
            const link = document.querySelector('a[href*="/products/"]');
            let productId = null, brand = '';
            if (link) {
                const m = link.href.match(/\/products\/(\d+)/);
                if (m) productId = m[1];
                // 검색 결과 카드에서 브랜드 (첫번째 텍스트 줄)
                const lines = link.innerText.trim().split('\n').map(s => s.trim()).filter(s => s);
                if (lines.length > 0) brand = lines[0];
            }
            // 카테고리
            let category = '';
            const cats = document.querySelectorAll('.category, [class*="category"], [class*="tag"]');
            for (const el of cats) {
                const t = el.innerText.trim();
                if (t) { category = t; break; }
            }
            return { productId, category, brand };
        }""")

        product_id = search_info.get("productId") if search_info else None
        kream_category = search_info.get("category", "") if search_info else ""
        kream_brand = search_info.get("brand", "") if search_info else ""

        if kream_session:
            await context.storage_state(path=STATE_FILE_KREAM)
        await browser.close()

    if product_id:
        results = await collect_prices([product_id], headless=get_headless(), include_partner=False)
        # 카테고리/브랜드 정보를 kream 데이터에 주입
        if results:
            if kream_brand:
                results[0].setdefault("kream", {})["brand"] = kream_brand
        if results and kream_category:
            results[0].setdefault("kream", {})["category"] = kream_category
        return results
    return []


# ═══════════════════════════════════════════
# API: 입찰 등록
# ═══════════════════════════════════════════

@app.route("/api/bid", methods=["POST"])
def api_bid():
    """판매 입찰 등록"""
    data = request.json or {}
    product_id = str(data.get("productId", "")).strip()
    price = int(data.get("price", 0))
    size = str(data.get("size", "ONE SIZE")).strip()
    qty = int(data.get("quantity", 1))

    if not product_id or not price:
        return jsonify({"error": "productId, price 필요"}), 400

    tid = new_task()
    add_log(tid, "info", f"입찰 시작: #{product_id} {price:,}원 × {qty}개")

    def run():
        try:
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            result = loop.run_until_complete(
                run_bid(product_id, price, size, qty, tid)
            )
            loop.close()
            finish_task(tid, result=result)
        except Exception as e:
            traceback.print_exc()
            finish_task(tid, error=str(e))

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return jsonify({"taskId": tid})


async def run_bid(product_id, price, size, qty, tid):
    async with async_playwright() as p:
        browser = await create_browser(p, headless=get_headless())
        context = await create_context(browser, STATE_FILE)
        page = await context.new_page()
        await apply_stealth(page)

        if not await ensure_logged_in(page):
            add_log(tid, "error", "판매자센터 로그인 필요 (python3 kream_bot.py --mode login)")
            await browser.close()
            return {"success": False, "error": "로그인 필요"}

        bid_data = {
            "product_id": product_id,
            "사이즈": size,
            "입찰가격": price,
            "수량": qty,
        }

        add_log(tid, "info", f"판매 입찰 등록 중... #{product_id} {price:,}원 × {qty}개")
        success = await place_bid(page, bid_data, delay=2.0)

        await context.storage_state(path=STATE_FILE)
        await browser.close()

        if success:
            add_log(tid, "success", f"입찰 등록 완료! #{product_id} → {price:,}원")
            save_history("입찰", product_id, price, qty, True)
            save_bid_local(product_id, model="", size=size, price=price, source="placed")
        else:
            add_log(tid, "error", f"입찰 등록 실패: #{product_id}")

        return {"success": success}


# ═══════════════════════════════════════════
# API: 고시정보 등록
# ═══════════════════════════════════════════

@app.route("/api/product-info", methods=["POST"])
def api_product_info():
    """상품 고시정보 등록"""
    data = request.json or {}
    product_id = str(data.get("productId", "")).strip()

    if not product_id:
        return jsonify({"error": "productId 필요"}), 400

    tid = new_task()
    add_log(tid, "info", f"고시정보 등록 시작: #{product_id}")

    def run():
        try:
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            result = loop.run_until_complete(
                run_product_info(product_id, data, tid)
            )
            loop.close()
            finish_task(tid, result=result)
        except Exception as e:
            traceback.print_exc()
            finish_task(tid, error=str(e))

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return jsonify({"taskId": tid})


async def run_product_info(product_id, data, tid):
    async with async_playwright() as p:
        browser = await create_browser(p, headless=get_headless())
        context = await create_context(browser, STATE_FILE)
        page = await context.new_page()
        await apply_stealth(page)

        if not await ensure_logged_in(page):
            add_log(tid, "error", "판매자센터 로그인 필요")
            await browser.close()
            return {"success": False, "error": "로그인 필요"}

        gosi = data.get("gosi", {})
        category = gosi.get("category", "가방")
        product_data = build_gosi_data(product_id, gosi, category)

        add_log(tid, "info", f"고시정보 입력 중... #{product_id}")
        await fill_product_info(page, product_data, delay=2.0)

        await context.storage_state(path=STATE_FILE)
        await browser.close()

        add_log(tid, "success", f"고시정보 등록 완료: #{product_id}")
        return {"success": True}


# ═══════════════════════════════════════════
# API: 고시정보 + 입찰 통합 실행
# ═══════════════════════════════════════════

@app.route("/api/register", methods=["POST"])
def api_register():
    """고시정보 등록 (필요시) + 판매 입찰 통합 실행"""
    data = request.json or {}
    product_id = str(data.get("productId", "")).strip()
    price = int(data.get("price", 0))
    size = str(data.get("size", "ONE SIZE")).strip()
    qty = int(data.get("quantity", 1))
    gosi_already = data.get("gosiAlready", False)
    gosi = data.get("gosi", {})

    if not product_id or not price:
        return jsonify({"error": "productId, price 필요"}), 400

    tid = new_task()
    add_log(tid, "info", f"자동화 시작: #{product_id} → {price:,}원 × {qty}개")

    def run():
        try:
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            result = loop.run_until_complete(
                run_full_register(product_id, price, size, qty,
                                  gosi_already, gosi, tid)
            )
            loop.close()
            finish_task(tid, result=result)
        except Exception as e:
            traceback.print_exc()
            finish_task(tid, error=str(e))

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return jsonify({"taskId": tid})


GOSI_DEFAULTS = {
    "country": "상품별 상이 (케어라벨 참고)",
    "caution": "제품 라벨 참조",
    "warranty": "관련 법 및 소비자 분쟁 해결 기준에 따름",
    "phone": "01075446127",
    "origin_bag": "China (중국) (CN)",
    "origin_shoe": "China (중국) (CN)",
    "hs_bag": "4202.92",
    "hs_shoe": "6404.11",
}


def build_gosi_data(product_id, gosi, category="가방"):
    """고시정보 dict 조립 (기본값 적용)"""
    is_shoe = "신발" in category or "sneaker" in category.lower()
    return {
        "product_id": product_id,
        "고시카테고리": gosi.get("category", "의류"),
        "종류": gosi.get("type", ""),
        "소재": gosi.get("material", ""),
        "색상": gosi.get("color", ""),
        "크기": gosi.get("size", ""),
        "제조자_수입자": gosi.get("maker", ""),
        "제조국": gosi.get("country", GOSI_DEFAULTS["country"]),
        "취급시_주의사항": gosi.get("caution", GOSI_DEFAULTS["caution"]),
        "품질보증기준": gosi.get("warranty", GOSI_DEFAULTS["warranty"]),
        "AS_전화번호": gosi.get("phone", GOSI_DEFAULTS["phone"]),
        "원산지": gosi.get("origin",
                        GOSI_DEFAULTS["origin_shoe"] if is_shoe else GOSI_DEFAULTS["origin_bag"]),
        "HS코드": gosi.get("hsCode",
                        GOSI_DEFAULTS["hs_shoe"] if is_shoe else GOSI_DEFAULTS["hs_bag"]),
    }


async def run_full_register(product_id, price, size, qty, gosi_already, gosi, tid, model="", bid_days=30):
    async with async_playwright() as p:
        browser = await create_browser(p, headless=get_headless())
        context = await create_context(browser, STATE_FILE)
        page = await context.new_page()
        await apply_stealth(page)

        if not await ensure_logged_in(page):
            add_log(tid, "error", "판매자센터 로그인 필요 (python3 kream_bot.py --mode login)")
            await browser.close()
            return {"success": False, "error": "로그인 필요"}

        # ── 1) 고시정보 자동 감지 + 등록 ──
        if not gosi_already:
            add_log(tid, "info", f"고시정보 등록 중... #{product_id}")
            category = gosi.get("category", "가방")
            product_data = build_gosi_data(product_id, gosi, category)
            try:
                await fill_product_info(page, product_data, delay=2.0)
                add_log(tid, "success", "고시정보 등록 완료")
            except Exception as e:
                add_log(tid, "error", f"고시정보 등록 실패: {e}")
                await browser.close()
                return {"success": False, "error": f"고시정보 실패: {e}"}
        else:
            add_log(tid, "info", "고시정보 건너뜀 (이미 등록됨)")

        # ── 2) 판매 입찰 등록 ──
        add_log(tid, "info", f"판매 입찰 등록 중... {price:,}원 × {qty}개 ({bid_days}일)")
        bid_data = {
            "product_id": product_id,
            "사이즈": size,
            "입찰가격": price,
            "수량": qty,
            "bid_days": bid_days,
        }

        try:
            success = await place_bid(page, bid_data, delay=2.0)
        except Exception as e:
            add_log(tid, "error", f"입찰 등록 실패: {e}")
            await browser.close()
            return {"success": False, "error": f"입찰 실패: {e}"}

        await context.storage_state(path=STATE_FILE)
        await browser.close()

        if success:
            add_log(tid, "success", f"입찰 등록 완료! #{product_id} → {price:,}원 × {qty}개")
            task_type = "고시정보+입찰" if not gosi_already else "입찰"
            save_history(task_type, product_id, price, qty, True)
            save_bid_local(product_id, model=model, size=size, price=price, source="placed")
        else:
            add_log(tid, "error", "입찰 등록 실패")
            save_history("입찰실패", product_id, price, qty, False)

        return {"success": success}


# ═══════════════════════════════════════════
# API: 태스크 상태 폴링
# ═══════════════════════════════════════════

@app.route("/api/task/<task_id>")
def api_task_status(task_id):
    """태스크 실행 상태 및 로그 조회"""
    task = tasks.get(task_id)
    if not task:
        return jsonify({"error": "태스크 없음"}), 404
    return jsonify(task)


# ═══════════════════════════════════════════
# API: 가격 자동 조정
# ═══════════════════════════════════════════

@app.route("/api/adjust/scan", methods=["POST"])
def api_adjust_scan():
    """1~3단계: 내 입찰 수집 → 시장 분석 → 추천 생성"""
    tid = new_task()
    add_log(tid, "info", "가격 조정 스캔 시작...")

    def run():
        try:
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            add_log(tid, "info", "1단계: 내 입찰 목록 수집 중...")
            result = loop.run_until_complete(full_adjust_flow(headless=get_headless()))
            loop.close()

            n_bids = len(result.get("bids", []))
            n_recs = len(result.get("recommendations", []))
            raises = sum(1 for r in result.get("recommendations", []) if r["action"] == "raise")
            add_log(tid, "success",
                    f"스캔 완료: 입찰 {n_bids}건, 상향 제안 {raises}건, 유지 {n_recs - raises}건")
            finish_task(tid, result=result)
        except Exception as e:
            traceback.print_exc()
            finish_task(tid, error=str(e))

    threading.Thread(target=run, daemon=True).start()
    return jsonify({"taskId": tid})


@app.route("/api/adjust/execute", methods=["POST"])
def api_adjust_execute():
    """5단계: 승인된 항목들의 가격 수정 실행"""
    data = request.json or {}
    items = data.get("items", [])  # [{orderId, newPrice}, ...]

    if not items:
        return jsonify({"error": "수정할 항목 없음"}), 400

    tid = new_task()
    add_log(tid, "info", f"가격 수정 실행: {len(items)}건")

    def run():
        try:
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)

            results = []
            for i, item in enumerate(items, 1):
                oid = item["orderId"]
                price = item["newPrice"]
                add_log(tid, "info", f"[{i}/{len(items)}] {oid} → {price:,}원 수정 중...")

                ok = loop.run_until_complete(modify_bid_price(oid, price, headless=get_headless()))
                results.append({"orderId": oid, "success": ok})

                if ok:
                    add_log(tid, "success", f"{oid} → {price:,}원 수정 완료")
                else:
                    add_log(tid, "error", f"{oid} 수정 실패")

            loop.close()

            success = sum(1 for r in results if r["success"])
            add_log(tid, "success", f"완료: {success}/{len(items)}건 성공")
            finish_task(tid, result={"results": results, "success": success, "total": len(items)})
        except Exception as e:
            traceback.print_exc()
            finish_task(tid, error=str(e))

    threading.Thread(target=run, daemon=True).start()
    return jsonify({"taskId": tid})


# ═══════════════════════════════════════════
# API: 대량 입찰 엑셀 생성
# ═══════════════════════════════════════════

@app.route("/api/bulk/generate", methods=["POST"])
def api_bulk_generate():
    """KREAM 대량입찰 양식 엑셀 생성"""
    data = request.json or {}
    items = data.get("items", [])
    if not items:
        return jsonify({"error": "items 필요"}), 400

    output_path = BASE_DIR / "kream_bulk_bid.xlsx"
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "대량입찰"

    # 1행: 유의사항
    ws.append(["[유의사항] 상품번호, 모델번호, 영문상품명은 수정하지 마세요. 판매희망가와 수량만 입력하세요."])
    # 2행: 헤더
    ws.append(["상품번호", "모델번호", "영문상품명", "옵션명", "판매희망가", "수량", "입찰기한", "창고보관"])
    # 3행: 필수/선택
    ws.append(["필수", "필수", "필수", "필수", "필수", "필수", "선택", "선택"])

    # 4행~: 데이터
    for item in items:
        ws.append([
            item.get("productId", ""),
            item.get("model", ""),
            item.get("nameEn", ""),
            item.get("size", "ONE SIZE"),
            item.get("price", ""),
            item.get("quantity", 1),
            item.get("deadline", ""),
            item.get("warehouse", ""),
        ])

    wb.save(str(output_path))
    return jsonify({"ok": True, "path": str(output_path), "count": len(items)})


@app.route("/api/bulk/download")
def api_bulk_download():
    """생성된 대량입찰 엑셀 다운로드"""
    path = BASE_DIR / "kream_bulk_bid.xlsx"
    if not path.exists():
        return jsonify({"error": "파일 없음"}), 404
    return send_file(str(path), as_attachment=True, download_name="kream_bulk_bid.xlsx")


@app.route("/api/bulk/upload", methods=["POST"])
def api_bulk_upload():
    """KREAM 판매자센터에 대량입찰 엑셀 업로드 자동화"""
    tid = new_task()
    add_log(tid, "info", "대량입찰 엑셀 업로드 시작...")

    def run():
        try:
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            result = loop.run_until_complete(upload_bulk_excel(tid))
            loop.close()
            finish_task(tid, result=result)
        except Exception as e:
            traceback.print_exc()
            finish_task(tid, error=str(e))

    threading.Thread(target=run, daemon=True).start()
    return jsonify({"taskId": tid})


async def upload_bulk_excel(tid):
    """partner.kream.co.kr/asks/bulk 에 엑셀 업로드"""
    excel_path = str(BASE_DIR / "kream_bulk_bid.xlsx")
    if not Path(excel_path).exists():
        add_log(tid, "error", "대량입찰 엑셀 파일 없음 → 먼저 생성하세요")
        return {"success": False}

    async with async_playwright() as p:
        browser = await create_browser(p, headless=get_headless())
        context = await create_context(browser, STATE_FILE)
        page = await context.new_page()
        await apply_stealth(page)

        if not await ensure_logged_in(page):
            add_log(tid, "error", "판매자센터 로그인 필요")
            await browser.close()
            return {"success": False}

        add_log(tid, "info", "대량 입찰/수정 페이지 이동...")
        await page.goto(f"{PARTNER_URL}/asks/bulk", wait_until="domcontentloaded")
        await page.wait_for_timeout(2000)

        # 파일 업로드 input 찾기
        try:
            file_input = page.locator('input[type="file"]').first
            await file_input.set_input_files(excel_path)
            await page.wait_for_timeout(3000)
            add_log(tid, "success", "엑셀 파일 업로드 완료")

            # 업로드 확인/등록 버튼 클릭
            for btn_text in ["일괄 등록", "등록", "확인", "업로드"]:
                try:
                    btn = page.locator(f'button:has-text("{btn_text}")').first
                    if await btn.is_visible(timeout=2000):
                        await btn.click()
                        await page.wait_for_timeout(3000)
                        add_log(tid, "info", f"'{btn_text}' 클릭")
                        break
                except Exception:
                    continue

            # 최종 확인
            try:
                confirm = page.locator('button:has-text("확인")').first
                if await confirm.is_visible(timeout=2000):
                    await confirm.click()
                    await page.wait_for_timeout(2000)
            except Exception:
                pass

            add_log(tid, "success", "대량입찰 등록 완료!")
        except Exception as e:
            add_log(tid, "error", f"업로드 실패: {e}")
            await browser.close()
            return {"success": False}

        await context.storage_state(path=STATE_FILE)
        await browser.close()

    return {"success": True}


# ═══════════════════════════════════════════
# API: 입찰 내역 관리 (7단계)
# ═══════════════════════════════════════════

@app.route("/api/my-bids")
def api_my_bids():
    """내 입찰 목록 조회"""
    tid = new_task()
    add_log(tid, "info", "내 입찰 목록 수집 중...")

    def run():
        try:
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            from kream_adjuster import collect_my_bids
            bids = loop.run_until_complete(collect_my_bids(headless=get_headless()))
            loop.close()
            add_log(tid, "success", f"입찰 {len(bids)}건 수집")
            finish_task(tid, result={"bids": bids})
        except Exception as e:
            traceback.print_exc()
            finish_task(tid, error=str(e))

    threading.Thread(target=run, daemon=True).start()
    return jsonify({"taskId": tid})


@app.route("/api/my-bids/delete", methods=["POST"])
def api_delete_bids():
    """선택한 입찰 삭제"""
    data = request.json or {}
    order_ids = data.get("orderIds", [])
    if not order_ids:
        return jsonify({"error": "orderIds 필요"}), 400

    tid = new_task()
    add_log(tid, "info", f"입찰 삭제 시작: {len(order_ids)}건")

    def run():
        try:
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            result = loop.run_until_complete(delete_bids(order_ids, tid))
            loop.close()
            finish_task(tid, result=result)
        except Exception as e:
            traceback.print_exc()
            finish_task(tid, error=str(e))

    threading.Thread(target=run, daemon=True).start()
    return jsonify({"taskId": tid})


async def delete_bids(order_ids, tid):
    """판매자센터에서 입찰 삭제"""
    async with async_playwright() as p:
        browser = await create_browser(p, headless=get_headless())
        context = await create_context(browser, STATE_FILE)
        page = await context.new_page()
        await apply_stealth(page)

        url = f"{PARTNER_URL}/business/asks?page=1&perPage=50&startDate=&endDate="
        await page.goto(url, wait_until="domcontentloaded")
        await page.wait_for_timeout(2500)

        if "/sign-in" in page.url:
            add_log(tid, "error", "로그인 필요")
            await browser.close()
            return {"success": 0, "total": len(order_ids)}

        success = 0
        for i, oid in enumerate(order_ids, 1):
            add_log(tid, "info", f"[{i}/{len(order_ids)}] {oid} 삭제 중...")
            deleted = await page.evaluate("""(orderId) => {
                const allEls = document.querySelectorAll('*');
                for (const el of allEls) {
                    const direct = Array.from(el.childNodes)
                        .filter(n => n.nodeType === 3)
                        .map(n => n.textContent.trim()).join('');
                    if (direct === orderId) {
                        let parent = el;
                        for (let i = 0; i < 15; i++) {
                            parent = parent.parentElement;
                            if (!parent) break;
                            const btns = parent.querySelectorAll('button');
                            for (const btn of btns) {
                                if (btn.innerText.includes('삭제')) {
                                    btn.click();
                                    return true;
                                }
                            }
                        }
                    }
                }
                return false;
            }""", oid)

            if deleted:
                await page.wait_for_timeout(1000)
                # 확인 팝업
                try:
                    confirm = page.locator('button:has-text("확인")').last
                    if await confirm.is_visible(timeout=2000):
                        await confirm.click()
                        await page.wait_for_timeout(1200)
                except Exception:
                    pass
                success += 1
                add_log(tid, "success", f"{oid} 삭제 완료")
            else:
                add_log(tid, "error", f"{oid} 삭제 버튼 못 찾음")

        await context.storage_state(path=STATE_FILE)
        await browser.close()

    return {"success": success, "total": len(order_ids)}


@app.route("/api/my-bids/modify", methods=["POST"])
def api_modify_bid():
    """입찰가 수정"""
    data = request.json or {}
    order_id = data.get("orderId", "")
    new_price = int(data.get("newPrice", 0))
    if not order_id or not new_price:
        return jsonify({"error": "orderId, newPrice 필요"}), 400

    tid = new_task()
    add_log(tid, "info", f"입찰가 수정: {order_id} → {new_price:,}원")

    def run():
        try:
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            ok = loop.run_until_complete(modify_bid_price(order_id, new_price, headless=get_headless()))
            loop.close()
            if ok:
                add_log(tid, "success", f"수정 완료: {new_price:,}원")
            else:
                add_log(tid, "error", "수정 실패")
            finish_task(tid, result={"success": ok})
        except Exception as e:
            traceback.print_exc()
            finish_task(tid, error=str(e))

    threading.Thread(target=run, daemon=True).start()
    return jsonify({"taskId": tid})


# ═══════════════════════════════════════════
# API: 중국 가격 수집 (识货/得物 앱)
# ═══════════════════════════════════════════

@app.route("/api/china-price", methods=["POST"])
def api_china_price():
    """识货/得物 앱에서 중국 가격 수집"""
    data = request.json or {}
    model = str(data.get("model", "")).strip()
    app_name = data.get("app", "识货")
    if not model:
        return jsonify({"error": "model 필요"}), 400

    tid = new_task()
    add_log(tid, "info", f"중국 가격 검색: {model} ({app_name})")

    def run():
        try:
            from china_price import search_price, load_config
            config = load_config()
            config["app_name"] = app_name
            result = search_price(model, config)
            add_log(tid, "success" if not result.get("error") else "error",
                    f"검색 완료: {model}")
            finish_task(tid, result=result)
        except Exception as e:
            import traceback; traceback.print_exc()
            finish_task(tid, error=str(e))

    threading.Thread(target=run, daemon=True).start()
    return jsonify({"taskId": tid})


# ═══════════════════════════════════════════
# API: KREAM 키워드 검색
# ═══════════════════════════════════════════

@app.route("/api/keyword-search", methods=["POST"])
def api_keyword_search():
    """KREAM에서 키워드로 상품 검색"""
    data = request.json or {}
    keyword = str(data.get("keyword", "")).strip()
    max_scroll = int(data.get("maxScroll", 3))
    if not keyword:
        return jsonify({"error": "keyword 필요"}), 400

    tid = new_task()
    add_log(tid, "info", f"KREAM 검색: '{keyword}'")

    def run():
        try:
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            result = loop.run_until_complete(
                kream_keyword_search(keyword, max_scroll, tid)
            )
            loop.close()
            finish_task(tid, result=result)
        except Exception as e:
            traceback.print_exc()
            finish_task(tid, error=str(e))

    threading.Thread(target=run, daemon=True).start()
    return jsonify({"taskId": tid})


async def kream_keyword_search(keyword, max_scroll, tid):
    """kream.co.kr 검색 → 상품 목록 수집"""
    from kream_collector import (
        create_browser as col_browser,
        create_context as col_context,
        apply_stealth as col_stealth,
        STATE_FILE_KREAM,
    )
    import urllib.parse

    kream_session = STATE_FILE_KREAM if Path(STATE_FILE_KREAM).exists() else None

    async with async_playwright() as p:
        browser = await col_browser(p, headless=get_headless())
        context = await col_context(browser, kream_session)
        page = await context.new_page()
        await col_stealth(page)

        encoded = urllib.parse.quote(keyword)
        url = f"https://kream.co.kr/search?keyword={encoded}&tab=products"
        add_log(tid, "info", f"검색 페이지 로딩: {keyword}")
        await page.goto(url, wait_until="domcontentloaded")
        try:
            await page.wait_for_selector('a[href*="/products/"]', timeout=3500)
            await page.wait_for_timeout(300)
        except Exception:
            await page.wait_for_timeout(2000)

        # 스크롤로 더 많은 상품 로딩
        for i in range(max_scroll):
            await page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
            await page.wait_for_timeout(1500)

        add_log(tid, "info", "상품 목록 파싱 중...")

        products = await page.evaluate(r"""() => {
            const results = [];
            const seen = new Set();
            const cards = document.querySelectorAll('a[href*="/products/"]');

            for (const card of cards) {
                const href = card.href || '';
                const pidMatch = href.match(/\/products\/(\d+)/);
                if (!pidMatch) continue;
                const pid = pidMatch[1];
                if (seen.has(pid)) continue;
                seen.add(pid);

                const text = card.innerText.trim();
                const lines = text.split('\n').map(s => s.trim()).filter(s => s);
                const img = card.querySelector('img');
                const imgAlt = (img && img.alt) || '';

                // imgAlt: "한글명(English Name)" 형태
                let nameKr = '', nameEn = '';
                const altMatch = imgAlt.match(/^(.+?)\((.+)\)$/);
                if (altMatch) {
                    nameKr = altMatch[1].trim();
                    nameEn = altMatch[2].trim();
                } else {
                    nameKr = imgAlt;
                }

                // 브랜드: 첫 줄
                let brand = lines[0] || '';

                // 가격: "숫자,숫자원" 패턴
                let price = 0;
                for (const line of lines) {
                    const pm = line.match(/^([0-9,]+)\uC6D0$/);
                    if (pm) { price = parseInt(pm[1].replace(/,/g, '')); break; }
                }

                // 거래수, 관심수
                let trades = 0, interest = 0;
                for (const line of lines) {
                    const tm = line.match(/\uAC70\uB798\s*([0-9,.]+\uB9CC?)/);
                    if (tm) {
                        let v = tm[1].replace(/,/g, '');
                        if (v.includes('\uB9CC')) trades = parseFloat(v) * 10000;
                        else trades = parseInt(v);
                    }
                    const im = line.match(/\uAD00\uC2EC\s*([0-9,.]+\uB9CC?)/);
                    if (im) {
                        let v = im[1].replace(/,/g, '');
                        if (v.includes('\uB9CC')) interest = parseFloat(v) * 10000;
                        else interest = parseInt(v);
                    }
                }

                results.push({
                    productId: pid,
                    brand: brand,
                    nameKr: nameKr,
                    nameEn: nameEn,
                    price: price,
                    trades: trades,
                    interest: interest,
                });
            }
            return results;
        }""")

        # ── 2단계: 각 상품 상세 페이지에서 모델번호 수집 ──
        add_log(tid, "info", f"{len(products)}건 모델번호 수집 중...")
        for i, prod in enumerate(products):
            try:
                detail_url = f"https://kream.co.kr/products/{prod['productId']}"
                await page.goto(detail_url, wait_until="domcontentloaded")
                await page.wait_for_timeout(1000)

                model_info = await page.evaluate(r"""() => {
                    const body = document.body.innerText;
                    const m = body.match(/모델번호\s*([A-Za-z0-9][A-Za-z0-9_\-\/. ]+)/);
                    return m ? m[1].trim() : null;
                }""")

                if model_info:
                    prod["model"] = model_info

                # 10건마다 로그
                if (i + 1) % 10 == 0:
                    add_log(tid, "info", f"모델번호 수집 {i+1}/{len(products)}건...")
            except Exception:
                pass

        if kream_session:
            await context.storage_state(path=STATE_FILE_KREAM)
        await browser.close()

    collected = sum(1 for p in products if p.get("model"))
    add_log(tid, "success", f"검색 완료: '{keyword}' → {len(products)}건 (모델번호 {collected}건)")
    return {"keyword": keyword, "products": products, "count": len(products)}


@app.route("/api/keyword-search/download", methods=["POST"])
def api_keyword_download():
    """키워드 검색 결과를 엑셀로 다운로드"""
    data = request.json or {}
    products = data.get("products", [])
    if not products:
        return jsonify({"error": "데이터 없음"}), 400

    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "검색결과"
    ws.append(["키워드", "상품ID", "브랜드", "상품명", "영문명", "모델번호",
               "표시가", "거래수", "관심수", "즉시구매가", "즉시판매가"])
    for p in products:
        ws.append([
            p.get("keyword", ""),
            p.get("productId", ""),
            p.get("brand", ""),
            p.get("nameKr", ""),
            p.get("nameEn", ""),
            p.get("model", ""),
            p.get("price", ""),
            p.get("trades", ""),
            p.get("interest", ""),
            p.get("instantBuy", ""),
            p.get("instantSell", ""),
        ])

    path = str(BASE_DIR / "kream_search_result.xlsx")
    wb.save(path)
    return send_file(path, as_attachment=True, download_name="kream_search_result.xlsx")


# ═══════════════════════════════════════════
# API: 상품 발굴 데이터
# ═══════════════════════════════════════════

def parse_discovery_excel(path):
    """KREAM 데이터 엑셀 파싱"""
    wb = openpyxl.load_workbook(path, data_only=True)
    result = {"overseas_top100": [], "search_surge": [], "brand_top100": []}

    # 해외직구 TOP 100
    if "해외직구 TOP 100" in wb.sheetnames:
        ws = wb["해외직구 TOP 100"]
        for row in ws.iter_rows(min_row=2, max_col=7, values_only=True):
            if not row[3]:
                continue
            result["overseas_top100"].append({
                "category": row[0] or "",
                "brand": row[2] or "",
                "productId": str(row[3]) if row[3] else "",
                "name": row[4] or "",
                "model": row[5] or "",
                "rank": row[6] if row[6] else 999,
            })

    # 크림 내 검색량 급등
    if "크림 내 검색량 급등" in wb.sheetnames:
        ws = wb["크림 내 검색량 급등"]
        for row in ws.iter_rows(min_row=2, max_col=7, values_only=True):
            if not row[0]:
                continue
            result["search_surge"].append({
                "productId": str(row[0]) if row[0] else "",
                "brand": row[1] or "",
                "model": row[2] or "",
                "name": row[3] or "",
                "category": row[4] or "",
                "surge": row[6] if row[6] else 0,
            })

    # BRAND TOP 100
    if "BRAND TOP 100" in wb.sheetnames:
        ws = wb["BRAND TOP 100"]
        for row in ws.iter_rows(min_row=2, max_col=3, values_only=True):
            if not row[1]:
                continue
            result["brand_top100"].append({
                "brand": row[0] or "",
                "productId": str(row[1]) if row[1] else "",
                "name": row[2] or "",
            })

    wb.close()
    return result


@app.route("/api/discovery")
def api_discovery():
    """엑셀에서 상품 발굴 데이터 조회"""
    path = DISCOVERY_FILE
    if not path.exists():
        return jsonify({"error": "엑셀 파일 없음", "overseas_top100": [], "search_surge": [], "brand_top100": []}), 200
    try:
        data = parse_discovery_excel(path)
        return jsonify(data)
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/discovery/upload", methods=["POST"])
def api_discovery_upload():
    """새 엑셀 파일 업로드"""
    if "file" not in request.files:
        return jsonify({"error": "파일 없음"}), 400
    f = request.files["file"]
    if not f.filename.endswith(".xlsx"):
        return jsonify({"error": "xlsx 파일만 가능"}), 400
    f.save(str(DISCOVERY_FILE))
    return jsonify({"ok": True, "filename": f.filename})


# ═══════════════════════════════════════════
# API: 설정
# ═══════════════════════════════════════════

@app.route("/api/settings", methods=["GET"])
def api_get_settings():
    if SETTINGS_FILE.exists():
        return jsonify(json.loads(SETTINGS_FILE.read_text()))
    return jsonify({})


@app.route("/api/settings", methods=["POST"])
def api_save_settings():
    data = request.json or {}
    SETTINGS_FILE.write_text(json.dumps(data, ensure_ascii=False, indent=2))
    return jsonify({"ok": True})


# ═══════════════════════════════════════════
# API: 환율
# ═══════════════════════════════════════════

@app.route("/api/exchange-rate", methods=["GET"])
def api_get_exchange_rate():
    with _exchange_rate_lock:
        return jsonify(_exchange_rate_cache.copy())


@app.route("/api/exchange-rate/refresh", methods=["POST"])
def api_refresh_exchange_rate():
    result = fetch_exchange_rates()
    if result:
        return jsonify({"ok": True, **result})
    return jsonify({"ok": False, "error": "환율 조회 실패"}), 500


# ═══════════════════════════════════════════
# API: 상품 큐 + 일괄 실행
# ═══════════════════════════════════════════

def detect_category(english_name):
    """KREAM 영문명으로 카테고리 자동 판별"""
    name = (english_name or "").lower()

    bag_kw = ['bag', 'backpack', 'tote', 'pouch', 'wallet', 'clutch',
              'purse', 'satchel', 'rucksack', 'crossbody', 'shoulder bag',
              'duffle', 'messenger', 'fanny pack', 'waist bag']
    shoe_kw = ['shoe', 'sneaker', 'boot', 'sandal', 'slipper',
               'runner', 'trainer', 'loafer', 'mule', 'clog',
               'slide', 'flip flop', 'oxford', 'derby']
    clothing_kw = ['jacket', 'hoodie', 'shirt', 'pants', 'shorts',
                   'dress', 'skirt', 'coat', 'sweater', 'cardigan',
                   'vest', 'tee', 't-shirt', 'jogger', 'track']

    for kw in bag_kw:
        if kw in name:
            return {"category": "가방", "tariff": 0.08, "auto": True}
    for kw in shoe_kw:
        if kw in name:
            return {"category": "신발", "tariff": 0.13, "auto": True}
    for kw in clothing_kw:
        if kw in name:
            return {"category": "의류", "tariff": 0.13, "auto": True}
    return {"category": None, "tariff": None, "auto": False}


def _map_kream_category(kream_cat):
    """KREAM에서 반환하는 카테고리 문자열을 우리 카테고리로 매핑"""
    cat = (kream_cat or "").lower()
    if any(k in cat for k in ['bag', 'wallet', 'acc', '가방', '지갑', '액세서리']):
        return "가방"
    if any(k in cat for k in ['shoe', 'sneaker', 'sandal', 'boot', '신발', '스니커즈']):
        return "신발"
    if any(k in cat for k in ['apparel', 'clothing', 'top', 'bottom', 'outer',
                               '의류', '상의', '하의', '아우터']):
        return "의류"
    return None


def detect_category_kr(korean_name):
    """한글 상품명에서 카테고리 판별"""
    name = korean_name or ""
    bag_kw = ['숄더백', '토트백', '크로스백', '백팩', '파우치', '지갑', '클러치',
              '더플백', '메신저백', '웨이스트백', '버킷백', '호보백', '에코백',
              '가방', '백 ', '월렛']
    shoe_kw = ['러닝화', '스니커즈', '슬라이드', '샌들', '부츠', '로퍼',
               '슬리퍼', '트레이너', '운동화', '스니커', '구두']
    clothing_kw = ['후드', '자켓', '티셔츠', '팬츠', '쇼츠', '스웨터',
                   '코트', '셔츠', '조거', '베스트', '드레스']

    for kw in bag_kw:
        if kw in name:
            return "가방"
    for kw in shoe_kw:
        if kw in name:
            return "신발"
    for kw in clothing_kw:
        if kw in name:
            return "의류"
    return None


def auto_fill_gosi(kream_data):
    """KREAM 상품명에서 고시정보 자동 추출"""
    eng_name_raw = kream_data.get("product_name_en") or kream_data.get("english_name") or kream_data.get("nameEn") or ""
    eng_name = eng_name_raw.lower()
    kor_name = kream_data.get("product_name") or kream_data.get("nameKr") or ""
    brand = kream_data.get("brand") or ""

    # 브랜드가 없으면 영문명 첫 단어에서 추출
    if not brand and eng_name_raw:
        first_word = eng_name_raw.split()[0] if eng_name_raw.split() else ""
        known_brands = ["Adidas", "Nike", "New Balance", "Asics", "Puma",
                        "Converse", "Vans", "Reebok", "Fila", "Skechers",
                        "Balenciaga", "Gucci", "Prada", "Loewe", "Moncler"]
        for b in known_brands:
            if b.lower() == first_word.lower():
                brand = b
                break
        if not brand:
            brand = first_word  # 첫 단어를 브랜드로 사용

    info = {"manufacturer": brand}

    # 종류
    type_map = {
        "shoulder bag": "숄더백", "tote bag": "토트백", "tote": "토트백",
        "crossbody": "크로스백", "backpack": "백팩", "rucksack": "백팩",
        "pouch": "파우치", "wallet": "지갑", "clutch": "클러치",
        "duffle": "더플백", "messenger": "메신저백", "waist bag": "웨이스트백",
        "fanny pack": "웨이스트백", "bucket bag": "버킷백", "hobo": "호보백",
        "running shoe": "러닝화", "sneaker": "스니커즈", "slide": "슬라이드",
        "sandal": "샌들", "boot": "부츠", "loafer": "로퍼",
        "trainer": "트레이너", "slipper": "슬리퍼",
        "hoodie": "후드", "jacket": "자켓", "t-shirt": "티셔츠",
        "pants": "팬츠", "shorts": "쇼츠", "sweater": "스웨터",
    }
    info["type"] = "상품별 상이"
    for eng, kor in type_map.items():
        if eng in eng_name:
            info["type"] = kor
            break
    else:
        kor_types = ["숄더백", "토트백", "크로스백", "백팩", "파우치", "지갑",
                     "러닝화", "스니커즈", "슬라이드", "샌들", "부츠",
                     "후드", "자켓", "티셔츠", "팬츠"]
        for kt in kor_types:
            if kt in kor_name:
                info["type"] = kt
                break

    # 소재
    material_map = {
        "denim": "데님", "leather": "가죽", "nylon": "나일론",
        "canvas": "캔버스", "suede": "스웨이드", "mesh": "메쉬",
        "cotton": "코튼", "polyester": "폴리에스터", "wool": "울",
        "silk": "실크", "fleece": "플리스", "gore-tex": "고어텍스",
        "rubber": "고무", "synthetic": "합성", "knit": "니트",
        "terry": "테리", "corduroy": "코듀로이", "satin": "새틴",
        "velvet": "벨벳", "linen": "리넨",
    }
    mats = [kor for eng, kor in material_map.items() if eng in eng_name]
    info["material"] = ", ".join(mats) if mats else "상품별 상이"

    # 색상
    color_map = {
        "black": "블랙", "white": "화이트", "red": "레드",
        "blue": "블루", "navy": "네이비", "green": "그린",
        "grey": "그레이", "gray": "그레이", "pink": "핑크",
        "beige": "베이지", "brown": "브라운", "cream": "크림",
        "orange": "오렌지", "yellow": "옐로", "purple": "퍼플",
        "silver": "실버", "gold": "골드", "olive": "올리브",
        "burgundy": "버건디", "khaki": "카키", "ivory": "아이보리",
        "coral": "코랄", "mint": "민트", "charcoal": "차콜",
    }
    colors = [kor for eng, kor in color_map.items() if eng in eng_name]
    info["color"] = ", ".join(colors) if colors else "상품별 상이"

    info["size"] = "상품별 상이"

    cat = detect_category(eng_name)
    if cat.get("category") == "가방":
        info["hs_code"] = "4202.92"
        info["tariff"] = 8
    elif cat.get("category") == "신발":
        info["hs_code"] = "6404.11"
        info["tariff"] = 13
    else:
        info["hs_code"] = ""
        info["tariff"] = 13

    return info


def _calc_profit_simple(sell_price, total_cost):
    """판매가, 원가로 간단한 마진 문자열 반환"""
    settings = {}
    if SETTINGS_FILE.exists():
        try:
            settings = json.loads(SETTINGS_FILE.read_text())
        except Exception:
            pass
    fee_rate = float(settings.get("feeRate", 0.06))
    fixed_fee = int(settings.get("fixedFee", 2500))
    vat_rate = float(settings.get("vatRate", 0.10))
    effective_rate = 1 - fee_rate * (1 + vat_rate)
    settlement = round(sell_price * effective_rate - fixed_fee)
    profit = settlement - total_cost
    if total_cost > 0:
        rate = profit / total_cost * 100
        return f"{'+' if profit >= 0 else ''}{profit:,.0f} ({rate:.1f}%)"
    return f"{'+' if profit >= 0 else ''}{profit:,.0f}"


def calculate_margin_for_queue(cny_price, category, shipping_krw=8000):
    """큐 일괄 실행용 마진 계산"""
    settings = {}
    if SETTINGS_FILE.exists():
        try:
            settings = json.loads(SETTINGS_FILE.read_text())
        except Exception:
            pass

    cny_rate = float(settings.get("cnyRate", 218.12))
    usd_rate = float(settings.get("usdRate", 1495.76))
    fee_rate = float(settings.get("feeRate", 0.06))
    fixed_fee = int(settings.get("fixedFee", 2500))
    cny_margin = float(settings.get("cnyMargin", 1.03))
    vat_rate = float(settings.get("vatRate", 0.10))
    usd_limit = float(settings.get("usdLimit", 150))

    tariff_rate = 0.08 if category == "가방" else 0.13
    krw_price = round(cny_price * cny_rate * cny_margin)
    usd_equiv = round(cny_price * cny_rate / usd_rate, 2)

    customs = 0
    import_vat = 0
    if usd_equiv > usd_limit:
        customs = round(cny_price * cny_rate * tariff_rate)
        import_vat = round((cny_price * cny_rate + customs) * vat_rate)

    total_cost = krw_price + customs + import_vat + shipping_krw

    margins = {}
    for pct in [0, 10, 15, 20]:
        target_profit = total_cost * (pct / 100)
        required_net = total_cost + target_profit
        # settlement = sell_price - (sell_price * fee * 1.1) - fixed
        # settlement = sell_price * (1 - fee * 1.1) - fixed
        effective_rate = 1 - fee_rate * (1 + vat_rate)
        raw_price = (required_net + fixed_fee) / effective_rate
        # KREAM은 1,000원 단위만 가능 → 올림
        sell_price = int(math.ceil(raw_price / 1000) * 1000)
        settlement = round(sell_price * effective_rate - fixed_fee)
        margins[f"margin_{pct}"] = {
            "sell_price": sell_price,
            "profit": settlement - total_cost,
        }

    return {
        "krw_price": krw_price,
        "customs": customs,
        "import_vat": import_vat,
        "shipping": shipping_krw,
        "total_cost": total_cost,
        "margins": margins,
    }


@app.route("/api/queue/add", methods=["POST"])
def api_queue_add():
    """큐에 상품 추가.
    가방/의류: {"model":"IX7694", "cny":220}
    신발(사이즈별): {"model":"ID6016", "sizes":[{"size":"38","cny_price":314},...],"sizeSystem":"EU"}
    """
    global queue_counter
    data = request.json or {}
    model = str(data.get("model", "")).strip()

    if not model:
        return jsonify({"error": "model 필요"}), 400

    # sizes 배열이 있으면 신발(사이즈별 가격), 없으면 단일 가격
    sizes = data.get("sizes", [])
    cny = data.get("cny")

    # result가 함께 전달되면 cny/sizes 없어도 허용 (완료 항목 복사)
    if not sizes and cny is None and not data.get("result"):
        return jsonify({"error": "cny 또는 sizes 필요"}), 400

    with queue_lock:
        queue_counter += 1
        # result/status/gosi를 함께 전달하면 KREAM 검색 없이 바로 완료 상태로 추가 (복사 기능)
        preset_result = data.get("result", None)
        preset_status = data.get("status", "대기") if preset_result else "대기"
        item = {
            "id": queue_counter,
            "model": model.upper(),
            "cny": float(cny) if cny is not None else None,
            "category": data.get("category", ""),
            "categoryAuto": False,
            "sizes": sizes,  # [{"size":"38","cny_price":314}, ...]
            "sizeSystem": data.get("sizeSystem", ""),  # "EU" or "JP"
            "size": data.get("size", ""),
            "shipping": int(data.get("shipping", 8000)),
            "quantity": int(data.get("quantity", 1)),
            "bid_days": int(data.get("bid_days", 30)),
            "status": preset_status,
            "result": preset_result,
            "gosi": data.get("gosi", None),
        }
        product_queue.append(item)

    save_queue()
    return jsonify({"ok": True, "item": item})


@app.route("/api/queue/upload-excel", methods=["POST"])
def api_queue_upload_excel():
    """XLSX 파일 업로드 → 파싱 → 큐에 추가"""
    global queue_counter
    if "file" not in request.files:
        return jsonify({"error": "파일 없음"}), 400

    file = request.files["file"]
    tmp_path = BASE_DIR / f"_tmp_upload_{file.filename}"
    try:
        file.save(str(tmp_path))
        wb = openpyxl.load_workbook(str(tmp_path), data_only=True)
        ws = wb.active
        headers = [str(cell.value or "").strip() for cell in ws[1]]

        # 컬럼 인덱스 매핑
        def find_col(keywords):
            for i, h in enumerate(headers):
                if any(k in h for k in keywords):
                    return i
            return -1

        i_model = find_col(["모델", "model", "Model"])
        i_category = find_col(["카테고리", "category"])
        i_size = find_col(["사이즈", "size"])
        i_cny = find_col(["CNY", "cny", "중국가"])
        i_qty = find_col(["수량", "qty", "quantity"])
        i_shipping = find_col(["배송비", "shipping"])
        i_bid_days = find_col(["만료", "bid_days"])

        if i_model == -1:
            wb.close()
            return jsonify({"error": "모델번호 컬럼을 찾을 수 없습니다"}), 400

        # 각 행을 독립적으로 큐에 추가 (같은 품번도 별도 항목)
        rows = []
        for row in ws.iter_rows(min_row=2, values_only=True):
            if not row or len(row) <= i_model:
                continue
            model = str(row[i_model] or "").strip()
            if not model:
                continue

            category = str(row[i_category] or "").strip() if i_category >= 0 else ""
            size = str(row[i_size] or "").strip() if i_size >= 0 else ""
            cny = float(row[i_cny] or 0) if i_cny >= 0 else 0
            qty = int(row[i_qty] or 1) if i_qty >= 0 else 1
            shipping = int(row[i_shipping] or 8000) if i_shipping >= 0 else 8000
            bid_days = int(row[i_bid_days] or 30) if i_bid_days >= 0 else 30

            sizes = []
            row_cny = None
            if size and size != "ONE SIZE":
                sizes.append({"size": size, "cny_price": cny})
            else:
                row_cny = cny if cny else None

            rows.append({
                "model": model.upper(), "category": category, "sizes": sizes,
                "cny": row_cny, "quantity": qty, "shipping": shipping, "bid_days": bid_days,
            })

        wb.close()

        # 큐에 추가
        added = []
        with queue_lock:
            for m in rows:
                queue_counter += 1
                item = {
                    "id": queue_counter,
                    "model": m["model"],
                    "cny": m["cny"],
                    "category": m["category"],
                    "categoryAuto": False,
                    "sizes": m["sizes"],
                    "sizeSystem": "",
                    "size": "전사이즈" if m["sizes"] else "",
                    "shipping": m["shipping"],
                    "quantity": m["quantity"],
                    "bid_days": m["bid_days"],
                    "status": "대기",
                    "result": None,
                    "gosi": None,
                }
                product_queue.append(item)
                added.append(item)

        save_queue()
        return jsonify({"ok": True, "count": len(added), "items": added, "queue": product_queue})

    except Exception as e:
        traceback.print_exc()
        return jsonify({"error": f"파일 파싱 실패: {e}"}), 400
    finally:
        if tmp_path.exists():
            tmp_path.unlink()


@app.route("/api/queue/bulk-add", methods=["POST"])
def api_queue_bulk_add():
    """CSV/엑셀에서 파싱한 상품 목록을 큐에 일괄 추가"""
    global queue_counter
    data = request.json or {}
    items = data.get("items", [])
    if not items:
        return jsonify({"error": "items 필요"}), 400

    added = []
    with queue_lock:
        for row in items:
            model = str(row.get("model", "")).strip()
            if not model:
                continue

            queue_counter += 1

            sizes = row.get("sizes", [])
            cny = row.get("cny")

            item = {
                "id": queue_counter,
                "model": model.upper(),
                "cny": float(cny) if cny is not None else None,
                "category": row.get("category", ""),
                "categoryAuto": False,
                "sizes": sizes,
                "sizeSystem": row.get("sizeSystem", ""),
                "size": row.get("size", ""),
                "shipping": int(row.get("shipping", 8000)),
                "quantity": int(row.get("quantity", 1)),
                "bid_days": int(row.get("bid_days", 30)),
                "status": "대기",
                "result": None,
                "gosi": None,
            }
            product_queue.append(item)
            added.append(item)

    save_queue()
    return jsonify({"ok": True, "count": len(added), "items": added})


@app.route("/api/queue/download-excel")
def api_queue_download_excel():
    """현재 큐를 XLSX 파일로 다운로드"""
    import io

    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "상품큐"
    headers = ["모델번호", "카테고리", "사이즈", "CNY", "배송비", "수량", "만료일(일)", "상태"]
    ws.append(headers)

    for item in product_queue:
        sizes = item.get("sizes", [])
        if sizes:
            for s in sizes:
                ws.append([
                    item.get("model", ""),
                    item.get("category", ""),
                    s.get("size", ""),
                    s.get("cny_price", 0),
                    item.get("shipping", 8000),
                    item.get("quantity", 1),
                    item.get("bid_days", 30),
                    item.get("status", "대기"),
                ])
        else:
            ws.append([
                item.get("model", ""),
                item.get("category", ""),
                item.get("size", ""),
                item.get("cny", 0) or 0,
                item.get("shipping", 8000),
                item.get("quantity", 1),
                item.get("bid_days", 30),
                item.get("status", "대기"),
            ])

    buf = io.BytesIO()
    wb.save(buf)
    buf.seek(0)

    fname = f"queue_{datetime.now().strftime('%Y%m%d_%H%M')}.xlsx"
    return send_file(buf, mimetype="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                     as_attachment=True, download_name=fname)


@app.route("/api/queue/template")
def api_queue_template():
    """업로드용 빈 엑셀 양식 다운로드 (예시 1행 포함)"""
    import io

    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "큐 양식"
    headers = ["모델번호", "카테고리", "사이즈", "중국가(CNY)", "배송비", "수량", "만료일(일)"]
    ws.append(headers)
    ws.append(["IX7694", "가방", "ONE SIZE", 220, 8000, 1, 30])

    # 컬럼 너비 조정
    widths = [14, 10, 12, 14, 10, 8, 12]
    for i, w in enumerate(widths, 1):
        ws.column_dimensions[openpyxl.utils.get_column_letter(i)].width = w

    buf = io.BytesIO()
    wb.save(buf)
    buf.seek(0)
    return send_file(buf, mimetype="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                     as_attachment=True, download_name="kream_queue_template.xlsx")


@app.route("/api/queue/list")
def api_queue_list():
    """큐 목록 조회"""
    return jsonify({"queue": product_queue})


@app.route("/api/queue/<int:item_id>", methods=["DELETE"])
def api_queue_delete(item_id):
    """큐에서 삭제"""
    with queue_lock:
        idx = next((i for i, q in enumerate(product_queue) if q["id"] == item_id), None)
        if idx is not None:
            product_queue.pop(idx)
            save_queue()
            return jsonify({"ok": True})
    return jsonify({"error": "항목 없음"}), 404


@app.route("/api/queue/<int:item_id>", methods=["PUT"])
def api_queue_update(item_id):
    """큐 항목 수정"""
    data = request.json or {}
    with queue_lock:
        item = next((q for q in product_queue if q["id"] == item_id), None)
        if not item:
            return jsonify({"error": "항목 없음"}), 404
        for key in ["model", "cny", "category", "size", "shipping", "quantity",
                     "sizes", "sizeSystem", "gosi", "selectedMargin", "bid_days"]:
            if key in data:
                item[key] = data[key]
        if "model" in data:
            item["model"] = str(data["model"]).upper()
        save_queue()
        return jsonify({"ok": True, "item": item})


@app.route("/api/queue/clear", methods=["DELETE"])
def api_queue_clear():
    """큐 전체 삭제"""
    with queue_lock:
        product_queue.clear()
    save_queue()
    return jsonify({"ok": True})


@app.route("/api/queue/execute", methods=["POST"])
def api_queue_execute():
    """큐 일괄 실행: KREAM 검색 + 카테고리 판별 + 마진 계산"""
    if not product_queue:
        return jsonify({"error": "큐가 비어있음"}), 400

    # 대기 상태인 항목만 실행
    pending = [q for q in product_queue if q["status"] in ("대기", "실패")]
    if not pending:
        return jsonify({"error": "실행할 항목 없음"}), 400

    tid = new_task()
    add_log(tid, "info", f"큐 일괄 실행 시작: {len(pending)}건")

    def run():
        try:
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)

            search_cache = {}  # 품번별 KREAM 검색 결과 캐시

            for i, item in enumerate(pending, 1):
                model = item["model"]
                item["status"] = "검색 중"

                try:
                    # 같은 품번이면 캐시된 검색 결과 재사용
                    if model in search_cache:
                        cached = search_cache[model]
                        if cached is None:
                            item["status"] = "실패"
                            item["result"] = {"error": "KREAM 검색 결과 없음 (캐시)"}
                            add_log(tid, "info", f"[{i}/{len(pending)}] {model} 캐시 사용 → 검색 결과 없음")
                            continue
                        if cached == "session_expired":
                            item["status"] = "실패"
                            item["result"] = {"error": "세션 만료 (캐시)"}
                            add_log(tid, "info", f"[{i}/{len(pending)}] {model} 캐시 사용 → 세션 만료")
                            continue
                        kream = cached
                        add_log(tid, "info", f"[{i}/{len(pending)}] {model} 캐시 사용 (검색 생략)")
                    else:
                        add_log(tid, "info", f"[{i}/{len(pending)}] {model} KREAM 검색 중...")
                        results = loop.run_until_complete(search_by_model(model))

                        if not results or len(results) == 0:
                            search_cache[model] = None
                            item["status"] = "실패"
                            item["result"] = {"error": "KREAM 검색 결과 없음"}
                            add_log(tid, "error", f"{model}: 검색 결과 없음")
                            continue

                        kream = results[0].get("kream", {})
                        if kream.get("session_expired"):
                            search_cache[model] = "session_expired"
                            item["status"] = "실패"
                            item["result"] = {"error": "세션 만료"}
                            add_log(tid, "error", f"{model}: 세션 만료")
                            continue

                        search_cache[model] = kream

                    product_id = str(kream.get("product_id", ""))
                    # collector는 product_name_en 키를 사용
                    name_en = kream.get("product_name_en", "") or kream.get("english_name", "") or ""
                    name_kr = kream.get("product_name", "")
                    # 상품명에서 발매가 정보 제거 (예: "발매가 $65 (약 96,700원)")
                    name_kr = re.sub(r'\s*발매가\s*\$?\d[\d,]*\s*(\(약\s*[\d,]+원\))?\s*', '', name_kr).strip()
                    name_en = re.sub(r'\s*Retail\s*Price\s*\$?\d[\d,]*\s*', '', name_en, flags=re.IGNORECASE).strip()
                    # 즉시구매가 = 현재 판매입찰 최저가 (과거 체결가 아님)
                    instant_buy = kream.get("instant_buy_price")  # sell_bids 최저가
                    recent_trade = kream.get("recent_trade_price") or kream.get("display_price")  # 과거 체결가

                    # 사이즈 자동 설정
                    if not item.get("sizes") and not item.get("size"):
                        kream_sizes = kream.get("sizes", [])
                        if kream_sizes:
                            item["size"] = "전사이즈"
                        else:
                            item["size"] = "ONE SIZE"

                    # 카테고리 자동 판별
                    item["status"] = "계산 중"
                    if not item["category"]:
                        # 1순위: KREAM 카테고리 정보
                        kream_cat = kream.get("category", "")
                        if kream_cat:
                            cat_mapped = _map_kream_category(kream_cat)
                            if cat_mapped:
                                item["category"] = cat_mapped
                                item["categoryAuto"] = True
                        # 2순위: 영문 상품명 파싱
                        if not item["category"]:
                            cat_info = detect_category(name_en)
                            if cat_info["category"]:
                                item["category"] = cat_info["category"]
                                item["categoryAuto"] = True
                        # 3순위: 한글 상품명에서도 시도
                        if not item["category"] and name_kr:
                            cat_info = detect_category_kr(name_kr)
                            if cat_info:
                                item["category"] = cat_info
                                item["categoryAuto"] = True
                        # 못 찾으면 미분류
                        if not item["category"]:
                            item["category"] = "미분류"
                            item["categoryAuto"] = True

                    # 고시정보 자동 채움
                    gosi = auto_fill_gosi({
                        "english_name": name_en,
                        "product_name": name_kr,
                        "brand": kream.get("brand", ""),
                    })
                    item["gosi"] = gosi

                    # 마진 계산 — 사이즈별 가격이 있으면 각각 계산
                    input_sizes = item.get("sizes", [])
                    if input_sizes:
                        size_margins = []
                        for sz in input_sizes:
                            sz_cny = float(sz.get("cny_price", 0))
                            mi = calculate_margin_for_queue(
                                sz_cny, item["category"], item["shipping"]
                            )
                            size_margins.append({
                                "size": sz["size"],
                                "cny": sz_cny,
                                "totalCost": mi["total_cost"],
                                "margins": mi["margins"],
                            })
                        # 대표 마진 (최저 CNY 기준)
                        min_cost = min(sm["totalCost"] for sm in size_margins)
                        max_cost = max(sm["totalCost"] for sm in size_margins)
                        rep_cny = min(float(sz.get("cny_price", 0)) for sz in input_sizes)
                        margin_info = calculate_margin_for_queue(
                            rep_cny, item["category"], item["shipping"]
                        )
                    else:
                        size_margins = []
                        margin_info = calculate_margin_for_queue(
                            item["cny"], item["category"], item["shipping"]
                        )

                    item["result"] = {
                        "productId": product_id,
                        "nameKr": name_kr,
                        "nameEn": name_en,
                        "brand": kream.get("brand", ""),
                        "kreamSizes": kream.get("sizes", []),
                        "totalCost": margin_info["total_cost"],
                        "margins": margin_info["margins"],
                        "krwPrice": margin_info["krw_price"],
                        "customs": margin_info["customs"],
                        "importVat": margin_info["import_vat"],
                        "sizeMargins": size_margins,
                        "gosi": gosi,
                        # KREAM 가격 (명확히 구분)
                        "instantBuyPrice": instant_buy,       # 즉시구매가 = 현재 판매입찰 최저가
                        "instantSellPrice": kream.get("instant_sell_price"),  # 즉시판매가 = 현재 구매입찰 최고가
                        "recentTradePrice": recent_trade,     # 최근 체결가 (과거)
                        "totalTrades": kream.get("total_trades"),
                        "sellBids": kream.get("sell_bids", []),
                        "buyBids": kream.get("buy_bids", []),
                        "sizeDeliveryPrices": kream.get("size_delivery_prices", []),
                    }
                    item["status"] = "완료"
                    cost_str = f"원가 {margin_info['total_cost']:,}원"
                    if input_sizes:
                        cost_str = f"{len(input_sizes)}사이즈, 원가 {min_cost:,}~{max_cost:,}원"
                    add_log(tid, "success",
                            f"{model}: {name_kr or name_en} → {cost_str}, 즉시구매가 {instant_buy or 0:,}원")

                except Exception as e:
                    item["status"] = "실패"
                    item["result"] = {"error": str(e)}
                    add_log(tid, "error", f"{model}: {e}")

            loop.close()

            done = sum(1 for q in pending if q["status"] == "완료")
            add_log(tid, "success", f"일괄 실행 완료: {done}/{len(pending)}건 성공")
            save_queue()

            # batch 히스토리 저장 (검색+마진 계산)
            batch_items = []
            for item in pending:
                r = item.get("result", {})
                margin_str = None
                if item["status"] == "완료" and r.get("totalCost"):
                    mg = (r.get("margins") or {}).get("margin_15", {})
                    if mg.get("profit"):
                        margin_str = f"+{mg['profit']:,.0f} ({mg.get('margin_rate',0):.1f}%)"
                batch_items.append({
                    "model": item["model"],
                    "name": r.get("nameKr") or r.get("nameEn") or "-",
                    "size": item.get("size", ""),
                    "bid_price": None,
                    "cost": r.get("totalCost"),
                    "instant_buy": r.get("instantBuyPrice"),
                    "margin": margin_str,
                    "status": item["status"],
                })
            save_batch_history("검색+마진계산", batch_items)

            finish_task(tid, result={"queue": product_queue})

        except Exception as e:
            traceback.print_exc()
            finish_task(tid, error=str(e))

    threading.Thread(target=run, daemon=True).start()
    return jsonify({"taskId": tid})


@app.route("/api/queue/auto-register", methods=["POST"])
def api_queue_auto_register():
    """큐에서 선택된 상품들을 자동으로 고시정보 등록 + 입찰 (Playwright)"""
    data = request.json or {}
    bid_items = data.get("items", [])
    # items: [{productId, model, size, price, quantity, gosi:{...}, category, gosiAlready}]

    if not bid_items:
        return jsonify({"error": "항목 없음"}), 400

    # 세션 파일 확인
    if not Path(STATE_FILE).exists():
        return jsonify({"error": "세션 없음. 먼저 python3 kream_bot.py --mode login 실행"}), 400

    tid = new_task()
    add_log(tid, "info", f"자동 입찰 시작: {len(bid_items)}건")

    with auto_bid_lock:
        auto_bid_control["state"] = "running"
        auto_bid_event.set()

    def run():
        try:
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)

            results = []
            stopped = False
            for i, bi in enumerate(bid_items, 1):
                # 일시정지 체크: event가 clear되면 대기
                if not auto_bid_event.is_set():
                    add_log(tid, "info", "⏸ 일시정지 중... (이어서 진행 또는 중단 대기)")
                auto_bid_event.wait()  # paused면 여기서 블로킹

                # 중단 체크
                with auto_bid_lock:
                    if auto_bid_control["state"] == "stopping":
                        add_log(tid, "info", f"⏹ 사용자 중단 요청 — {i-1}/{len(bid_items)}건 완료 후 중단")
                        stopped = True
                        break

                pid = bi["productId"]
                price = bi["price"]
                size = bi.get("size", "ONE SIZE")
                qty = bi.get("quantity", 1)
                gosi = bi.get("gosi", {})
                gosi_already = bi.get("gosiAlready", False)
                category = bi.get("category", "가방")
                bid_days = int(bi.get("bid_days", 30))

                add_log(tid, "info",
                        f"[{i}/{len(bid_items)}] #{pid} {bi.get('model','')} "
                        f"{size} → {price:,}원 × {qty} ({bid_days}일)")

                result = loop.run_until_complete(
                    run_full_register(pid, price, size, qty,
                                      gosi_already, {**gosi, "category": category}, tid,
                                      model=bi.get("model", ""), bid_days=bid_days)
                )
                results.append({
                    "productId": pid, "model": bi.get("model", ""),
                    "size": size, "price": price,
                    "success": result.get("success", False),
                })

            loop.close()

            ok = sum(1 for r in results if r["success"])
            total_attempted = len(results)
            if stopped:
                add_log(tid, "info", f"중단됨: {ok}/{total_attempted}건 성공 (전체 {len(bid_items)}건 중 {total_attempted}건 처리)")
            else:
                add_log(tid, "success", f"완료: {ok}/{len(bid_items)}건 성공")

            # batch 히스토리 저장
            batch_items = []
            for bi, r in zip(bid_items[:total_attempted], results):
                margin_str = None
                if r["success"]:
                    cost = bi.get("cost", 0)
                    if cost and r.get("price"):
                        pi = _calc_profit_simple(r["price"], cost)
                        margin_str = pi
                batch_items.append({
                    "model": bi.get("model", ""),
                    "name": bi.get("nameEn", "") or bi.get("name", "-"),
                    "size": r.get("size", bi.get("size", "")),
                    "bid_price": r.get("price"),
                    "margin": margin_str,
                    "status": "입찰완료" if r["success"] else "실패",
                })
            if batch_items:
                save_batch_history("자동입찰", batch_items)

            finish_task(tid, result={"results": results, "success": ok, "total": len(bid_items), "stopped": stopped})

        except Exception as e:
            traceback.print_exc()
            finish_task(tid, error=str(e))
        finally:
            with auto_bid_lock:
                auto_bid_control["state"] = "idle"
                auto_bid_event.set()

    threading.Thread(target=run, daemon=True).start()
    return jsonify({"taskId": tid})


@app.route("/api/auto-bid/pause", methods=["POST"])
def api_auto_bid_pause():
    with auto_bid_lock:
        if auto_bid_control["state"] != "running":
            return jsonify({"error": "실행 중이 아닙니다"}), 400
        auto_bid_control["state"] = "paused"
        auto_bid_event.clear()  # 다음 상품 전에 대기
    return jsonify({"ok": True, "state": "paused"})


@app.route("/api/auto-bid/resume", methods=["POST"])
def api_auto_bid_resume():
    with auto_bid_lock:
        if auto_bid_control["state"] != "paused":
            return jsonify({"error": "일시정지 상태가 아닙니다"}), 400
        auto_bid_control["state"] = "running"
        auto_bid_event.set()  # 대기 해제
    return jsonify({"ok": True, "state": "running"})


@app.route("/api/auto-bid/stop", methods=["POST"])
def api_auto_bid_stop():
    with auto_bid_lock:
        if auto_bid_control["state"] not in ("running", "paused"):
            return jsonify({"error": "실행 중이 아닙니다"}), 400
        auto_bid_control["state"] = "stopping"
        auto_bid_event.set()  # paused 상태에서도 깨움
    return jsonify({"ok": True, "state": "stopping"})


@app.route("/api/auto-bid/status")
def api_auto_bid_status():
    with auto_bid_lock:
        return jsonify({"state": auto_bid_control["state"]})


# ═══════════════════════════════════════════
# API: 실행 이력
# ═══════════════════════════════════════════

@app.route("/api/history")
def api_history():
    if HISTORY_FILE.exists():
        return jsonify(json.loads(HISTORY_FILE.read_text()))
    return jsonify([])


def save_history(task_type, product_id, price, qty, success):
    history = []
    if HISTORY_FILE.exists():
        try:
            history = json.loads(HISTORY_FILE.read_text())
        except Exception:
            pass

    history.insert(0, {
        "date": datetime.now().strftime("%Y/%m/%d %H:%M"),
        "type": task_type,
        "productId": product_id,
        "price": price,
        "quantity": qty,
        "success": 1 if success else 0,
        "fail": 0 if success else 1,
    })
    history = history[:200]
    HISTORY_FILE.write_text(json.dumps(history, ensure_ascii=False, indent=2))


def save_batch_history(batch_type, items_detail):
    """일괄 실행 단위(batch)로 히스토리 저장
    items_detail: [{model, name, bid_price, margin, status}, ...]
    """
    history = []
    if BATCH_HISTORY_FILE.exists():
        try:
            data = json.loads(BATCH_HISTORY_FILE.read_text())
            history = data.get("history", [])
        except Exception:
            pass

    total = len(items_detail)
    success = sum(1 for it in items_detail if "완료" in (it.get("status") or ""))
    failed = total - success

    entry = {
        "executed_at": datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
        "type": batch_type,
        "total": total,
        "success": success,
        "failed": failed,
        "items": items_detail,
    }

    history.insert(0, entry)
    history = history[:30]  # 최근 30건만 유지

    BATCH_HISTORY_FILE.write_text(json.dumps(
        {"history": history}, ensure_ascii=False, indent=2
    ))


@app.route("/api/batch-history")
def api_batch_history():
    """일괄 실행 이력 조회 (최근 30건)"""
    if BATCH_HISTORY_FILE.exists():
        try:
            return jsonify(json.loads(BATCH_HISTORY_FILE.read_text()))
        except Exception:
            pass
    return jsonify({"history": []})


# ═══════════════════════════════════════════
# 내 입찰 현황 로컬 저장 헬퍼
# ═══════════════════════════════════════════

def load_my_bids_local():
    if MY_BIDS_FILE.exists():
        try:
            return json.loads(MY_BIDS_FILE.read_text())
        except Exception:
            pass
    return {"bids": [], "lastSync": None}


def save_bid_local(product_id, model="", size="ONE SIZE", price=0, source="placed", order_id=None):
    """입찰 성공 시 로컬 JSON에 기록 (동일 상품+사이즈는 덮어씀)"""
    data = load_my_bids_local()
    data["bids"] = [b for b in data["bids"]
                    if not (str(b.get("productId")) == str(product_id) and b.get("size") == size)]
    data["bids"].append({
        "productId": str(product_id),
        "model": model,
        "size": size,
        "price": price,
        "date": datetime.now().strftime("%Y/%m/%d %H:%M"),
        "source": source,
        "orderId": order_id,
    })
    MY_BIDS_FILE.write_text(json.dumps(data, ensure_ascii=False, indent=2))


@app.route("/api/my-bids/local")
def api_my_bids_local():
    """로컬 저장된 내 입찰 현황 조회"""
    return jsonify(load_my_bids_local())


@app.route("/api/my-bids/sync", methods=["POST"])
def api_my_bids_sync():
    """판매자센터에서 내 입찰 목록 동기화 → 로컬 JSON 저장"""
    tid = new_task()
    add_log(tid, "info", "내 입찰 현황 동기화 시작...")

    def run():
        try:
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            from kream_adjuster import collect_my_bids
            bids = loop.run_until_complete(collect_my_bids(headless=get_headless()))
            loop.close()

            data = {
                "bids": [{
                    "productId": str(b.get("productId", "")),
                    "model": b.get("model", ""),
                    "size": b.get("size", "ONE SIZE"),
                    "price": b.get("bidPrice", 0),
                    "date": datetime.now().strftime("%Y/%m/%d %H:%M"),
                    "source": "sync",
                    "orderId": b.get("orderId", ""),
                    "nameKr": b.get("nameKr", ""),
                } for b in bids],
                "lastSync": datetime.now().strftime("%Y/%m/%d %H:%M"),
            }
            MY_BIDS_FILE.write_text(json.dumps(data, ensure_ascii=False, indent=2))
            add_log(tid, "success", f"동기화 완료: {len(bids)}건 저장")
            finish_task(tid, result=data)
        except Exception as e:
            traceback.print_exc()
            finish_task(tid, error=str(e))

    threading.Thread(target=run, daemon=True).start()
    return jsonify({"taskId": tid})


# ═══════════════════════════════════════════
# 실행
# ═══════════════════════════════════════════

if __name__ == "__main__":
    print("=" * 50)
    print("  KREAM 판매자 대시보드 서버")
    print("  http://localhost:5001")
    print("=" * 50)
    # 서버 시작 시 환율 자동 조회 (백그라운드)
    threading.Thread(target=fetch_exchange_rates, daemon=True).start()
    app.run(host="0.0.0.0", port=5001, debug=False)
