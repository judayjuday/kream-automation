"""
환율 손익(FX P&L) 분석 서비스 — Step 43-2.

핵심 책임:
1. 매칭된 입찰의 환율 손익 계산 (bid_cost.exchange_rate vs remittance.exchange_rate)
2. 미매칭 입찰의 환율 위험 노출액 계산
3. 협력사별 평균 환율 비교

절대 규칙 #1: 환율 데이터 없으면 'unknown' 반환, 가짜 값 금지.
"""
import sqlite3
import os
from typing import Dict, List, Any, Optional

DB_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'price_history.db')


def _get_conn():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.row_factory = sqlite3.Row
    return conn


def calculate_fx_pnl_for_bid(bid_cost_id: int, order_id: str) -> Dict[str, Any]:
    """
    개별 입찰의 환율 손익 계산.

    Returns:
        {
            'order_id': str,
            'bid_cost_rate': float | None,  # 입찰 시점 환율
            'matched_rate': float | None,   # 매칭된 송금 환율 (가중평균)
            'fx_pnl_per_cny': float | None, # CNY당 손익 KRW
            'fx_pnl_total': float | None,   # 총 손익 KRW
            'status': 'matched' | 'unmatched' | 'no_bid_cost',
        }
    """
    conn = _get_conn()
    try:
        cur = conn.cursor()

        # bid_cost 정보
        cur.execute("PRAGMA table_info(bid_cost)")
        cols = {c[1] for c in cur.fetchall()}
        has_id = 'id' in cols

        if has_id:
            cur.execute("SELECT * FROM bid_cost WHERE id = ?", (bid_cost_id,))
        else:
            cur.execute("SELECT rowid as id, * FROM bid_cost WHERE order_id = ?", (order_id,))

        bid = cur.fetchone()
        if not bid:
            return {'status': 'no_bid_cost', 'order_id': order_id}

        bid_cost_rate = bid['exchange_rate']
        cny_price = bid['cny_price']

        # 매칭 정보 (가중평균 환율)
        cur.execute("""
            SELECT rh.exchange_rate, rbm.allocated_cny
            FROM remittance_bid_match rbm
            JOIN remittance_history rh ON rh.id = rbm.remittance_id
            WHERE rbm.order_id = ?
        """, (order_id,))
        matches = cur.fetchall()

        if not matches:
            return {
                'order_id': order_id,
                'bid_cost_rate': bid_cost_rate,
                'matched_rate': None,
                'fx_pnl_per_cny': None,
                'fx_pnl_total': None,
                'cny_price': cny_price,
                'status': 'unmatched',
            }

        total_alloc = sum(m['allocated_cny'] for m in matches)
        if total_alloc <= 0:
            return {
                'order_id': order_id,
                'bid_cost_rate': bid_cost_rate,
                'matched_rate': None,
                'cny_price': cny_price,
                'status': 'unmatched',
            }

        weighted = sum(m['exchange_rate'] * m['allocated_cny'] for m in matches)
        matched_rate = round(weighted / total_alloc, 4)

        # 손익 = (입찰시점 환율 - 송금환율) × CNY 원가
        # 양수 = 환율이 내려서 이익 (실제 KRW가 덜 나감)
        # 음수 = 환율이 올라서 손해
        fx_pnl_per_cny = round(bid_cost_rate - matched_rate, 4)
        fx_pnl_total = round(fx_pnl_per_cny * cny_price, 2)

        return {
            'order_id': order_id,
            'bid_cost_rate': bid_cost_rate,
            'matched_rate': matched_rate,
            'fx_pnl_per_cny': fx_pnl_per_cny,
            'fx_pnl_total': fx_pnl_total,
            'cny_price': cny_price,
            'matched_alloc_cny': total_alloc,
            'status': 'matched',
        }
    finally:
        conn.close()


