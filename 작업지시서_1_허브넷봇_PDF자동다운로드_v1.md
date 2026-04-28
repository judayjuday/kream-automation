# 작업지시서 1: 허브넷 봇 + PDF 자동 다운로드

작성일: 2026-04-28
대상 시스템: KREAM 자동화 (`~/Desktop/kream_automation/`)
관련 문서: `KREAM_허브넷_SSRO_통합아키텍처_v1.md`
다음 단계: `작업지시서_2_KREAM_SSRO_동기화` (예정)

---

## 0. 작업 목적과 범위

### 목적
KREAM에서 판매가 발생할 때마다, 허브넷에서 해당 주문의 송장 PDF를 자동으로 다운로드해서 로컬에 저장한다. 향후 SSRO 동기화 단계에서 이 PDF를 Supabase Storage로 푸시할 예정.

### 범위
**포함:**
- 허브넷 자동 로그인 + 세션 관리
- 허브넷 주문 데이터 조회 (KREAM `sales_history` 기준 매칭)
- 송장 HTML 페이지 → PDF 자동 변환
- 로컬 PDF 저장 (`~/Desktop/kream_automation/labels/`)
- 판매 수집 스케줄러와 자동 연결
- 대시보드에 PDF 다운로드 현황 표시

**제외 (다음 작업지시서):**
- SSRO 연동
- Supabase Storage 업로드
- 협력사 발주 엑셀 생성
- 위챗 메시지 자동 생성

---

## 1. 사전 발견 사항 (이미 확인됨)

### 1.1 허브넷 시스템 구조
- **SPA 아님.** jQuery + AJAX 서버 (PHP 추정)
- **봇 감지 없음.** Playwright 불필요 (단, PDF 변환에는 사용)
- **세션 인증.** 쿠키 기반
- **로그인 엔드포인트:** `POST https://kpartner.ehub24.net/auth`
- **데이터 조회 엔드포인트:** `POST https://kpartner.ehub24.net/list_ajax`
- **송장 출력 엔드포인트:** `POST https://kpartner.ehub24.net/kream_invoice_print`

### 1.2 사용자 식별 정보 (HTML에서 추출됨)
```
userPt2 = "61"           # 셀러 ID
userPt3 = "CN"           # Origin 코드
userEmail = "judaykream@gmail.com"
userLevel = "1"
```

### 1.3 응답 데이터 필드 매핑
허브넷 `list_ajax` 응답의 `data[]` 안 필드:

| 필드명 | 의미 | 예시 |
|-------|------|------|
| `add1` | 주문번호 | `A-SN160261934` |
| `add2` | **HBL 번호** ⭐ | `H2604252301517` |
| `add3` | 송하인 | `주데이` |
| `add9` | 품명 | `Asics Gel-1090 White Silver` |
| `add10` | 수량 | `1` |
| `add12` | 중량 | `2.00` |
| `add16` | 볼륨중량 | `1.82` |
| `add26` | Origin | `CN` |
| `add56` | 택배번호 | (대부분 비어있음) |
| `add146` | 작업 상태 | |
| `tracking` | 트래킹 번호 | (대부분 비어있음) |
| `order_yn` | 취소 여부 | `Y`=취소, `N`=정상 |

### 1.4 KREAM ↔ 허브넷 매칭 키
- KREAM `sales_history.order_id` ↔ 허브넷 `add1` (주문번호)
- 단, KREAM order_id 형식이 허브넷 add1 형식(`A-SN160261934`)과 정확히 일치하는지 검증 필요. 다를 경우 model+size 기반 보조 매칭 로직 필요.

### 1.5 송장 PDF 흐름
허브넷에서 PDF는 직접 다운로드되지 않고 다음 흐름:
1. `list_ajax`에 `mode=get_print_invoice` + HBL 번호들 전송
2. 응답으로 송장 데이터 JSON 반환
3. JS가 새 창을 열고 `kream_invoice_print` 엔드포인트에 그 JSON을 POST
4. 새 창에 송장 HTML 페이지 렌더링 (사용자가 인쇄 → PDF로 저장)

