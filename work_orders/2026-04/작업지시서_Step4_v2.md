# Step 4: 자동 재입찰 시스템 — Claude Code 작업지시서 v2

**작성일:** 2026-04-24
**버전:** v2 (선행 탐색 섹션 추가, 롤백 계획 추가, 로직 검증 테스트 보강)
**단일 커밋:** `feat: 자동 재입찰 시스템 (기본 OFF, 무한루프 방지, 가격 급변 감지)`
**예상 소요:** 선행 탐색 15분 + 구현 60~90분 + 테스트 20분

---

## 📌 Claude Code 실행 순서 요약

1. **이 지시서 처음부터 끝까지 읽기** (특히 0.5절 선행 탐색과 7절 롤백)
2. **0.5절 탐색 1~9 모두 실행** → 탐색 결과 보고서 작성
3. 보고서 기반으로 지시서의 코드 예시를 실제 코드베이스에 맞게 **조정**
4. STEP 2.1 → 2.2 → 2.3 → 2.4 → 2.5 순서로 구현
5. 3절 테스트 시나리오 3.1 ~ 3.9 모두 실행
6. 4절 체크리스트 전체 확인
7. 6절 Git 작업 원칙 따라 커밋/푸시
8. 8절 완료 보고 양식에 따라 한국어로 보고

**지시서의 코드 예시는 "이런 형태로 만들라"는 골격이지 복사-붙여넣기용이 아님.**
**실제 코드베이스 구조를 우선하고, 지시서 의도와 충돌하면 승주님에게 확인.**

---

## 0. 사전 확인 (작업 시작 전)

### CLAUDE.md 절대 규칙 6개 재확인
1. ❌ 원가 없으면 가짜 값 사용 금지 → NULL
2. ❌ 판매 완료 건 수정/삭제 금지
3. ❌ price_history.db 직접 DROP/DELETE 금지
4. ❌ auth_state.json 백업 없이 덮어쓰기 금지
5. ❌ git push -f, git reset --hard 금지
6. ❌ 테스트 데이터로 실제 입찰 금지

### 검증 시스템 동작 확인
- `.claude/settings.json` Hook 정상 동작
- `db-migration`, `api-addition` Skill 참조

---

## 0.5 선행 탐색 (⚠️ 필수 — 코드 작성 전 먼저 실행)

**이 지시서는 "이런 구조로 만들어야 한다"는 설계도이지, 구체적인 함수명/변수명까지 확정된 게 아닙니다.**
Claude Code는 기존 코드베이스를 먼저 탐색해서 아래 정보를 파악한 후 지시서의 의도에 맞게 구현할 것.

### 탐색 1: DB / 설정 / 헬퍼 함수 이름 확인

```bash
cd ~/Desktop/kream_automation

# 1-1. DB 초기화 함수 위치
grep -n "CREATE TABLE IF NOT EXISTS" kream_server.py | head -10
grep -n "def init_db\|def init_database\|def create_tables" kream_server.py

# 1-2. DB 경로 상수
grep -n "DB_PATH\|price_history.db\|sqlite3.connect" kream_server.py | head -10

# 1-3. 설정 로드/저장 함수 실제 이름
grep -n "def load_settings\|def save_settings\|def get_settings\|def update_settings" kream_server.py

# 1-4. settings.json 기본값 병합 패턴
grep -n "DEFAULT_SETTINGS\|default_settings\|settings.setdefault" kream_server.py | head -10

# 1-5. Flask app 변수명
grep -n "app = Flask\|@app.route" kream_server.py | head -5
```

**Claude Code는 위 결과를 바탕으로 지시서의 `load_settings()`, `save_settings()`, `DB_PATH`, `app` 을 실제 이름으로 치환해서 구현할 것.**

### 탐색 2: 판매 수집 스케줄러 통합 지점 찾기

```bash
# 2-1. 판매 수집 스케줄러 함수 이름
grep -n "def.*sales.*sync\|_run_sales\|sales_scheduler\|collect_shipments" kream_server.py

# 2-2. 스케줄러가 new_items를 어떻게 만드는지 확인
grep -n "new_items\|new_count\|INSERT INTO sales_history" kream_server.py | head -20

# 2-3. 판매 수집 스케줄러 함수 전문 확인 (함수 길이에 따라 조정)
# 위 2-1 결과의 라인 번호를 L이라 할 때:
# sed -n 'L,L+150p' kream_server.py
```

**Claude Code는 스케줄러 함수 끝부분 (새 판매 감지 후) 에 `auto_rebid_after_sale()` 호출을 추가.**
**new_items dict의 실제 키 이름(order_id / product_id / model / size / sale_price)을 반드시 확인하고 맞춰서 사용할 것.**

### 탐색 3: 기존 원가 계산 / 정산액 계산 로직 찾기

```bash
# 3-1. 원가/마진/정산액 관련 함수 검색
grep -n "expected_profit\|정산액\|settlement\|profit\|margin" kream_server.py | head -30

# 3-2. /api/adjust/pending 쪽 구현 찾기 (Step 3에서 이미 계산식 있음)
grep -n "adjust/pending\|calculate_profit\|bid_cost" kream_server.py | head -20

# 3-3. 수수료율/고정수수료 상수
grep -n "feeRate\|fee_rate\|FIXED_FEE\|2500" kream_server.py | head -10
```

**Claude Code는 새 함수를 만들기 전에 반드시 기존 계산 로직이 있는지 확인하고, 있으면 재사용/리팩토링할 것.**
**없으면 인수인계서 11항의 공식대로 구현:**
- `정산액 = 판매가 × (1 - 0.06 × 1.1) - 2500`
- `원가 = CNY × 환율 × 1.03 + 8000`
- `예상수익 = 정산액 - 원가`

### 탐색 4: 기존 async API 처리 패턴 (asyncio 충돌 방지)

```bash
# 4-1. /api/bid, /api/register 같은 async 호출 API가 Flask에서 어떻게 처리되는지
grep -n "new_event_loop\|run_until_complete\|asyncio.run" kream_server.py | head -15

# 4-2. /api/adjust/run-once 같은 기존 수동 실행 API 패턴 (Step 3에서 만든 것)
grep -n "auto_adjust.*run_once\|/api/auto-adjust/run-once" kream_server.py -A 20 | head -40

# 4-3. /api/sales/sync 가 어떻게 돌고있는지
grep -n "/api/sales/sync" kream_server.py -A 20 | head -30
```

