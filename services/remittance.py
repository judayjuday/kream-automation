"""
송금 환율 시스템 — Step 42

핵심 책임:
1. 송금 이력 CRUD
2. bid_cost ↔ remittance 매칭 (FIFO 자동 / 수동)
3. 매칭된 입찰의 환율 조회 (마진 재계산용)

환율 폴백 체인 (calc_expected_profit에서 사용):
1. remittance_bid_match → remittance.exchange_rate  ← 신규 최우선
2. bid_cost.exchange_rate
3. settings.exchange_rate
4. 217 (안전 폴백)
"""
import sqlite3
import os
import hashlib
import shutil
import json
from pathlib import Path
from datetime import datetime
from typing import Optional, List, Dict, Any

DB_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'price_history.db')


def _get_conn():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.row_factory = sqlite3.Row
    return conn


# ============================================================
# 송금 CRUD
# ============================================================

def add_remittance(
    remittance_date: str,
    amount_cny: float,
    amount_krw: float,
    supplier: Optional[str] = None,
    wechat_id: Optional[str] = None,
    fee_krw: float = 0,
    notes: Optional[str] = None,
) -> Dict[str, Any]:
    """
    송금 이력 등록.
    exchange_rate는 amount_krw / amount_cny로 자동 계산.

    절대 규칙 #1 준수: 가짜 값 사용 금지. amount_cny=0이면 거부.
    """
    if amount_cny <= 0:
        return {'success': False, 'error': 'amount_cny must be > 0'}
    if amount_krw <= 0:
        return {'success': False, 'error': 'amount_krw must be > 0'}

    exchange_rate = round(amount_krw / amount_cny, 4)

    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("""
            INSERT INTO remittance_history
            (remittance_date, amount_cny, amount_krw, exchange_rate,
             supplier, wechat_id, fee_krw, notes)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, (remittance_date, amount_cny, amount_krw, exchange_rate,
              supplier, wechat_id, fee_krw, notes))
        conn.commit()
        new_id = cur.lastrowid
        return {
            'success': True,
            'id': new_id,
            'exchange_rate': exchange_rate,
            'message': f'송금 등록 완료 (id={new_id}, 환율={exchange_rate})'
        }
    except Exception as e:
        conn.rollback()
        return {'success': False, 'error': str(e)}
    finally:
        conn.close()


def list_remittances(limit: int = 50, status: Optional[str] = None) -> List[Dict]:
    """송금 이력 목록."""
    conn = _get_conn()
    try:
        cur = conn.cursor()
        if status:
            cur.execute("""
                SELECT * FROM remittance_history
                WHERE status = ?
                ORDER BY remittance_date DESC, id DESC
                LIMIT ?
            """, (status, limit))
        else:
            cur.execute("""
                SELECT * FROM remittance_history
                ORDER BY remittance_date DESC, id DESC
                LIMIT ?
            """, (limit,))
        return [dict(r) for r in cur.fetchall()]
    finally:
        conn.close()


def get_remittance(remittance_id: int) -> Optional[Dict]:
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("SELECT * FROM remittance_history WHERE id = ?", (remittance_id,))
        r = cur.fetchone()
        return dict(r) if r else None
    finally:
        conn.close()


# ============================================================
# 매칭 로직
# ============================================================

def get_unmatched_bids() -> List[Dict]:
    """
    매칭되지 않은 bid_cost 목록.
    remittance_bid_match에 없거나, 부분 매칭만 된 건 포함.
    """
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("PRAGMA table_info(bid_cost)")
        cols = {c[1] for c in cur.fetchall()}
        has_id = 'id' in cols

        if has_id:
            cur.execute("""
                SELECT bc.id as bid_cost_id, bc.order_id, bc.model, bc.size,
                       bc.cny_price, bc.exchange_rate, bc.created_at,
                       COALESCE(SUM(rbm.allocated_cny), 0) as matched_cny
                FROM bid_cost bc
                LEFT JOIN remittance_bid_match rbm ON rbm.bid_cost_id = bc.id
                GROUP BY bc.id
                HAVING matched_cny < bc.cny_price
                ORDER BY bc.created_at ASC
            """)
        else:
            cur.execute("""
                SELECT bc.rowid as bid_cost_id, bc.order_id, bc.model, bc.size,
                       bc.cny_price, bc.exchange_rate, bc.created_at,
                       COALESCE(SUM(rbm.allocated_cny), 0) as matched_cny
                FROM bid_cost bc
                LEFT JOIN remittance_bid_match rbm ON rbm.order_id = bc.order_id
                GROUP BY bc.order_id
                HAVING matched_cny < bc.cny_price
                ORDER BY bc.created_at ASC
            """)
        return [dict(r) for r in cur.fetchall()]
    finally:
        conn.close()


def match_bid_to_remittance(
    remittance_id: int,
    bid_cost_id: int,
    order_id: Optional[str] = None,
    allocated_cny: Optional[float] = None,
    method: str = 'manual'
) -> Dict[str, Any]:
    """
    특정 송금에 입찰 매칭.
    allocated_cny=None이면 bid_cost.cny_price 전액 매칭.
    """
    conn = _get_conn()
    try:
        cur = conn.cursor()

        cur.execute("SELECT * FROM remittance_history WHERE id = ?", (remittance_id,))
        rem = cur.fetchone()
        if not rem:
            return {'success': False, 'error': f'remittance {remittance_id} not found'}
        if rem['status'] != 'active':
            return {'success': False, 'error': f'remittance status={rem["status"]}'}

        remaining = rem['amount_cny'] - rem['allocated_cny']
        if remaining <= 0:
            return {'success': False, 'error': 'remittance fully allocated'}

        cur.execute("PRAGMA table_info(bid_cost)")
        cols = {c[1] for c in cur.fetchall()}
        has_id = 'id' in cols

        if has_id:
            cur.execute("SELECT * FROM bid_cost WHERE id = ?", (bid_cost_id,))
        else:
            if not order_id:
                return {'success': False, 'error': 'order_id required when bid_cost has no id'}
            cur.execute("SELECT rowid, * FROM bid_cost WHERE order_id = ?", (order_id,))

        bid = cur.fetchone()
        if not bid:
            return {'success': False, 'error': 'bid_cost not found'}

        if allocated_cny is None:
            allocated_cny = bid['cny_price']
        if allocated_cny > remaining:
            return {'success': False,
                    'error': f'allocated_cny {allocated_cny} > remaining {remaining}'}

        order_id_val = order_id or bid['order_id']
        bid_id_val = bid['id'] if has_id else bid['rowid']

        try:
            cur.execute("""
                INSERT INTO remittance_bid_match
                (remittance_id, bid_cost_id, order_id, allocated_cny, match_method)
                VALUES (?, ?, ?, ?, ?)
            """, (remittance_id, bid_id_val, order_id_val, allocated_cny, method))
        except sqlite3.IntegrityError:
            return {'success': False, 'error': 'already matched'}

        new_allocated = rem['allocated_cny'] + allocated_cny
        new_status = 'depleted' if new_allocated >= rem['amount_cny'] - 0.01 else 'active'
        cur.execute("""
            UPDATE remittance_history
            SET allocated_cny = ?, status = ?, updated_at = CURRENT_TIMESTAMP
            WHERE id = ?
        """, (new_allocated, new_status, remittance_id))

        conn.commit()
        return {
            'success': True,
            'remittance_id': remittance_id,
            'bid_cost_id': bid_id_val,
            'order_id': order_id_val,
            'allocated_cny': allocated_cny,
            'remittance_status': new_status,
        }
    except Exception as e:
        conn.rollback()
        return {'success': False, 'error': str(e)}
    finally:
        conn.close()


def auto_match_fifo(max_matches: int = 100) -> Dict[str, Any]:
    """
    FIFO 자동 매칭:
    - 가장 오래된 active 송금부터
    - 가장 오래된 미매칭 입찰부터 순서대로 할당
    - 송금 잔액 소진 시 다음 송금으로
    """
    matched = 0
    skipped = 0
    errors = []

    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, amount_cny, allocated_cny FROM remittance_history
            WHERE status = 'active'
            ORDER BY remittance_date ASC, id ASC
        """)
        remittances = [dict(r) for r in cur.fetchall()]
    finally:
        conn.close()

    if not remittances:
        return {'success': True, 'matched': 0, 'message': 'no active remittance'}

    unmatched = get_unmatched_bids()
    if not unmatched:
        return {'success': True, 'matched': 0, 'message': 'no unmatched bids'}

    rem_idx = 0
    rem = remittances[rem_idx]
    rem_remaining = rem['amount_cny'] - rem['allocated_cny']

    for bid in unmatched:
        if matched >= max_matches:
            break

        bid_remaining_cny = bid['cny_price'] - bid['matched_cny']
        if bid_remaining_cny <= 0:
            continue

        while rem_remaining < bid_remaining_cny and rem_idx < len(remittances) - 1:
            rem_idx += 1
            rem = remittances[rem_idx]
            rem_remaining = rem['amount_cny'] - rem['allocated_cny']

        if rem_remaining < bid_remaining_cny:
            if rem_remaining > 0:
                result = match_bid_to_remittance(
                    rem['id'], bid['bid_cost_id'], bid['order_id'],
                    rem_remaining, 'fifo_auto'
                )
                if result['success']:
                    matched += 1
                    rem_remaining = 0
                else:
                    errors.append(result['error'])
            skipped += 1
            continue

        result = match_bid_to_remittance(
            rem['id'], bid['bid_cost_id'], bid['order_id'],
            bid_remaining_cny, 'fifo_auto'
        )
        if result['success']:
            matched += 1
            rem_remaining -= bid_remaining_cny
        else:
            errors.append(result['error'])

    return {
        'success': True,
        'matched': matched,
        'skipped': skipped,
        'errors': errors[:10],
        'message': f'FIFO 매칭 {matched}건 완료, {skipped}건 스킵'
    }