→ **자동화 전략:** Python으로 1~3단계 수행 → 받은 HTML을 Playwright headless 브라우저에 로드 → `page.pdf()` 호출

---

## 2. DB 스키마 변경

### 2.1 신규 테이블: `hubnet_orders`
허브넷에서 조회한 주문 데이터 캐시.

```sql
CREATE TABLE IF NOT EXISTS hubnet_orders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    hbl_number TEXT NOT NULL UNIQUE,
    order_no TEXT NOT NULL,                  -- 허브넷 add1 (A-SN...)
    shipper TEXT,                            -- 송하인 (주데이)
    product_name TEXT,                       -- 품명
    quantity INTEGER,
    weight REAL,
    volume_weight REAL,
    origin TEXT,                             -- CN/JP
    tracking TEXT,
    delivery_no TEXT,
    work_status TEXT,
    order_status TEXT,                       -- normal/cancelled
    raw_data TEXT,                           -- JSON 원본 (디버깅용)
    fetched_at TEXT DEFAULT CURRENT_TIMESTAMP,
    matched_kream_order_id TEXT,             -- KREAM sales_history.order_id
    matched_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_hubnet_order_no ON hubnet_orders(order_no);
CREATE INDEX IF NOT EXISTS idx_hubnet_kream_match ON hubnet_orders(matched_kream_order_id);
```

### 2.2 신규 테이블: `hubnet_pdf_log`
PDF 다운로드 시도/결과 이력.

```sql
CREATE TABLE IF NOT EXISTS hubnet_pdf_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    hbl_number TEXT NOT NULL,
    kream_order_id TEXT,
    pdf_path TEXT,                           -- 로컬 저장 경로
    file_size INTEGER,
    status TEXT NOT NULL,                    -- success/failed/skipped/duplicate
    error_message TEXT,
    duration_ms INTEGER,
    triggered_by TEXT,                       -- scheduler/manual/sync_request
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_pdf_log_hbl ON hubnet_pdf_log(hbl_number);
CREATE INDEX IF NOT EXISTS idx_pdf_log_status ON hubnet_pdf_log(status);
CREATE INDEX IF NOT EXISTS idx_pdf_log_created ON hubnet_pdf_log(created_at);
```

### 2.3 기존 테이블 수정: `sales_history`
```sql
-- ⚠️ NULL 허용 필수 (CLAUDE.md 절대 규칙)
ALTER TABLE sales_history ADD COLUMN hbl_number TEXT;
ALTER TABLE sales_history ADD COLUMN pdf_path TEXT;
ALTER TABLE sales_history ADD COLUMN pdf_downloaded_at TEXT;
```

### 2.4 마이그레이션 절차
1. 백업 먼저: `cp price_history.db price_history_backup_$(date +%Y%m%d).db`
2. 신규 테이블 + ALTER 실행
3. `/api/health` 확인하여 서버 정상 동작 검증
4. CLAUDE.md `db-migration` SKILL 준수

---

## 3. 신규 파일

### 3.1 `kream_hubnet_bot.py` (신규, ~600줄 예상)
허브넷 통신 + PDF 변환 핵심 모듈.

**주요 함수 (시그니처):**