**Claude Code는 기존 async API의 asyncio 루프 처리 패턴을 그대로 따를 것. 지시서 2.4.3의 코드는 참고용이며, 기존 패턴과 다르면 기존 패턴 우선.**

### 탐색 5: place_bid() 래퍼 — 브라우저 세션 관리 패턴

```bash
# 5-1. 기존에 place_bid를 호출하는 엔드포인트들이 어떻게 브라우저를 여는지
grep -n "place_bid\|create_browser\|ensure_logged_in" kream_server.py | head -20

# 5-2. /api/bid 엔드포인트 전문 (패턴 참고용)
grep -n "/api/bid\"" kream_server.py -A 50 | head -70

# 5-3. save_state_with_localstorage 호출 패턴
grep -n "save_state_with_localstorage" kream_server.py | head -10
```

**Claude Code는 `_execute_rebid()` 를 구현할 때 위 패턴을 그대로 따를 것:**
1. `async with async_playwright() as p:`
2. `browser = await create_browser(p, headless=False)`
3. `context = await create_context(browser, storage='auth_state.json')`
4. `page = await context.new_page()`
5. `await ensure_logged_in(page, context)`
6. `await place_bid(page, bid_data)`
7. `await save_state_with_localstorage(page, context, 'auth_state.json', 'https://partner.kream.co.kr')`
8. `await context.close()` → `await browser.close()`

### 탐색 6: sales_history 실제 스키마와 collect_shipments 매핑

```bash
# 6-1. sales_history 실제 스키마
sqlite3 ~/Desktop/kream_automation/price_history.db ".schema sales_history"

# 6-2. collect_shipments가 반환하는 dict 키 확인
grep -n "def collect_shipments\|def _parse_shipment_row" kream_bot.py -A 30 | head -60

# 6-3. INSERT INTO sales_history 쿼리로 컬럼 확인
grep -n "INSERT INTO sales_history\|INSERT OR" kream_server.py | head -5
```

**Claude Code는 `auto_rebid_after_sale()` 의 입력 dict 키를 sales_history 실제 컬럼과 맞출 것.**
**특히 `sale_price` 컬럼명 / `product_id` 채워지는지 / `order_id` UNIQUE 여부 확인.**

### 탐색 7: KREAM 가격 수집 함수 재사용

```bash
# 7-1. 기존 가격 수집 래퍼
grep -n "def collect_prices\|def collect_from_kream\|async def search_product" kream_server.py kream_collector.py | head -10

# 7-2. /api/search 엔드포인트 내부 로직
grep -n "/api/search\"" kream_server.py -A 30 | head -40
```

**Claude Code는 `_fetch_kream_prices_for_model(model)` 를 구현할 때 `kream_collector.collect_prices` 또는 `/api/search` 의 내부 로직을 재사용할 것.**
**사이즈별 buy_price 딕셔너리로 반환하는 형태로 래핑. 반드시 각 사이즈 개별 매핑 (인수인계서 11항 "즉시구매가 정의" 준수).**

### 탐색 8: health_alert 시그니처

```bash
# 8-1. health_alert 함수 실제 시그니처
grep -n "def send_health_alert\|def health_alert\|import health_alert" kream_server.py health_alert.py | head -10

# 8-2. 기존 호출 예시
grep -n "send_health_alert\|health_alert\." kream_server.py | head -10
```

**Claude Code는 지시서의 `send_health_alert('type', 'msg')` 호출을 실제 시그니처에 맞춰 수정할 것.**

### 탐색 9: my_bids_local.json 실제 구조

```bash
# 9-1. 실제 JSON 구조 확인 (상위 레벨만)
python3 -c "import json; d=json.load(open('my_bids_local.json')); \
  print('keys:', list(d.keys())); \
  print('first bid keys:', list(d.get('bids', [{}])[0].keys()) if d.get('bids') else 'EMPTY')"
```

**Claude Code는 `_get_my_other_bids()` 함수의 키 이름(`orderId` vs `order_id`, `price` vs `bid_price`, `size` 형식 등)을 실제 구조에 맞출 것.**

---

## 🛑 탐색 결과 보고 의무

Claude Code는 위 9개 탐색을 **모두** 수행한 후, 다음 항목을 명시적으로 보고한 뒤에만 구현에 들어갈 것:

```
## 선행 탐색 결과 보고

1. DB 초기화 함수 이름: `XXX()`
2. 설정 로드/저장: `load_settings()` / `save_settings()` 존재 여부: [O/X]
3. DB_PATH 상수: `XXX`
4. Flask app 변수: `app` (표준)
5. 판매 수집 스케줄러 함수: `XXX()`
6. sales_history 실제 컬럼: [...]
7. 기존 원가 계산 함수: `XXX()` 재사용 [O/X]
8. asyncio 처리 패턴: [new_event_loop / asyncio.run / 기존 함수 재사용]
9. place_bid 래퍼 패턴: [기존 /api/bid 구조 따름]
10. KREAM 가격 수집 재사용: `XXX()`
11. send_health_alert 시그니처: `XXX(type, msg)`
12. my_bids_local.json 구조: {keys}

위 정보로 구현 가능: [O/X]
추가 확인 필요 항목: [없음 / 있으면 나열]
```

**탐색 결과와 지시서 2.3의 코드 예시가 충돌하면 → 실제 코드베이스 구조 우선.**

---

## 1. 설계 확정사항 (사전 검토 완료)

### 1.1 `place_bid()` 반환값 한계 대응
- `kream_bot.py:2316` 에서 `return bid_success` (Boolean만 반환)
- → `auto_rebid_log.new_order_id`는 **NULL 허용**
- 성공 여부만 기록, 추후 my-bids 동기화 시 역매칭 가능

### 1.2 "판매가 ±10%" 해석
- `재입찰가 < 판매가 × 0.9` 또는 `재입찰가 > 판매가 × 1.1` → 차단
- 시장 붕괴/폭등 시 자동 재입찰 멈춤

### 1.3 KREAM 가격 수집 최적화
- 동일 모델 여러 사이즈 판매 시 → 모델별 그룹핑 후 1회만 `/api/search` 호출
- 사이즈별 딕셔너리로 분배

### 1.4 자기 입찰 제외
- 경쟁자 가격 계산 시 `my_bids_local.json` 조회
- 해당 모델+사이즈에 내 다른 입찰이 최저가면 제외하고 그 다음 호가 사용

