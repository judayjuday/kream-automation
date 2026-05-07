"""
비즈니스 인사이트 — Step 47-1.

bid_cost + sales_history + auto_rebid_log 통합 분석:
- 일별/주별/월별 마진 추세
- 카테고리별 수익성
- 협력사별 ROI
- 시장 가격 추적 (47-2에서 확장)

절대 규칙: sales_history는 조회만. 데이터 변경 X.
"""
import sqlite3
import os
from typing import Dict, List, Any, Optional
from datetime import datetime, timedelta

DB_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'price_history.db')


def _get_conn():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.row_factory = sqlite3.Row
    return conn


def margin_trend_daily(days: int = 30) -> List[Dict]:
    """일별 마진 추세 (sales_history 기반)."""
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute(f"""
            SELECT
                date(sh.trade_date) as date,
                COUNT(*) as sales_count,
                SUM(sh.sale_price) as total_revenue,
                COUNT(bc.order_id) as matched_count,
                COALESCE(SUM(bc.cny_price * bc.exchange_rate * 1.03 + 8000), 0) as total_cost,
                COALESCE(SUM(sh.sale_price * (1 - 0.06 * 1.1) - 2500
                       - (bc.cny_price * bc.exchange_rate * 1.03 + 8000)), 0) as total_profit
            FROM sales_history sh
            LEFT JOIN bid_cost bc ON bc.order_id = sh.order_id
            WHERE sh.ship_status = '판매자 발송완료'
              AND sh.trade_date >= date('now', '-{days} days')
            GROUP BY date(sh.trade_date)
            ORDER BY date ASC
        """)
        return [dict(r) for r in cur.fetchall()]
    finally:
        conn.close()


def category_profitability() -> List[Dict]:
    """카테고리별 수익성 (model_price_book.category 기준)."""
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("""
            SELECT
                COALESCE(pb.category, '미분류') as category,
                COUNT(DISTINCT bc.order_id) as bid_count,
                COUNT(DISTINCT sh.order_id) as sale_count,
                COALESCE(AVG(bc.cny_price * bc.exchange_rate), 0) as avg_cost_krw,
                COALESCE(AVG(sh.sale_price), 0) as avg_sale_krw,
                COALESCE(SUM(
                    CASE WHEN sh.order_id IS NOT NULL THEN
                        sh.sale_price * (1 - 0.06 * 1.1) - 2500
                        - (bc.cny_price * bc.exchange_rate * 1.03 + 8000)
                    ELSE 0 END
                ), 0) as total_profit
            FROM bid_cost bc
            LEFT JOIN model_price_book pb ON pb.model = bc.model
            LEFT JOIN sales_history sh ON sh.order_id = bc.order_id AND sh.ship_status = '판매자 발송완료'
            GROUP BY COALESCE(pb.category, '미분류')
            ORDER BY total_profit DESC
        """)
        rows = []
        for r in cur.fetchall():
            d = dict(r)
            d['avg_profit_per_sale'] = round(d['total_profit'] / d['sale_count'], 2) if d['sale_count'] else 0
            d['conversion_rate'] = round(d['sale_count'] / d['bid_count'] * 100, 2) if d['bid_count'] else 0
            rows.append(d)
        return rows
    finally:
        conn.close()


def supplier_roi() -> List[Dict]:
    """협력사별 ROI (송금 KRW 대비 발생 마진)."""
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("""
            SELECT
                rs.id as supplier_id,
                rs.name as supplier_name,
                COUNT(DISTINCT rh.id) as remittance_count,
                COALESCE(SUM(rh.amount_krw), 0) as total_invested_krw,
                COUNT(DISTINCT rbm.bid_cost_id) as matched_bid_count,
                COUNT(DISTINCT sh.order_id) as sold_count,
                COALESCE(SUM(
                    CASE WHEN sh.order_id IS NOT NULL THEN
                        sh.sale_price * (1 - 0.06 * 1.1) - 2500
                        - (bc.cny_price * bc.exchange_rate * 1.03 + 8000)
                    ELSE 0 END
                ), 0) as realized_profit
            FROM remittance_supplier rs
            LEFT JOIN remittance_history rh ON rh.supplier_id = rs.id AND rh.status != 'cancelled'
            LEFT JOIN remittance_bid_match rbm ON rbm.remittance_id = rh.id
            LEFT JOIN bid_cost bc ON bc.order_id = rbm.order_id
            LEFT JOIN sales_history sh ON sh.order_id = rbm.order_id AND sh.ship_status = '판매자 발송완료'
            GROUP BY rs.id, rs.name
            ORDER BY realized_profit DESC
        """)
        rows = []
        for r in cur.fetchall():
            d = dict(r)
            d['roi_pct'] = round(d['realized_profit'] / d['total_invested_krw'] * 100, 2) if d['total_invested_krw'] else 0
            d['sell_through_rate'] = round(d['sold_count'] / d['matched_bid_count'] * 100, 2) if d['matched_bid_count'] else 0
            rows.append(d)
        return rows
    finally:
        conn.close()


def comprehensive_dashboard() -> Dict[str, Any]:
    """종합 비즈니스 대시보드 데이터."""
    return {
        'checked_at': datetime.now().isoformat(),
        'daily_trend_30d': margin_trend_daily(30),
        'category_profitability': category_profitability(),
        'supplier_roi': supplier_roi(),
    }