def auto_match_supplier_aware(
    supplier_id: Optional[int] = None,
    max_matches: int = 100
) -> Dict[str, Any]:
    """
    협력사 인지 매칭 (Step 43-3).
    - supplier_id 지정: 해당 협력사 송금 → 모든 미매칭 입찰 (FIFO)
    - supplier_id 미지정: 협력사 있는 송금부터 우선 처리, 협력사 없는 송금은 후순위
    """
    matched = 0
    skipped = 0
    errors = []

    conn = _get_conn()
    try:
        cur = conn.cursor()
        if supplier_id:
            cur.execute("""
                SELECT id, amount_cny, allocated_cny, supplier_id FROM remittance_history
                WHERE status = 'active' AND supplier_id = ?
                ORDER BY remittance_date ASC, id ASC
            """, (supplier_id,))
        else:
            # 협력사 있는 것 우선
            cur.execute("""
                SELECT id, amount_cny, allocated_cny, supplier_id FROM remittance_history
                WHERE status = 'active'
                ORDER BY (supplier_id IS NULL) ASC, remittance_date ASC, id ASC
            """)
        remittances = [dict(r) for r in cur.fetchall()]
    finally:
        conn.close()

    if not remittances:
        return {'success': True, 'matched': 0, 'message': 'no active remittance'}

    unmatched = get_unmatched_bids()
    if not unmatched:
        return {'success': True, 'matched': 0, 'message': 'no unmatched bids'}

    rem_idx = 0
    rem = remittances[rem_idx]
    rem_remaining = rem['amount_cny'] - rem['allocated_cny']

    for bid in unmatched:
        if matched >= max_matches:
            break
        bid_remaining = bid['cny_price'] - bid['matched_cny']
        if bid_remaining <= 0:
            continue

        while rem_remaining < bid_remaining and rem_idx < len(remittances) - 1:
            rem_idx += 1
            rem = remittances[rem_idx]
            rem_remaining = rem['amount_cny'] - rem['allocated_cny']

        if rem_remaining < bid_remaining:
            if rem_remaining > 0:
                result = match_bid_to_remittance(
                    rem['id'], bid['bid_cost_id'], bid['order_id'],
                    rem_remaining, 'supplier_aware_partial'
                )
                if result['success']:
                    matched += 1
                    rem_remaining = 0
                else:
                    errors.append(result['error'])
            skipped += 1
            continue

        result = match_bid_to_remittance(
            rem['id'], bid['bid_cost_id'], bid['order_id'],
            bid_remaining, 'supplier_aware_fifo'
        )
        if result['success']:
            matched += 1
            rem_remaining -= bid_remaining
        else:
            errors.append(result['error'])

    return {
        'success': True,
        'matched': matched,
        'skipped': skipped,
        'errors': errors[:10],
        'method': 'supplier_aware',
        'message': f'협력사 인지 매칭 {matched}건 완료, {skipped}건 스킵'
    }


