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
import sys
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

    Step 41 환율 폴백 체인:
      1) cost_row.exchange_rate (입찰 시점 환율, bid_cost에서 옴)
      2) settings.exchange_rate (현재 환율)
      3) 217 (안전 폴백)

    배송비 폴백:
      1) cost_row.overseas_shipping
      2) settings.overseas_shipping
      3) 8000
    """
    if not cost_row or not cost_row.get("cny_price"):
        return None
    settings = settings or {}
    cny = cost_row["cny_price"]

    rate = cost_row.get("exchange_rate")
    if not rate:
        rate = settings.get("exchange_rate")
    if not rate:
        rate = 217

    shipping = cost_row.get("overseas_shipping")
    if shipping is None:
        shipping = settings.get("overseas_shipping")
    if shipping is None:
        shipping = 8000

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

    Step 41:
      - today_real_count / remaining_quota 시뮬레이션
      - min_profit 응답에 노출
      - dry_run_* 로그 7일 자동 정리 (실행 로그는 보존)
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

    # 오늘 이미 실행된 실제 재입찰 수 (dry_run 제외, success만)
    today = datetime.now().strftime("%Y-%m-%d")
    today_real_count = conn.execute(
        """
        SELECT COUNT(*) FROM auto_rebid_log
        WHERE date(executed_at) = ?
          AND action NOT LIKE 'dry_run_%'
          AND action LIKE '%success%'
        """,
        (today,),
    ).fetchone()[0]
    remaining_quota = max(0, daily_max - today_real_count)

    # 7일 이상된 dry_run 로그 정리 (실제 실행 로그는 보존)
    cleanup_deleted = 0
    try:
        cleanup_cutoff = (datetime.now() - timedelta(days=7)).strftime("%Y-%m-%d %H:%M:%S")
        cleanup_deleted = conn.execute(
            """
            DELETE FROM auto_rebid_log
            WHERE action LIKE 'dry_run_%' AND executed_at < ?
            """,
            (cleanup_cutoff,),
        ).rowcount
        conn.commit()
        if cleanup_deleted > 0:
            print(f"[CLEANUP] dry_run 로그 {cleanup_deleted}건 정리 (7일 경과)", file=sys.stderr)
    except Exception as e:
        print(f"[CLEANUP-FAIL] {e}", file=sys.stderr)

    conn.close()

    executable = [i for i in items if i["status"] in ("GO", "GO_FUZZY")][:remaining_quota]
    min_profit = int(settings.get("auto_rebid_min_profit", 3000))

    return {
        "candidates_total": len(candidates),
        "by_status": by_status,
        "executable_count": len(executable),
        "daily_max": daily_max,
        "today_real_count": today_real_count,
        "remaining_quota": remaining_quota,
        "min_profit": min_profit,
        "hours": hours,
        "cleanup_deleted": cleanup_deleted,
        "items": items,
        "executable": executable,
    }


def format_dry_run_for_discord(result):
    """Discord bids 채널용 메시지 포맷. Step 41 강화:
    - GO 후보 전체 표시 (5건 제한 X)
    - 예상 마진 합계
    - LOW 별도 섹션
    - 일 한도 시뮬 (today_real / remaining_quota)
    """
    lines = [f"자동 재입찰 dry-run ({datetime.now().strftime('%Y-%m-%d %H:%M')})"]
    lines.append("")

    bs = result["by_status"]
    lines.append(f"후보: {result['candidates_total']}건 (최근 {result['hours']}h)")
    lines.append(
        f"GO {bs.get('GO', 0)} / GO_FUZZY {bs.get('GO_FUZZY', 0)} / "
        f"LOW {bs.get('LOW', 0)} / NO_COST {bs.get('NO_COST', 0)} / "
        f"ACTIVE {bs.get('ACTIVE_BID_EXISTS', 0)} / COOLDOWN {bs.get('COOLDOWN', 0)}"
    )

    executable_items = result.get("executable", [])
    total_profit = sum((i.get("expected_profit") or 0) for i in executable_items)
    today_real = result.get("today_real_count", 0)
    remaining = result.get("remaining_quota", result.get("daily_max", 0))
    min_profit = result.get("min_profit", 3000)
    lines.append(
        f"실행 시: {result['executable_count']}건 / "
        f"오늘 실행 {today_real} / 잔여 {remaining} (한도 {result['daily_max']}) / "
        f"예상 마진 합계 {total_profit:,}원 / min_profit {min_profit:,}"
    )
    lines.append("")

    go_items = [i for i in result["items"] if i["status"] in ("GO", "GO_FUZZY")]
    if go_items:
        lines.append(f"[GO 후보 전체 {len(go_items)}건]")
        for i in go_items:
            profit_v = i.get("expected_profit")
            profit = f"{profit_v:,}" if profit_v is not None else "NULL"
            rebid_v = i.get("rebid_price")
            rebid = f"{rebid_v:,}" if rebid_v else "-"
            tag = "GO" if i["status"] == "GO" else "FUZZY"
            suffix = ""
            if i.get("status") == "GO_FUZZY" and i.get("matched_cost_size"):
                suffix = f" (cost_size={i.get('matched_cost_size')})"
            lines.append(
                f"[{tag}] {i.get('model')}/{i.get('size')} | "
                f"{i.get('sale_price'):,} → {rebid} | 마진 {profit}{suffix}"
            )

    low_items = [i for i in result["items"] if i["status"] == "LOW"]
    if low_items:
        lines.append("")
        lines.append(f"[LOW {len(low_items)}건 — min_profit {min_profit:,} 미달]")
        for i in low_items[:3]:
            profit_v = i.get("expected_profit")
            profit = f"{profit_v:,}" if profit_v is not None else "NULL"
            lines.append(
                f"[LOW] {i.get('model')}/{i.get('size')} | "
                f"{i.get('sale_price'):,} | 마진 {profit}"
            )

    return "\n".join(lines)