### 1.5 기본값 OFF
- `settings.json` 신규 3개 키 모두 기본 OFF/0/빈 리스트

---

## 2. 작업 순서

### STEP 2.1 — DB 마이그레이션 (auto_rebid_log 테이블)

**위치:** `kream_server.py` 내 DB 초기화 함수 (기존 `init_db()` 또는 유사 함수)

**추가할 SQL:**
```sql
CREATE TABLE IF NOT EXISTS auto_rebid_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    original_order_id TEXT,
    model TEXT,
    size TEXT,
    sold_price INTEGER,
    new_bid_price INTEGER,
    expected_profit INTEGER,
    action TEXT,
    skip_reason TEXT,
    new_order_id TEXT,
    executed_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_rebid_executed ON auto_rebid_log(executed_at);
CREATE INDEX IF NOT EXISTS idx_rebid_model_size ON auto_rebid_log(model, size, executed_at);
```

**action 값 enum (주석으로 명시):**
- `auto_rebid_success`: 재입찰 성공
- `skipped_no_cost`: 원가 없음
- `skipped_loop_guard`: 24시간 내 5회 초과
- `skipped_margin_low`: 마진 < 4,000원
- `skipped_price_shift`: 재입찰가가 판매가 ±10% 벗어남
- `skipped_blacklist`: 블랙리스트 모델
- `skipped_daily_limit`: 하루 최대 건수 초과
- `skipped_disabled`: 기능 OFF
- `rebid_failed`: 입찰 실행 실패

**db-migration Skill 준수:**
- NULL 허용 ✅
- DROP 없음 ✅
- 인덱스 명명: `idx_테이블_컬럼` 형식 ✅

---

### STEP 2.2 — `settings.json` 기본값 추가

**위치:** `settings.json` 로드 시 기본값 병합 로직 (기존 패턴 따름)

**추가 기본값:**
```python
DEFAULT_SETTINGS = {
    # ... 기존 ...
    "auto_rebid_enabled": False,
    "auto_rebid_daily_max": 20,
    "auto_rebid_blacklist": [],  # 모델번호 리스트
}
```

---

### STEP 2.3 — 자동 재입찰 엔진 (`kream_server.py`)

#### 2.3.1 헬퍼 함수들

```python
def _log_auto_rebid(conn, original_order_id, model, size, sold_price,
                     new_bid_price, expected_profit, action,
                     skip_reason=None, new_order_id=None):
    """auto_rebid_log에 기록."""
    conn.execute("""
        INSERT INTO auto_rebid_log
        (original_order_id, model, size, sold_price, new_bid_price,
         expected_profit, action, skip_reason, new_order_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (original_order_id, model, size, sold_price, new_bid_price,
          expected_profit, action, skip_reason, new_order_id))


def _count_recent_rebids(conn, model, size, hours=24):
    """같은 모델+사이즈의 최근 N시간 성공 재입찰 횟수."""
    cursor = conn.execute("""
        SELECT COUNT(*) FROM auto_rebid_log
        WHERE model = ? AND size = ?
          AND action = 'auto_rebid_success'
          AND executed_at > datetime('now', ?)
    """, (model, size, f'-{hours} hours'))
    return cursor.fetchone()[0]


def _count_today_success(conn):
    """오늘 자정 이후 성공 재입찰 총 건수."""
    cursor = conn.execute("""
        SELECT COUNT(*) FROM auto_rebid_log
        WHERE action = 'auto_rebid_success'
          AND date(executed_at) = date('now', 'localtime')
    """)
    return cursor.fetchone()[0]


def _get_my_other_bids(model, size, exclude_order_id):
    """내 입찰 중 해당 모델+사이즈의 다른 입찰들 (자기 입찰 제외용)."""
    try:
        with open('my_bids_local.json', 'r', encoding='utf-8') as f:
            data = json.load(f)
        bids = data.get('bids', [])
        return [b for b in bids
                if b.get('model') == model
                and str(b.get('size')) == str(size)
                and str(b.get('orderId')) != str(exclude_order_id)]
    except Exception:
        return []
```

#### 2.3.2 핵심 엔진 함수