# ============================================================
# 환율 조회 (마진 재계산용)
# ============================================================

def get_matched_exchange_rate(order_id: str) -> Optional[float]:
    """
    특정 입찰의 매칭된 송금 환율 조회.
    여러 송금에 분할 매칭된 경우 가중평균 환율 반환.
    매칭 없으면 None.
    """
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("""
            SELECT rh.exchange_rate, rbm.allocated_cny
            FROM remittance_bid_match rbm
            JOIN remittance_history rh ON rh.id = rbm.remittance_id
            WHERE rbm.order_id = ?
        """, (order_id,))
        rows = cur.fetchall()
        if not rows:
            return None

        total_cny = sum(r['allocated_cny'] for r in rows)
        if total_cny <= 0:
            return None

        weighted = sum(r['exchange_rate'] * r['allocated_cny'] for r in rows)
        return round(weighted / total_cny, 4)
    finally:
        conn.close()


# ============================================================
# 통계
# ============================================================

def get_summary() -> Dict[str, Any]:
    """송금 + 매칭 요약."""
    conn = _get_conn()
    try:
        cur = conn.cursor()

        cur.execute("""
            SELECT COUNT(*) as cnt,
                   COALESCE(SUM(amount_cny), 0) as total_cny,
                   COALESCE(SUM(amount_krw), 0) as total_krw,
                   COALESCE(SUM(allocated_cny), 0) as allocated_cny
            FROM remittance_history WHERE status != 'cancelled'
        """)
        rem = dict(cur.fetchone())

        unmatched = get_unmatched_bids()
        unmatched_cny = sum(b['cny_price'] - b['matched_cny'] for b in unmatched)

        return {
            'remittance_count': rem['cnt'],
            'total_remittance_cny': rem['total_cny'],
            'total_remittance_krw': rem['total_krw'],
            'allocated_cny': rem['allocated_cny'],
            'remaining_cny': rem['total_cny'] - rem['allocated_cny'],
            'unmatched_bid_count': len(unmatched),
            'unmatched_bid_cny': round(unmatched_cny, 2),
        }
    finally:
        conn.close()


