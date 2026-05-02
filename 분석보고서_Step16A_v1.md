# 분석 보고서 — Step 16-A (Phase 1)

작성일: 2026-05-01
대상 코드: `kream_server.py` (HEAD: c03acfe)
대상 DB: `price_history.db`

---

## A. bid_cost 테이블 정밀 분석

### A-1. 스키마 (kream_server.py:231-249)

```sql
CREATE TABLE bid_cost (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    order_id TEXT UNIQUE,                      -- UNIQUE 제약 (UPSERT 키)
    model TEXT,
    size TEXT,                                  -- ★ TEXT 타입 (INTEGER 아님)
    cny_price REAL,
    exchange_rate REAL,
    overseas_shipping INTEGER DEFAULT 8000,
    other_costs INTEGER DEFAULT 0,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
)
```

### A-2. 인덱스

- `sqlite_autoindex_bid_cost_1` (order_id UNIQUE 자동)
- `idx_bc_model` (model)
- `idx_bc_model_size` (model, size)

### A-3. 데이터 현황

| 항목 | 값 |
|---|---|
| 총 행 수 | **48건** |
| cny_price 채워짐 | 48건 (100%) |
| `updated_at` 컬럼 | **없음** (`created_at`만) |
| size 값 분포 | `225, 230, 235, 240, 245, 250, 255, 260, ONE SIZE` (TEXT) |

### A-4. cny_source 컬럼 추가 시 영향도

- ALTER TABLE ADD COLUMN은 SQLite WAL 모드에서 안전 (메타데이터 수정만, 락 짧음).
- 기존 48건 처리: DEFAULT NULL 또는 `'unknown'` 가능.
- `_init_bid_cost_table` 내부에 `PRAGMA table_info` 체크 후 `ALTER TABLE` 추가 패턴이 안전함 (서버 재시작 시 idempotent).

---

## B. _save_bid_cost 함수 및 호출 지점

### B-1. 정의 (kream_server.py:282-301)

```python
def _save_bid_cost(order_id, model, size, cny_price, exchange_rate,
                   overseas_shipping=8000, other_costs=0):
    """입찰 성공 시 원가 정보 저장 (order_id 기준 UPSERT)"""
    if not order_id or not cny_price:
        return
    ...INSERT INTO bid_cost (...) VALUES (?,?,?,?,?,?,?)
       ON CONFLICT(order_id) DO UPDATE SET
         cny_price=excluded.cny_price,
         exchange_rate=excluded.exchange_rate,
         overseas_shipping=excluded.overseas_shipping,
         other_costs=excluded.other_costs
```

- UPSERT 키: `order_id`
- 반환값 없음
- 가드: `order_id` 또는 `cny_price` 누락 시 즉시 return (빈 행 저장 방지)

### B-2. 호출 지점 7곳

| # | 라인 | 호출 컨텍스트 | 빈도 |
|---|---|---|---|
| 1 | 1451 | 단일 자동 등록 — `run_full_register` 성공 후 | 단건 |
| 2 | 4061 | 일괄 입찰 — 다중 사이즈 묶음 입찰 후 | 대량 (per size) |
| 3 | 4100 | 일괄 입찰 — 단일 사이즈 분기 | 대량 (per item) |
| 4 | 5074 | `POST /api/bid-cost/upsert` — 수동 입력 | 단건 (사용자) |
| 5 | 5201 | `POST /api/bid-cost/bulk-upsert` — 모달 일괄 입력 | 대량 (사용자) |
| 6 | 7218 | 자동 재입찰 (`auto_rebid_after_sale` 내부) — `_run_bid_only_*` 후 | 단건 (스케줄러) |

### B-3. 호출 시 cny_price 처리 패턴

- 자동 입찰 계열(1, 2, 3, 6): 호출자가 `cny_price` 없으면 `_save_bid_cost`를 **호출하지 않고** 경고 로그만 남김.
- 수동 입력 계열(4, 5): API 진입 시 `cny_price > 0` 검증, 통과 못 하면 400 에러.

⇒ 자동 채택 로직을 넣을 때, "호출자에서 cny_price가 없어도 _save_bid_cost를 호출해서 shihuo로부터 채우게 한다" 또는 "함수 내부에서 cny_price=None 허용" 둘 중 한 가지 방식 선택 필요.

---

## C. 매칭 키 정합성

### C-1. 키 후보 비교

