"""
kream_hubnet_bot.py — 허브넷(kpartner.ehub24.net) 자동화 봇

작업지시서_1_허브넷봇_PDF자동다운로드_v1.md 기준 구현.
Step 2 진행 중: 로그인 + 세션 관리 (Func 1~4).
"""

from __future__ import annotations

import argparse
import json
import logging
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import requests

# ─── 상수 ──────────────────────────────────────────────────
HUBNET_BASE_URL = "https://kpartner.ehub24.net/"
HUBNET_LOGIN_URL = "https://kpartner.ehub24.net/auth"
HUBNET_LIST_URL = "https://kpartner.ehub24.net/list"
HUBNET_LIST_AJAX_URL = "https://kpartner.ehub24.net/list_ajax"
HUBNET_INVOICE_PRINT_URL = "https://kpartner.ehub24.net/kream_invoice_print"
DEFAULT_TIMEOUT = 10  # 초
FETCH_TIMEOUT = 30  # list_ajax는 응답이 클 수 있어 별도

# raw_data 저장 시 제외할 민감 필드 (작업지시서 §6.2 개인정보 미저장)
SENSITIVE_KEYS = frozenset(['consignee', 'consignee_phone', 'consignee_address'])

# DB 경로 (kream_collector.py와 동일 — price_history.db 단일 소스)
DB_PATH = Path(__file__).parent / "price_history.db"

# 허브넷 사용자 식별 (작업지시서 §1.2)
HUBNET_USER_PT2 = "61"
HUBNET_USER_PT3 = "CN"
HUBNET_USER_EMAIL = "judaykream@gmail.com"
HUBNET_USER_LEVEL = "1"
DEFAULT_USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)
SESSION_LIFETIME_DAYS = 30  # 만료 추정 (PHPSESSID 보수적)
SETTINGS_PATH = Path(__file__).parent / "settings.json"

# ─── 로거 ──────────────────────────────────────────────────
logger = logging.getLogger(__name__)


def _setup_logging(verbose: bool = False) -> None:
    level = logging.DEBUG if verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format="[%(levelname)s] %(message)s",
    )


def _build_session() -> requests.Session:
    """User-Agent + Referer 기본 헤더가 설정된 빈 Session 반환."""
    s = requests.Session()
    s.headers.update({
        "User-Agent": DEFAULT_USER_AGENT,
        "Referer": HUBNET_BASE_URL,
        "Accept": "application/json, text/javascript, */*; q=0.01",
        "Accept-Language": "ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7",
        "X-Requested-With": "XMLHttpRequest",
    })
    return s


def _load_settings() -> dict:
    if not SETTINGS_PATH.exists():
        raise RuntimeError(f"settings.json 파일 없음: {SETTINGS_PATH}")
    with SETTINGS_PATH.open("r", encoding="utf-8") as f:
        return json.load(f)


# ─── Func 1: hubnet_login ──────────────────────────────────
def hubnet_login(email: str, password: str) -> requests.Session:
    """허브넷 로그인. 성공 시 인증된 Session 반환.

    실패 시 RuntimeError 발생. **빈 세션 저장 절대 금지.**
    호출자가 결과 Session을 받아 save_hubnet_session() 해야 함.
    """
    if not email or not password:
        raise RuntimeError("hubnet_login: email/password 비어있음")

    session = _build_session()

    # 1) 로그인 페이지 GET (CSRF/세션쿠키 사전 발급 가능성 대비)
    try:
        session.get(HUBNET_BASE_URL, timeout=DEFAULT_TIMEOUT)
    except requests.RequestException as e:
        logger.warning("초기 페이지 GET 실패(무시 가능): %s", e)

    # 2) 로그인 POST
    payload = {
        "action": "login",
        "email": email,
        "password": password,
    }
    try:
        resp = session.post(
            HUBNET_LOGIN_URL,
            data=payload,
            timeout=DEFAULT_TIMEOUT,
            allow_redirects=False,
        )
    except requests.RequestException as e:
        raise RuntimeError(f"허브넷 로그인 요청 실패: {e}") from e

    logger.debug("응답 상태: %s", resp.status_code)
    logger.debug("응답 헤더 Content-Type: %s", resp.headers.get("Content-Type"))
    logger.debug("응답 본문(앞 500자): %s", resp.text[:500])

    # 3) 응답 파싱 (JSON 우선, 실패 시 본문 키워드 검사)
    success = False
    response_keys: list[str] = []
    parsed: dict | None = None
    try:
        parsed = resp.json()
        if isinstance(parsed, dict):
            response_keys = list(parsed.keys())
            success = bool(parsed.get("success") is True or parsed.get("result") == "ok")
    except ValueError:
        # JSON이 아닐 때: 일부 PHP 구현은 redirect/HTML로 응답
        body = resp.text or ""
        if resp.status_code in (302, 301):
            # 리다이렉트 응답이면 보통 로그인 성공
            success = True
        elif "logout" in body.lower() or "성공" in body:
            success = True

    if not success:
        # 실패 — 호출자에게 빈 세션 저장 책임이 있으면 안 됨.
        # 여기서 raise하면 save가 호출되지 않음.
        msg = (
            f"허브넷 로그인 실패. status={resp.status_code}, "
            f"keys={response_keys}, body_preview={resp.text[:200]!r}"
        )
        raise RuntimeError(msg)

    # 4) 쿠키에 PHPSESSID 같은 세션 쿠키 들어왔는지 확인
    cookie_names = [c.name for c in session.cookies]
    if not cookie_names:
        raise RuntimeError("로그인 응답에 쿠키 없음 — 세션 미발급")

    logger.info("로그인 성공 (응답 keys=%s, 쿠키=%s)", response_keys, cookie_names)
    # 로그인 성공 응답 구조 메타 정보 보고용 — Session에 첨부
    setattr(session, "_hubnet_login_response_keys", response_keys)
    setattr(session, "_hubnet_login_response_status", resp.status_code)
    return session


