"""
자동 재입찰 백테스트 — Step 45-4.

과거 데이터로 자동 재입찰 시뮬레이션:
- sales_history에서 체결 후 재입찰 가능 시점 식별
- bid_cost와 매칭하여 마진 시뮬
- 6중 안전장치 시뮬레이션 (마진 하한, 쿨다운 등)
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


def simulate_backtest(days: int = 30, min_profit: int = 3000,
                       cooldown_hours: int = 6) -> Dict[str, Any]:
    """
    과거 N일 백테스트.

    sales_history에서 판매 발송완료 건을 후보로:
    - bid_cost로 마진 계산
    - min_profit 통과 여부
    - 같은 (model, size) 쿨다운 체크
    """
    conn = _get_conn()
    try:
        cur = conn.cursor()

        cur.execute(f"""
            SELECT sh.*, bc.cny_price, bc.exchange_rate
            FROM sales_history sh
            LEFT JOIN bid_cost bc ON bc.order_id = sh.order_id
            WHERE sh.ship_status = '판매자 발송완료'
              AND sh.trade_date >= date('now', '-{days} days')
            ORDER BY sh.trade_date ASC
        """)
        candidates = [dict(r) for r in cur.fetchall()]

        result = {
            'days': days,
            'min_profit': min_profit,
            'cooldown_hours': cooldown_hours,
            'total_candidates': len(candidates),
            'go': 0,
            'low': 0,
            'no_cost': 0,
            'cooldown': 0,
            'total_profit': 0.0,
            'samples': [],
        }

        cooldown_map = {}

        for c in candidates:
            key = (c['model'], c['size'])

            if not c['cny_price'] or not c['exchange_rate']:
                result['no_cost'] += 1
                continue

            last = cooldown_map.get(key)
            if last:
                hours_since = (datetime.fromisoformat(c['trade_date']) - last).total_seconds() / 3600
                if hours_since < cooldown_hours:
                    result['cooldown'] += 1
                    continue

            sale_price = c['sale_price'] or 0
            settlement = sale_price * (1 - 0.06 * 1.1) - 2500
            cost = c['cny_price'] * c['exchange_rate'] * 1.03 + 8000
            profit = settlement - cost

            if profit >= min_profit:
                result['go'] += 1
                result['total_profit'] += profit
                cooldown_map[key] = datetime.fromisoformat(c['trade_date'])
                if len(result['samples']) < 20:
                    result['samples'].append({
                        'order_id': c['order_id'],
                        'model': c['model'],
                        'size': c['size'],
                        'sale_price': sale_price,
                        'cost': round(cost, 2),
                        'profit': round(profit, 2),
                        'trade_date': c['trade_date'],
                    })
            else:
                result['low'] += 1

        result['total_profit'] = round(result['total_profit'], 2)
        result['avg_profit'] = round(result['total_profit'] / result['go'], 2) if result['go'] else 0
        return result
    finally:
        conn.close()