| 후보 | bid_cost | shihuo_prices(active=1) | 비고 |
|---|---|---|---|
| 후보 1 | (`model`, `size`) | (`model`, `kream_mm`) | bid_cost.size: TEXT, shihuo.kream_mm: INTEGER |
| 후보 2 | (`model`, `size`) | (`model`, `size_normalized`) | 양쪽 TEXT, 그러나 bid_cost.size는 mm 문자열, size_normalized는 EU 사이즈 |

**채택 후보**: **후보 1** — `bc.model = sh.model AND sh.kream_mm = CAST(bc.size AS INTEGER) AND sh.active=1`

### C-2. 캐스팅 동작 검증

```sql
-- bid_cost 샘플
order_id          | model         | size      | typeof(size)
A-AC158953985     | IX7694        | ONE SIZE  | text
A-SN160258316     | 1203A243-021  | 250       | text
A-SN160262282     | 1183B938-100  | 225       | text

-- shihuo_prices(active=1) 샘플
model   | kream_mm | size_eu | size_normalized
JQ1501  | 215      | 35⅔     | 35.5
JQ1501  | 265      | 42      | 42
IA8913  | NULL     | (空)    | (空)        ← mapping 실패
IC8349  | NULL     | (空)    | (空)        ← mapping 실패 (ONE SIZE류)
```

- `CAST('250' AS INTEGER) = 250` ✅
- `CAST('ONE SIZE' AS INTEGER) = 0` → kream_mm=0인 행 없음 → **자연 미매칭** (안전)
- `kream_mm IS NULL`인 행은 매칭 안 됨 (조인 후 NULL 비교 회피).

### C-3. 현재 실제 매칭 시뮬레이션

```sql
SELECT bc.order_id, bc.model, bc.size, bc.cny_price, sh.cny_price, sh.kream_mm
  FROM bid_cost bc
  LEFT JOIN shihuo_prices sh
    ON sh.active=1 AND sh.model = bc.model
   AND sh.kream_mm = CAST(bc.size AS INTEGER)
 WHERE sh.cny_price IS NOT NULL;
```

⇒ **결과 0건.** 현재 bid_cost는 모델 `1183B938-100`, `IX7694` 등이고, shihuo active 배치는 모델 `JQ1501` 등 — 모델 풀이 겹치지 않음. 회귀 테스트는 가상 데이터로 검증해야 함.

---

## D. 리포트 API (`/api/bid-cost/shihuo-diff`) 설계

### D-1. SQL JOIN 가능 (단일 쿼리)

```sql
SELECT bc.order_id, bc.model, bc.size,
       bc.cny_price        AS bc_cny,
       sh.cny_price        AS sh_cny,
       sh.batch_id         AS sh_batch,
       sh.kream_mm         AS sh_kream_mm,
       sh.size_eu          AS sh_size_eu,
       bc.exchange_rate
  FROM bid_cost bc
  JOIN shihuo_prices sh
    ON sh.active=1
   AND sh.model = bc.model
   AND sh.kream_mm = CAST(bc.size AS INTEGER)
 WHERE sh.cny_price <> bc.cny_price
 ORDER BY ABS(sh.cny_price - bc.cny_price) DESC
```

- bid_cost 48건 × shihuo active 45건 → 부담 없음 (인덱스 `idx_shihuo_active_kream` 활용 가능).
- `JOIN`(INNER)으로 매칭 행만, 가격 차이 있는 것만 필터.

### D-2. KREAM 입찰가 / 마진 계산

`my_bids_local.json`은 파일이라 SQL JOIN 불가. Python에서 후처리:

```python
my_bids = json.loads(MY_BIDS_FILE.read_text())  # {pid: [{size, price, ...}, ...]} 구조 가정
# diff 결과 각 행마다:
#   - 매칭 입찰: bids[product_id]에서 size 일치 항목
#   - 새 마진 추정: settlement(bid_price) - (sh_cny * exchange_rate * 1.03 + overseas + other)
```

⇒ Step 16-A의 1차 범위는 **JSON JOIN 없이 SQL JOIN 결과만 반환**하고, `current_bid_price` / `new_profit_estimate`는 v2에서 추가 권장. (대시보드에서 model+size로 my_bids_local.json을 합칠 수도 있음.)

### D-3. 응답 포맷 (제안)

