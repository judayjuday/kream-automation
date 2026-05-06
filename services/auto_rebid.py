"""자동 재입찰 dry-run wrapper (Step 35).

실제 입찰 로직은 kream_server.auto_rebid_after_sale()이 담당.
이 모듈은 dry-run 단발 트리거 + 활성 입찰 체크 헬퍼만 제공.

정책:
- 판매 발생가와 동일 가격으로 재입찰 시뮬레이션
- 24h 쿨다운 (auto_rebid_log 기준)
- my_bids_local.json에 동일 model+size 활성 입찰이 이미 있으면 스킵
- 원가 없으면 NULL (절대 규칙 #1: 가짜 값 금지)
- auto_rebid_log 기존 스키마 그대로 사용, action 컬럼에 dry_run_<STATUS> prefix

절대 금지:
- _execute_rebid() 호출 X
- auto_rebid_enabled 변경 X
- auto_rebid_dry_run 변경 X
"""

import json
import sqlite3
from pathlib import Path
from datetime import datetime, timedelta

BASE_DIR = Path(__file__).resolve().parent.parent
DB_PATH = str(BASE_DIR / "price_history.db")
MY_BIDS_PATH = BASE_DIR / "my_bids_local.json"

# Step 36 정책 상수
COOLDOWN_HOURS = 6  # KREAM 운송장 정시 자동발급 + 취소 불가 → 짧게 가능
SHIP_STATUS_OK = "판매자 발송완료"  # 정상 거래만 후보 (테스트/미발송 자동 제외)
DEFAULT_DAILY_MAX = 10  # 보수적 기본값 (settings에 명시값 있으면 그게 우선)


def get_rebid_candidates(hours=24):
    """sales_history 최근 N시간 판매건 → 후보 list[dict].

    trade_date / collected_at 둘 중 더 최근값 기준으로 필터.
    Step 36: ship_status='판매자 발송완료'만 (정상 거래, 테스트/미발송 자동 제외).
    """
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cutoff = (datetime.now() - timedelta(hours=hours)).strftime("%Y-%m-%d %H:%M:%S")
    rows = conn.execute(
        """
        SELECT order_id, product_id, model, size, sale_price, trade_date, collected_at, ship_status
        FROM sales_history
        WHERE COALESCE(trade_date, collected_at) >= ?
          AND ship_status = ?
        ORDER BY COALESCE(trade_date, collected_at) DESC
        """,
        (cutoff, SHIP_STATUS_OK),
    ).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def has_active_bid(model, size):
    """my_bids_local.json에서 동일 model+size 활성 입찰 존재 여부."""
    if not MY_BIDS_PATH.exists():
        return False
    try:
        data = json.loads(MY_BIDS_PATH.read_text(encoding="utf-8"))
        bids = data.get("bids", []) if isinstance(data, dict) else data
        target_size = str(size).strip()
        for b in bids:
            if b.get("model") == model and str(b.get("size")).strip() == target_size:
                return True
    except Exception:
        return False
    return False


def get_bid_cost(model, size):
    """원가 매칭. Step 37: 폴백 체인 확장.

    1차: bid_cost (model, size) 정확
    2차: model_price_book (model, size) 정확 또는 (model, NULL = 전 사이즈)
    3차: bid_cost (model만) fuzzy

    리턴 dict의 match_type:
      bid_cost_exact / price_book_exact / price_book_all_sizes / bid_cost_fuzzy
    price_book 매칭 시 exchange_rate/overseas_shipping/other_costs는 None →
    calc_expected_profit이 settings 기본값으로 보강.
    """
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row

    # 1차: bid_cost 정확
    row = conn.execute(
        """
        SELECT cny_price, exchange_rate, overseas_shipping, other_costs, size,
               'bid_cost_exact' as match_type
        FROM bid_cost
        WHERE model = ? AND size = ?
        ORDER BY rowid DESC
        LIMIT 1
        """,
        (model, str(size)),
    ).fetchone()
    if row:
        conn.close()
        return dict(row)
    conn.close()

    # 2차: model_price_book
    try:
        from services.price_book import lookup_price
        pb = lookup_price(model, size)
    except Exception:
        pb = None
    if pb:
        return {
            "cny_price": pb["cny_price"],
            "exchange_rate": None,
            "overseas_shipping": None,
            "other_costs": None,
            "size": size if pb["match_type"] == "exact" else None,
            "match_type": f"price_book_{pb['match_type']}",
        }

    # 3차: bid_cost fuzzy (model만)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    row = conn.execute(
        """
        SELECT cny_price, exchange_rate, overseas_shipping, other_costs, size,
               'bid_cost_fuzzy' as match_type
        FROM bid_cost
        WHERE model = ?
        ORDER BY rowid DESC
        LIMIT 1
        """,
        (model,),
    ).fetchone()
    conn.close()
    return dict(row) if row else None


