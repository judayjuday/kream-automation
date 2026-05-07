"""
일일 리포트 자동 발송 — Step 45-3.

매일 23시에 Discord로 자동 재입찰 요약 발송.
- 오늘 실행 건수 (성공/실패)
- 누적 마진
- 실패율
- 모델별 TOP 5
- 비정상 패턴 경고
"""
import sqlite3
import os
import json
import urllib.request
from typing import Dict, List, Any, Optional
from datetime import datetime

DB_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'price_history.db')
SETTINGS_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'settings.json')


def _get_conn():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.row_factory = sqlite3.Row
    return conn


def _load_settings() -> Dict:
    with open(SETTINGS_PATH, 'r') as f:
        return json.load(f)


def build_daily_report() -> Dict[str, Any]:
    """오늘 자동 재입찰 요약 데이터."""
    conn = _get_conn()
    try:
        cur = conn.cursor()

        cur.execute("""
            SELECT
                COUNT(*) as total,
                SUM(CASE WHEN action = 'auto_modified' THEN 1 ELSE 0 END) as success,
                SUM(CASE WHEN action = 'modify_failed' THEN 1 ELSE 0 END) as failed,
                COALESCE(SUM(CASE WHEN action = 'auto_modified' THEN expected_profit ELSE 0 END), 0) as total_profit
            FROM auto_rebid_log
            WHERE date(executed_at) = date('now', 'localtime')
              AND action NOT LIKE 'dry_run_%'
        """)
        today = dict(cur.fetchone())

        fail_rate = 0
        if (today['success'] or 0) + (today['failed'] or 0) > 0:
            fail_rate = round(today['failed'] / (today['success'] + today['failed']) * 100, 2)

        cur.execute("""
            SELECT model, size, COUNT(*) as cnt, COALESCE(SUM(expected_profit), 0) as profit
            FROM auto_rebid_log
            WHERE date(executed_at) = date('now', 'localtime')
              AND action = 'auto_modified'
            GROUP BY model, size
            ORDER BY profit DESC
            LIMIT 5
        """)
        top_models = [dict(r) for r in cur.fetchall()]

        cur.execute("""
            SELECT action, skip_reason, COUNT(*) as cnt
            FROM auto_rebid_log
            WHERE date(executed_at) = date('now', 'localtime')
              AND action LIKE 'skipped_%'
            GROUP BY action, skip_reason
            ORDER BY cnt DESC
            LIMIT 5
        """)
        top_skips = [dict(r) for r in cur.fetchall()]

        warnings = []
        if fail_rate >= 20:
            warnings.append(f'⚠️ 실패율 {fail_rate}% (20% 이상)')

        return {
            'date': datetime.now().strftime('%Y-%m-%d'),
            'today': today,
            'fail_rate_pct': fail_rate,
            'top_models': top_models,
            'top_skips': top_skips,
            'warnings': warnings,
        }
    finally:
        conn.close()


def format_for_discord(report: Dict) -> str:
    today = report['today']
    lines = [
        f"📊 **자동 재입찰 일일 리포트** ({report['date']})",
        "",
        f"실행: 총 **{today['total']}건** (성공 {today['success']} / 실패 {today['failed']})",
        f"누적 마진: **{today['total_profit']:,.0f}원**",
        f"실패율: {report['fail_rate_pct']}%",
        "",
    ]
    if report['warnings']:
        lines.append("**경고**")
        for w in report['warnings']:
            lines.append(f"  {w}")
        lines.append("")
    if report['top_models']:
        lines.append("**TOP 모델 (마진 기준)**")
        for m in report['top_models']:
            lines.append(f"  • {m['model']}/{m['size'] or '-'} — {m['cnt']}건, {m['profit']:,.0f}원")
        lines.append("")
    if report['top_skips']:
        lines.append("**TOP 스킵 사유**")
        for s in report['top_skips']:
            lines.append(f"  • {s['action']} ({s['skip_reason'] or '-'}): {s['cnt']}건")
    return "\n".join(lines)


def send_discord(message: str, webhook_url: Optional[str] = None) -> Dict[str, Any]:
    """Discord webhook 발송."""
    if not webhook_url:
        s = _load_settings()
        webhook_url = s.get('discord_webhook_url') or s.get('discord_webhook')
    if not webhook_url:
        return {'success': False, 'error': 'discord_webhook_url not configured in settings.json'}

    try:
        data = json.dumps({'content': message}).encode('utf-8')
        req = urllib.request.Request(
            webhook_url, data=data,
            headers={'Content-Type': 'application/json'}
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            return {'success': True, 'status': resp.status}
    except Exception as e:
        return {'success': False, 'error': str(e)}


def run_daily_report() -> Dict[str, Any]:
    """리포트 생성 + Discord 발송."""
    report = build_daily_report()
    message = format_for_discord(report)
    discord_result = send_discord(message)
    return {
        'report': report,
        'discord': discord_result,
        'message_preview': message,
    }
