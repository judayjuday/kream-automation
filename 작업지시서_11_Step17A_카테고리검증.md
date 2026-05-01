# 작업지시서 11 — Step 17-A 카테고리 검증 + ONE SIZE 차단

## 목적

신발 카테고리(运动鞋/球鞋)에서 사이즈 누락 시 입찰 차단. 
현재는 size 누락 → 자동으로 "ONE SIZE" fallback → KREAM에 잘못 등록.

근본 원인 (진단 완료):
- kream_server.py 5곳 + kream_bot.py 1곳에서 size 누락 시 "ONE SIZE" 디폴트
- bid_cost 테이블 디폴트도 'ONE SIZE'
- 카테고리 검증 로직 부재

## 절대 규칙

1. price_history.db DROP/DELETE 금지
2. 자동 입찰 트리거 추가 금지
3. 기존 ONE SIZE 입찰 데이터 일방적 삭제 금지 (Step 17-B에서 별도 처리)
4. 검증 실패 시 명확한 에러 메시지 + 입찰 차단 (silently fallback 금지)
5. shihuo_prices 활성 batch 무조건 보존
6. 모든 코드 수정 후 py_compile 검증

## 사전 백업

이미 run_step17_full.sh가 수행:
- price_history_backup_step17_pre.db
- kream_server.py.step17_pre.bak

추가 백업:
```bash
cp tabs/tab_register.html tabs/tab_register.html.step17a_pre.bak 2>/dev/null || true
```

## Phase 1: 사전 분석

다음 명령으로 코드 구조 정확히 파악 후 본 작업지시서 v2 생성.

### 1-1. 카테고리 판별 헬퍼 함수 위치 확인
```bash
grep -n "_shihuo_category_to_internal\|category.*shoes\|category.*bags" kream_server.py | head -20
grep -n "categorize\|category_for\|is_shoes\|is_bag" kream_server.py | head -20
```

### 1-2. 모든 size 디폴트 fallback 지점 정확히 찾기
```bash
grep -n "ONE SIZE\|one_size\|onesize" kream_server.py kream_bot.py
```

각 위치마다:
- 함수명, 호출 컨텍스트
- size 누락 시 현재 동작
- 변경 후 동작 정의

### 1-3. KREAM 상품 카테고리 가져오기 가능한 API 확인
```bash
grep -n "products/.*HTTP\|api.kream\|productInfo\|product_info" kream_server.py kream_bot.py | head -20
```
이미 KREAM 상품 페이지 호출 코드가 있는지 확인. 있으면 카테고리 파싱 추가, 없으면 신설.

### 1-4. 카테고리 캐시 테이블 설계
```sql
CREATE TABLE IF NOT EXISTS model_category (
    model TEXT PRIMARY KEY,
    category TEXT NOT NULL,        -- 'shoes' | 'bags' | 'apparel' | 'unknown'
    source TEXT NOT NULL,          -- 'shihuo' | 'kream' | 'manual'
    needs_size INTEGER NOT NULL,   -- 0/1 (1이면 사이즈 필수)
    cached_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    notes TEXT
);
CREATE INDEX IF NOT EXISTS idx_model_category_needs_size ON model_category(needs_size);
```

## Phase 2: 본 작업

### Step A-1: model_category 테이블 신설 + 초기 마이그레이션
```bash
sqlite3 price_history.db < migration_step17a.sql
```

`migration_step17a.sql`:
```sql
BEGIN;

CREATE TABLE IF NOT EXISTS model_category (
    model TEXT PRIMARY KEY,
    category TEXT NOT NULL,
    source TEXT NOT NULL,
    needs_size INTEGER NOT NULL,
    cached_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    notes TEXT
);
CREATE INDEX IF NOT EXISTS idx_model_category_needs_size ON model_category(needs_size);

-- shihuo_prices의 활성 데이터로 초기화 (A안: 식货 우선)
INSERT OR IGNORE INTO model_category (model, category, source, needs_size, notes)
SELECT DISTINCT 
    model,
    category,
    'shihuo' AS source,
    CASE WHEN category = 'bags' THEN 0 ELSE 1 END AS needs_size,
    '식货 활성 batch 자동 추론'
FROM shihuo_prices
WHERE active=1 AND category IS NOT NULL;

COMMIT;
```

### Step A-2: 카테고리 판정 함수 신설 (kream_server.py)

