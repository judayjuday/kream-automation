"""
송금 환율 시스템 — Step 42

핵심 책임:
1. 송금 이력 CRUD
2. bid_cost ↔ remittance 매칭 (FIFO 자동 / 수동)
3. 매칭된 입찰의 환율 조회 (마진 재계산용)

환율 폴백 체인 (calc_expected_profit에서 사용):
1. remittance_bid_match → remittance.exchange_rate  ← 신규 최우선
2. bid_cost.exchange_rate
3. settings.exchange_rate
4. 217 (안전 폴백)
"""
import sqlite3
import os
from typing import Optional, List, Dict, Any

DB_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'price_history.db')


def _get_conn():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.row_factory = sqlite3.Row
    return conn


# ============================================================
# 송금 CRUD
# ============================================================

def add_remittance(
    remittance_date: str,
    amount_cny: float,
    amount_krw: float,
    supplier: Optional[str] = None,
    wechat_id: Optional[str] = None,
    fee_krw: float = 0,
    notes: Optional[str] = None,
) -> Dict[str, Any]:
    """
    송금 이력 등록.
    exchange_rate는 amount_krw / amount_cny로 자동 계산.

    절대 규칙 #1 준수: 가짜 값 사용 금지. amount_cny=0이면 거부.
    """
    if amount_cny <= 0:
        return {'success': False, 'error': 'amount_cny must be > 0'}
    if amount_krw <= 0:
        return {'success': False, 'error': 'amount_krw must be > 0'}

    exchange_rate = round(amount_krw / amount_cny, 4)

    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("""
            INSERT INTO remittance_history
            (remittance_date, amount_cny, amount_krw, exchange_rate,
             supplier, wechat_id, fee_krw, notes)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, (remittance_date, amount_cny, amount_krw, exchange_rate,
              supplier, wechat_id, fee_krw, notes))
        conn.commit()
        new_id = cur.lastrowid
        return {
            'success': True,
            'id': new_id,
            'exchange_rate': exchange_rate,
            'message': f'송금 등록 완료 (id={new_id}, 환율={exchange_rate})'
        }
    except Exception as e:
        conn.rollback()
        return {'success': False, 'error': str(e)}
    finally:
        conn.close()


def list_remittances(limit: int = 50, status: Optional[str] = None) -> List[Dict]:
    """송금 이력 목록."""
    conn = _get_conn()
    try:
        cur = conn.cursor()
        if status:
            cur.execute("""
                SELECT * FROM remittance_history
                WHERE status = ?
                ORDER BY remittance_date DESC, id DESC
                LIMIT ?
            """, (status, limit))
        else:
            cur.execute("""
                SELECT * FROM remittance_history
                ORDER BY remittance_date DESC, id DESC
                LIMIT ?
            """, (limit,))
        return [dict(r) for r in cur.fetchall()]
    finally:
        conn.close()


def get_remittance(remittance_id: int) -> Optional[Dict]:
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("SELECT * FROM remittance_history WHERE id = ?", (remittance_id,))
        r = cur.fetchone()
        return dict(r) if r else None
    finally:
        conn.close()


# ============================================================
# 매칭 로직
# ============================================================

def get_unmatched_bids() -> List[Dict]:
    """
    매칭되지 않은 bid_cost 목록.
    remittance_bid_match에 없거나, 부분 매칭만 된 건 포함.
    """
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("PRAGMA table_info(bid_cost)")
        cols = {c[1] for c in cur.fetchall()}
        has_id = 'id' in cols

        if has_id:
            cur.execute("""
                SELECT bc.id as bid_cost_id, bc.order_id, bc.model, bc.size,
                       bc.cny_price, bc.exchange_rate, bc.created_at,
                       COALESCE(SUM(rbm.allocated_cny), 0) as matched_cny
                FROM bid_cost bc
                LEFT JOIN remittance_bid_match rbm ON rbm.bid_cost_id = bc.id
                GROUP BY bc.id
                HAVING matched_cny < bc.cny_price
                ORDER BY bc.created_at ASC
            """)
        else:
            cur.execute("""
                SELECT bc.rowid as bid_cost_id, bc.order_id, bc.model, bc.size,
                       bc.cny_price, bc.exchange_rate, bc.created_at,
                       COALESCE(SUM(rbm.allocated_cny), 0) as matched_cny
                FROM bid_cost bc
                LEFT JOIN remittance_bid_match rbm ON rbm.order_id = bc.order_id
                GROUP BY bc.order_id
                HAVING matched_cny < bc.cny_price
                ORDER BY bc.created_at ASC
            """)
        return [dict(r) for r in cur.fetchall()]
    finally:
        conn.close()


def match_bid_to_remittance(
    remittance_id: int,
    bid_cost_id: int,
    order_id: Optional[str] = None,
    allocated_cny: Optional[float] = None,
    method: str = 'manual'
) -> Dict[str, Any]:
    """
    특정 송금에 입찰 매칭.
    allocated_cny=None이면 bid_cost.cny_price 전액 매칭.
    """
    conn = _get_conn()
    try:
        cur = conn.cursor()

        cur.execute("SELECT * FROM remittance_history WHERE id = ?", (remittance_id,))
        rem = cur.fetchone()
        if not rem:
            return {'success': False, 'error': f'remittance {remittance_id} not found'}
        if rem['status'] != 'active':
            return {'success': False, 'error': f'remittance status={rem["status"]}'}

        remaining = rem['amount_cny'] - rem['allocated_cny']
        if remaining <= 0:
            return {'success': False, 'error': 'remittance fully allocated'}

        cur.execute("PRAGMA table_info(bid_cost)")
        cols = {c[1] for c in cur.fetchall()}
        has_id = 'id' in cols

        if has_id:
            cur.execute("SELECT * FROM bid_cost WHERE id = ?", (bid_cost_id,))
        else:
            if not order_id:
                return {'success': False, 'error': 'order_id required when bid_cost has no id'}
            cur.execute("SELECT rowid, * FROM bid_cost WHERE order_id = ?", (order_id,))

        bid = cur.fetchone()
        if not bid:
            return {'success': False, 'error': 'bid_cost not found'}

        if allocated_cny is None:
            allocated_cny = bid['cny_price']
        if allocated_cny > remaining:
            return {'success': False,
                    'error': f'allocated_cny {allocated_cny} > remaining {remaining}'}

        order_id_val = order_id or bid['order_id']
        bid_id_val = bid['id'] if has_id else bid['rowid']

        try:
            cur.execute("""
                INSERT INTO remittance_bid_match
                (remittance_id, bid_cost_id, order_id, allocated_cny, match_method)
                VALUES (?, ?, ?, ?, ?)
            """, (remittance_id, bid_id_val, order_id_val, allocated_cny, method))
        except sqlite3.IntegrityError:
            return {'success': False, 'error': 'already matched'}

        new_allocated = rem['allocated_cny'] + allocated_cny
        new_status = 'depleted' if new_allocated >= rem['amount_cny'] - 0.01 else 'active'
        cur.execute("""
            UPDATE remittance_history
            SET allocated_cny = ?, status = ?, updated_at = CURRENT_TIMESTAMP
            WHERE id = ?
        """, (new_allocated, new_status, remittance_id))

        conn.commit()
        return {
            'success': True,
            'remittance_id': remittance_id,
            'bid_cost_id': bid_id_val,
            'order_id': order_id_val,
            'allocated_cny': allocated_cny,
            'remittance_status': new_status,
        }
    except Exception as e:
        conn.rollback()
        return {'success': False, 'error': str(e)}
    finally:
        conn.close()


def auto_match_fifo(max_matches: int = 100) -> Dict[str, Any]:
    """
    FIFO 자동 매칭:
    - 가장 오래된 active 송금부터
    - 가장 오래된 미매칭 입찰부터 순서대로 할당
    - 송금 잔액 소진 시 다음 송금으로
    """
    matched = 0
    skipped = 0
    errors = []

    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, amount_cny, allocated_cny FROM remittance_history
            WHERE status = 'active'
            ORDER BY remittance_date ASC, id ASC
        """)
        remittances = [dict(r) for r in cur.fetchall()]
    finally:
        conn.close()

    if not remittances:
        return {'success': True, 'matched': 0, 'message': 'no active remittance'}

    unmatched = get_unmatched_bids()
    if not unmatched:
        return {'success': True, 'matched': 0, 'message': 'no unmatched bids'}

    rem_idx = 0
    rem = remittances[rem_idx]
    rem_remaining = rem['amount_cny'] - rem['allocated_cny']

    for bid in unmatched:
        if matched >= max_matches:
            break

        bid_remaining_cny = bid['cny_price'] - bid['matched_cny']
        if bid_remaining_cny <= 0:
            continue

        while rem_remaining < bid_remaining_cny and rem_idx < len(remittances) - 1:
            rem_idx += 1
            rem = remittances[rem_idx]
            rem_remaining = rem['amount_cny'] - rem['allocated_cny']

        if rem_remaining < bid_remaining_cny:
            if rem_remaining > 0:
                result = match_bid_to_remittance(
                    rem['id'], bid['bid_cost_id'], bid['order_id'],
                    rem_remaining, 'fifo_auto'
                )
                if result['success']:
                    matched += 1
                    rem_remaining = 0
                else:
                    errors.append(result['error'])
            skipped += 1
            continue

        result = match_bid_to_remittance(
            rem['id'], bid['bid_cost_id'], bid['order_id'],
            bid_remaining_cny, 'fifo_auto'
        )
        if result['success']:
            matched += 1
            rem_remaining -= bid_remaining_cny
        else:
            errors.append(result['error'])

    return {
        'success': True,
        'matched': matched,
        'skipped': skipped,
        'errors': errors[:10],
        'message': f'FIFO 매칭 {matched}건 완료, {skipped}건 스킵'
    }