```python
import requests
from playwright.async_api import async_playwright

# ─── 인증 ────────────────────────────────────────
def hubnet_login(email: str, password: str) -> requests.Session
    """허브넷 로그인. 성공 시 인증된 Session 반환.
    실패 시 RuntimeError. 빈 세션 저장 금지."""

def save_hubnet_session(session: requests.Session, path: str)
    """쿠키만 JSON으로 저장. ~/Desktop/kream_automation/auth_state_hubnet.json"""

def load_hubnet_session(path: str) -> requests.Session | None
    """저장된 쿠키 로드. 만료 시 None 반환."""

def ensure_hubnet_logged_in() -> requests.Session
    """세션 로드 → 만료면 재로그인. settings.json에서 자격증명 읽음."""

# ─── 데이터 조회 ────────────────────────────────────
def fetch_hubnet_orders(
    session: requests.Session,
    start_date: str,           # 'YYYY-MM-DD'
    end_date: str,
    search_mode: str = 'date_only',  # 'date_only' | 'bulk_hbl' | 'bulk_order'
    bulk_numbers: list[str] = None,
    page_size: int = 100,
) -> list[dict]
    """허브넷 KREAM HBL 조회.
    반환: list of {hbl_number, order_no, shipper, product_name, qty, ...}
    실패 시 RuntimeError, 폴백 금지."""

def upsert_hubnet_orders(orders: list[dict])
    """hubnet_orders 테이블에 UPSERT (hbl_number 기준)."""

# ─── KREAM 매칭 ─────────────────────────────────────
def match_hubnet_to_kream(kream_order_id: str) -> dict | None
    """KREAM order_id로 허브넷 주문 찾기.
    1차: 정확 일치 (add1 == order_id)
    2차: model+size 보조 매칭 (1차 실패 시)
    3차: NULL 반환 (매칭 실패 — '수집 실패' 명시, 폴백 금지)"""

def update_kream_sales_with_hbl(kream_order_id: str, hbl_number: str)
    """sales_history에 hbl_number 채우기."""

# ─── PDF 변환 ────────────────────────────────────────
async def fetch_invoice_html(
    session: requests.Session,
    hbl_numbers: list[str],
) -> str
    """
    1. /list_ajax mode=get_print_invoice → 송장 데이터 JSON 받음
    2. /kream_invoice_print에 POST하여 HTML 페이지 받음
    3. HTML 문자열 반환
    """

async def html_to_pdf(
    html: str,
    output_path: str,
    base_url: str = 'https://kpartner.ehub24.net/',
) -> dict
    """
    Playwright headless로 HTML → PDF 변환.
    base_url 설정 필수 (상대 경로 리소스 로드).
    반환: {success, pdf_path, file_size, error}
    A4 사이즈, 여백 0.5cm.
    """

async def download_invoice_pdf(
    hbl_number: str,
    kream_order_id: str = None,
    triggered_by: str = 'manual',
) -> dict
    """
    단일 HBL의 송장 PDF 다운로드 + 저장.
    경로: ~/Desktop/kream_automation/labels/{YYYYMM}/{HBL}_{model}_{size}_{date}.pdf
    중복 다운로드 방지 (파일 존재 + DB 체크).
    hubnet_pdf_log에 결과 기록.
    """

async def download_pending_invoices(
    triggered_by: str = 'scheduler',
    limit: int = 50,
) -> dict
    """
    sales_history에서 PDF 미다운로드 건 조회 → 일괄 다운로드.
    반환: {total, success, failed, skipped, errors:[]}
    """

# ─── CLI 모드 ────────────────────────────────────────
async def main():
    # python3 kream_hubnet_bot.py --mode auth
    # python3 kream_hubnet_bot.py --mode fetch --start 2026-04-21 --end 2026-04-28
    # python3 kream_hubnet_bot.py --mode pdf --hbl H2604252301517
    # python3 kream_hubnet_bot.py --mode pending
```

### 3.2 `auth_state_hubnet.json` (신규, 자동 생성)
허브넷 세션 쿠키 저장. 형식 예시:
```json
{
  "cookies": [
    {"name": "PHPSESSID", "value": "...", "domain": "kpartner.ehub24.net", ...}
  ],
  "saved_at": "2026-04-28T10:00:00",
  "expires_estimate": "2026-05-28T10:00:00"
}
```

⚠️ **`.gitignore`에 추가 필수.** 인수인계서 v7 §11 규칙 준수.

### 3.3 `~/Desktop/kream_automation/labels/` 폴더 (신규)
PDF 저장 디렉토리. 구조:
```
labels/
├── 202604/
│   ├── H2604252301517_1203A243-100_230_20260425.pdf
│   ├── H2604221701468_1203A243-021_240_20260422.pdf
│   └── ...
├── 202605/
└── ...
```

월별 폴더로 분리 (한 폴더에 너무 많은 파일 방지).