`get_model_category(model)` 함수:
```python
def get_model_category(model):
    """모델의 카테고리/사이즈 필수 여부 반환.
    
    우선순위:
    1. model_category 테이블 캐시 (식货 우선, 그다음 KREAM, 그다음 manual)
    2. shihuo_prices 활성 batch 직접 조회 (캐시 미스 시)
    3. KREAM 상품 페이지 폴백 (선택, 시간 오래 걸림)
    4. 모두 실패 시 'unknown', needs_size=1 (보수적)
    
    반환: {"category": str, "needs_size": bool, "source": str}
    """
    if not model:
        return {"category": "unknown", "needs_size": True, "source": "default"}
    
    conn = sqlite3.connect(str(PRICE_DB))
    try:
        # 1. 캐시 조회
        row = conn.execute(
            "SELECT category, needs_size, source FROM model_category WHERE model=?",
            (model,)
        ).fetchone()
        if row:
            return {"category": row[0], "needs_size": bool(row[1]), "source": row[2]}
        
        # 2. shihuo_prices 활성 직접 조회
        row = conn.execute(
            "SELECT category FROM shihuo_prices WHERE active=1 AND model=? LIMIT 1",
            (model,)
        ).fetchone()
        if row:
            cat = row[0]
            needs = 0 if cat == 'bags' else 1
            # 캐시에 기록
            conn.execute(
                "INSERT OR IGNORE INTO model_category (model, category, source, needs_size, notes) VALUES (?,?,?,?,?)",
                (model, cat, 'shihuo', needs, 'shihuo_prices 활성 batch 추론')
            )
            conn.commit()
            return {"category": cat, "needs_size": bool(needs), "source": "shihuo"}
    finally:
        conn.close()
    
    # 3. KREAM 폴백 (옵션, Phase 2.5에서 활성화)
    # kream_cat = _fetch_kream_category(model)
    # if kream_cat: ...
    
    # 4. 보수적 디폴트
    return {"category": "unknown", "needs_size": True, "source": "default"}
```

### Step A-3: validate_size_for_bid 함수 신설

```python
def validate_size_for_bid(model, size, raise_on_error=False):
    """입찰 전 사이즈 유효성 검증.
    
    - 모델이 사이즈 필수 카테고리인데 size가 'ONE SIZE' 또는 빈값 → 차단
    - 사이즈 필수 아닌 카테고리는 통과
    
    반환: (is_valid: bool, error_msg: str or None, category_info: dict)
    """
    cat_info = get_model_category(model)
    size_clean = (size or "").strip().upper()
    
    # 사이즈 필수 카테고리에서 ONE SIZE 또는 빈값 → 차단
    if cat_info["needs_size"]:
        if not size_clean or size_clean in ("ONE SIZE", "ONESIZE", "ONE_SIZE", "FREE"):
            msg = f"카테고리 '{cat_info['category']}'은 사이즈 필수입니다 (model={model}, size='{size}')"
            if raise_on_error:
                raise ValueError(msg)
            return (False, msg, cat_info)
    
    return (True, None, cat_info)
```

### Step A-4: 입찰 진입점 6곳에 검증 추가

각 위치에서 size 처리 직전에 validate_size_for_bid 호출:
- kream_server.py:1337 (수동 입찰 단건)
- kream_server.py:1471 (다른 진입점)
- kream_server.py:1855 (대량)
- kream_server.py:3470 (큐 일괄)
- kream_server.py:3539 (큐 자동 등록)
- kream_bot.py:1736 (place_bid 함수 진입)

각 위치 패턴:
```python
size = str(data.get("size", "")).strip()  # 디폴트 'ONE SIZE' 제거
is_valid, err_msg, cat_info = validate_size_for_bid(model, size)
if not is_valid:
    return jsonify({"ok": False, "error": err_msg, "code": "SIZE_REQUIRED"}), 400
    # 또는 자동 입찰 컨텍스트면:
    # add_log(tid, "error", err_msg)
    # continue  # 다음 항목으로
```

⚠️ 단, 가방 카테고리 (IX7694, KA9266 등)는 통과되어야 함. validate_size_for_bid가 정확히 분기.

### Step A-5: bid_cost 테이블 디폴트 변경
```sql
-- bid_cost.size DEFAULT를 NULL로 변경 (멱등 처리)
-- 단, 기존 데이터는 그대로 유지
-- ALTER COLUMN은 SQLite 미지원이라 스키마 재작성 필요
-- 대안: _save_bid_cost에서 빈값/None 들어오면 명시적으로 size를 받도록 강제
```

대안 — 코드에서 강제 (간단):
- _save_bid_cost 첫 줄에 size None/빈값 검증 추가:
```python
if not size or not str(size).strip():
    raise ValueError(f"size required for bid_cost (order_id={order_id}, model={model})")
```