```json
{
  "ok": true,
  "active_batch_id": "shihuo_20260501_121000",
  "count": 0,
  "items": [
    {
      "order_id": "...",
      "model": "JQ1501",
      "size": "265",
      "bc_cny": 620.0,
      "sh_cny": 599.0,
      "diff_cny": -21.0,
      "diff_pct": -3.39,
      "sh_batch": "shihuo_20260501_121000",
      "sh_size_eu": "42",
      "exchange_rate": 215.38
    }
  ]
}
```

---

## E. `/api/shihuo/rollback` 정밀 분석

### E-1. 현재 정의 (kream_server.py:8886-8898)

```python
@app.route("/api/shihuo/rollback/<batch_id>", methods=["POST"])
def api_shihuo_rollback(batch_id):
    """특정 batch를 active=1로, 그 외 active=0."""
    with sqlite3.connect(str(PRICE_DB)) as conn:
        existing = conn.execute(
            "SELECT COUNT(*) FROM shihuo_prices WHERE batch_id=?", (batch_id,)
        ).fetchone()[0]
        if existing == 0:
            return jsonify({"ok": False, "error": f"batch_id {batch_id} 존재하지 않음"}), 404
        conn.execute("UPDATE shihuo_prices SET active=0 WHERE batch_id != ?", (batch_id,))
        conn.execute("UPDATE shihuo_prices SET active=1 WHERE batch_id = ?", (batch_id,))
        conn.commit()
    return jsonify({"ok": True, "batch_id": batch_id, "restored": existing})
```

### E-2. 동작 본질

- **이름은 rollback인데 실제 동작은 "지정 batch만 활성화"** → `import` 시점의 활성화 로직(`UPDATE active=0 WHERE batch_id != ?` + `UPDATE active=1 WHERE batch_id = ?`, 8779라인)과 **완전히 동일**.
- 진짜 비활성화(=현재 active 배치 끄기) 기능은 **없음**.

### E-3. 호출자

- `grep -rn "shihuo/rollback" tabs/ kream_dashboard.html` → **0건**
- `grep -n "shihuo" kream_dashboard.html` → 식货 앱 검색 텍스트뿐(라인 6640-6656), API 호출 없음

⇒ **현재 호출자 없음**. 리네임/추가 시 프런트엔드 깨짐 위험 0. (curl 등 외부 호출 가능성은 있으니 backwards-compat 별칭만 남겨두면 충분.)

---

## F. 위험 분석

### F-1. ALTER TABLE bid_cost ADD COLUMN cny_source TEXT

| 항목 | 평가 |
|---|---|
| WAL 모드 안전성 | 안전 (SQLite ADD COLUMN은 메타데이터만, 데이터 재작성 없음) |
| DEFAULT 값 | 신규 행: 호출 측에서 명시. 기존 48건: NULL → 마이그레이션 1회 `UPDATE bid_cost SET cny_source='unknown' WHERE cny_source IS NULL` 권장 |
| 멱등성 | `_init_bid_cost_table`에서 `PRAGMA table_info(bid_cost)` 체크 후 컬럼 없으면 ALTER (재시작 반복 안전) |
| 백업 | 작업 전 `cp price_history.db price_history_backup_step16a_pre.db` 필수 |

### F-2. _save_bid_cost 자동 채택 분기

| 위험 | 완화책 |
|---|---|
| 사용자 명시 입력을 식货로 덮어쓸 위험 | **manual 우선 원칙** — 호출자가 cny_price>0을 명시하면 그대로 사용, source='manual'. None/0일 때만 shihuo 조회 |
| 식货 매칭 실패 시 무한 NULL 저장 | shihuo 매칭 실패 + manual 없음 → 기존처럼 저장 스킵 (호출자에서 경고 로그) |
| 모델 표기 변형 (대소문자, 하이픈) | 1차에서는 정확 일치(`=`)만 적용. 차후 정규화 룩업이 필요하면 v2 |
| 동시성 (스케줄러 + 사용자 동시 호출) | 별도 트랜잭션마다 UPSERT — 마지막 쓰기 우선. cny_source 컬럼이 추가되어 추적 가능하므로 사후 감사 가능 |

### F-3. /api/shihuo/rollback 리네임

