"""모델별 마스터 단가표 조회 (Step 37).

bid_cost / auto_rebid 폴백으로 사용.
size=NULL 레코드는 해당 모델의 모든 사이즈에 동일 단가 적용 (가방류 등).
"""

import sqlite3
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent
DB_PATH = str(BASE_DIR / "price_history.db")


def lookup_price(model, size=None):
    """단가표 조회.

    1차: (model, size) 정확 매칭
    2차: (model, size IS NULL) 매칭 (전 사이즈 동일 단가)

    Returns: dict | None
        {cny_price, category, brand, is_bulk_item, notes, source, match_type}
        match_type ∈ {'exact', 'all_sizes'}
    """
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row

    if size is not None:
        row = conn.execute(
            """
            SELECT cny_price, category, brand, is_bulk_item, notes, source,
                   'exact' as match_type
            FROM model_price_book
            WHERE model = ? AND size = ?
            LIMIT 1
            """,
            (model, str(size)),
        ).fetchone()
        if row:
            conn.close()
            return dict(row)

    row = conn.execute(
        """
        SELECT cny_price, category, brand, is_bulk_item, notes, source,
               'all_sizes' as match_type
        FROM model_price_book
        WHERE model = ? AND size IS NULL
        LIMIT 1
        """,
        (model,),
    ).fetchone()

    conn.close()
    return dict(row) if row else None


def upsert_price(model, size, cny_price, **kwargs):
    """등록/수정 (UNIQUE(model, size) 기반)."""
    conn = sqlite3.connect(DB_PATH)
    conn.execute(
        """
        INSERT INTO model_price_book
        (model, size, cny_price, category, brand, is_bulk_item, notes, source, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
        ON CONFLICT(model, size) DO UPDATE SET
            cny_price = excluded.cny_price,
            category = COALESCE(excluded.category, category),
            brand = COALESCE(excluded.brand, brand),
            is_bulk_item = excluded.is_bulk_item,
            notes = COALESCE(excluded.notes, notes),
            source = excluded.source,
            updated_at = CURRENT_TIMESTAMP
        """,
        (
            model,
            str(size) if size else None,
            cny_price,
            kwargs.get("category"),
            kwargs.get("brand"),
            int(kwargs.get("is_bulk_item", 0) or 0),
            kwargs.get("notes"),
            kwargs.get("source", "사장님 직접 입력"),
        ),
    )
    conn.commit()
    conn.close()


def list_all(bulk_only=False):
    """전체 단가표 조회."""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    where = "WHERE is_bulk_item = 1" if bulk_only else ""
    rows = conn.execute(
        f"""
        SELECT * FROM model_price_book {where}
        ORDER BY is_bulk_item DESC, model, size
        """
    ).fetchall()
    conn.close()
    return [dict(r) for r in rows]
