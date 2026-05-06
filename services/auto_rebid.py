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


def get_rebid_candidates(hours=24):
    """sales_history 최근 N시간 판매건 → 후보 list[dict].

    trade_date / collected_at 둘 중 더 최근값 기준으로 필터.
    """
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cutoff = (datetime.now() - timedelta(hours=hours)).strftime("%Y-%m-%d %H:%M:%S")
    rows = conn.execute(
        """
        SELECT order_id, product_id, model, size, sale_price, trade_date, collected_at
        FROM sales_history
        WHERE COALESCE(trade_date, collected_at) >= ?
        ORDER BY COALESCE(trade_date, collected_at) DESC
        """,
        (cutoff,),
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
    """bid_cost에서 model+size 가장 최근 1건 (fuzzy)."""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    row = conn.execute(
        """
        SELECT cny_price, exchange_rate, overseas_shipping, other_costs
        FROM bid_cost
        WHERE model = ? AND size = ?
        ORDER BY rowid DESC
        LIMIT 1
        """,
        (model, str(size)),
    ).fetchone()
    conn.close()
    return dict(row) if row else None


def calc_settlement(price):
    """정산액 = price × (1 - 0.06 × 1.1) - 2500."""
    return int(price * (1 - 0.06 * 1.1) - 2500)


def calc_expected_profit(rebid_price, cost_row):
    """원가 없으면 None 반환 (절대 규칙 #1)."""
    if not cost_row or not cost_row.get("cny_price"):
        return None
    cny = cost_row["cny_price"]
    rate = cost_row.get("exchange_rate") or 217
    shipping = cost_row.get("overseas_shipping") or 8000
    other = cost_row.get("other_costs") or 0
    cost_krw = int(cny * rate * 1.03) + shipping + other
    return calc_settlement(rebid_price) - cost_krw


def check_cooldown(conn, model, size, hours=24):
    """auto_rebid_log에서 동일 model+size 24h 내 시도(dry-run/실행 모두) 존재 여부."""
    cutoff = (datetime.now() - timedelta(hours=hours)).strftime("%Y-%m-%d %H:%M:%S")
    cnt = conn.execute(
        """
        SELECT COUNT(*) FROM auto_rebid_log
        WHERE model = ? AND size = ? AND executed_at >= ?
        """,
        (model, str(size), cutoff),
    ).fetchone()[0]
    return cnt > 0


def evaluate_candidate(cand, settings, conn):
    """후보 1건 평가 → status 반환.

    status: GO / LOW / NO_COST / ACTIVE_BID_EXISTS / COOLDOWN
    """
    model = cand["model"]
    size = cand["size"]
    sale_price = cand["sale_price"]

    if has_active_bid(model, size):
        return {"status": "ACTIVE_BID_EXISTS", "rebid_price": None, "expected_profit": None}

    if check_cooldown(conn, model, size, hours=24):
        return {"status": "COOLDOWN", "rebid_price": None, "expected_profit": None}

    cost_row = get_bid_cost(model, size)
    if not cost_row:
        return {"status": "NO_COST", "rebid_price": sale_price, "expected_profit": None}

    rebid_price = sale_price
    profit = calc_expected_profit(rebid_price, cost_row)
    min_profit = int(settings.get("auto_rebid_min_profit", 4000))

    if profit is None:
        return {"status": "NO_COST", "rebid_price": rebid_price, "expected_profit": None}
    if profit < min_profit:
        return {"status": "LOW", "rebid_price": rebid_price, "expected_profit": profit}

    return {"status": "GO", "rebid_price": rebid_price, "expected_profit": profit}


def log_dry_run(conn, cand, eval_result):
    """기존 auto_rebid_log 스키마 그대로, action에 dry_run_<status> prefix."""
    action = f"dry_run_{eval_result['status']}"
    skip_reason = eval_result["status"] if eval_result["status"] != "GO" else None
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
    """
    if daily_max is None:
        daily_max = int(settings.get("auto_rebid_daily_max", 20))

    candidates = get_rebid_candidates(hours=hours)
    conn = sqlite3.connect(DB_PATH)

    items = []
    by_status = {"GO": 0, "LOW": 0, "NO_COST": 0, "ACTIVE_BID_EXISTS": 0, "COOLDOWN": 0}

    for cand in candidates:
        eval_result = evaluate_candidate(cand, settings, conn)
        log_dry_run(conn, cand, eval_result)
        s = eval_result["status"]
        by_status[s] = by_status.get(s, 0) + 1
        items.append({**cand, **eval_result})

    conn.close()

    executable = [i for i in items if i["status"] == "GO"][:daily_max]

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
    """Discord bids 채널용 메시지 포맷."""
    lines = [f"자동 재입찰 dry-run ({datetime.now().strftime('%Y-%m-%d %H:%M')})"]
    lines.append(f"")
    lines.append(f"후보: {result['candidates_total']}건 (최근 {result['hours']}h)")
    bs = result["by_status"]
    lines.append(
        f"GO {bs.get('GO', 0)} / LOW {bs.get('LOW', 0)} / "
        f"NO_COST {bs.get('NO_COST', 0)} / ACTIVE {bs.get('ACTIVE_BID_EXISTS', 0)} / "
        f"COOLDOWN {bs.get('COOLDOWN', 0)}"
    )
    lines.append(f"실제 실행 시: {result['executable_count']}건 (한도 {result['daily_max']})")
    lines.append("")
    lines.append("[상위 5건]")
    for i in result["items"][:5]:
        profit_v = i.get("expected_profit")
        profit = f"{profit_v:,}" if profit_v is not None else "NULL"
        rebid_v = i.get("rebid_price")
        rebid = f"{rebid_v:,}" if rebid_v else "-"
        lines.append(
            f"- {i.get('model')} / {i.get('size')} / 판매 {i.get('sale_price'):,} → "
            f"재입찰 {rebid} / 마진 {profit} / {i.get('status')}"
        )
    return "\n".join(lines)