---

## 4. 기존 파일 수정

### 4.1 `kream_server.py` — API 6개 추가

| 메서드 | 경로 | 설명 |
|--------|------|------|
| GET | `/api/hubnet/status` | 허브넷 세션 상태 + 통계 |
| POST | `/api/hubnet/login` | 수동 재로그인 (자격증명 settings.json에서) |
| POST | `/api/hubnet/sync` | 허브넷 데이터 수동 조회 (날짜 범위) |
| POST | `/api/hubnet/pdf/download` | 특정 HBL PDF 강제 다운로드 |
| POST | `/api/hubnet/pdf/batch` | pending 일괄 다운로드 트리거 |
| GET | `/api/hubnet/pdf/log` | 다운로드 이력 조회 (`?limit=50&status=all`) |

**주의:** CLAUDE.md `api-addition` SKILL 준수. 모든 응답은 표준 JSON 구조 `{success, data?, error?}`.

### 4.2 `kream_server.py` — 판매 수집 스케줄러에 후속 작업 추가
기존 `_run_sales_collection()` 함수 마지막에 추가:
```python
# 판매 수집 직후 → 허브넷 PDF 다운로드 트리거
try:
    if settings.get('hubnet_auto_pdf', True):
        result = await download_pending_invoices(triggered_by='scheduler', limit=20)
        if result['failed'] > 0:
            send_alert(f"허브넷 PDF 다운로드 {result['failed']}건 실패", ...)
except Exception as e:
    # 허브넷 실패가 판매 수집을 막으면 안 됨
    log_error(f"허브넷 PDF 다운로드 오류: {e}")
```

⚠️ **격리 원칙:** 허브넷 실패해도 판매 수집은 정상 완료. 알림만 발송.

### 4.3 `tab_logistics.html` — 허브넷 패널 추가

기존 물류 관리 탭에 신규 섹션:

```
┌─ 허브넷 PDF 자동 다운로드 ─────────────────────┐
│  세션 상태: 🟢 정상 (마지막 로그인: 2시간 전)   │
│  자동 다운로드: 🟢 ON                           │
│  [수동 재로그인] [지금 동기화] [설정]            │
│                                                 │
│  📊 오늘 통계                                   │
│  ├─ 다운로드 성공: 12건                          │
│  ├─ 실패: 0건                                   │
│  ├─ 매칭 실패 (KREAM↔허브넷): 1건 ⚠️           │
│  └─ 평균 소요: 3.2초/건                         │
│                                                 │
│  📋 최근 다운로드 이력 (최근 20건)               │
│  ┌─────────┬──────────┬──────┬────────┬───┐    │
│  │ 시각     │ HBL      │ 품명 │ 상태   │   │    │
│  ├─────────┼──────────┼──────┼────────┼───┤    │
│  │ 11:32:15│ H260425..│ Asics│ ✅ 완료│📄│    │
│  │ 11:32:08│ H260422..│ Asics│ ✅ 완료│📄│    │
│  │ 09:01:33│ H260420..│ Adidas│ ❌ 실패│↻│    │
│  └─────────┴──────────┴──────┴────────┴───┘    │
└─────────────────────────────────────────────────┘
```

- 📄 클릭 → 로컬 PDF 새 탭으로 열기
- ↻ 클릭 → 실패 건 재시도

### 4.4 `settings.json` — 신규 키 추가
```json
{
  "hubnet_email": "judaykream@gmail.com",
  "hubnet_password": "1234",
  "hubnet_auto_pdf": true,
  "hubnet_pdf_max_per_run": 20,
  "hubnet_session_path": "/Users/iseungju/Desktop/kream_automation/auth_state_hubnet.json",
  "hubnet_pdf_dir": "/Users/iseungju/Desktop/kream_automation/labels"
}
```

⚠️ **`settings.json`은 이미 `.gitignore`에 있는지 확인.** 없으면 추가.

---

## 5. 단계별 구현 순서 (Claude Code 작업 지시)

각 단계 끝나면 **반드시 테스트 후 다음 단계로**.

