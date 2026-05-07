"""
통합 헤드라인 — Step 47-7.

대시보드 첫 화면용 핵심 KPI:
- 오늘 매출/마진
- 이번 주 누적
- 자동 재입찰 상태
- 미매칭 송금 / 매칭 안 된 입찰
- 데이터 품질 점수
- 시스템 상태
"""
import sqlite3
import os
import json
from typing import Dict, Any
from datetime import datetime

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB_PATH = os.path.join(BASE_DIR, 'price_history.db')
SETTINGS_PATH = os.path.join(BASE_DIR, 'settings.json')


def _get_conn():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.row_factory = sqlite3.Row
    return conn


def get_headline() -> Dict[str, Any]:
    """전체 헤드라인 데이터 한 번에 조회."""
    conn = _get_conn()
    try:
        cur = conn.cursor()

        # 오늘
        cur.execute("""
            SELECT COUNT(*) as cnt, COALESCE(SUM(sale_price), 0) as revenue
            FROM sales_history
            WHERE date(trade_date) = date('now', 'localtime')
              AND ship_status = '판매자 발송완료'
        """)
        today = dict(cur.fetchone())

        # 이번 주
        cur.execute("""
            SELECT COUNT(*) as cnt, COALESCE(SUM(sale_price), 0) as revenue
            FROM sales_history
            WHERE trade_date >= date('now', '-7 days')
              AND ship_status = '판매자 발송완료'
        """)
        this_week = dict(cur.fetchone())

        # 자동 재입찰 오늘
        cur.execute("""
            SELECT COUNT(*) as cnt,
                   COALESCE(SUM(CASE WHEN action = 'auto_modified' THEN expected_profit ELSE 0 END), 0) as profit,
                   SUM(CASE WHEN action = 'auto_modified' THEN 1 ELSE 0 END) as success,
                   SUM(CASE WHEN action = 'modify_failed' THEN 1 ELSE 0 END) as failed
            FROM auto_rebid_log
            WHERE date(executed_at) = date('now', 'localtime')
              AND action NOT LIKE 'dry_run_%'
        """)
        rebid_today = dict(cur.fetchone())

        # 미매칭 송금 (잔액 있는 active)
        cur.execute("""
            SELECT
                COUNT(*) as count,
                COALESCE(SUM(amount_cny - allocated_cny), 0) as remaining_cny
            FROM remittance_history
            WHERE status = 'active'
        """)
        unmatched_rem = dict(cur.fetchone())

        # 미매칭 입찰
        cur.execute("""
            SELECT COUNT(*) as count, COALESCE(SUM(bc.cny_price), 0) as cny
            FROM bid_cost bc
            LEFT JOIN remittance_bid_match rbm ON rbm.order_id = bc.order_id
            WHERE rbm.id IS NULL
        """)
        unmatched_bid = dict(cur.fetchone())

        # 설정
        try:
            with open(SETTINGS_PATH, 'r') as f:
                s = json.load(f)
            rebid_status = {
                'enabled': s.get('auto_rebid_enabled', False),
                'dry_run': s.get('auto_rebid_dry_run', True),
                'daily_max': s.get('auto_rebid_daily_max', 0),
                'min_profit': s.get('auto_rebid_min_profit', 3000),
            }
        except Exception:
            rebid_status = {}

        return {
            'checked_at': datetime.now().isoformat(),
            'today': today,
            'this_week': this_week,
            'rebid_today': rebid_today,
            'rebid_status': rebid_status,
            'unmatched_remittance': unmatched_rem,
            'unmatched_bid': unmatched_bid,
        }
    finally:
        conn.close()
