"""
데이터 Export — Step 47-5.
주요 테이블 CSV/JSON 다운로드.
"""
import sqlite3
import os
import csv
import io
from typing import Dict, Any
from datetime import datetime

DB_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'price_history.db')

# Export 가능 테이블 (화이트리스트)
EXPORTABLE_TABLES = {
    'bid_cost', 'sales_history', 'remittance_history', 'remittance_supplier',
    'remittance_invoice', 'remittance_receipt', 'remittance_bid_match',
    'model_price_book', 'auto_rebid_log',
}


def export_table_csv(table: str, limit: int = 10000) -> Dict[str, Any]:
    """테이블 CSV 문자열 반환."""
    if table not in EXPORTABLE_TABLES:
        return {'success': False, 'error': f'table not allowed: {table}'}

    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        cur = conn.cursor()
        cur.execute(f"SELECT * FROM {table} LIMIT {limit}")
        rows = [dict(r) for r in cur.fetchall()]

        if not rows:
            return {'success': True, 'csv': '', 'count': 0}

        out = io.StringIO()
        writer = csv.DictWriter(out, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

        return {
            'success': True,
            'csv': out.getvalue(),
            'count': len(rows),
            'table': table,
            'exported_at': datetime.now().isoformat(),
        }
    finally:
        conn.close()


def export_table_json(table: str, limit: int = 10000) -> Dict[str, Any]:
    """테이블 JSON 반환."""
    if table not in EXPORTABLE_TABLES:
        return {'success': False, 'error': f'table not allowed: {table}'}

    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        cur = conn.cursor()
        cur.execute(f"SELECT * FROM {table} LIMIT {limit}")
        rows = [dict(r) for r in cur.fetchall()]
        return {
            'success': True,
            'data': rows,
            'count': len(rows),
            'table': table,
        }
    finally:
        conn.close()


def list_tables() -> Dict[str, Any]:
    """Export 가능 테이블 목록 + 레코드 수."""
    conn = sqlite3.connect(DB_PATH)
    try:
        cur = conn.cursor()
        result = {}
        for t in EXPORTABLE_TABLES:
            try:
                cur.execute(f"SELECT COUNT(*) FROM {t}")
                result[t] = cur.fetchone()[0]
            except Exception:
                result[t] = None
        return {'success': True, 'tables': result}
    finally:
        conn.close()