### Step 1: 인프라 준비 (30분)
**목표:** DB 마이그레이션 + 폴더 + 설정 키
- [ ] `price_history.db` 백업
- [ ] `hubnet_orders`, `hubnet_pdf_log` 테이블 생성
- [ ] `sales_history`에 컬럼 3개 추가 (NULL 허용)
- [ ] `~/Desktop/kream_automation/labels/` 폴더 생성
- [ ] `settings.json`에 신규 키 추가
- [ ] `.gitignore`에 `auth_state_hubnet.json` 추가
- [ ] 검증: `sqlite3 price_history.db ".schema hubnet_orders"`

### Step 2: 허브넷 로그인 (1시간)
**목표:** Python으로 로그인 성공
- [ ] `kream_hubnet_bot.py` 신규 생성
- [ ] `hubnet_login()`, `save_hubnet_session()`, `load_hubnet_session()` 구현
- [ ] CLI 모드: `python3 kream_hubnet_bot.py --mode auth`
- [ ] 검증: 실행 후 `auth_state_hubnet.json` 생성됨, 쿠키 들어있음
- [ ] 검증: 두 번째 실행 시 기존 세션 재사용 (재로그인 X)

### Step 3: 허브넷 데이터 조회 (1시간)
**목표:** Python으로 KREAM HBL 목록 받아오기
- [ ] `fetch_hubnet_orders()` 구현
- [ ] `upsert_hubnet_orders()` 구현
- [ ] CLI: `python3 kream_hubnet_bot.py --mode fetch --start 2026-04-21 --end 2026-04-28`
- [ ] 검증: `hubnet_orders` 테이블에 데이터 채워짐
- [ ] 검증: 같은 명령 다시 실행해도 중복 없음 (UPSERT 동작)

### Step 4: KREAM ↔ 허브넷 매칭 (1시간)
**목표:** sales_history에 hbl_number 자동 채우기
- [ ] `match_hubnet_to_kream()` 구현 (1차 정확 일치만)
- [ ] `update_kream_sales_with_hbl()` 구현
- [ ] CLI: `python3 kream_hubnet_bot.py --mode match`
- [ ] 검증: 기존 sales_history 일부에 hbl_number 채워짐
- [ ] 검증: 매칭 실패 건은 NULL 유지 (가짜 값 금지)

### Step 5: 송장 HTML 받아오기 (1시간)
**목표:** Python으로 송장 HTML 페이지 받기
- [ ] `fetch_invoice_html()` 구현
- [ ] CLI: `python3 kream_hubnet_bot.py --mode html --hbl H2604252301517`
- [ ] 검증: HTML 파일이 `/tmp/test_invoice.html`로 저장됨
- [ ] 검증: 브라우저로 열면 송장 화면 보임

### Step 6: HTML → PDF 변환 (2시간)
**목표:** Playwright로 PDF 생성
- [ ] `html_to_pdf()` 구현
- [ ] CLI: `python3 kream_hubnet_bot.py --mode pdf --hbl H2604252301517`
- [ ] 검증: PDF 파일이 `~/Desktop/kream_automation/labels/202604/`에 저장됨
- [ ] 검증: 받은 PDF가 사용자 제공 샘플과 동일한 형태인지 비교

### Step 7: 통합 함수 + 일괄 다운로드 (1시간)
**목표:** `download_invoice_pdf()`, `download_pending_invoices()` 동작
- [ ] 두 함수 구현
- [ ] CLI: `python3 kream_hubnet_bot.py --mode pending`
- [ ] 검증: 다운로드 결과가 `hubnet_pdf_log`에 기록됨
- [ ] 검증: 이미 다운로드된 건은 skip 처리됨

### Step 8: API 엔드포인트 (1시간)
**목표:** `kream_server.py`에 6개 API 추가
- [ ] 6개 엔드포인트 추가 (CLAUDE.md `api-addition` SKILL 준수)
- [ ] curl 테스트 작성: `curl http://localhost:5001/api/hubnet/status`
- [ ] 검증: 모든 응답이 `{success, ...}` 표준 형식