### Step A-6: 검증

```bash
python3 -c "import py_compile; py_compile.compile('kream_server.py', doraise=True)"
python3 -c "import py_compile; py_compile.compile('kream_bot.py', doraise=True)"

# 회귀 테스트
python3 << 'PYTEST'
import sqlite3
conn = sqlite3.connect('price_history.db')

# 카테고리 캐시 확인
print("=== model_category 캐시 ===")
for row in conn.execute("SELECT * FROM model_category"):
    print(row)

# 가방 모델은 ONE SIZE 통과해야
# 신발 모델은 ONE SIZE 차단되어야
# (validate_size_for_bid 직접 import해서 테스트)
PYTEST

# 서버 재시작
lsof -ti:5001 | xargs kill -9 2>/dev/null
sleep 1
nohup python3 kream_server.py > server.log 2>&1 & disown
sleep 3
curl -s http://localhost:5001/api/health | head -c 200
```

### Step A-7: 회귀 테스트 시나리오

```bash
# 시나리오 1: 신발 모델 ONE SIZE 입찰 시도 → 400 에러 기대
curl -X POST http://localhost:5001/api/bid \
  -H "Content-Type: application/json" \
  -d '{"productId":"467187","model":"JQ4110","size":"ONE SIZE","price":100000}' \
  | python3 -m json.tool

# 시나리오 2: 신발 모델 사이즈 입력 → 통과
curl -X POST http://localhost:5001/api/bid \
  -H "Content-Type: application/json" \
  -d '{"productId":"467187","model":"JQ4110","size":"230","price":100000}' \
  | python3 -m json.tool

# 시나리오 3: 가방 모델 ONE SIZE → 통과
curl -X POST http://localhost:5001/api/bid \
  -H "Content-Type: application/json" \
  -d '{"productId":"XXX","model":"IX7694","size":"ONE SIZE","price":100000}' \
  | python3 -m json.tool

# 시나리오 4: 가방 모델 JE3208 ONE SIZE → 통과 (재임포트 후 가방 등록됨)
curl -X POST http://localhost:5001/api/bid \
  -H "Content-Type: application/json" \
  -d '{"productId":"XXX","model":"JE3208","size":"ONE SIZE","price":100000}' \
  | python3 -m json.tool
```

⚠️ 위 curl이 실제 입찰을 발화시키지 않도록 사전 검증만 통과/실패 확인하는 모드 필요.
- /api/bid는 실제 입찰 실행 가능성 → 위험
- 대신 별도 테스트 엔드포인트 신설: /api/_test/validate-size (DEBUG 가드)
- 또는 Python에서 validate_size_for_bid 직접 호출하여 검증

권장: 다음 sqlite3 + python 직접 검증
```bash
python3 << 'PYTEST'
import sys
sys.path.insert(0, '.')
# kream_server.py에서 validate_size_for_bid를 import 가능하게 모듈 임포트 부작용 점검
# (Flask app 초기화 부작용이 있을 수 있음 - 작업지시서 8 검증때 발견된 패턴)
# 안전한 방법: 별도 작은 테스트 파일에 동일 로직 복제하여 검증
PYTEST
```

가장 안전: Step A-2~A-3 함수를 작성한 직후 별도 _test_validate.py 파일로 동일 로직 단위 테스트 후 통합.

## Phase 3: 사용자 검증

브라우저에서:
1. 가격 자동 조정 탭 → 추천 목록에 ONE SIZE 신발 모델이 더 이상 안 뜨는지 확인 (Step 17-B 후)
2. 새 입찰 등록 시 사이즈 필수 검증 동작 확인

## 보고 형식

[Step 17-A 완료]
- model_category 테이블 신설: ✓
- 초기 마이그레이션: shihuo 활성 batch에서 N개 모델 캐시
- 카테고리 판정 함수: get_model_category, validate_size_for_bid 신설
- 입찰 진입점 6곳 검증 추가: ✓ (위치 라인 명시)
- bid_cost.size 강제 검증: ✓
- 회귀 테스트:
  - 신발 ONE SIZE 차단: ✓
  - 신발 사이즈 정상: ✓
  - 가방 ONE SIZE 통과: ✓
  - JE3208/JE3209 가방 통과: ✓
- 서버 정상 재시작: ✓

[발견 사항]
- ...

[변경 파일]
- kream_server.py: +N -M
- price_history.db: model_category 테이블 추가

[다음 액션]
Step 17-B (기존 잘못 등록 데이터 정리) 진행
