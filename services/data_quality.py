"""
데이터 품질 검증 — Step 46-1.

핵심 책임:
1. bid_cost 무결성 (음수/NULL/이상치)
2. 고아 레코드 (매칭 끊긴 송금/입찰)
3. 중복 데이터 (같은 model+size+order_id)
4. 환율 이상치 (평균 대비 ±20% 이상)

절대 규칙: 데이터 자동 삭제 금지. 탐지만 하고 사장님이 결정.
"""
import sqlite3
import os
from typing import Dict, List, Any
from datetime import datetime

DB_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'price_history.db')


def _get_conn():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.row_factory = sqlite3.Row
    return conn


def _table_exists(cur, table_name: str) -> bool:
    cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name=?", (table_name,))
    return cur.fetchone() is not None


def check_bid_cost_integrity() -> Dict[str, Any]:
    """bid_cost 무결성 검증."""
    conn = _get_conn()
    try:
        cur = conn.cursor()

        if not _table_exists(cur, 'bid_cost'):
            return {
                'avg_exchange_rate': None,
                'invalid_cny': [],
                'invalid_rate': [],
                'rate_outliers': [],
                'cny_outliers': [],
                'total_issues': 0,
                'note': 'bid_cost 테이블 없음',
            }

        # 1. 음수 또는 0인 cny_price
        cur.execute("""
            SELECT order_id, model, size, cny_price, exchange_rate
            FROM bid_cost
            WHERE cny_price IS NULL OR cny_price <= 0
        """)
        invalid_cny = [dict(r) for r in cur.fetchall()]

        # 2. 음수 또는 0인 exchange_rate
        cur.execute("""
            SELECT order_id, model, size, cny_price, exchange_rate
            FROM bid_cost
            WHERE exchange_rate IS NULL OR exchange_rate <= 0
        """)
        invalid_rate = [dict(r) for r in cur.fetchall()]

        # 3. 환율 이상치 (평균 ±20%)
        cur.execute("SELECT AVG(exchange_rate) as avg_rate FROM bid_cost WHERE exchange_rate > 0")
        avg = cur.fetchone()['avg_rate']
        if avg:
            lo = avg * 0.8
            hi = avg * 1.2
            cur.execute("""
                SELECT order_id, model, size, cny_price, exchange_rate
                FROM bid_cost
                WHERE exchange_rate > 0
                  AND (exchange_rate < ? OR exchange_rate > ?)
            """, (lo, hi))
            outliers = [dict(r) for r in cur.fetchall()]
        else:
            outliers = []

        # 4. 비정상 cny_price (5위안 이하 또는 100,000위안 이상)
        cur.execute("""
            SELECT order_id, model, size, cny_price, exchange_rate
            FROM bid_cost
            WHERE cny_price > 0 AND (cny_price < 5 OR cny_price > 100000)
        """)
        cny_outliers = [dict(r) for r in cur.fetchall()]

        return {
            'avg_exchange_rate': round(avg, 4) if avg else None,
            'invalid_cny': invalid_cny,
            'invalid_rate': invalid_rate,
            'rate_outliers': outliers,
            'cny_outliers': cny_outliers,
            'total_issues': len(invalid_cny) + len(invalid_rate) + len(outliers) + len(cny_outliers),
        }
    finally:
        conn.close()