### Step 9: 대시보드 UI (1.5시간)
**목표:** `tab_logistics.html`에 허브넷 패널 추가
- [ ] 상태 표시 + 통계 영역
- [ ] 다운로드 이력 테이블
- [ ] [수동 재로그인] [지금 동기화] 버튼
- [ ] PDF 새 탭 열기 (📄)
- [ ] 실패 재시도 (↻)
- [ ] 검증: 브라우저에서 작동 확인

### Step 10: 스케줄러 통합 (30분) ⚠️ 가장 신중하게
**목표:** 판매 수집 후 자동 PDF 다운로드
- [ ] `_run_sales_collection()` 끝에 트리거 추가
- [ ] 격리: try/except로 감싸기 (허브넷 실패 시 판매 수집 영향 X)
- [ ] settings의 `hubnet_auto_pdf` 체크 (기본 false로 시작 권장)
- [ ] 검증: 수동으로 판매 수집 트리거 → PDF 자동 다운로드 확인
- [ ] 검증: 일부러 허브넷 실패 시키고 판매 수집은 정상 완료되는지

### Step 11: 프로덕션 활성화 (사용자 확인 후)
- [ ] 며칠 수동 모드로 안정성 검증
- [ ] 문제 없으면 settings의 `hubnet_auto_pdf: true`로 변경
- [ ] 인수인계서 v8 작성

---

## 6. 위험 요소 + 대응

### 6.1 알려진 위험

| 위험 | 가능성 | 영향 | 대응 |
|------|--------|------|------|
| 허브넷 세션 만료 | 중 | 중 | 재로그인 자동화 + 빈 세션 저장 금지 |
| 허브넷 API 변경 | 저 | 고 | 응답 검증 + 변경 감지 알림 |
| KREAM ↔ 허브넷 매칭 실패 | 중 | 중 | NULL 유지 + 대시보드 알림 |
| 송장 페이지 구조 변경 | 저 | 고 | PDF 변환 실패 알림 + 수동 fallback |
| Playwright 메모리 누수 | 중 | 저 | 함수 단위로 browser 닫기 |
| PDF 디스크 공간 폭발 | 저 | 저 | 월별 폴더 + 90일 후 자동 압축 (별도 작업) |
| 동시 다운로드 충돌 | 저 | 저 | DB 트랜잭션 + Lock |

### 6.2 절대 하지 말아야 할 것 (CLAUDE.md 절대 규칙)

1. **빈 세션 저장 금지.** 로그인 실패 시 `auth_state_hubnet.json` 덮어쓰기 X
2. **매칭 실패 시 폴백 금지.** 가짜 HBL 사용 X, NULL 유지
3. **DB DROP/DELETE 금지.** 마이그레이션 시 ALTER만
4. **`auth_state_hubnet.json` git push 금지.** `.gitignore` 필수
5. **테스트로 실제 송장 인쇄 금지.** 다운로드만, 실제 인쇄 X

### 6.3 검증 시스템 활용
- Claude Code 작업 시 매 단계마다 `.claude/hooks/syntax-check.sh` 자동 실행됨
- DB 변경은 `.claude/skills/db-migration/SKILL.md` 준수
- API 추가는 `.claude/skills/api-addition/SKILL.md` 준수
- Stop hook이 체크리스트 환기

---

## 7. 검증 시나리오

### 7.1 단위 검증 (각 Step 끝)
각 Step의 [검증] 항목 통과 필수.

### 7.2 통합 검증 (Step 11 직전)
시나리오 1: 정상 플로우
1. 새 KREAM 판매 발생 (또는 sales_history에 임시 데이터 INSERT)
2. 판매 수집 스케줄러 수동 실행
3. 허브넷 PDF 자동 다운로드되는지 확인
4. `~/Desktop/kream_automation/labels/202604/` 에 파일 생성 확인
5. `hubnet_pdf_log` 테이블에 success 기록 확인
6. 대시보드에서 신규 다운로드 표시 확인