```python
async def auto_rebid_after_sale(sale_records):
    """
    판매 감지 시 자동 재입찰 실행.

    Args:
        sale_records: list of dict
            [{'order_id': ..., 'model': ..., 'size': ...,
              'sale_price': ..., 'product_id': ...}, ...]

    Returns:
        dict: {'success': N, 'skipped': N, 'failed': N, 'details': [...]}
    """
    settings = load_settings()

    # 기능 OFF 체크 (최우선)
    if not settings.get('auto_rebid_enabled', False):
        return {'success': 0, 'skipped': len(sale_records), 'failed': 0,
                'details': [{'reason': 'skipped_disabled'} for _ in sale_records]}

    # sales 스케줄러 내부에서 호출되므로 DB 커넥션 새로 열기
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row

    try:
        results = {'success': 0, 'skipped': 0, 'failed': 0, 'details': []}

        # === 최적화: 모델별 그룹핑해서 KREAM 가격 1회만 수집 ===
        model_groups = {}
        for sale in sale_records:
            m = sale.get('model')
            model_groups.setdefault(m, []).append(sale)

        daily_max = settings.get('auto_rebid_daily_max', 20)
        blacklist = set(settings.get('auto_rebid_blacklist', []))
        min_profit = settings.get('auto_adjust_min_profit', 4000)

        for model, sales_for_model in model_groups.items():

            # [안전장치 5] 블랙리스트 체크 (모델 단위)
            if model in blacklist:
                for sale in sales_for_model:
                    _log_auto_rebid(conn, sale.get('order_id'), model,
                                    sale.get('size'), sale.get('sale_price'),
                                    None, None, 'skipped_blacklist',
                                    f'Model {model} in blacklist')
                    results['skipped'] += 1
                    results['details'].append({
                        'order_id': sale.get('order_id'),
                        'action': 'skipped_blacklist'
                    })
                continue

            # === 모델별 1회 KREAM 가격 수집 ===
            try:
                kream_data = await _fetch_kream_prices_for_model(model)
                # {size: {buy_price: int, ...}}
            except Exception as e:
                print(f"[auto_rebid] KREAM 수집 실패 {model}: {e}")
                for sale in sales_for_model:
                    _log_auto_rebid(conn, sale.get('order_id'), model,
                                    sale.get('size'), sale.get('sale_price'),
                                    None, None, 'rebid_failed',
                                    f'KREAM fetch failed: {e}')
                    results['failed'] += 1
                continue

            # === 사이즈별 처리 ===
            for sale in sales_for_model:
                order_id = sale.get('order_id')
                size = str(sale.get('size'))
                sold_price = sale.get('sale_price')

                # [안전장치 4] 하루 한도 체크
                today_count = _count_today_success(conn)
                if today_count >= daily_max:
                    _log_auto_rebid(conn, order_id, model, size, sold_price,
                                    None, None, 'skipped_daily_limit',
                                    f'Today: {today_count}/{daily_max}')
                    results['skipped'] += 1
                    results['details'].append({
                        'order_id': order_id,
                        'action': 'skipped_daily_limit'
                    })
                    continue

                # [안전장치 1] 원가 체크
                cursor = conn.execute(
                    "SELECT * FROM bid_cost WHERE order_id = ?", (order_id,))
                cost_row = cursor.fetchone()

                if not cost_row:
                    # 원가 데이터 없음 → 스킵 (원가 복구 도구는 별도)
                    _log_auto_rebid(conn, order_id, model, size, sold_price,
                                    None, None, 'skipped_no_cost',
                                    'bid_cost row not found')
                    results['skipped'] += 1
                    results['details'].append({
                        'order_id': order_id,
                        'action': 'skipped_no_cost'
                    })
                    continue

                # [안전장치 2] 루프 가드
                recent_count = _count_recent_rebids(conn, model, size, hours=24)
                if recent_count >= 5:
                    _log_auto_rebid(conn, order_id, model, size, sold_price,
                                    None, None, 'skipped_loop_guard',
                                    f'{recent_count} rebids in 24h')
                    results['skipped'] += 1
                    results['details'].append({
                        'order_id': order_id,
                        'action': 'skipped_loop_guard'
                    })
                    # 알림: 루프 가드 트리거
                    send_health_alert('auto_rebid_loop_guard',
                        f'{model} {size} 24시간 내 5회 재입찰 - 수동 확인 필요')
                    continue

                # === 재입찰가 계산 ===
                size_data = kream_data.get(size) or kream_data.get(str(size))
                if not size_data:
                    _log_auto_rebid(conn, order_id, model, size, sold_price,
                                    None, None, 'rebid_failed',
                                    f'Size {size} not in KREAM data')
                    results['failed'] += 1
                    continue

                competitor_price = size_data.get('buy_price')
                if not competitor_price:
                    _log_auto_rebid(conn, order_id, model, size, sold_price,
                                    None, None, 'rebid_failed',
                                    'No competitor buy_price')
                    results['failed'] += 1
                    continue

                # 자기 입찰 제외 (내 다른 입찰이 최저가면 그 다음 호가 사용)
                # → buy_price는 KREAM 전체 최저가이므로 내 입찰이 포함될 수 있음
                # → 재입찰 시점엔 방금 판매된 건이 사라졌으니 대체로 문제없지만,
                #    같은 모델+사이즈에 내가 다른 입찰 가지고 있을 수 있음
                my_others = _get_my_other_bids(model, size, order_id)
                if my_others:
                    # 내 최저가가 buy_price와 일치하면 다른 경쟁자 가격 필요
                    my_lowest = min((b.get('price', 0) for b in my_others),
                                    default=0)
                    if my_lowest and my_lowest <= competitor_price:
                        # 내 입찰이 최저가 → 그 다음 호가는 현재로선 알 수 없음
                        # → 안전하게 skip (자기 언더컷 방지)
                        _log_auto_rebid(conn, order_id, model, size, sold_price,
                                        None, None, 'skipped_margin_low',
                                        f'My own bid is lowest ({my_lowest})')
                        results['skipped'] += 1
                        continue

                # 언더컷 계산
                undercut = settings.get('undercut_amount', 1000)
                new_bid_price = competitor_price - undercut
                # 1,000원 단위 올림
                new_bid_price = math.ceil(new_bid_price / 1000) * 1000

                # [안전장치 3] 가격 급변 체크 (판매가 ±10%)
                lower_bound = sold_price * 0.9
                upper_bound = sold_price * 1.1
                if new_bid_price < lower_bound or new_bid_price > upper_bound:
                    _log_auto_rebid(conn, order_id, model, size, sold_price,
                                    new_bid_price, None, 'skipped_price_shift',
                                    f'Sold: {sold_price}, New: {new_bid_price}')
                    results['skipped'] += 1
                    results['details'].append({
                        'order_id': order_id,
                        'action': 'skipped_price_shift',
                        'new_bid_price': new_bid_price
                    })
                    send_health_alert('auto_rebid_price_shift',
                        f'{model} {size} 가격 급변 - 판매가 {sold_price} → 재입찰가 {new_bid_price}')
                    continue

                # 예상 수익 계산
                expected_profit = _calc_expected_profit(new_bid_price, cost_row)

                # [안전장치 마진 하한]
                if expected_profit < min_profit:
                    _log_auto_rebid(conn, order_id, model, size, sold_price,
                                    new_bid_price, expected_profit,
                                    'skipped_margin_low',
                                    f'Profit {expected_profit} < {min_profit}')
                    results['skipped'] += 1
                    results['details'].append({
                        'order_id': order_id,
                        'action': 'skipped_margin_low',
                        'expected_profit': expected_profit
                    })
                    continue

                # === 실제 입찰 실행 ===
                try:
                    bid_result = await _execute_rebid(
                        product_id=sale.get('product_id'),
                        model=model,
                        size=size,
                        price=new_bid_price,
                        cny_price=cost_row['cny_price'],
                    )

                    if bid_result.get('success'):
                        _log_auto_rebid(conn, order_id, model, size, sold_price,
                                        new_bid_price, expected_profit,
                                        'auto_rebid_success',
                                        None, None)  # new_order_id는 NULL
                        results['success'] += 1
                        results['details'].append({
                            'order_id': order_id,
                            'action': 'auto_rebid_success',
                            'new_bid_price': new_bid_price,
                            'expected_profit': expected_profit
                        })
                    else:
                        _log_auto_rebid(conn, order_id, model, size, sold_price,
                                        new_bid_price, expected_profit,
                                        'rebid_failed',
                                        bid_result.get('error', 'unknown'))
                        results['failed'] += 1

                except Exception as e:
                    _log_auto_rebid(conn, order_id, model, size, sold_price,
                                    new_bid_price, expected_profit,
                                    'rebid_failed', str(e))
                    results['failed'] += 1

            conn.commit()

        # [안전장치 알림] 3회 연속 실패 감지
        _check_repeated_failures(conn)

        return results

    finally:
        conn.close()
```