def calc_settlement(price):
    """정산액 = price × (1 - 0.06 × 1.1) - 2500."""
    return int(price * (1 - 0.06 * 1.1) - 2500)


def calc_expected_profit(rebid_price, cost_row, settings=None):
    """원가 없으면 None 반환 (절대 규칙 #1).

    Step 37: cost_row의 환율/배송비가 None이면 settings 기본값으로 보강
    (price_book 폴백은 cost_row에 환율/배송비가 없음).
    """
    if not cost_row or not cost_row.get("cny_price"):
        return None
    settings = settings or {}
    cny = cost_row["cny_price"]
    rate = cost_row.get("exchange_rate") or settings.get("exchange_rate") or 217
    shipping = cost_row.get("overseas_shipping") or settings.get("overseas_shipping") or 8000
    other = cost_row.get("other_costs") or 0
    cost_krw = int(cny * rate * 1.03) + shipping + other
    return calc_settlement(rebid_price) - cost_krw


def check_cooldown(conn, model, size, hours=None):
    """auto_rebid_log에서 동일 model+size 쿨다운 내 '실제' 재입찰 시도 존재 여부.

    Step 36: dry_run_* action은 쿨다운 카운트에서 제외 (실제 실행만).
    """
    if hours is None:
        hours = COOLDOWN_HOURS
    cutoff = (datetime.now() - timedelta(hours=hours)).strftime("%Y-%m-%d %H:%M:%S")
    cnt = conn.execute(
        """
        SELECT COUNT(*) FROM auto_rebid_log
        WHERE model = ? AND size = ? AND executed_at >= ?
          AND action NOT LIKE 'dry_run_%'
        """,
        (model, str(size), cutoff),
    ).fetchone()[0]
    return cnt > 0


def evaluate_candidate(cand, settings, conn):
    """후보 1건 평가 → status 반환.

    status: GO / GO_FUZZY / LOW / NO_COST / ACTIVE_BID_EXISTS / COOLDOWN
      · GO_FUZZY: 마진 통과했지만 bid_cost를 size fuzzy로 매칭한 케이스
        → 사장님이 size 매칭 정확도 점검 후 등록 보강 권장
    """
    model = cand["model"]
    size = cand["size"]
    sale_price = cand["sale_price"]

    if has_active_bid(model, size):
        return {"status": "ACTIVE_BID_EXISTS", "rebid_price": None, "expected_profit": None,
                "match_type": None, "matched_cost_size": None}

    if check_cooldown(conn, model, size):
        return {"status": "COOLDOWN", "rebid_price": None, "expected_profit": None,
                "match_type": None, "matched_cost_size": None}

    cost_row = get_bid_cost(model, size)
    if not cost_row:
        return {"status": "NO_COST", "rebid_price": sale_price, "expected_profit": None,
                "match_type": None, "matched_cost_size": None}

    match_type = cost_row.get("match_type")
    matched_cost_size = cost_row.get("size")
    rebid_price = sale_price
    profit = calc_expected_profit(rebid_price, cost_row, settings)
    min_profit = int(settings.get("auto_rebid_min_profit", 4000))

    if profit is None:
        return {"status": "NO_COST", "rebid_price": rebid_price, "expected_profit": None,
                "match_type": match_type, "matched_cost_size": matched_cost_size}
    if profit < min_profit:
        return {"status": "LOW", "rebid_price": rebid_price, "expected_profit": profit,
                "match_type": match_type, "matched_cost_size": matched_cost_size}

    # GO_FUZZY: bid_cost를 model만 매칭한 우연 케이스만 (사장님 검증 필요).
    # Step 39: price_book_all_sizes는 사장님이 명시적으로 "전 사이즈 동일"
    # 선언한 신뢰도 높은 매칭 → GO로 승급.
    status = "GO_FUZZY" if match_type == "bid_cost_fuzzy" else "GO"
    return {"status": status, "rebid_price": rebid_price, "expected_profit": profit,
            "match_type": match_type, "matched_cost_size": matched_cost_size}


