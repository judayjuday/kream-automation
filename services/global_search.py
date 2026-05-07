"""
전역 검색 — Step 47-4.

여러 테이블을 통합 검색:
- bid_cost (모델/order_id)
- sales_history (order_id/모델)
- remittance_history (거래번호/메모)
- remittance_invoice (인보이스번호)
- remittance_supplier (협력사명)
- model_price_book (모델/카테고리)
- auto_rebid_log (모델/order_id) — 조회만
"""
import sqlite3
import os
from typing import Dict, List, Any

DB_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'price_history.db')


def _get_conn():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.row_factory = sqlite3.Row
    return conn


def search(query: str, limit: int = 20) -> Dict[str, Any]:
    """전역 검색."""
    if not query or len(query) < 2:
        return {'query': query, 'error': 'query too short'}

    pattern = f'%{query}%'
    conn = _get_conn()
    results = {}

    try:
        cur = conn.cursor()

        # bid_cost
        cur.execute(f"""
            SELECT order_id, model, size, cny_price, exchange_rate, created_at
            FROM bid_cost
            WHERE order_id LIKE ? OR model LIKE ?
            ORDER BY created_at DESC LIMIT {limit}
        """, (pattern, pattern))
        results['bid_cost'] = [dict(r) for r in cur.fetchall()]

        # sales_history
        cur.execute(f"""
            SELECT order_id, model, size, sale_price, trade_date, ship_status
            FROM sales_history
            WHERE order_id LIKE ? OR model LIKE ?
            ORDER BY trade_date DESC LIMIT {limit}
        """, (pattern, pattern))
        results['sales'] = [dict(r) for r in cur.fetchall()]

        # remittance_history
        cur.execute(f"""
            SELECT id, remittance_date, transaction_no, supplier, amount_krw,
                   exchange_rate, status, notes
            FROM remittance_history
            WHERE transaction_no LIKE ? OR supplier LIKE ? OR notes LIKE ?
            ORDER BY remittance_date DESC LIMIT {limit}
        """, (pattern, pattern, pattern))
        results['remittance'] = [dict(r) for r in cur.fetchall()]

        # remittance_invoice
        cur.execute(f"""
            SELECT ri.invoice_no, ri.invoice_date, ri.invoice_amount_usd,
                   rh.remittance_date, rh.supplier
            FROM remittance_invoice ri
            LEFT JOIN remittance_history rh ON rh.id = ri.remittance_id
            WHERE ri.invoice_no LIKE ?
            ORDER BY ri.invoice_date DESC LIMIT {limit}
        """, (pattern,))
        results['invoices'] = [dict(r) for r in cur.fetchall()]

        # supplier
        cur.execute(f"""
            SELECT id, name, name_en, wechat_id, default_currency
            FROM remittance_supplier
            WHERE name LIKE ? OR name_en LIKE ? OR wechat_id LIKE ?
            LIMIT {limit}
        """, (pattern, pattern, pattern))
        results['suppliers'] = [dict(r) for r in cur.fetchall()]

        # price_book
        cur.execute(f"""
            SELECT model, size, cny_price, category, brand, source
            FROM model_price_book
            WHERE model LIKE ? OR category LIKE ? OR brand LIKE ?
            LIMIT {limit}
        """, (pattern, pattern, pattern))
        results['price_book'] = [dict(r) for r in cur.fetchall()]

        # auto_rebid_log (실제 컬럼: original_order_id)
        cur.execute(f"""
            SELECT executed_at, model, size, action, expected_profit, original_order_id
            FROM auto_rebid_log
            WHERE model LIKE ? OR original_order_id LIKE ?
            ORDER BY executed_at DESC LIMIT {limit}
        """, (pattern, pattern))
        results['auto_rebid_log'] = [dict(r) for r in cur.fetchall()]

        # 총 결과 수
        results['totals'] = {k: len(v) for k, v in results.items() if isinstance(v, list)}
        results['query'] = query
        results['total_count'] = sum(results['totals'].values())
        return results
    finally:
        conn.close()
