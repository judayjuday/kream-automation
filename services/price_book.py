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
    """등록/수정.

    NULL-safe 처리: SQLite UNIQUE는 NULL을 서로 다른 값으로 취급하므로
    ON CONFLICT(model, size)가 size=NULL 케이스를 못 잡음.
    → 명시적으로 SELECT → UPDATE/INSERT 분기.
    """
    size_v = str(size) if size else None
    params = (
        kwargs.get("category"),
        kwargs.get("brand"),
        int(kwargs.get("is_bulk_item", 0) or 0),
        kwargs.get("notes"),
        kwargs.get("source", "사장님 직접 입력"),
        cny_price,
    )

    conn = sqlite3.connect(DB_PATH)
    if size_v is None:
        existing = conn.execute(
            "SELECT id FROM model_price_book WHERE model = ? AND size IS NULL",
            (model,),
        ).fetchone()
    else:
        existing = conn.execute(
            "SELECT id FROM model_price_book WHERE model = ? AND size = ?",
            (model, size_v),
        ).fetchone()

    if existing:
        conn.execute(
            """
            UPDATE model_price_book
            SET cny_price = ?,
                category = COALESCE(?, category),
                brand = COALESCE(?, brand),
                is_bulk_item = ?,
                notes = COALESCE(?, notes),
                source = ?,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = ?
            """,
            (cny_price, params[0], params[1], params[2], params[3], params[4], existing[0]),
        )
    else:
        conn.execute(
            """
            INSERT INTO model_price_book
            (model, size, cny_price, category, brand, is_bulk_item, notes, source, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
            """,
            (model, size_v, cny_price, params[0], params[1], params[2], params[3], params[4]),
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


# ============================================================
# Step 43-7: CSV 일괄 업로드
# ============================================================
import csv
import io
from typing import Dict, Any


def bulk_upsert_from_csv(csv_text: str) -> Dict[str, Any]:
    """
    CSV 일괄 업로드 (UPSERT).

    필수 컬럼: model, cny_price
    선택 컬럼: size, category, brand, is_bulk_item, notes, source

    절대 규칙 #7: 인보이스 단가 자동 시드 금지.
    이 함수는 사장님이 검증한 단가만 입력하는 용도.
    """
    reader = csv.DictReader(io.StringIO(csv_text))
    inserted = 0
    updated = 0
    errors = []

    conn = sqlite3.connect(DB_PATH)
    try:
        cur = conn.cursor()
        for line_no, row in enumerate(reader, start=2):
            try:
                model = (row.get('model') or '').strip()
                cny_str = (row.get('cny_price') or '').strip()
                if not model or not cny_str:
                    errors.append(f'L{line_no}: model/cny_price 필수')
                    continue
                cny = float(cny_str)
                if cny <= 0:
                    errors.append(f'L{line_no}: cny_price > 0')
                    continue

                size = (row.get('size') or '').strip() or None
                category = (row.get('category') or '').strip() or None
                brand = (row.get('brand') or '').strip() or None
                is_bulk = 1 if (row.get('is_bulk_item') or '').strip().lower() in ('1','true','y','yes') else 0
                notes = (row.get('notes') or '').strip() or None
                source = (row.get('source') or '').strip() or '사장님 일괄 입력 (CSV)'

                # NULL-safe UPSERT (size NULL 처리)
                if size is None:
                    cur.execute("""
                        SELECT id FROM model_price_book WHERE model = ? AND size IS NULL
                    """, (model,))
                else:
                    cur.execute("""
                        SELECT id FROM model_price_book WHERE model = ? AND size = ?
                    """, (model, size))
                existing = cur.fetchone()
                if existing:
                    cur.execute("""
                        UPDATE model_price_book
                        SET cny_price = ?, category = ?, brand = ?,
                            is_bulk_item = ?, notes = ?, source = ?,
                            updated_at = CURRENT_TIMESTAMP
                        WHERE id = ?
                    """, (cny, category, brand, is_bulk, notes, source, existing[0]))
                    updated += 1
                else:
                    cur.execute("""
                        INSERT INTO model_price_book
                        (model, size, cny_price, category, brand, is_bulk_item, notes, source, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                    """, (model, size, cny, category, brand, is_bulk, notes, source))
                    inserted += 1
            except Exception as e:
                errors.append(f'L{line_no}: {e}')

        conn.commit()
    finally:
        conn.close()

    return {
        'success': True,
        'inserted': inserted,
        'updated': updated,
        'errors': errors[:20],
        'total_errors': len(errors),
    }