#### 2.3.3 판매 수집 스케줄러 연동

**기존 `_run_sales_sync()` 또는 동일 역할 함수 끝부분에 추가:**

```python
# 새로 수집된 판매가 있으면 자동 재입찰 시도
if new_items:
    try:
        rebid_result = await auto_rebid_after_sale(new_items)
        print(f"[auto_rebid] success={rebid_result['success']} "
              f"skipped={rebid_result['skipped']} "
              f"failed={rebid_result['failed']}")
    except Exception as e:
        print(f"[auto_rebid] 예외: {e}")
        send_health_alert('auto_rebid_exception', str(e))
```

---

### STEP 2.4 — API 4개 추가

#### 2.4.1 `GET /api/auto-rebid/status`

```python
@app.route('/api/auto-rebid/status', methods=['GET'])
def api_auto_rebid_status():
    try:
        settings = load_settings()
        conn = sqlite3.connect(DB_PATH)
        conn.row_factory = sqlite3.Row

        # 오늘 통계
        today_success = conn.execute("""
            SELECT COUNT(*) FROM auto_rebid_log
            WHERE action = 'auto_rebid_success'
              AND date(executed_at) = date('now', 'localtime')
        """).fetchone()[0]

        today_skipped = conn.execute("""
            SELECT COUNT(*) FROM auto_rebid_log
            WHERE action LIKE 'skipped_%'
              AND date(executed_at) = date('now', 'localtime')
        """).fetchone()[0]

        today_failed = conn.execute("""
            SELECT COUNT(*) FROM auto_rebid_log
            WHERE action = 'rebid_failed'
              AND date(executed_at) = date('now', 'localtime')
        """).fetchone()[0]

        last_sale = conn.execute("""
            SELECT MAX(collected_at) FROM sales_history
        """).fetchone()[0]

        conn.close()

        return jsonify({
            'ok': True,
            'enabled': settings.get('auto_rebid_enabled', False),
            'daily_max': settings.get('auto_rebid_daily_max', 20),
            'blacklist': settings.get('auto_rebid_blacklist', []),
            'today': {
                'success': today_success,
                'skipped': today_skipped,
                'failed': today_failed,
            },
            'last_sale': last_sale,
        })
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500
```

#### 2.4.2 `POST /api/auto-rebid/toggle`

```python
@app.route('/api/auto-rebid/toggle', methods=['POST'])
def api_auto_rebid_toggle():
    try:
        data = request.get_json() or {}
        enabled = bool(data.get('enabled', False))

        settings = load_settings()
        settings['auto_rebid_enabled'] = enabled
        save_settings(settings)

        return jsonify({'ok': True, 'enabled': enabled})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500
```

#### 2.4.3 `POST /api/auto-rebid/run-once`

```python
@app.route('/api/auto-rebid/run-once', methods=['POST'])
def api_auto_rebid_run_once():
    """수동 1회 실행 (enabled 무관).
       최근 1시간 내 sales_history 대상."""
    try:
        conn = sqlite3.connect(DB_PATH)
        conn.row_factory = sqlite3.Row
        rows = conn.execute("""
            SELECT order_id, product_id, model, size, sale_price
            FROM sales_history
            WHERE collected_at > datetime('now', '-1 hour')
            ORDER BY collected_at DESC
        """).fetchall()
        sales = [dict(r) for r in rows]
        conn.close()

        if not sales:
            return jsonify({'ok': True, 'message': '최근 1시간 내 판매 없음',
                            'success': 0, 'skipped': 0, 'failed': 0})

        # 일시적으로 enabled 무시하고 실행
        settings = load_settings()
        original_enabled = settings.get('auto_rebid_enabled')
        settings['auto_rebid_enabled'] = True
        save_settings(settings)

        try:
            loop = asyncio.new_event_loop()
            result = loop.run_until_complete(auto_rebid_after_sale(sales))
            loop.close()
        finally:
            # 원래 상태 복원
            settings = load_settings()
            settings['auto_rebid_enabled'] = original_enabled
            save_settings(settings)

        return jsonify({'ok': True, **result})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500
```

#### 2.4.4 `GET /api/auto-rebid/history`

```python
@app.route('/api/auto-rebid/history', methods=['GET'])
def api_auto_rebid_history():
    try:
        limit = int(request.args.get('limit', 50))
        filter_type = request.args.get('filter', 'all')
        from_date = request.args.get('from_date')
        to_date = request.args.get('to_date')

        conn = sqlite3.connect(DB_PATH)
        conn.row_factory = sqlite3.Row

        query = "SELECT * FROM auto_rebid_log WHERE 1=1"
        params = []

        if filter_type == 'success':
            query += " AND action = 'auto_rebid_success'"
        elif filter_type == 'skipped':
            query += " AND action LIKE 'skipped_%'"
        elif filter_type == 'failed':
            query += " AND action = 'rebid_failed'"

        if from_date:
            query += " AND executed_at >= ?"
            params.append(from_date)
        if to_date:
            query += " AND executed_at <= ?"
            params.append(to_date)

        query += " ORDER BY executed_at DESC LIMIT ?"
        params.append(limit)

        rows = conn.execute(query, params).fetchall()
        history = [dict(r) for r in rows]
        conn.close()

        return jsonify({'ok': True, 'history': history, 'count': len(history)})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500
```

**api-addition Skill 준수:**
- JSON 에러 응답 ✅
- 응답 구조 `{ok: bool, ...}` 표준 ✅
- curl 테스트 필수 ✅

---

### STEP 2.5 — 대시보드 UI

#### 2.5.1 `tab_sales.html` 상단에 자동 재입찰 패널 추가

