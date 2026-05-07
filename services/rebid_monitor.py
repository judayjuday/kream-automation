"""
자동 재입찰 실시간 모니터링 — Step 45-1.

auto_rebid_log 테이블에서 최근 N시간 통계 집계.
"""
import sqlite3
import os
from typing import Dict, List, Any
from datetime import datetime, timedelta

DB_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'price_history.db')


def _get_conn():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.row_factory = sqlite3.Row
    return conn


def realtime_stats(hours: int = 24) -> Dict[str, Any]:
    """최근 N시간 자동 재입찰 실시간 통계."""
    conn = _get_conn()
    try:
        cur = conn.cursor()

        cur.execute(f"""
            SELECT action, COUNT(*) as cnt
            FROM auto_rebid_log
            WHERE executed_at >= datetime('now', '-{hours} hours')
              AND action NOT LIKE 'dry_run_%'
            GROUP BY action
        """)
        by_action = {r['action']: r['cnt'] for r in cur.fetchall()}

        cur.execute(f"""
            SELECT
                COUNT(*) as success_count,
                COALESCE(SUM(expected_profit), 0) as total_profit,
                COALESCE(AVG(expected_profit), 0) as avg_profit
            FROM auto_rebid_log
            WHERE executed_at >= datetime('now', '-{hours} hours')
              AND action = 'auto_modified'
        """)
        success = dict(cur.fetchone())

        cur.execute(f"""
            SELECT
                COUNT(*) as total,
                SUM(CASE WHEN action = 'modify_failed' THEN 1 ELSE 0 END) as failed
            FROM auto_rebid_log
            WHERE executed_at >= datetime('now', '-{hours} hours')
              AND action IN ('auto_modified', 'modify_failed')
        """)
        rate_row = dict(cur.fetchone())
        fail_rate = round(rate_row['failed'] / rate_row['total'] * 100, 2) if rate_row['total'] > 0 else 0

        cur.execute(f"""
            SELECT
                strftime('%Y-%m-%d %H:00', executed_at) as hour,
                COUNT(*) as cnt,
                SUM(CASE WHEN action = 'auto_modified' THEN 1 ELSE 0 END) as success_cnt,
                SUM(CASE WHEN action = 'modify_failed' THEN 1 ELSE 0 END) as fail_cnt,
                COALESCE(SUM(CASE WHEN action = 'auto_modified' THEN expected_profit ELSE 0 END), 0) as profit
            FROM auto_rebid_log
            WHERE executed_at >= datetime('now', '-{hours} hours')
              AND action NOT LIKE 'dry_run_%'
            GROUP BY hour
            ORDER BY hour DESC
        """)
        hourly = [dict(r) for r in cur.fetchall()]

        return {
            'hours': hours,
            'by_action': by_action,
            'success_count': success['success_count'],
            'total_profit': round(success['total_profit'], 2),
            'avg_profit': round(success['avg_profit'], 2),
            'fail_rate_pct': fail_rate,
            'hourly': hourly,
        }
    finally:
        conn.close()


def model_stats(hours: int = 168) -> List[Dict]:
    """모델별 자동 재입찰 통계 (최근 N시간, 기본 1주)."""
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute(f"""
            SELECT
                model, size,
                COUNT(*) as total_attempts,
                SUM(CASE WHEN action = 'auto_modified' THEN 1 ELSE 0 END) as success,
                SUM(CASE WHEN action = 'modify_failed' THEN 1 ELSE 0 END) as failed,
                COALESCE(SUM(CASE WHEN action = 'auto_modified' THEN expected_profit ELSE 0 END), 0) as total_profit,
                MAX(executed_at) as last_attempt
            FROM auto_rebid_log
            WHERE executed_at >= datetime('now', '-{hours} hours')
              AND action NOT LIKE 'dry_run_%'
            GROUP BY model, size
            ORDER BY total_profit DESC, total_attempts DESC
        """)
        return [dict(r) for r in cur.fetchall()]
    finally:
        conn.close()


def skip_reasons(hours: int = 24) -> List[Dict]:
    """스킵 사유 집계 (LOW / NO_COST / ACTIVE / COOLDOWN 등)."""
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute(f"""
            SELECT
                action, skip_reason, COUNT(*) as cnt
            FROM auto_rebid_log
            WHERE executed_at >= datetime('now', '-{hours} hours')
              AND action LIKE 'skipped_%'
            GROUP BY action, skip_reason
            ORDER BY cnt DESC
        """)
        return [dict(r) for r in cur.fetchall()]
    finally:
        conn.close()


def model_roi_analysis(days: int = 30) -> List[Dict]:
    """
    모델별 ROI 분석:
    - 자동 재입찰 시도 횟수
    - 성공 횟수 + 누적 마진
    - 평균 마진
    - 실패율
    - ROI 점수 (마진 ÷ 시도)
    """
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute(f"""
            SELECT
                model, size,
                COUNT(*) as attempts,
                SUM(CASE WHEN action = 'auto_modified' THEN 1 ELSE 0 END) as success,
                SUM(CASE WHEN action = 'modify_failed' THEN 1 ELSE 0 END) as failed,
                SUM(CASE WHEN action LIKE 'skipped_%' THEN 1 ELSE 0 END) as skipped,
                COALESCE(SUM(CASE WHEN action = 'auto_modified' THEN expected_profit ELSE 0 END), 0) as total_profit,
                COALESCE(AVG(CASE WHEN action = 'auto_modified' THEN expected_profit ELSE NULL END), 0) as avg_profit
            FROM auto_rebid_log
            WHERE executed_at >= datetime('now', '-{days} days')
              AND action NOT LIKE 'dry_run_%'
            GROUP BY model, size
            HAVING attempts >= 1
            ORDER BY total_profit DESC
        """)
        items = []
        for r in cur.fetchall():
            d = dict(r)
            d['fail_rate_pct'] = round(d['failed'] / max(d['success'] + d['failed'], 1) * 100, 2)
            d['success_rate_pct'] = round(d['success'] / max(d['attempts'], 1) * 100, 2)
            d['roi_per_attempt'] = round(d['total_profit'] / max(d['attempts'], 1), 2)
            items.append(d)
        return items
    finally:
        conn.close()


def recent_executions(limit: int = 50) -> List[Dict]:
    """최근 실행 이력 (성공/실패 모두)."""
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute(f"""
            SELECT * FROM auto_rebid_log
            WHERE action NOT LIKE 'dry_run_%'
            ORDER BY executed_at DESC
            LIMIT {limit}
        """)
        return [dict(r) for r in cur.fetchall()]
    finally:
        conn.close()