# ─── Func 2: save_hubnet_session ───────────────────────────
def save_hubnet_session(session: requests.Session, path: str) -> None:
    """쿠키만 JSON으로 저장. 빈 쿠키 저장 금지."""
    cookies = []
    for c in session.cookies:
        cookies.append({
            "name": c.name,
            "value": c.value,
            "domain": c.domain,
            "path": c.path,
            "secure": c.secure,
            "expires": c.expires,
        })
    if not cookies:
        raise RuntimeError("저장할 쿠키 없음 — 빈 세션 저장 금지")

    now = datetime.now(timezone.utc)
    payload = {
        "cookies": cookies,
        "saved_at": now.isoformat(),
        "expires_estimate": (now + timedelta(days=SESSION_LIFETIME_DAYS)).isoformat(),
    }
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    tmp.replace(p)
    logger.info("세션 저장: %s (쿠키 %d개)", p, len(cookies))


# ─── Func 3: load_hubnet_session ───────────────────────────
def load_hubnet_session(path: str) -> requests.Session | None:
    """저장된 쿠키 로드. 파일 없거나 만료 추정 시 None."""
    p = Path(path)
    if not p.exists():
        logger.info("세션 파일 없음: %s", p)
        return None
    try:
        with p.open("r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        logger.warning("세션 파일 손상: %s", e)
        return None

    # 만료 추정 체크
    expires_str = data.get("expires_estimate")
    if expires_str:
        try:
            expires = datetime.fromisoformat(expires_str)
            if expires <= datetime.now(timezone.utc):
                logger.info("세션 만료 추정 (expires=%s)", expires_str)
                return None
        except ValueError:
            logger.warning("expires_estimate 파싱 실패: %s", expires_str)

    cookies = data.get("cookies") or []
    if not cookies:
        logger.warning("저장된 쿠키 0개 — None 반환")
        return None

    session = _build_session()
    for c in cookies:
        session.cookies.set(
            name=c["name"],
            value=c["value"],
            domain=c.get("domain"),
            path=c.get("path", "/"),
        )
    logger.info("세션 로드: %s (쿠키 %d개)", p, len(cookies))
    return session


# ─── Func 4: ensure_hubnet_logged_in ───────────────────────
def _is_session_alive(session: requests.Session) -> bool:
    """HUBNET_LIST_URL에 GET 요청해서 로그인 상태 확인.
    리다이렉트(302)면 보통 로그인 페이지로 보내짐 → 만료.
    200이면서 본문에 로그인 폼이 없으면 살아있음.
    """
    try:
        resp = session.get(
            HUBNET_LIST_URL,
            timeout=DEFAULT_TIMEOUT,
            allow_redirects=False,
        )
    except requests.RequestException as e:
        logger.warning("세션 확인 ping 실패: %s", e)
        return False

    if resp.status_code in (301, 302, 303, 307, 308):
        loc = resp.headers.get("Location", "")
        logger.info("세션 만료 추정 — 리다이렉트 → %s", loc)
        return False
    if resp.status_code != 200:
        logger.info("세션 확인 비정상 status=%s", resp.status_code)
        return False

    body = resp.text or ""
    # 로그인 폼 흔적이 있으면 미인증 상태
    if 'name="password"' in body and 'name="email"' in body:
        # 다만 list 페이지에 로그인 폼이 같이 렌더링될 수도 있어
        # userPt2/userEmail 같은 인증 후 마커가 같이 있으면 살아있는 걸로 본다.
        if "userEmail" in body or "userPt2" in body:
            return True
        logger.info("세션 만료 추정 — 본문에 로그인 폼만 있음")
        return False
    return True


def ensure_hubnet_logged_in() -> requests.Session:
    """세션 로드 → ping → 만료면 재로그인 + 저장."""
    settings = _load_settings()
    session_path = settings.get("hubnet_session_path")
    email = settings.get("hubnet_email")
    password = settings.get("hubnet_password")

    if not session_path:
        raise RuntimeError("settings.json에 hubnet_session_path 없음")
    if not email or not password:
        raise RuntimeError("settings.json에 hubnet_email/password 없음")

    # 1) 기존 세션 로드 시도
    sess = load_hubnet_session(session_path)
    if sess is not None and _is_session_alive(sess):
        logger.info("세션 유효 확인됨 (재로그인 X)")
        return sess

    # 2) 신규 로그인
    if sess is None:
        logger.info("세션 파일 없음/만료, 신규 로그인 시도")
    else:
        logger.info("세션 ping 실패, 재로그인 시도")
    sess = hubnet_login(email, password)
    save_hubnet_session(sess, session_path)
    return sess


# ─── Func 5: fetch_hubnet_orders ──────────────────────────
def fetch_hubnet_orders(
    session: requests.Session,
    start_date: str,
    end_date: str,
    search_mode: str = "date_only",
    bulk_numbers: list[str] | None = None,
    page_size: int = 100,
) -> list[dict]:
    """허브넷 KREAM HBL 조회. 작업지시서 §1.3 + §3.1 기준.

    Parameters:
        session: 인증된 requests.Session (ensure_hubnet_logged_in() 결과)
        start_date, end_date: 'YYYY-MM-DD'
        search_mode: 'date_only' | 'bulk_hbl' | 'bulk_order'
        bulk_numbers: bulk_* 모드일 때 HBL/주문번호 목록
        page_size: 페이지 크기 (기본 100)

    Returns:
        list of dict — 각 dict는 hubnet_orders 컬럼 키 + 'raw' 필드.
        (DB 저장은 upsert_hubnet_orders()가 처리.)

    실패 시 RuntimeError. 폴백 금지 (CLAUDE.md 절대 규칙).
    """
    if search_mode not in ("date_only", "bulk_hbl", "bulk_order"):
        raise RuntimeError(f"잘못된 search_mode: {search_mode}")
    if search_mode != "date_only" and not bulk_numbers:
        raise RuntimeError(f"search_mode={search_mode}인데 bulk_numbers 비어있음")

    payload: dict[str, str] = {
        "mode": "search_kream",
        "start_date": start_date,
        "end_date": end_date,
        "search_mode": search_mode,
        "user_pt2": HUBNET_USER_PT2,
        "user_email": HUBNET_USER_EMAIL,
        "user_pt3": HUBNET_USER_PT3,
        "user_level": HUBNET_USER_LEVEL,
        "page_size": str(page_size),
    }
    if search_mode == "bulk_hbl":
        payload["bulk_hbl_numbers"] = json.dumps(bulk_numbers, ensure_ascii=False)
    elif search_mode == "bulk_order":
        payload["bulk_order_numbers"] = json.dumps(bulk_numbers, ensure_ascii=False)

    logger.info(
        "허브넷 조회 요청: mode=%s start=%s end=%s page_size=%s",
        search_mode, start_date, end_date, page_size,
    )
    logger.debug("payload=%s", payload)

    try:
        resp = session.post(
            HUBNET_LIST_AJAX_URL,
            data=payload,
            timeout=FETCH_TIMEOUT,
            headers={"Referer": HUBNET_LIST_URL},
        )
    except requests.RequestException as e:
        raise RuntimeError(f"허브넷 list_ajax 요청 실패: {e}") from e

    logger.debug("응답 status=%s len=%d", resp.status_code, len(resp.text))
    if resp.status_code != 200:
        raise RuntimeError(
            f"허브넷 list_ajax 비정상 status={resp.status_code} body={resp.text[:300]!r}"
        )

    try:
        parsed = resp.json()
    except ValueError as e:
        raise RuntimeError(
            f"허브넷 응답 JSON 파싱 실패: {e} body_preview={resp.text[:300]!r}"
        ) from e

    if not isinstance(parsed, dict):
        raise RuntimeError(f"허브넷 응답 형식 예상 외 (dict 아님): {type(parsed)}")

    success = parsed.get("success")
    if success is False:
        raise RuntimeError(f"허브넷 응답 success=false, parsed={parsed!r}")

    raw_list = parsed.get("data")
    if raw_list is None:
        # success가 빠지고 data만 들어오는 경우도 있을 수 있어 keys 보고
        raise RuntimeError(
            f"허브넷 응답에 data 없음. keys={list(parsed.keys())} preview={resp.text[:300]!r}"
        )
    if not isinstance(raw_list, list):
        raise RuntimeError(f"허브넷 응답 data 형식 예상 외 (list 아님): {type(raw_list)}")

    logger.info("허브넷 조회 결과: %d건", len(raw_list))

    # 응답 필드 → hubnet_orders 컬럼 매핑 (작업지시서 §1.3)
    out: list[dict] = []
    for row in raw_list:
        if not isinstance(row, dict):
            logger.warning("data 항목이 dict 아님, skip: %r", row)
            continue
        order_yn = (row.get("order_yn") or "").strip().upper()
        order_status = "cancelled" if order_yn == "Y" else "normal"

        def _to_int(v):
            try:
                return int(str(v).strip()) if v not in (None, "") else None
            except (TypeError, ValueError):
                return None

        def _to_float(v):
            try:
                return float(str(v).strip()) if v not in (None, "") else None
            except (TypeError, ValueError):
                return None

        mapped = {
            "hbl_number": (row.get("add2") or "").strip() or None,
            "order_no": (row.get("add1") or "").strip() or None,
            "shipper": row.get("add3"),
            "product_name": row.get("add9"),
            "quantity": _to_int(row.get("add10")),
            "weight": _to_float(row.get("add12")),
            "volume_weight": _to_float(row.get("add16")),
            "origin": row.get("add26"),
            "tracking": row.get("tracking"),
            "delivery_no": row.get("add56"),
            "work_status": row.get("add146"),
            "order_status": order_status,
            "raw": row,  # raw_data로 저장 (디버깅용)
        }
        if not mapped["hbl_number"]:
            logger.warning("HBL 번호(add2) 비어있음, skip: order_no=%s", mapped["order_no"])
            continue
        if not mapped["order_no"]:
            logger.warning("주문번호(add1) 비어있음, skip: hbl=%s", mapped["hbl_number"])
            continue
        out.append(mapped)

    logger.info("매핑 완료: %d건 (전체 %d건 중)", len(out), len(raw_list))
    return out


# ─── Func 6: upsert_hubnet_orders ─────────────────────────
def upsert_hubnet_orders(orders: list[dict]) -> dict:
    """list_ajax 응답 raw row 리스트를 hubnet_orders 테이블에 upsert.

    `orders`는 list_ajax 응답 `data` 항목 그대로(add1, add2, ... 키를 가진 dict).
    UNIQUE 키는 hbl_number(add2). INSERT OR REPLACE 사용 → 기존 행 완전 대체.
    matched_kream_order_id / matched_at은 Step 4에서 별도 처리 (여기선 건드리지 않음).
    raw_data에는 SENSITIVE_KEYS 제외한 dict의 JSON 직렬화 결과 저장.

    Returns:
        {'inserted': int, 'updated': int, 'total': int, 'errors': list[dict]}

    절대 폴백 금지(CLAUDE.md): hbl_number / order_no 비어있는 행은 skip + errors 기록.
    """
    result: dict = {'inserted': 0, 'updated': 0, 'total': 0, 'errors': []}
    if not orders:
        return result

    def _to_int(v):
        if v in (None, ''):
            return None
        try:
            return int(str(v).strip())
        except (TypeError, ValueError):
            return None

    def _to_float(v):
        if v in (None, ''):
            return None
        try:
            return float(str(v).strip())
        except (TypeError, ValueError):
            return None

    conn = sqlite3.connect(str(DB_PATH))
    try:
        cur = conn.cursor()
        for idx, order in enumerate(orders):
            try:
                if not isinstance(order, dict):
                    result['errors'].append({
                        'index': idx,
                        'reason': f'order가 dict 아님: {type(order).__name__}',
                    })
                    continue

                hbl_number = (order.get('add2') or '').strip() or None
                order_no = (order.get('add1') or '').strip() or None
                if not hbl_number or not order_no:
                    # 매칭 실패 시 폴백 금지 — skip + 보고
                    result['errors'].append({
                        'index': idx,
                        'reason': 'hbl_number(add2) 또는 order_no(add1) 비어있음',
                        'hbl_number': hbl_number,
                        'order_no': order_no,
                    })
                    continue

                shipper = order.get('add3')
                product_name = order.get('add9')
                quantity = _to_int(order.get('add10'))
                weight = _to_float(order.get('add12'))
                volume_weight = _to_float(order.get('add16'))
                origin = order.get('add26')
                tracking = order.get('tracking') or None
                delivery_no = order.get('add56') or None
                work_status = order.get('add146') or None
                size = order.get('add38') or None
                wdate = order.get('wdate') or None
                order_status = 'cancelled' if order.get('order_yn') == 'Y' else 'normal'

                # 민감 필드 제외 검증 + 로깅
                if any(k in order for k in SENSITIVE_KEYS):
                    logger.debug("민감 필드 제외: hbl=%s", hbl_number)
                raw_dict = {k: v for k, v in order.items() if k not in SENSITIVE_KEYS}
                raw_data = json.dumps(raw_dict, ensure_ascii=False)

                # 신규/갱신 판별 (INSERT OR REPLACE는 rowcount로 구분 불가)
                cur.execute(
                    "SELECT 1 FROM hubnet_orders WHERE hbl_number = ?",
                    (hbl_number,),
                )
                existed = cur.fetchone() is not None

                cur.execute(
                    """
                    INSERT OR REPLACE INTO hubnet_orders (
                        hbl_number, order_no, shipper, product_name,
                        quantity, weight, volume_weight, origin,
                        tracking, delivery_no, work_status, order_status,
                        size, wdate, raw_data, fetched_at
                    ) VALUES (
                        ?, ?, ?, ?,
                        ?, ?, ?, ?,
                        ?, ?, ?, ?,
                        ?, ?, ?, CURRENT_TIMESTAMP
                    )
                    """,
                    (
                        hbl_number, order_no, shipper, product_name,
                        quantity, weight, volume_weight, origin,
                        tracking, delivery_no, work_status, order_status,
                        size, wdate, raw_data,
                    ),
                )
                if existed:
                    result['updated'] += 1
                else:
                    result['inserted'] += 1
            except sqlite3.Error as e:
                result['errors'].append({
                    'index': idx,
                    'reason': f'DB 오류: {e}',
                    'hbl_number': (order.get('add2') if isinstance(order, dict) else None),
                    'order_no': (order.get('add1') if isinstance(order, dict) else None),
                })
            except Exception as e:  # noqa: BLE001 — 행 단위 격리
                result['errors'].append({
                    'index': idx,
                    'reason': f'처리 오류: {type(e).__name__}: {e}',
                    'hbl_number': (order.get('add2') if isinstance(order, dict) else None),
                    'order_no': (order.get('add1') if isinstance(order, dict) else None),
                })
        conn.commit()
    finally:
        conn.close()

    result['total'] = result['inserted'] + result['updated']
    logger.info(
        "upsert 완료: inserted=%d updated=%d total=%d errors=%d",
        result['inserted'], result['updated'], result['total'], len(result['errors']),
    )
    return result


# ─── Func 7: match_hubnet_to_kream ────────────────────────
def match_hubnet_to_kream(kream_order_id: str) -> dict | None:
    """KREAM order_id로 허브넷 hbl_number 매칭. 1차 정확 일치만 사용.

    1차: hubnet_orders.order_no = kream_order_id AND order_status != 'cancelled'
    2차: list_ajax 응답에 KREAM model 코드 없음 확인 (raw_data 키 검사 2026-04-30) → 스텁.

    Returns:
        매칭 시: {'hbl_number', 'hubnet_id', 'match_type': 'exact_order_id', 'raw': dict}
        미매칭 시: None  (CLAUDE.md 절대 규칙 7: 폴백/추측 매칭 금지)
    """
    if not kream_order_id:
        return None

    conn = sqlite3.connect(str(DB_PATH))
    try:
        cur = conn.cursor()
        cur.execute(
            """SELECT id, hbl_number, raw_data FROM hubnet_orders
               WHERE order_no = ? AND order_status != 'cancelled'
               LIMIT 1""",
            (kream_order_id,),
        )
        row = cur.fetchone()
    finally:
        conn.close()

    if row:
        try:
            raw = json.loads(row[2]) if row[2] else {}
        except (TypeError, ValueError):
            raw = {}
        return {
            'hbl_number': row[1],
            'hubnet_id': row[0],
            'match_type': 'exact_order_id',
            'raw': raw,
        }

    # 2차 매칭 스텁
    # TODO: list_ajax 응답에 KREAM model 코드 없음 (확인 완료 2026-04-30).
    #       향후 PDF 메타데이터 또는 별도 매핑 테이블 도입 시 구현.
    return None


# ─── Func 8: update_kream_sales_with_hbl ──────────────────
def update_kream_sales_with_hbl(
    kream_order_id: str,
    hbl_number: str,
    hubnet_id: int,
) -> bool:
    """sales_history + hubnet_orders 양방향 매칭 정보 갱신.

    트랜잭션: 두 UPDATE 모두 rowcount=1이어야 commit. 아니면 rollback + False.
    matched_at은 datetime.now(timezone.utc).isoformat() 형식.
    """
    if not kream_order_id or not hbl_number or hubnet_id is None:
        logger.error("update_kream_sales_with_hbl: 인자 누락")
        return False

    matched_at = datetime.now(timezone.utc).isoformat()
    conn = sqlite3.connect(str(DB_PATH))
    try:
        cur = conn.cursor()
        cur.execute(
            "UPDATE sales_history SET hbl_number = ? WHERE order_id = ?",
            (hbl_number, kream_order_id),
        )
        if cur.rowcount != 1:
            conn.rollback()
            logger.error(
                "sales_history 업데이트 실패: rowcount=%d order_id=%s",
                cur.rowcount, kream_order_id,
            )
            return False

        cur.execute(
            """UPDATE hubnet_orders
               SET matched_kream_order_id = ?, matched_at = ?
               WHERE id = ?""",
            (kream_order_id, matched_at, hubnet_id),
        )
        if cur.rowcount != 1:
            conn.rollback()
            logger.error(
                "hubnet_orders 업데이트 실패: rowcount=%d hubnet_id=%s",
                cur.rowcount, hubnet_id,
            )
            return False

        conn.commit()
        return True
    except sqlite3.Error as e:
        conn.rollback()
        logger.error("매칭 트랜잭션 실패: %s (order_id=%s, hubnet_id=%s)",
                     e, kream_order_id, hubnet_id)
        return False
    finally:
        conn.close()


# ─── Func 9: match_all_unmatched ──────────────────────────
def match_all_unmatched() -> dict:
    """sales_history.hbl_number IS NULL 행 전체 순회 → match → update.

    Returns:
        {'total': int, 'matched': int, 'unmatched': int,
         'unmatched_order_ids': list[str], 'errors': list[dict]}
    """
    result: dict = {
        'total': 0, 'matched': 0, 'unmatched': 0,
        'unmatched_order_ids': [], 'errors': [],
    }

    conn = sqlite3.connect(str(DB_PATH))
    try:
        cur = conn.cursor()
        cur.execute(
            "SELECT order_id FROM sales_history "
            "WHERE hbl_number IS NULL ORDER BY order_id"
        )
        order_ids = [r[0] for r in cur.fetchall()]
    finally:
        conn.close()

    result['total'] = len(order_ids)
    for oid in order_ids:
        if not oid:
            result['errors'].append({'order_id': oid, 'reason': 'order_id 비어있음'})
            continue
        try:
            m = match_hubnet_to_kream(oid)
            if not m:
                result['unmatched'] += 1
                result['unmatched_order_ids'].append(oid)
                continue
            ok = update_kream_sales_with_hbl(oid, m['hbl_number'], m['hubnet_id'])
            if ok:
                result['matched'] += 1
                logger.info(
                    "매칭 성공: %s → %s (hubnet_id=%s)",
                    oid, m['hbl_number'], m['hubnet_id'],
                )
            else:
                result['errors'].append({
                    'order_id': oid,
                    'reason': 'update_kream_sales_with_hbl 실패',
                    'hbl_number': m.get('hbl_number'),
                    'hubnet_id': m.get('hubnet_id'),
                })
        except Exception as e:  # noqa: BLE001 — 행 단위 격리
            result['errors'].append({
                'order_id': oid,
                'reason': f'{type(e).__name__}: {e}',
            })

    logger.info(
        "match_all_unmatched 완료: total=%d matched=%d unmatched=%d errors=%d",
        result['total'], result['matched'], result['unmatched'], len(result['errors']),
    )
    return result


# ─── Func 10: fetch_invoice_html ──────────────────────────
def fetch_invoice_html(
    session: requests.Session,
    hbl_numbers: list[str],
) -> str:
    """허브넷 송장 HTML 페이지를 받아옴 (1개 이상 HBL).

    흐름 (list 페이지 인라인 JS L1201~ 분석 기반, 2026-04-30):
      1. POST /list_ajax (mode=get_print_invoice) → JSON {success, data: [...]}
      2. POST /kream_invoice_print (invoice_data=JSON.stringify(data)) → HTML

    실패 시 RuntimeError. 폴백 금지(CLAUDE.md 절대 규칙 7):
    빈 입력 / success!=true / 빈 data / non-HTML 응답 / 오류 페이지 → 모두 RuntimeError.
    """
    if not hbl_numbers:
        raise RuntimeError("fetch_invoice_html: hbl_numbers 비어있음")
    if not isinstance(hbl_numbers, (list, tuple)):
        raise RuntimeError(
            f"fetch_invoice_html: hbl_numbers는 list여야 함 "
            f"(받은 타입={type(hbl_numbers).__name__})"
        )

    # ─── 1단계: get_print_invoice ─────────────────────────
    # PHP 측이 배열로 받도록 키에 '[]' 직접 포함 (jQuery 기본 인코딩과 동일)
    data: list[tuple[str, str]] = [
        ("mode", "get_print_invoice"),
        ("seller_id", ""),
        ("user_pt2", HUBNET_USER_PT2),
        ("user_email", HUBNET_USER_EMAIL),
        ("user_level", HUBNET_USER_LEVEL),
        ("user_pt3", HUBNET_USER_PT3),
    ]
    for h in hbl_numbers:
        if not h:
            raise RuntimeError("fetch_invoice_html: hbl_numbers에 빈 값 포함")
        data.append(("hbl_numbers[]", h))

    logger.info("get_print_invoice 요청: hbl_numbers=%s", hbl_numbers)
    try:
        resp1 = session.post(
            HUBNET_LIST_AJAX_URL,
            data=data,
            timeout=FETCH_TIMEOUT,
            headers={"Referer": HUBNET_LIST_URL},
        )
    except requests.RequestException as e:
        raise RuntimeError(f"get_print_invoice 요청 실패: {e}") from e

    logger.debug("get_print_invoice status=%d len=%d", resp1.status_code, len(resp1.text))
    if resp1.status_code != 200:
        raise RuntimeError(
            f"get_print_invoice 비정상 status={resp1.status_code} "
            f"body={resp1.text[:300]!r}"
        )
    try:
        parsed = resp1.json()
    except ValueError as e:
        raise RuntimeError(
            f"get_print_invoice JSON 파싱 실패: {e} body={resp1.text[:300]!r}"
        ) from e
    if not isinstance(parsed, dict):
        raise RuntimeError(f"get_print_invoice 응답 dict 아님: {type(parsed)}")
    if parsed.get("success") is not True:
        raise RuntimeError(f"get_print_invoice success!=true. parsed={parsed!r}")
    invoice_list = parsed.get("data")
    if not isinstance(invoice_list, list) or not invoice_list:
        raise RuntimeError(
            f"get_print_invoice data 비어있음 (HBL 미존재 가능성). "
            f"hbl_numbers={hbl_numbers} keys={list(parsed.keys())}"
        )
    logger.info("get_print_invoice 결과: data=%d건", len(invoice_list))

    # ─── 2단계: kream_invoice_print ───────────────────────
    invoice_data_json = json.dumps(invoice_list, ensure_ascii=False)
    logger.debug("kream_invoice_print payload len=%d", len(invoice_data_json))
    try:
        resp2 = session.post(
            HUBNET_INVOICE_PRINT_URL,
            data={"invoice_data": invoice_data_json},
            timeout=FETCH_TIMEOUT,
            headers={"Referer": HUBNET_LIST_URL},
        )
    except requests.RequestException as e:
        raise RuntimeError(f"kream_invoice_print 요청 실패: {e}") from e

    ct = resp2.headers.get("Content-Type", "")
    logger.debug(
        "kream_invoice_print status=%d len=%d ct=%s",
        resp2.status_code, len(resp2.text), ct,
    )
    if resp2.status_code != 200:
        raise RuntimeError(
            f"kream_invoice_print 비정상 status={resp2.status_code} "
            f"body={resp2.text[:300]!r}"
        )
    if "html" not in ct.lower():
        raise RuntimeError(
            f"kream_invoice_print Content-Type이 HTML 아님: ct={ct!r} "
            f"body={resp2.text[:300]!r}"
        )
    body = resp2.text or ""
    if not body.strip():
        raise RuntimeError("kream_invoice_print 응답 본문 비어있음")
    # 옵션 1 진단에서 확인된 오류 페이지 마커
    if "송장 출력 - 오류" in body or "<title>KREAM 송장 출력 - 오류" in body:
        raise RuntimeError(
            f"kream_invoice_print가 오류 페이지 반환. body={body[:500]!r}"
        )

    logger.info("송장 HTML 수신: %d bytes (%d건)", len(body), len(invoice_list))
    return body


# ─── CLI 진입점 ────────────────────────────────────────────
def _cli_auth() -> int:
    try:
        sess = ensure_hubnet_logged_in()
    except RuntimeError as e:
        logger.error("인증 실패: %s", e)
        return 1

    cookie_names = [c.name for c in sess.cookies]
    keys = getattr(sess, "_hubnet_login_response_keys", None)
    if keys is not None:
        logger.info("로그인 응답 JSON keys: %s", keys)
    logger.info("최종 쿠키: %s (%d개)", cookie_names, len(cookie_names))
    return 0


def _cli_fetch(args) -> int:
    """--mode fetch: 허브넷 조회 → upsert (--no-save 시 미리보기만)."""
    if not args.start or not args.end:
        logger.error("--start, --end 필수 (YYYY-MM-DD)")
        return 2

    try:
        sess = ensure_hubnet_logged_in()
    except RuntimeError as e:
        logger.error("인증 실패: %s", e)
        return 1

    try:
        orders = fetch_hubnet_orders(
            sess,
            start_date=args.start,
            end_date=args.end,
            search_mode=args.search_mode,
            page_size=args.page_size,
        )
    except RuntimeError as e:
        logger.error("조회 실패: %s", e)
        return 1

    logger.info("조회 결과: %d건", len(orders))
    print(f"\n=== 조회 결과: {len(orders)}건 ===")
    if orders:
        print("\n[샘플 5건 매핑 (HBL, order_no, product_name, qty, status)]")
        for o in orders[:5]:
            print(
                f"  - {o['hbl_number']} | {o['order_no']} | "
                f"{o.get('product_name')} | qty={o.get('quantity')} | {o['order_status']}"
            )

    if args.no_save:
        logger.info("--no-save: DB 저장 생략 (미리보기만)")
        return 0

    # fetch 결과의 raw 필드만 뽑아서 upsert에 전달 (B단계 정합)
    raw_orders = [o['raw'] for o in orders if isinstance(o, dict) and 'raw' in o]
    if len(raw_orders) != len(orders):
        logger.warning("raw 필드 누락 행 %d개 — upsert에서 제외", len(orders) - len(raw_orders))

    result = upsert_hubnet_orders(raw_orders)
    print(
        f"\n=== upsert 결과 ===\n"
        f"inserted={result['inserted']} updated={result['updated']} "
        f"total={result['total']} errors={len(result['errors'])}"
    )
    if result['errors']:
        print("\n[errors 상세]")
        for e in result['errors'][:10]:
            print(f"  - {e}")
        if len(result['errors']) > 10:
            print(f"  ... ({len(result['errors']) - 10}건 더)")
        return 1
    return 0


def _cli_html_test(args) -> int:
    """--mode html-test --hbl <HBL>: 단일 HBL HTML을 /tmp/invoice_test.html에 저장."""
    if not args.hbl:
        logger.error("--hbl 필수 (예: --hbl H2604252301517)")
        return 2

    try:
        sess = ensure_hubnet_logged_in()
    except RuntimeError as e:
        logger.error("인증 실패: %s", e)
        return 1

    try:
        html = fetch_invoice_html(sess, [args.hbl])
    except RuntimeError as e:
        logger.error("HTML 수신 실패: %s", e)
        return 1

    out_path = Path("/tmp/invoice_test.html")
    out_path.write_text(html, encoding="utf-8")
    print("\n=== html-test 결과 ===")
    print(f"hbl: {args.hbl}")
    print(f"saved: {out_path}")
    print(f"size: {len(html)} bytes")
    print(f"\n[첫 200자 미리보기]\n{html[:200]}")
    return 0


def _cli_match(args) -> int:
    """--mode match: 미매칭 sales_history 일괄 매칭."""
    result = match_all_unmatched()
    print(
        f"\n=== match 결과 ===\n"
        f"total={result['total']} matched={result['matched']} "
        f"unmatched={result['unmatched']} errors={len(result['errors'])}"
    )
    if result['unmatched_order_ids']:
        print("\n[미매칭 order_id]")
        for oid in result['unmatched_order_ids']:
            print(f"  - {oid}")
    if result['errors']:
        print("\n[errors 상세]")
        for e in result['errors'][:10]:
            print(f"  - {e}")
        if len(result['errors']) > 10:
            print(f"  ... ({len(result['errors']) - 10}건 더)")
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="허브넷 자동화 봇 CLI")
    parser.add_argument(
        "--mode",
        required=True,
        choices=["auth", "fetch", "match", "html-test"],
        help=(
            "실행 모드 (auth=로그인 검증, fetch=주문 조회+저장, "
            "match=KREAM↔허브넷 매칭, html-test=단일 HBL 송장 HTML 저장)"
        ),
    )
    parser.add_argument("--hbl", help="html-test 모드의 HBL 번호 (예: H2604252301517)")
    parser.add_argument("--start", help="조회 시작일 YYYY-MM-DD (fetch 모드 필수)")
    parser.add_argument("--end", help="조회 종료일 YYYY-MM-DD (fetch 모드 필수)")
    parser.add_argument(
        "--search-mode",
        dest="search_mode",
        default="date_only",
        choices=["date_only", "bulk_hbl", "bulk_order"],
    )
    parser.add_argument("--page-size", dest="page_size", type=int, default=100)
    parser.add_argument(
        "--no-save",
        dest="no_save",
        action="store_true",
        help="fetch 모드에서 DB 저장 생략 (미리보기만)",
    )
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)
    _setup_logging(args.verbose)

    if args.mode == "auth":
        return _cli_auth()
    if args.mode == "fetch":
        return _cli_fetch(args)
    if args.mode == "match":
        return _cli_match(args)
    if args.mode == "html-test":
        return _cli_html_test(args)
    return 2


if __name__ == "__main__":
    sys.exit(main())