# ============================================================
# Step 42-Phase 2.5: 영수증 파일 + USD 송금 + 협력사
# ============================================================

RECEIPTS_BASE = Path(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))) / 'receipts'
UPLOAD_LOG = RECEIPTS_BASE / '.metadata' / 'upload_log.jsonl'


def _ensure_receipts_dirs():
    """영수증 디렉토리 보장."""
    (RECEIPTS_BASE / '.metadata').mkdir(parents=True, exist_ok=True)


def _compute_sha256(file_path: Path) -> str:
    """파일 SHA256 해시 계산 (무결성 검증용)."""
    h = hashlib.sha256()
    with open(file_path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()


def save_receipt_file(temp_path: str, original_name: str, transaction_no: str = None) -> Dict[str, Any]:
    """
    임시 업로드된 영수증 파일을 영구 위치로 이동.
    구조: receipts/YYYY/MM/<transaction_no>_<timestamp>_<safe_name>

    절대 규칙: 기존 파일 덮어쓰기 금지. 같은 이름 있으면 timestamp suffix.
    """
    _ensure_receipts_dirs()
    src = Path(temp_path)
    if not src.exists():
        return {'success': False, 'error': f'temp file not found: {temp_path}'}

    now = datetime.now()
    year_month_dir = RECEIPTS_BASE / f"{now.year:04d}" / f"{now.month:02d}"
    year_month_dir.mkdir(parents=True, exist_ok=True)

    # 파일명 안전화 (공백/특수문자 제거)
    safe_name = ''.join(c if c.isalnum() or c in '._-' else '_' for c in original_name)
    timestamp = now.strftime('%Y%m%d_%H%M%S')
    txn_prefix = f"{transaction_no}_" if transaction_no else ""
    filename = f"{txn_prefix}{timestamp}_{safe_name}"

    dst = year_month_dir / filename
    # 충돌 방지
    counter = 1
    while dst.exists():
        dst = year_month_dir / f"{txn_prefix}{timestamp}_{counter}_{safe_name}"
        counter += 1

    shutil.copy2(str(src), str(dst))
    sha256 = _compute_sha256(dst)
    rel_path = str(dst.relative_to(RECEIPTS_BASE.parent))  # kream_automation 기준

    # 업로드 로그 (영구 기록 — 절대 삭제 금지)
    log_entry = {
        'timestamp': now.isoformat(),
        'original_name': original_name,
        'saved_path': rel_path,
        'sha256': sha256,
        'size_bytes': dst.stat().st_size,
        'transaction_no': transaction_no,
    }
    with open(UPLOAD_LOG, 'a', encoding='utf-8') as f:
        f.write(json.dumps(log_entry, ensure_ascii=False) + '\n')

    return {
        'success': True,
        'path': rel_path,
        'sha256': sha256,
        'size_bytes': dst.stat().st_size,
        'original_name': original_name,
    }


def verify_receipt_integrity(remittance_id: int) -> Dict[str, Any]:
    """저장된 영수증 SHA256 검증 (변조 감지)."""
    rem = get_remittance(remittance_id)
    if not rem:
        return {'success': False, 'error': 'remittance not found'}
    if not rem.get('receipt_path'):
        return {'success': False, 'error': 'no receipt attached'}

    full_path = RECEIPTS_BASE.parent / rem['receipt_path']
    if not full_path.exists():
        return {'success': False, 'error': 'file missing on disk', 'path': rem['receipt_path']}

    actual = _compute_sha256(full_path)
    expected = rem.get('receipt_sha256')
    return {
        'success': actual == expected,
        'expected': expected,
        'actual': actual,
        'path': rem['receipt_path'],
        'match': actual == expected,
    }


def add_remittance_v2(
    remittance_date: str,
    received_cny: float,                  # 협력사 실제 입금 CNY (사장님 확인값)
    amount_krw: float,                    # 한국 출금 KRW
    send_currency: str = 'CNY',           # CNY / USD
    send_amount: Optional[float] = None,  # USD 송금이면 USD 금액
    send_fx_rate: Optional[float] = None, # 영수증 FX Rate
    sender_service: Optional[str] = None, # SentBiz / KB / Wise
    transaction_no: Optional[str] = None,
    supplier_id: Optional[int] = None,
    supplier: Optional[str] = None,       # 레거시 호환
    wechat_id: Optional[str] = None,
    fee_krw: float = 0,
    notes: Optional[str] = None,
    receipt_path: Optional[str] = None,
    receipt_original_name: Optional[str] = None,
    receipt_sha256: Optional[str] = None,
) -> Dict[str, Any]:
    """
    USD 경유 송금 + 영수증 첨부 지원 v2.

    환율(exchange_rate, KRW/CNY)은 amount_krw / received_cny로 자동 계산.
    이게 진짜 원가 환율 (USD 경유여도 협력사 받은 CNY 기준).
    """
    # 절대 규칙 #1: 가짜 값 금지
    if received_cny <= 0:
        return {'success': False, 'error': 'received_cny must be > 0 (협력사 입금 CNY 필수)'}
    if amount_krw <= 0:
        return {'success': False, 'error': 'amount_krw must be > 0'}
    if send_currency not in ('CNY', 'USD'):
        return {'success': False, 'error': 'send_currency must be CNY or USD'}

    exchange_rate = round(amount_krw / received_cny, 4)
    cny_confirmed_at = datetime.now().isoformat() if received_cny > 0 else None
    receipt_uploaded_at = datetime.now().isoformat() if receipt_path else None

    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("""
            INSERT INTO remittance_history
            (remittance_date, amount_cny, amount_krw, exchange_rate,
             supplier, wechat_id, fee_krw, notes,
             send_currency, send_amount, send_fx_rate, received_cny, cny_confirmed_at,
             sender_service, transaction_no, supplier_id,
             receipt_path, receipt_original_name, receipt_sha256, receipt_uploaded_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            remittance_date, received_cny, amount_krw, exchange_rate,
            supplier, wechat_id, fee_krw, notes,
            send_currency, send_amount, send_fx_rate, received_cny, cny_confirmed_at,
            sender_service, transaction_no, supplier_id,
            receipt_path, receipt_original_name, receipt_sha256, receipt_uploaded_at,
        ))
        conn.commit()
        new_id = cur.lastrowid
        return {
            'success': True,
            'id': new_id,
            'exchange_rate': exchange_rate,
            'message': f'송금 등록 완료 (id={new_id}, 환율={exchange_rate}, 통화={send_currency})'
        }
    except Exception as e:
        conn.rollback()
        return {'success': False, 'error': str(e)}
    finally:
        conn.close()


# ----- 협력사 마스터 -----

def list_suppliers() -> List[Dict]:
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("SELECT * FROM remittance_supplier ORDER BY name")
        return [dict(r) for r in cur.fetchall()]
    finally:
        conn.close()


def add_supplier(name: str, name_en: Optional[str] = None,
                 wechat_id: Optional[str] = None, bank_account: Optional[str] = None,
                 default_currency: str = 'CNY', notes: Optional[str] = None) -> Dict[str, Any]:
    if not name:
        return {'success': False, 'error': 'name required'}
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("""
            INSERT INTO remittance_supplier (name, name_en, wechat_id, bank_account, default_currency, notes)
            VALUES (?, ?, ?, ?, ?, ?)
        """, (name, name_en, wechat_id, bank_account, default_currency, notes))
        conn.commit()
        return {'success': True, 'id': cur.lastrowid}
    except sqlite3.IntegrityError:
        return {'success': False, 'error': 'supplier name already exists'}
    except Exception as e:
        conn.rollback()
        return {'success': False, 'error': str(e)}
    finally:
        conn.close()


# ============================================================
# Step 42-Phase 2.6: 다중 영수증 첨부
# ============================================================

def list_receipts(remittance_id: int) -> List[Dict]:
    """특정 송금의 영수증 목록 (오래된 순)."""
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("""
            SELECT * FROM remittance_receipt
            WHERE remittance_id = ?
            ORDER BY uploaded_at ASC, id ASC
        """, (remittance_id,))
        return [dict(r) for r in cur.fetchall()]
    finally:
        conn.close()


def attach_receipt(
    remittance_id: int,
    receipt_path: str,
    original_name: Optional[str] = None,
    sha256: Optional[str] = None,
    size_bytes: Optional[int] = None,
    receipt_type: str = 'other',
    description: Optional[str] = None,
) -> Dict[str, Any]:
    """
    송금에 영수증 1개 추가 첨부.

    receipt_type:
      - 'send'    : 송금증 (SentBiz 등 한국 측)
      - 'arrival' : 협력사 입금 명세서 (인보이스)
      - 'invoice' : 별도 인보이스/세금계산서
      - 'other'   : 기타
    """
    if receipt_type not in ('send', 'arrival', 'invoice', 'other'):
        return {'success': False, 'error': f'invalid receipt_type: {receipt_type}'}

    conn = _get_conn()
    try:
        cur = conn.cursor()
        # 송금 존재 확인
        cur.execute("SELECT 1 FROM remittance_history WHERE id = ?", (remittance_id,))
        if not cur.fetchone():
            return {'success': False, 'error': f'remittance {remittance_id} not found'}

        cur.execute("""
            INSERT INTO remittance_receipt
            (remittance_id, receipt_type, receipt_path, original_name, sha256,
             size_bytes, description)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, (remittance_id, receipt_type, receipt_path, original_name, sha256,
              size_bytes, description))
        conn.commit()
        return {
            'success': True,
            'id': cur.lastrowid,
            'remittance_id': remittance_id,
            'receipt_type': receipt_type,
        }
    except Exception as e:
        conn.rollback()
        return {'success': False, 'error': str(e)}
    finally:
        conn.close()


def get_receipt(receipt_id: int) -> Optional[Dict]:
    """영수증 1건 조회."""
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("SELECT * FROM remittance_receipt WHERE id = ?", (receipt_id,))
        r = cur.fetchone()
        return dict(r) if r else None
    finally:
        conn.close()


def delete_receipt(receipt_id: int) -> Dict[str, Any]:
    """
    영수증 메타데이터 삭제 (DB만, 파일은 보존).
    절대 규칙 #2/#3: 데이터 영구 삭제는 신중히. 파일은 receipts/ 에 그대로 보존.
    """
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("SELECT * FROM remittance_receipt WHERE id = ?", (receipt_id,))
        r = cur.fetchone()
        if not r:
            return {'success': False, 'error': 'receipt not found'}

        cur.execute("DELETE FROM remittance_receipt WHERE id = ?", (receipt_id,))
        conn.commit()
        return {
            'success': True,
            'message': f'영수증 메타 삭제 완료 (파일은 receipts/{r["receipt_path"]} 보존)',
            'preserved_file': r['receipt_path'],
        }
    except Exception as e:
        conn.rollback()
        return {'success': False, 'error': str(e)}
    finally:
        conn.close()


def update_received_cny(remittance_id: int, received_cny: float) -> Dict[str, Any]:
    """
    USD 송금 후 협력사로부터 CNY 입금 확인되면 호출.
    환율 재계산 + cny_confirmed_at 갱신.
    """
    if received_cny <= 0:
        return {'success': False, 'error': 'received_cny must be > 0'}

    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("SELECT amount_krw FROM remittance_history WHERE id = ?", (remittance_id,))
        row = cur.fetchone()
        if not row:
            return {'success': False, 'error': 'remittance not found'}

        new_rate = round(row['amount_krw'] / received_cny, 4)
        now = datetime.now().isoformat()
        cur.execute("""
            UPDATE remittance_history
            SET received_cny = ?, amount_cny = ?, exchange_rate = ?,
                cny_confirmed_at = ?, updated_at = CURRENT_TIMESTAMP
            WHERE id = ?
        """, (received_cny, received_cny, new_rate, now, remittance_id))
        conn.commit()
        return {
            'success': True,
            'id': remittance_id,
            'received_cny': received_cny,
            'exchange_rate': new_rate,
        }
    except Exception as e:
        conn.rollback()
        return {'success': False, 'error': str(e)}
    finally:
        conn.close()


# ============================================================
# Step 43-4: 인보이스번호 추적
# ============================================================

def link_invoice(remittance_id: int, invoice_no: str,
                 invoice_date: Optional[str] = None,
                 invoice_amount_usd: Optional[float] = None,
                 invoice_amount_cny: Optional[float] = None,
                 description: Optional[str] = None) -> Dict[str, Any]:
    """송금에 인보이스 연결.
    절대 규칙 #7: 인보이스 단가는 시스템 의사결정에 사용 금지. 추적/메모 용도만.
    """
    if not invoice_no:
        return {'success': False, 'error': 'invoice_no required'}
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("SELECT id, invoice_no_primary FROM remittance_history WHERE id = ?", (remittance_id,))
        row = cur.fetchone()
        if not row:
            return {'success': False, 'error': 'remittance not found'}

        try:
            cur.execute("""
                INSERT INTO remittance_invoice
                (remittance_id, invoice_no, invoice_date, invoice_amount_usd, invoice_amount_cny, description)
                VALUES (?, ?, ?, ?, ?, ?)
            """, (remittance_id, invoice_no, invoice_date, invoice_amount_usd, invoice_amount_cny, description))
        except sqlite3.IntegrityError:
            return {'success': False, 'error': '이미 연결됨 (UNIQUE)'}

        new_id = cur.lastrowid

        # primary가 없으면 첫 인보이스를 primary로
        if not row['invoice_no_primary']:
            cur.execute("UPDATE remittance_history SET invoice_no_primary = ? WHERE id = ?",
                        (invoice_no, remittance_id))

        conn.commit()
        return {'success': True, 'id': new_id}
    except Exception as e:
        conn.rollback()
        return {'success': False, 'error': str(e)}
    finally:
        conn.close()


def list_invoices(remittance_id: int) -> List[Dict]:
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("""
            SELECT * FROM remittance_invoice
            WHERE remittance_id = ?
            ORDER BY id ASC
        """, (remittance_id,))
        return [dict(r) for r in cur.fetchall()]
    finally:
        conn.close()


def find_by_invoice(invoice_no: str) -> List[Dict]:
    """인보이스번호로 송금 검색."""
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("""
            SELECT rh.*, ri.invoice_no, ri.invoice_date, ri.invoice_amount_usd
            FROM remittance_invoice ri
            JOIN remittance_history rh ON rh.id = ri.remittance_id
            WHERE ri.invoice_no LIKE ?
            ORDER BY rh.remittance_date DESC
        """, (f'%{invoice_no}%',))
        return [dict(r) for r in cur.fetchall()]
    finally:
        conn.close()


# ============================================================
# Step 43-5: 매칭 해제 / 송금 취소 (운영 안전망)
# ============================================================

def unmatch(match_id: int) -> Dict[str, Any]:
    """매칭 해제. 송금 allocated_cny 자동 재계산.
    절대 규칙 #2/#3 준수: bid_cost/sales_history 미접촉, 매칭 row만 제거.
    """
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("SELECT * FROM remittance_bid_match WHERE id = ?", (match_id,))
        m = cur.fetchone()
        if not m:
            return {'success': False, 'error': 'match not found'}

        rid = m['remittance_id']
        alloc = m['allocated_cny']

        cur.execute("DELETE FROM remittance_bid_match WHERE id = ?", (match_id,))

        # 송금 allocated_cny 재계산
        cur.execute("""
            UPDATE remittance_history
            SET allocated_cny = COALESCE((
                SELECT SUM(allocated_cny) FROM remittance_bid_match WHERE remittance_id = ?
            ), 0),
            updated_at = CURRENT_TIMESTAMP
            WHERE id = ?
        """, (rid, rid))

        # depleted였던 게 active로 돌아갔으면 그대로 두고, 잔액 0이면 다시 depleted
        cur.execute("""
            UPDATE remittance_history
            SET status = CASE
                WHEN allocated_cny >= amount_cny - 0.01 THEN 'depleted'
                ELSE 'active'
            END
            WHERE id = ? AND status != 'cancelled'
        """, (rid,))

        conn.commit()
        return {
            'success': True,
            'unmatched_id': match_id,
            'remittance_id': rid,
            'released_cny': alloc,
        }
    except Exception as e:
        conn.rollback()
        return {'success': False, 'error': str(e)}
    finally:
        conn.close()


def cancel_remittance(remittance_id: int, reason: str = '') -> Dict[str, Any]:
    """
    송금 취소. 모든 매칭 해제 + status='cancelled'.
    절대 규칙 #2/#3: 데이터 삭제 아님, status만 변경.
    """
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("SELECT * FROM remittance_history WHERE id = ?", (remittance_id,))
        rem = cur.fetchone()
        if not rem:
            return {'success': False, 'error': 'remittance not found'}
        if rem['status'] == 'cancelled':
            return {'success': False, 'error': 'already cancelled'}

        # 모든 매칭 해제 (매칭 row만 삭제, 입찰/판매 데이터는 미접촉)
        cur.execute("DELETE FROM remittance_bid_match WHERE remittance_id = ?", (remittance_id,))
        unmatched = cur.rowcount

        # status 변경
        new_notes = (rem['notes'] or '') + f' | [CANCELLED] {reason}'
        cur.execute("""
            UPDATE remittance_history
            SET status = 'cancelled', allocated_cny = 0, notes = ?, updated_at = CURRENT_TIMESTAMP
            WHERE id = ?
        """, (new_notes.strip(), remittance_id))

        conn.commit()
        return {
            'success': True,
            'remittance_id': remittance_id,
            'matches_released': unmatched,
        }
    except Exception as e:
        conn.rollback()
        return {'success': False, 'error': str(e)}
    finally:
        conn.close()


def list_matches(remittance_id: int) -> List[Dict]:
    """송금에 연결된 매칭 목록."""
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("""
            SELECT rbm.*, bc.model, bc.size, bc.cny_price as bid_cny
            FROM remittance_bid_match rbm
            LEFT JOIN bid_cost bc ON bc.order_id = rbm.order_id
            WHERE rbm.remittance_id = ?
            ORDER BY rbm.created_at DESC
        """, (remittance_id,))
        return [dict(r) for r in cur.fetchall()]
    finally:
        conn.close()