def log_dry_run(conn, cand, eval_result):
    """기존 auto_rebid_log 스키마 그대로, action에 dry_run_<status> prefix."""
    action = f"dry_run_{eval_result['status']}"
    skip_reason = eval_result["status"] if eval_result["status"] not in ("GO", "GO_FUZZY") else None
    conn.execute(
        """
        INSERT INTO auto_rebid_log
        (original_order_id, model, size, sold_price, new_bid_price,
         expected_profit, action, skip_reason, executed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            cand.get("order_id"),
            cand["model"],
            cand["size"],
            cand.get("sale_price"),
            eval_result.get("rebid_price"),
            eval_result.get("expected_profit"),
            action,
            skip_reason,
            datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        ),
    )
    conn.commit()


def run_dry_run(settings, hours=24, daily_max=None):
    """전체 실행. 실제 place_bid 호출 X.

    리턴: {candidates_total, by_status, items, executable, executable_count, daily_max, hours}
    Step 36: GO_FUZZY 분류 추가, executable에는 GO + GO_FUZZY 모두 포함.
    """
    if daily_max is None:
        daily_max = int(settings.get("auto_rebid_daily_max", DEFAULT_DAILY_MAX))

    candidates = get_rebid_candidates(hours=hours)
    conn = sqlite3.connect(DB_PATH)

    items = []
    by_status = {
        "GO": 0, "GO_FUZZY": 0, "LOW": 0, "NO_COST": 0,
        "ACTIVE_BID_EXISTS": 0, "COOLDOWN": 0,
    }

    for cand in candidates:
        eval_result = evaluate_candidate(cand, settings, conn)
        log_dry_run(conn, cand, eval_result)
        s = eval_result["status"]
        by_status[s] = by_status.get(s, 0) + 1
        items.append({**cand, **eval_result})

    conn.close()

    executable = [i for i in items if i["status"] in ("GO", "GO_FUZZY")][:daily_max]

    return {
        "candidates_total": len(candidates),
        "by_status": by_status,
        "executable_count": len(executable),
        "daily_max": daily_max,
        "hours": hours,
        "items": items,
        "executable": executable,
    }


def format_dry_run_for_discord(result):
    """Discord bids 채널용 메시지 포맷. Step 36: ship_status, GO_FUZZY 표시 추가."""
    lines = [f"자동 재입찰 dry-run ({datetime.now().strftime('%Y-%m-%d %H:%M')})"]
    lines.append(f"")
    lines.append(f"후보: {result['candidates_total']}건 (최근 {result['hours']}h)")
    bs = result["by_status"]
    lines.append(
        f"GO {bs.get('GO', 0)} / GO_FUZZY {bs.get('GO_FUZZY', 0)} / "
        f"LOW {bs.get('LOW', 0)} / NO_COST {bs.get('NO_COST', 0)} / "
        f"ACTIVE {bs.get('ACTIVE_BID_EXISTS', 0)} / COOLDOWN {bs.get('COOLDOWN', 0)}"
    )
    lines.append(f"실제 실행 시: {result['executable_count']}건 (한도 {result['daily_max']})")
    lines.append("")
    lines.append("[상위 5건]")
    for i in result["items"][:5]:
        profit_v = i.get("expected_profit")
        profit = f"{profit_v:,}" if profit_v is not None else "NULL"
        rebid_v = i.get("rebid_price")
        rebid = f"{rebid_v:,}" if rebid_v else "-"
        ship = i.get("ship_status") or "-"
        suffix = ""
        if i.get("status") == "GO_FUZZY" and i.get("matched_cost_size"):
            suffix = f" (cost_size={i.get('matched_cost_size')})"
        lines.append(
            f"- {i.get('model')} / {i.get('size')} ({ship}) / 판매 {i.get('sale_price'):,} → "
            f"재입찰 {rebid} / 마진 {profit} / {i.get('status')}{suffix}"
        )
    return "\n".join(lines)