```html
<!-- 자동 재입찰 패널 -->
<div id="autoRebidPanel" style="background:#f8f9fa;border:1px solid #e0e0e0;
     border-radius:8px;padding:16px;margin-bottom:16px;">
  <div style="display:flex;justify-content:space-between;align-items:center;">
    <h3 style="margin:0;">🔄 자동 재입찰</h3>
    <label class="switch">
      <input type="checkbox" id="autoRebidToggle" onchange="toggleAutoRebid()">
      <span class="slider"></span>
    </label>
  </div>

  <div id="autoRebidStats" style="margin-top:12px;display:grid;
       grid-template-columns:repeat(3,1fr);gap:8px;">
    <div>✅ 성공: <span id="rebidSuccessCount">0</span>건</div>
    <div>⏭️ 건너뜀: <span id="rebidSkippedCount">0</span>건</div>
    <div>❌ 실패: <span id="rebidFailedCount">0</span>건</div>
  </div>

  <div style="margin-top:8px;font-size:12px;color:#666;">
    마지막 판매: <span id="rebidLastSale">-</span>
    | 하루 한도: <span id="rebidDailyMax">20</span>건
  </div>

  <div style="margin-top:8px;">
    <button onclick="runAutoRebidOnce()" class="btn-secondary">
      수동 1회 실행 (테스트)
    </button>
  </div>
</div>

<!-- 자동 재입찰 이력 섹션 -->
<div id="autoRebidHistorySection" style="margin-top:24px;">
  <div style="display:flex;justify-content:space-between;align-items:center;">
    <h3>자동 재입찰 이력</h3>
    <select id="rebidHistoryFilter" onchange="loadRebidHistory()">
      <option value="all">전체</option>
      <option value="success">성공</option>
      <option value="skipped">건너뜀</option>
      <option value="failed">실패</option>
    </select>
  </div>
  <table style="width:100%;margin-top:8px;">
    <thead>
      <tr>
        <th>시각</th><th>모델</th><th>사이즈</th>
        <th>판매가</th><th>재입찰가</th><th>마진</th><th>결과</th>
      </tr>
    </thead>
    <tbody id="rebidHistoryTbody"></tbody>
  </table>
</div>
```

#### 2.5.2 JS 함수들

```javascript
async function loadAutoRebidStatus() {
  const res = await fetch('/api/auto-rebid/status');
  const data = await res.json();
  if (!data.ok) return;
  document.getElementById('autoRebidToggle').checked = data.enabled;
  document.getElementById('rebidSuccessCount').textContent = data.today.success;
  document.getElementById('rebidSkippedCount').textContent = data.today.skipped;
  document.getElementById('rebidFailedCount').textContent = data.today.failed;
  document.getElementById('rebidDailyMax').textContent = data.daily_max;
  document.getElementById('rebidLastSale').textContent = data.last_sale || '없음';
}

async function toggleAutoRebid() {
  const enabled = document.getElementById('autoRebidToggle').checked;
  if (enabled) {
    if (!confirm('자동 재입찰을 켜시겠습니까? 판매 발생 시 자동으로 재입찰됩니다.')) {
      document.getElementById('autoRebidToggle').checked = false;
      return;
    }
  }
  const res = await fetch('/api/auto-rebid/toggle', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({enabled})
  });
  const data = await res.json();
  if (!data.ok) {
    alert('토글 실패: ' + data.error);
    document.getElementById('autoRebidToggle').checked = !enabled;
  }
}

async function runAutoRebidOnce() {
  if (!confirm('최근 1시간 내 판매 건에 대해 수동으로 재입찰을 시도합니다. 진행?')) return;
  const res = await fetch('/api/auto-rebid/run-once', {method: 'POST'});
  const data = await res.json();
  if (data.ok) {
    alert(`결과: 성공 ${data.success}건 / 건너뜀 ${data.skipped}건 / 실패 ${data.failed}건`);
    loadAutoRebidStatus();
    loadRebidHistory();
  } else {
    alert('실행 실패: ' + data.error);
  }
}

async function loadRebidHistory() {
  const filter = document.getElementById('rebidHistoryFilter').value;
  const res = await fetch(`/api/auto-rebid/history?limit=50&filter=${filter}`);
  const data = await res.json();
  if (!data.ok) return;
  const tbody = document.getElementById('rebidHistoryTbody');
  tbody.innerHTML = data.history.map(h => `
    <tr>
      <td>${h.executed_at}</td>
      <td>${h.model || '-'}</td>
      <td>${h.size || '-'}</td>
      <td>${h.sold_price ? h.sold_price.toLocaleString() + '원' : '-'}</td>
      <td>${h.new_bid_price ? h.new_bid_price.toLocaleString() + '원' : '-'}</td>
      <td>${h.expected_profit ? h.expected_profit.toLocaleString() + '원' : '-'}</td>
      <td>${actionLabel(h.action)}${h.skip_reason ? ' (' + h.skip_reason + ')' : ''}</td>
    </tr>
  `).join('');
}

function actionLabel(action) {
  const labels = {
    'auto_rebid_success': '✅ 성공',
    'skipped_no_cost': '⏭️ 원가없음',
    'skipped_loop_guard': '⏭️ 루프가드',
    'skipped_margin_low': '⏭️ 마진부족',
    'skipped_price_shift': '⏭️ 가격급변',
    'skipped_blacklist': '⏭️ 블랙리스트',
    'skipped_daily_limit': '⏭️ 하루한도',
    'rebid_failed': '❌ 실패',
  };
  return labels[action] || action;
}

// 탭 로드 시 호출
document.addEventListener('DOMContentLoaded', () => {
  if (document.getElementById('autoRebidPanel')) {
    loadAutoRebidStatus();
    loadRebidHistory();
  }
});
```

#### 2.5.3 `tab_settings.html` 설정 블록 추가

```html
<div class="settings-group">
  <h3>자동 재입찰</h3>
  <label>
    <input type="checkbox" id="setting_auto_rebid_enabled">
    자동 재입찰 활성화 (기본 OFF)
  </label>
  <label>
    하루 최대 재입찰 건수:
    <input type="number" id="setting_auto_rebid_daily_max" min="0" max="100" value="20">
  </label>
  <label>
    블랙리스트 모델 (쉼표 구분):
    <textarea id="setting_auto_rebid_blacklist" rows="2"
      placeholder="예: IX7694, DC5227"></textarea>
  </label>
</div>
```

---

## 3. 테스트 시나리오 (완료 전 필수)

### 3.1 문법 체크
```bash
python3 -c "import py_compile; py_compile.compile('kream_server.py', doraise=True)"
# 기대: 출력 없음 (성공)
```

### 3.2 서버 재시작
```bash
lsof -ti:5001 | xargs kill -9 2>/dev/null
sleep 2
nohup python3 kream_server.py > server.log 2>&1 &
disown
sleep 5
```