시나리오 2: 매칭 실패 케이스
1. 허브넷에 없는 KREAM 주문 추가
2. 판매 수집 트리거
3. PDF 다운로드 시도 → 매칭 실패로 skip
4. `hubnet_pdf_log`에 status=failed 기록
5. 대시보드에 "매칭 실패 1건" 표시

시나리오 3: 세션 만료 복구
1. `auth_state_hubnet.json` 일부러 손상
2. PDF 다운로드 트리거
3. 자동 재로그인 후 정상 다운로드
4. 새 쿠키로 세션 갱신됨

시나리오 4: 격리 검증
1. 허브넷 일시 차단 (가짜 URL 설정)
2. 판매 수집 트리거
3. 판매 수집은 정상 완료
4. 허브넷 다운로드는 실패 + 알림
5. 다음 사이클에 재시도

---

## 8. 다음 작업지시서 연결

이 작업 완료 후, **작업지시서 2 (KREAM → SSRO 동기화)** 시작 가능.

작업지시서 2에서 추가될 것:
- `ssro_sync.py` 신규
- Supabase Storage에 PDF 업로드 (이 작업의 `pdf_path` 활용)
- SSRO `orders`에 platform="kream" INSERT
- `hubnet_pdf_url` 컬럼에 Storage URL 저장

작업지시서 3에서 추가될 것:
- SSRO 측 InboundPage 수정
- 위챗 메시지 자동 생성

---

## 9. Claude Code 실행 명령

```bash
cd ~/Desktop/kream_automation
claude --dangerously-skip-permissions
```

**첫 프롬프트 예시:**
```
~/Desktop/kream_automation/CLAUDE.md를 읽고, 작업지시서 1번
(작업지시서_1_허브넷봇_PDF자동다운로드_v1.md)의 Step 1: 인프라 준비
부터 진행해줘. 각 Step 끝나면 검증 결과 보고하고 사용자 확인 후
다음 Step으로 진행.
```

**Step 별 진행 방식:**
- Claude Code가 한 Step 끝내면 → 검증 결과 보고 → 승주님이 "다음 Step" 승인
- 격리 원칙: 한 Step 작업 중 다른 시스템 손대지 않음
- 인수인계서는 작업 끝나면 v8로 업데이트

---

## 10. 산출물 체크리스트

작업 완료 시 다음이 모두 충족되어야 함:

- [ ] `kream_hubnet_bot.py` 신규 생성, 모든 함수 동작
- [ ] DB 테이블 2개 신규 + sales_history 컬럼 3개 추가
- [ ] `~/Desktop/kream_automation/labels/` 폴더에 PDF 자동 저장
- [ ] `kream_server.py`에 API 6개 추가
- [ ] `tab_logistics.html`에 허브넷 패널 추가
- [ ] 판매 수집 스케줄러와 통합 (격리됨)
- [ ] 대시보드에서 다운로드 현황 실시간 확인 가능
- [ ] 4가지 검증 시나리오 모두 통과
- [ ] 인수인계서 v8 작성 (이 작업 반영)
- [ ] git commit + push (auth_state_hubnet.json은 제외)

---

## 부록 A. 자료 참고

작업지시서와 함께 보관할 파일:
- 허브넷 로그인 페이지 HTML 캡처
- 허브넷 list 페이지 HTML 캡처 (필드 매핑 검증용)
- 허브넷 송장 PDF 샘플 (`KREAM_B_L_라벨_출력-예시.pdf`)
- 허브넷 list 페이지 스크린샷 (UI 흐름 참고)

## 부록 B. 예상 소요 시간

| 단계 | 예상 시간 |
|------|----------|
| Step 1~7 (구현) | 7시간 |
| Step 8~9 (서버 + UI) | 2.5시간 |
| Step 10 (스케줄러 통합) | 30분 |
| Step 11 (안정화) | 며칠 (시간보다 일수) |
| **합계** | **약 10시간 + 안정화 기간** |

Claude Code 사용 시 더 빠를 수 있으나, 검증 시간 포함하면 위와 비슷.