def find_orphan_records() -> Dict[str, Any]:
    """고아 레코드 탐지."""
    conn = _get_conn()
    try:
        cur = conn.cursor()

        orphan_matches = []
        orphan_invoices = []
        orphan_receipts = []
        orphan_suppliers = []

        if _table_exists(cur, 'remittance_bid_match') and _table_exists(cur, 'remittance_history'):
            cur.execute("""
                SELECT rbm.id, rbm.remittance_id, rbm.order_id
                FROM remittance_bid_match rbm
                LEFT JOIN remittance_history rh ON rh.id = rbm.remittance_id
                WHERE rh.id IS NULL
            """)
            orphan_matches = [dict(r) for r in cur.fetchall()]

        if _table_exists(cur, 'remittance_invoice') and _table_exists(cur, 'remittance_history'):
            cur.execute("""
                SELECT ri.id, ri.remittance_id, ri.invoice_no
                FROM remittance_invoice ri
                LEFT JOIN remittance_history rh ON rh.id = ri.remittance_id
                WHERE rh.id IS NULL
            """)
            orphan_invoices = [dict(r) for r in cur.fetchall()]

        if _table_exists(cur, 'remittance_receipt') and _table_exists(cur, 'remittance_history'):
            cur.execute("""
                SELECT rr.id, rr.remittance_id, rr.receipt_path
                FROM remittance_receipt rr
                LEFT JOIN remittance_history rh ON rh.id = rr.remittance_id
                WHERE rh.id IS NULL
            """)
            orphan_receipts = [dict(r) for r in cur.fetchall()]

        if _table_exists(cur, 'remittance_history') and _table_exists(cur, 'remittance_supplier'):
            cur.execute("""
                SELECT rh.id, rh.remittance_date, rh.supplier_id
                FROM remittance_history rh
                LEFT JOIN remittance_supplier rs ON rs.id = rh.supplier_id
                WHERE rh.supplier_id IS NOT NULL AND rs.id IS NULL
            """)
            orphan_suppliers = [dict(r) for r in cur.fetchall()]

        return {
            'orphan_matches': orphan_matches,
            'orphan_invoices': orphan_invoices,
            'orphan_receipts': orphan_receipts,
            'orphan_supplier_refs': orphan_suppliers,
            'total_orphans': (len(orphan_matches) + len(orphan_invoices)
                              + len(orphan_receipts) + len(orphan_suppliers)),
        }
    finally:
        conn.close()


def find_duplicates() -> Dict[str, Any]:
    """중복 데이터 탐지."""
    conn = _get_conn()
    try:
        cur = conn.cursor()

        dup_bid = []
        dup_pb = []
        dup_supplier = []

        if _table_exists(cur, 'bid_cost'):
            cur.execute("""
                SELECT order_id, COUNT(*) as cnt
                FROM bid_cost
                GROUP BY order_id
                HAVING cnt > 1
            """)
            dup_bid = [dict(r) for r in cur.fetchall()]

        if _table_exists(cur, 'model_price_book'):
            cur.execute("""
                SELECT model, COALESCE(size, '__NULL__') as size, COUNT(*) as cnt
                FROM model_price_book
                GROUP BY model, COALESCE(size, '__NULL__')
                HAVING cnt > 1
            """)
            dup_pb = [dict(r) for r in cur.fetchall()]

        if _table_exists(cur, 'remittance_supplier'):
            cur.execute("""
                SELECT name, COUNT(*) as cnt
                FROM remittance_supplier
                GROUP BY name HAVING cnt > 1
            """)
            dup_supplier = [dict(r) for r in cur.fetchall()]

        return {
            'duplicate_bid_cost': dup_bid,
            'duplicate_price_book': dup_pb,
            'duplicate_suppliers': dup_supplier,
            'total_duplicates': len(dup_bid) + len(dup_pb) + len(dup_supplier),
        }
    finally:
        conn.close()


def comprehensive_health_check() -> Dict[str, Any]:
    """종합 데이터 품질 점수."""
    integrity = check_bid_cost_integrity()
    orphans = find_orphan_records()
    duplicates = find_duplicates()

    total_issues = (
        integrity['total_issues']
        + orphans['total_orphans']
        + duplicates['total_duplicates']
    )

    # 점수: 100점 만점, 이슈 1개당 -1점, 최저 0점
    score = max(0, 100 - total_issues)
    grade = 'A' if score >= 95 else ('B' if score >= 80 else ('C' if score >= 60 else 'D'))

    return {
        'score': score,
        'grade': grade,
        'total_issues': total_issues,
        'integrity': integrity,
        'orphans': orphans,
        'duplicates': duplicates,
        'checked_at': datetime.now().isoformat(),
    }