### 3.3 헬스체크
```bash
curl -s http://localhost:5001/api/health | python3 -m json.tool
# 기대: status 정상, 스케줄러 running
```

### 3.4 API 4개 응답 확인

```bash
# 1) status
curl -s http://localhost:5001/api/auto-rebid/status | python3 -m json.tool
# 기대: ok:true, enabled:false, today.success:0

# 2) history
curl -s "http://localhost:5001/api/auto-rebid/history?limit=10" | python3 -m json.tool
# 기대: ok:true, history:[]

# 3) toggle 테스트 (OFF 유지)
curl -s -X POST http://localhost:5001/api/auto-rebid/toggle \
  -H "Content-Type: application/json" \
  -d '{"enabled": false}' | python3 -m json.tool
# 기대: ok:true, enabled:false

# 4) run-once (최근 1시간 판매 없으면 스킵)
curl -s -X POST http://localhost:5001/api/auto-rebid/run-once | python3 -m json.tool
# 기대: ok:true, message:"최근 1시간 내 판매 없음"
```

### 3.5 DB 테이블 확인
```bash
sqlite3 price_history.db "SELECT sql FROM sqlite_master WHERE name='auto_rebid_log';"
# 기대: CREATE TABLE 구문 출력

sqlite3 price_history.db ".indexes auto_rebid_log"
# 기대: idx_rebid_executed, idx_rebid_model_size
```

### 3.6 settings.json 기본값 확인
```bash
cat settings.json | python3 -c "import sys, json; d=json.load(sys.stdin); \
  print('auto_rebid_enabled:', d.get('auto_rebid_enabled')); \
  print('auto_rebid_daily_max:', d.get('auto_rebid_daily_max')); \
  print('auto_rebid_blacklist:', d.get('auto_rebid_blacklist'))"
# 기대: false, 20, []
```

### 3.7 기본 OFF 동작 확인
```bash
# 스케줄러 돌아도 auto_rebid_log에 기록 없어야 함 (enabled=false)
sqlite3 price_history.db "SELECT COUNT(*) FROM auto_rebid_log;"
# 기대: 0 (또는 시나리오 3.4의 run-once로 생긴 건만)
```

### 3.8 대시보드 UI 확인
- 브라우저에서 `http://localhost:5001` → 판매 관리 탭
- "🔄 자동 재입찰" 패널 표시 확인
- 토글 OFF 상태 확인
- 이력 섹션 표시 확인
- 설정 탭 → "자동 재입찰" 블록 확인

### 3.9 로직 검증 (DB INSERT 시뮬레이션)

**sales_history가 0건이라 실제 판매으로는 검증 불가. 아래는 임시 데이터로 로직만 검증.**

⚠️ **주의:** 테스트 데이터는 실제 입찰로 이어지면 안 됨. `auto_rebid_enabled=false` 유지 상태에서 `run-once` API로만 시도.

```bash
# 3.9.1 blacklist 검증 준비
# settings.json에 블랙리스트 추가
python3 -c "
import json
s = json.load(open('settings.json'))
s['auto_rebid_blacklist'] = ['TEST_BLACKLIST_MODEL']
json.dump(s, open('settings.json', 'w'), ensure_ascii=False, indent=2)
print('blacklist set')
"

# 3.9.2 sales_history에 임시 테스트 레코드 INSERT (검증 끝나면 DELETE)
sqlite3 price_history.db <<EOF
INSERT INTO sales_history (order_id, product_id, model, product_info, size,
                           sale_price, trade_date, ship_date, ship_status, collected_at)
VALUES ('TEST_REBID_1', 'TEST_PID_1', 'TEST_BLACKLIST_MODEL', 'Test Product',
        '270', 100000, datetime('now'), datetime('now'), 'shipped',
        datetime('now'));
EOF

# 3.9.3 run-once 실행 → blacklist 이유로 스킵되어야 함
curl -s -X POST http://localhost:5001/api/auto-rebid/run-once | python3 -m json.tool
# 기대: skipped: 1 (blacklist 사유)

# 3.9.4 DB 로그 확인
sqlite3 price_history.db "SELECT original_order_id, action, skip_reason \
  FROM auto_rebid_log WHERE original_order_id='TEST_REBID_1';"
# 기대: TEST_REBID_1|skipped_blacklist|...

# 3.9.5 ★ 테스트 데이터 정리 (필수 — CLAUDE.md 2번 "판매 완료 건 수정/삭제 금지"의 예외:
#     테스트 목적으로 직접 INSERT한 TEST_ 접두사 레코드는 삭제 가능)
sqlite3 price_history.db "DELETE FROM sales_history WHERE order_id='TEST_REBID_1';"
sqlite3 price_history.db "DELETE FROM auto_rebid_log WHERE original_order_id='TEST_REBID_1';"

# 3.9.6 blacklist 원복
python3 -c "
import json
s = json.load(open('settings.json'))
s['auto_rebid_blacklist'] = []
json.dump(s, open('settings.json', 'w'), ensure_ascii=False, indent=2)
print('blacklist cleared')
"
```

### 3.10 실제 판매 발생 시 모니터링 가이드 (배포 후)

실제 판매가 들어오는 시점에 다음을 확인:

```bash
# 1) sales_history에 새 체결건 들어왔는지
sqlite3 price_history.db "SELECT order_id, model, size, sale_price, collected_at \
  FROM sales_history ORDER BY collected_at DESC LIMIT 5;"

# 2) auto_rebid_log에 어떤 action이 기록됐는지
sqlite3 price_history.db "SELECT original_order_id, model, size, action, skip_reason, \
  executed_at FROM auto_rebid_log ORDER BY executed_at DESC LIMIT 5;"

# 3) enabled=false이므로 모두 skipped_disabled 이어야 정상
# 4) 승주님이 수동으로 enabled=true 바꾸면 실제 동작 시작
```

---

## 4. 완료 전 최종 체크리스트

### 선행 탐색
- [ ] 0.5절 탐색 1~9 모두 실행 완료
- [ ] 탐색 결과 보고서 작성 완료
- [ ] 지시서 2.3의 함수 시그니처를 실제 코드베이스에 맞춰 조정

