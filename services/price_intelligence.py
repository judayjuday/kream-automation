"""
단가표 인텔리전스 — Step 46-2.

bid_cost와 model_price_book에서 패턴 학습:
- 같은 brand/category 평균
- 모델명 prefix 매칭
- 시간 기반 가격 변동 추적

절대 규칙 #1: 추정값은 'estimated' 플래그 명시. 자동 시드 금지.
절대 규칙 #7: 인보이스 단가 사용 금지.
"""
import sqlite3
import os
import re
from typing import Dict, List, Any, Optional
from datetime import datetime

DB_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'price_history.db')


def _get_conn():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.row_factory = sqlite3.Row
    return conn


def estimate_price_for_model(model: str, size: Optional[str] = None) -> Dict[str, Any]:
    """
    특정 모델의 단가 추정 (bid_cost + price_book 통합).

    추정 전략 (우선순위):
    1. bid_cost (model, size) 정확 → 평균
    2. price_book (model, size) 또는 (model, NULL)
    3. bid_cost (model만) 평균
    4. 같은 prefix 모델군 평균 (예: 1203A243-021 → 1203A243-* 평균)

    Returns:
        {
            'estimated_cny': float | None,
            'confidence': 'exact' | 'model_avg' | 'prefix_avg' | 'none',
            'sample_size': int,
            'sources': [...]
        }
    """
    conn = _get_conn()
    try:
        cur = conn.cursor()

        # 1. bid_cost 정확 매칭
        if size:
            cur.execute("""
                SELECT cny_price FROM bid_cost
                WHERE model = ? AND size = ? AND cny_price > 0
            """, (model, size))
        else:
            cur.execute("""
                SELECT cny_price FROM bid_cost
                WHERE model = ? AND cny_price > 0
            """, (model,))
        rows = [r['cny_price'] for r in cur.fetchall()]
        if rows:
            return {
                'estimated_cny': round(sum(rows) / len(rows), 2),
                'min_cny': min(rows),
                'max_cny': max(rows),
                'confidence': 'exact',
                'sample_size': len(rows),
                'source': 'bid_cost (model+size 정확)' if size else 'bid_cost (model 정확)',
            }

        # 2. price_book
        cur.execute("""
            SELECT cny_price FROM model_price_book
            WHERE model = ? AND (size = ? OR size IS NULL)
            ORDER BY (size = ?) DESC
            LIMIT 1
        """, (model, size, size))
        pb = cur.fetchone()
        if pb:
            return {
                'estimated_cny': pb['cny_price'],
                'confidence': 'price_book',
                'sample_size': 1,
                'source': 'model_price_book',
            }

        # 3. 같은 모델 다른 사이즈 (size 지정한 경우만)
        if size:
            cur.execute("""
                SELECT cny_price FROM bid_cost
                WHERE model = ? AND cny_price > 0
            """, (model,))
            rows = [r['cny_price'] for r in cur.fetchall()]
            if rows:
                return {
                    'estimated_cny': round(sum(rows) / len(rows), 2),
                    'min_cny': min(rows),
                    'max_cny': max(rows),
                    'confidence': 'model_avg',
                    'sample_size': len(rows),
                    'source': 'bid_cost (같은 모델 다른 사이즈)',
                }

        # 4. prefix 매칭 (예: 1203A243-021 → 1203A243)
        prefix = re.split(r'[-_]', model)[0]
        if len(prefix) >= 4:  # 너무 짧은 prefix 제외
            cur.execute("""
                SELECT cny_price FROM bid_cost
                WHERE model LIKE ? AND cny_price > 0
            """, (f'{prefix}%',))
            rows = [r['cny_price'] for r in cur.fetchall()]
            if len(rows) >= 3:  # 최소 3건
                return {
                    'estimated_cny': round(sum(rows) / len(rows), 2),
                    'min_cny': min(rows),
                    'max_cny': max(rows),
                    'confidence': 'prefix_avg',
                    'sample_size': len(rows),
                    'source': f'bid_cost (prefix {prefix}* 평균)',
                }

        return {
            'estimated_cny': None,
            'confidence': 'none',
            'sample_size': 0,
            'source': '추정 데이터 없음',
        }
    finally:
        conn.close()


def find_models_without_pricebook() -> List[Dict]:
    """
    bid_cost에 있지만 model_price_book에는 없는 모델.
    사장님이 수동으로 등록 검토할 후보.
    """
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("""
            SELECT bc.model, bc.size, COUNT(*) as bid_count,
                   AVG(bc.cny_price) as avg_cny,
                   MIN(bc.cny_price) as min_cny,
                   MAX(bc.cny_price) as max_cny,
                   MAX(bc.created_at) as last_bid
            FROM bid_cost bc
            LEFT JOIN model_price_book pb
                ON pb.model = bc.model
                AND (pb.size = bc.size OR pb.size IS NULL)
            WHERE pb.id IS NULL
            GROUP BY bc.model, bc.size
            ORDER BY bid_count DESC, avg_cny DESC
        """)
        return [dict(r) for r in cur.fetchall()]
    finally:
        conn.close()


def price_change_history(model: str) -> Dict[str, Any]:
    """
    특정 모델의 가격 변동 이력 (bid_cost 시계열).
    인플레이션, 협력사 단가 인상 추적.
    """
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("""
            SELECT order_id, size, cny_price, exchange_rate, created_at
            FROM bid_cost
            WHERE model = ? AND cny_price > 0
            ORDER BY created_at ASC
        """, (model,))
        rows = [dict(r) for r in cur.fetchall()]

        if not rows:
            return {'model': model, 'history': [], 'change_pct': None}

        first_price = rows[0]['cny_price']
        last_price = rows[-1]['cny_price']
        change_pct = round((last_price - first_price) / first_price * 100, 2) if first_price > 0 else 0

        return {
            'model': model,
            'history': rows,
            'first_price': first_price,
            'last_price': last_price,
            'change_pct': change_pct,
            'sample_count': len(rows),
            'first_date': rows[0]['created_at'],
            'last_date': rows[-1]['created_at'],
        }
    finally:
        conn.close()