def calculate_portfolio_fx_pnl() -> Dict[str, Any]:
    """전체 포트폴리오 환율 손익 분석."""
    conn = _get_conn()
    try:
        cur = conn.cursor()

        # 전체 bid_cost
        cur.execute("PRAGMA table_info(bid_cost)")
        cols = {c[1] for c in cur.fetchall()}
        id_col = 'id' if 'id' in cols else 'rowid'

        cur.execute(f"""
            SELECT bc.{id_col} as id, bc.order_id, bc.cny_price, bc.exchange_rate
            FROM bid_cost bc
        """)
        all_bids = [dict(r) for r in cur.fetchall()]

        # 매칭 정보 일괄 조회
        cur.execute("""
            SELECT rbm.order_id, rh.exchange_rate, rbm.allocated_cny
            FROM remittance_bid_match rbm
            JOIN remittance_history rh ON rh.id = rbm.remittance_id
        """)
        match_rows = cur.fetchall()

        # order_id → [(rate, alloc), ...]
        match_map: Dict[str, List] = {}
        for r in match_rows:
            match_map.setdefault(r['order_id'], []).append((r['exchange_rate'], r['allocated_cny']))

        matched_count = 0
        unmatched_count = 0
        total_pnl_krw = 0.0
        unmatched_cny_exposure = 0.0
        unmatched_krw_exposure = 0.0

        details = []
        for bid in all_bids:
            ms = match_map.get(bid['order_id'])
            if ms:
                total_alloc = sum(a for _, a in ms)
                if total_alloc > 0:
                    weighted = sum(r * a for r, a in ms)
                    matched_rate = weighted / total_alloc
                    pnl_per_cny = (bid['exchange_rate'] or 0) - matched_rate
                    pnl_total = pnl_per_cny * bid['cny_price']
                    total_pnl_krw += pnl_total
                    matched_count += 1
                    details.append({
                        'order_id': bid['order_id'],
                        'cny_price': bid['cny_price'],
                        'bid_rate': bid['exchange_rate'],
                        'matched_rate': round(matched_rate, 4),
                        'pnl_krw': round(pnl_total, 2),
                    })
                    continue
            # 미매칭
            unmatched_count += 1
            unmatched_cny_exposure += bid['cny_price']
            unmatched_krw_exposure += (bid['cny_price'] * (bid['exchange_rate'] or 0))

        return {
            'matched_count': matched_count,
            'unmatched_count': unmatched_count,
            'total_pnl_krw': round(total_pnl_krw, 2),
            'avg_pnl_per_bid': round(total_pnl_krw / matched_count, 2) if matched_count else 0,
            'unmatched_cny_exposure': round(unmatched_cny_exposure, 2),
            'unmatched_krw_exposure': round(unmatched_krw_exposure, 2),
            'details': details[:50],  # 최근 50건만
        }
    finally:
        conn.close()


def supplier_fx_comparison() -> List[Dict]:
    """협력사별 평균 송금 환율 비교."""
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("""
            SELECT
                rs.id as supplier_id,
                rs.name as supplier_name,
                rs.name_en,
                COUNT(rh.id) as remittance_count,
                AVG(rh.exchange_rate) as avg_rate,
                MIN(rh.exchange_rate) as min_rate,
                MAX(rh.exchange_rate) as max_rate,
                SUM(rh.amount_cny) as total_cny,
                SUM(rh.amount_krw) as total_krw,
                SUM(rh.fee_krw) as total_fee_krw
            FROM remittance_supplier rs
            LEFT JOIN remittance_history rh ON rh.supplier_id = rs.id
            WHERE rh.id IS NOT NULL
            GROUP BY rs.id
            ORDER BY remittance_count DESC
        """)
        results = []
        for r in cur.fetchall():
            d = dict(r)
            if d['total_cny'] and d['total_krw']:
                d['effective_rate'] = round(d['total_krw'] / d['total_cny'], 4)
                d['fee_ratio_pct'] = round((d['total_fee_krw'] or 0) / d['total_krw'] * 100, 3) if d['total_fee_krw'] else 0
            results.append(d)
        return results
    finally:
        conn.close()