### 코드 품질
- [ ] 문법 체크 통과 (3.1)
- [ ] 서버 재시작 성공 (3.2)
- [ ] 헬스체크 정상 (3.3)
- [ ] 4개 API 모두 200 응답 (3.4)
- [ ] DB 테이블 + 인덱스 2개 생성 (3.5)
- [ ] settings.json 기본값 3개 추가 (3.6)
- [ ] 기본 OFF 동작 (3.7)
- [ ] 대시보드 UI 표시 (3.8)
- [ ] 로직 검증 (blacklist 경로, 3.9)
- [ ] 테스트 데이터 정리 완료 (3.9.5)

### 안전 규칙
- [ ] `auth_state*.json` 건드리지 않음
- [ ] `git push -f` 사용 안 함
- [ ] 판매 완료 건 수정/삭제 안 함 (TEST_ 접두사 테스트 데이터 예외)
- [ ] `sales_history` 테이블 DROP/DELETE 안 함
- [ ] 원가 없는 건 `skipped_no_cost`로 기록 (가짜 값 대입 금지)
- [ ] KREAM 수집 실패 시 `rebid_failed`로 기록 (폴백 데이터 사용 금지)

### 누락 방지 (Step 3에서 놓쳤던 것 재확인)
- [ ] `/api/adjust/pending` 은 그대로 작동 (Step 3 기능 영향 없음)
- [ ] `bid_cost` 테이블 INSERT 로직 건드리지 않음
- [ ] 기존 모니터링 스케줄러 타이밍 변경 안 함

---

## 5. 커밋 메시지

```
feat: 자동 재입찰 시스템 (기본 OFF, 무한루프 방지, 가격 급변 감지)

- auto_rebid_log 테이블 신설 (order_id FK 없이 독립, NULL 허용)
- auto_rebid_after_sale() 엔진 추가 (판매 수집 스케줄러 연동)
- 6중 안전장치:
  1. 원가 존재 체크 (bid_cost JOIN)
  2. 24시간 내 같은 모델+사이즈 5회 제한
  3. 판매가 ±10% 이내 가격 급변 차단
  4. 하루 최대 20건 (설정 변경 가능)
  5. 모델별 블랙리스트
  6. 마진 4,000원 하한
- 자기 입찰 제외 로직 (my_bids_local 참조)
- 모델별 KREAM 가격 그룹 수집으로 부하 감소
- API 4개: status, toggle, run-once, history
- UI: tab_sales 상단 패널 + 이력 테이블, tab_settings 블록
- place_bid() Boolean 반환 한계로 new_order_id는 NULL 허용

설계 근거:
- sales_history 0건 상태에서도 구현 가능 (수동 run-once로 테스트)
- 언더컷 자동 방어(Step 3)와 독립 동작
- 기본 OFF로 사용자 명시적 승인 필요
```

---

## 6. Git 작업 원칙

### 6.1 작업 시작 전
```bash
cd ~/Desktop/kream_automation
git status              # 작업 중인 파일 없는지 확인
git pull origin main    # 노트북에서 푸시된 변경사항 받기
git log --oneline -5    # 최근 커밋 확인
```

### 6.2 작업 중
- `git commit -f` 금지
- `git reset --hard` 금지
- `git push -f` 금지 (CLAUDE.md 절대 규칙 5)

### 6.3 작업 완료 후
```bash
git add -A
git diff --cached --stat   # 변경 파일 확인
git commit -m "feat: 자동 재입찰 시스템 (기본 OFF, 무한루프 방지, 가격 급변 감지)"
git push origin main
```

### 6.4 auth_state.json 보호
- auth_state*.json 은 .gitignore에 있어야 함
- `git status` 에 auth_state 가 뜨면 STOP → 승주님에게 확인

---

## 7. 롤백 계획

### 7.1 마이그레이션 실패 시
```bash
# 백업 확인
ls -la ~/Desktop/kream_automation/backups/ | tail -5

# auto_rebid_log 테이블만 삭제 (다른 테이블 영향 없음)
# ⚠️ 절대 규칙 3 "직접 DROP 금지"의 예외: 방금 만든 빈 테이블 롤백 목적
sqlite3 price_history.db "DROP TABLE IF EXISTS auto_rebid_log;"

# 서버 재시작하면 테이블 없이도 정상 작동 (다른 기능 영향 없음)
```

### 7.2 엔진 오작동으로 원치 않는 입찰 실행됐을 때
```bash
# 1) 긴급 정지 (최우선)
curl -X POST http://localhost:5001/api/auto-rebid/toggle \
  -H "Content-Type: application/json" \
  -d '{"enabled": false}'

# 2) 잘못 들어간 입찰 확인
sqlite3 price_history.db "SELECT * FROM auto_rebid_log \
  WHERE action='auto_rebid_success' \
  AND executed_at > datetime('now', '-1 hour');"

# 3) KREAM 판매자센터에서 해당 입찰 수동 삭제
#    (API 삭제는 /api/my-bids/delete 사용 가능하지만 수동 권장)

# 4) 원인 파악 후 수정 → 재배포
```

### 7.3 Git 롤백
```bash
# 방금 커밋만 되돌리기 (아직 푸시 전)
git reset --soft HEAD~1   # 커밋만 취소, 변경사항 유지
git diff                  # 뭐가 달라졌는지 확인 후 수정

# 이미 푸시됐다면
git revert HEAD           # 반대 커밋 생성 (force push 금지!)
git push origin main
```

### 7.4 긴급 OFF 명령 (외워두기)
```bash
# 원격에서도 실행 가능 (Cloudflare Tunnel)
curl -X POST https://jobs-keywords-mechanism-lead.trycloudflare.com/api/auto-rebid/toggle \
  -H "Content-Type: application/json" \
  -d '{"enabled": false}'
```

---

## 8. 완료 보고 양식

1. **구현 기능 요약 표** (기능명 / 파일 / 라인 수 / 상태)
2. **테스트 결과** (3.1~3.8 각 결과 붙여넣기)
3. **변경 파일 목록** (`git diff --stat`)
4. **알려진 제약사항**
   - `place_bid()` Boolean 반환으로 `new_order_id`는 NULL
   - 판매 데이터 0건이라 실제 재입찰 검증은 판매 발생 후 가능
   - KREAM 가격 수집 실패 시 `rebid_failed`로 기록 (폴백 금지 원칙)

---

**작업자:** Claude Code (`claude --dangerously-skip-permissions`)
**승인자:** 주데이
**Step 5는 이 작업 완료 + 주데이 OK 후 진행**