# ============================================================
# 환율 조회 (마진 재계산용)
# ============================================================

def get_matched_exchange_rate(order_id: str) -> Optional[float]:
    """
    특정 입찰의 매칭된 송금 환율 조회.
    여러 송금에 분할 매칭된 경우 가중평균 환율 반환.
    매칭 없으면 None.
    """
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("""
            SELECT rh.exchange_rate, rbm.allocated_cny
            FROM remittance_bid_match rbm
            JOIN remittance_history rh ON rh.id = rbm.remittance_id
            WHERE rbm.order_id = ?
        """, (order_id,))
        rows = cur.fetchall()
        if not rows:
            return None

        total_cny = sum(r['allocated_cny'] for r in rows)
        if total_cny <= 0:
            return None

        weighted = sum(r['exchange_rate'] * r['allocated_cny'] for r in rows)
        return round(weighted / total_cny, 4)
    finally:
        conn.close()


# ============================================================
# 통계
# ============================================================

def get_summary() -> Dict[str, Any]:
    """송금 + 매칭 요약."""
    conn = _get_conn()
    try:
        cur = conn.cursor()

        cur.execute("""
            SELECT COUNT(*) as cnt,
                   COALESCE(SUM(amount_cny), 0) as total_cny,
                   COALESCE(SUM(amount_krw), 0) as total_krw,
                   COALESCE(SUM(allocated_cny), 0) as allocated_cny
            FROM remittance_history WHERE status != 'cancelled'
        """)
        rem = dict(cur.fetchone())

        unmatched = get_unmatched_bids()
        unmatched_cny = sum(b['cny_price'] - b['matched_cny'] for b in unmatched)

        return {
            'remittance_count': rem['cnt'],
            'total_remittance_cny': rem['total_cny'],
            'total_remittance_krw': rem['total_krw'],
            'allocated_cny': rem['allocated_cny'],
            'remaining_cny': rem['total_cny'] - rem['allocated_cny'],
            'unmatched_bid_count': len(unmatched),
            'unmatched_bid_cny': round(unmatched_cny, 2),
        }
    finally:
        conn.close()