| 위험 | 완화책 |
|---|---|
| 외부 curl/스크립트 깨짐 | 기존 URL을 `activate`로 별칭 라우팅 (302 redirect 또는 함수 공유) — 한 분기 동안 유지 후 v17에서 제거 |
| "rollback"이라는 이름이 호출자 측에서 "비활성화"로 오해됨 | 1차에서 `/api/shihuo/activate/<batch_id>` 로 정식 명명 + `/api/shihuo/deactivate` (활성 배치 전체 active=0) 신설 |
| deactivate 후 가격 매칭 깨짐 | 모든 active=0 상태에서는 자동 채택 로직이 자연스럽게 매칭 0건 → 기존(=manual)으로 동작. 안전. |

### F-4. 프런트엔드 (Step 5 UI)

| 위험 | 완화책 |
|---|---|
| 식货 임포트 탭 위치 불명확 | `tabs/`에 식货 전용 파일 없음 → 별도 검토 필요 (Step 16-A 본 작업 Step 5에서 호스팅 위치 우선 확인) |
| 모달 닫힘/열림 상태 관리 | 기존 모달 패턴(예: tab_adjust 등) 재사용 |

---

## 의외점 / 추가 발견

1. **현재 bid_cost ↔ shihuo active 실제 매칭은 0건.** 모델 풀이 겹치지 않음. 회귀 테스트는 반드시 가상 bid_cost(`TEST_*` 접두사)로 진행.
2. **bid_cost.size는 TEXT**(예: `'250'`, `'ONE SIZE'`) — INTEGER가 아님. 매칭 시 `CAST(bid_cost.size AS INTEGER)` 필수.
3. **shihuo.size_eu**가 정확한 컬럼명 (작업지시서 8에서 발견된 `eu_size` 오타와 정반대 — 본 작업에서는 반드시 `size_eu`로 적을 것).
4. **bid_cost는 `updated_at` 컬럼이 없음.** cny_source의 마지막 변경 시점 추적이 필요하면 별도 컬럼 신설 필요(현재 범위에서는 불필요로 판단, source만으로 충분).
5. **현재 `/api/shihuo/rollback`의 동작은 import 활성화와 동일** — "rollback"이라는 이름이 의미를 호도하므로 리네임의 정당성 확보.
6. **shihuo_prices의 `kream_mm IS NULL`인 행이 다수**(IA8913, IX7693 등 — `mapping_status` non-success). LEFT JOIN 시 자동 제외되지만, 리포트 API에서는 `INNER JOIN` 또는 `WHERE sh.kream_mm IS NOT NULL` 명시.

---

## 본 작업지시서 작성에 필요한 결정 사항

1. **manual vs shihuo 우선순위**: manual 우선 (호출자가 cny_price>0 명시하면 그대로). shihuo 자동 채택은 cny_price 누락 시에만.
2. **cny_source 값 도메인**: `'shihuo' | 'manual' | 'unknown'` (기존 48건은 마이그레이션 1회 UPDATE로 `'unknown'`).
3. **자동 채택 활성 범위**: 자동 입찰 계열(라인 1451, 4061, 4100, 7218) — 호출자 측에서 cny_price 없을 때 _save_bid_cost를 **호출하도록** 변경(현재는 호출 자체 스킵). 또는 _save_bid_cost가 cny_price=None 받아 내부에서 lookup. → **후자 채택**(호출자 변경 최소화).
4. **리포트 API 1차 범위**: SQL JOIN 결과만(bc_cny, sh_cny, diff). KREAM 입찰가/새 마진은 v2.
5. **rollback 처리 방식**: `/api/shihuo/activate/<batch_id>` (정식 명명, 기존 동작 그대로) + `/api/shihuo/deactivate` (현재 active 배치 전체 끄기, 신규) 신설. 기존 `/api/shihuo/rollback/<batch_id>`는 별칭으로 한 분기 유지.
6. **백업 정책**: 작업 시작 전 `price_history_backup_step16a_pre.db` 1개 + Step 1 직전 1개(스키마 변경 직전).

---

## 핵심 라인 인덱스 (본 작업지시서 참조용)

- `_init_bid_cost_table`: kream_server.py:231-249
- `_save_bid_cost`: kream_server.py:282-301
- 호출자: 1451, 4061, 4100, 5074, 5201, 7218
- `api_shihuo_rollback`: kream_server.py:8886-8898
- `api_shihuo_import`: kream_server.py:8612-… (활성화 SQL은 8779)
- bid-cost API 라우트: 5047, 5113, 5127, 5164
- shihuo API 라우트: 8612, 8808, 8838, 8862, 8886
