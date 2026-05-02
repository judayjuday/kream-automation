# 작업지시서 10 — Step 16-A 본 작업 (Phase 2) [v2]

> **v2 변경 요약** (2026-05-01 — 패치지시서_작업지시서10_v2.md 반영)
> - 사전 사실 확인 결과 반영 (`imported_at` 실재 / SQLite 3.51 / 식货 UI 미존재 / auto_rebid 패턴 timestamp 누적형)
> - 수정 1 (★): `imported_at` 컬럼 실재 확인, v1 그대로 유지 — 단 매칭 0건 폴백 명시
> - 수정 2 (★): Step 6 회귀 테스트를 **A안 (sqlite3 직접 SQL 시뮬레이션)**으로 변경. `from kream_server import _save_bid_cost` 제거 (Flask 초기화 부작용 + 포트 충돌 방지)
> - 수정 3 (★): Step 2-2-d auto_rebid `order_id` 패턴 — **옵션 A (안정 키 UPSERT) 권장**, 옵션 B (별도 이력 테이블) 사용자 결정 필요
> - 수정 4 (★): SQLite 3.51.0이라 DROP COLUMN 지원됨 → Step 7-3 그대로 유지
> - 수정 5 (보강): Step 2-1 `_save_bid_cost` 단일 connection으로 통합
> - 수정 6 (보강): **식货 임포트 UI가 현재 미존재** — Step 5는 신규 UI 생성 단계로 재정의
> - 수정 7 (보강): Step 1 마이그레이션 BEGIN 트랜잭션 명시

목적: bid_cost UPSERT 시 shihuo 활성 배치로부터 cny_price 자동 채택 + cny_source 추적 + 리포트 API + shihuo activate/deactivate 분리.

선결: **`분석보고서_Step16A_v1.md` 검토 완료 후 진행.**

---

## 사전 사실 확인 결과 (2026-05-01 시점, v2에서 확정)

```
shihuo_prices 컬럼 (PRAGMA table_info):
 0|id INTEGER PK
 1|batch_id TEXT NOT NULL
 2|active INTEGER DEFAULT 1
 3|brand_raw TEXT
 4|brand_normalized TEXT
 5|category TEXT
 6|model TEXT NOT NULL
 7|color TEXT
 8|size_eu TEXT
 9|size_normalized TEXT
10|kream_mm INTEGER
11|cny_price REAL NOT NULL
12|supplier TEXT
13|platform TEXT
14|source_created_at DATETIME
15|imported_at DATETIME DEFAULT CURRENT_TIMESTAMP   ← v1 가정 그대로 유효
16|mapping_status TEXT
17|mapping_note TEXT

SQLite 버전: 3.51.0  (≥ 3.35 이므로 DROP COLUMN 지원)

식货 임포트 UI 위치 grep 결과:
- kream_dashboard.html: 0건
- tabs/*.html: 0건
- 즉, 식货 임포트는 백엔드 API(/api/shihuo/import, /api/shihuo/latest, /api/shihuo/by-model, /api/shihuo/unmapped, /api/shihuo/rollback)만 존재하고
  대시보드 측 UI는 아직 만들어지지 않았음. v2 Step 5에서 UI 신규 생성 필요.

auto_rebid 호출 패턴 (kream_server.py:7195~7235):
  order_id=f"{product_id}_{size}_rebid_{int(time.time())}"
  → 매 호출마다 timestamp가 달라 UPSERT 의도가 무력화되어 bid_cost 행이 무한 누적됨.
  v2에서 안정 키로 전환 (또는 사용자 결정에 따라 별도 이력 테이블).
```

---

## 절대 규칙 (위반 시 즉시 중단)

1. `bid_cost`, `shihuo_prices`에 대한 **DROP TABLE / DELETE FROM 금지**. 스키마 변경은 ALTER TABLE만.
2. **자동 입찰 트리거 추가 금지** — 본 작업은 원가 데이터 흐름만 다룸. 입찰 실행 코드(`kream_bot.py`, `_run_bid_only*`) 호출/생성 금지.
3. **manual cny_price 입력은 절대 식货 값으로 덮어쓰지 않음** (호출자가 cny_price>0을 명시하면 그대로 보관, source='manual').
4. **식货 매칭 실패 시 가짜 값 채우기 금지** — 매칭 실패 + manual 없음 = 기존처럼 저장 스킵 + 경고 로그.
5. `auth_state.json`, `my_bids_local.json` **수정 금지** (읽기만).
6. 모든 SQL/API 호출은 **실제 컬럼명** 사용:
   - `shihuo_prices.size_eu` (`eu_size` 아님)
   - `shihuo_prices.kream_mm` (INTEGER)
   - `shihuo_prices.imported_at` (DATETIME, 사전-1로 검증됨)
   - `bid_cost.size` (TEXT, mm 단위 문자열 또는 `'ONE SIZE'`)
   - `bid_cost.cny_price` (REAL)
   - 매칭 시 `CAST(bid_cost.size AS INTEGER) = shihuo_prices.kream_mm` 필수.
7. **테스트는 `TEST_` 접두사 order_id로만**. 끝나면 `DELETE FROM bid_cost WHERE order_id LIKE 'TEST_%'`.
8. **회귀 테스트에서 `from kream_server import _save_bid_cost` 금지** — Flask 앱 초기화 부작용 + 포트 충돌 위험. sqlite3 직접 SQL로 시뮬레이션 (Step 6).

---

## 사전 백업 (Step 1 진입 전 필수)

```bash
cp price_history.db price_history_backup_step16a_pre.db
ls -lh price_history_backup_step16a_pre.db   # 사이즈 확인
sqlite3 price_history.db "SELECT COUNT(*) FROM bid_cost; SELECT COUNT(*) FROM shihuo_prices WHERE active=1;"
# 기록: bid_cost 48건 / shihuo active 45건 (2026-05-01 기준)
```

---

## Step 1 — bid_cost 스키마 마이그레이션 (cny_source 추가)

### 1-1. `_init_bid_cost_table` 함수 수정 (kream_server.py:231-249)

기존 함수 끝에 **idempotent 컬럼 추가** 블록을 BEGIN 트랜잭션으로 감싸 덧붙임 (수정 7 적용):

```python
def _init_bid_cost_table():
    """bid_cost 테이블 생성 — 입찰 시점의 원가 정보 보관"""
    conn = sqlite3.connect(str(PRICE_DB))
    c = conn.cursor()
    c.execute("""CREATE TABLE IF NOT EXISTS bid_cost (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        order_id TEXT UNIQUE,
        model TEXT,
        size TEXT,
        cny_price REAL,
        exchange_rate REAL,
        overseas_shipping INTEGER DEFAULT 8000,
        other_costs INTEGER DEFAULT 0,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )""")
    c.execute("CREATE INDEX IF NOT EXISTS idx_bc_model ON bid_cost(model)")
    c.execute("CREATE INDEX IF NOT EXISTS idx_bc_model_size ON bid_cost(model, size)")

    # ── Step 16-A: cny_source 컬럼 추가 (idempotent, 트랜잭션 보장) ──
    cols = [r[1] for r in c.execute("PRAGMA table_info(bid_cost)").fetchall()]
    if "cny_source" not in cols:
        c.execute("BEGIN")
        try:
            c.execute("ALTER TABLE bid_cost ADD COLUMN cny_source TEXT")
            c.execute("UPDATE bid_cost SET cny_source='unknown' WHERE cny_source IS NULL")
            conn.commit()
        except Exception:
            conn.rollback()
            raise
    else:
        conn.commit()
    conn.close()
```

> 주의: `sqlite3.connect()`는 기본 isolation_level이 빈 문자열이 아니므로 `BEGIN`을 명시해 ALTER+UPDATE를 한 트랜잭션으로 묶는다. 이미 `cny_source`가 존재하면 BEGIN을 건너뛰어 불필요한 락을 피한다.

### 1-2. 검증

```bash
python3 -c "import py_compile; py_compile.compile('kream_server.py', doraise=True)"
# 서버 재시작
lsof -ti:5001 | xargs kill -9 2>/dev/null; python3 kream_server.py > server.log 2>&1 &
sleep 3
# 컬럼 추가 확인
sqlite3 -header price_history.db "PRAGMA table_info(bid_cost)"
# 기존 행 마이그레이션 확인
sqlite3 -header price_history.db "SELECT cny_source, COUNT(*) FROM bid_cost GROUP BY cny_source"
# 기대: unknown|48
```

---

## Step 2 — `_save_bid_cost` 분기 추가 (자동 채택 + cny_source 기록)

### 2-1. 함수 시그니처 변경 (kream_server.py:282-301) — 단일 connection 통합 (수정 5 적용)

```python
def _save_bid_cost(order_id, model, size, cny_price, exchange_rate,
                   overseas_shipping=8000, other_costs=0,
                   cny_source=None):
    """입찰 시점의 원가 저장 (UPSERT by order_id).

    cny_price가 None/0이면 shihuo_prices(active=1) 매칭으로 자동 채택 시도.
    매칭 키: model 정확 일치 + CAST(size AS INTEGER) = kream_mm.
    매칭 실패 시 저장 스킵.

    v2 변경: shihuo 조회와 UPSERT를 단일 connection으로 통합 (락 경합 완화).
    """
    if not order_id:
        return None

    resolved_cny = float(cny_price) if cny_price and float(cny_price) > 0 else None
    resolved_source = cny_source

    # manual 명시 입력이 우선 — 식货 절대 덮어쓰지 않음 (절대 규칙 #3)
    if resolved_cny is not None:
        if not resolved_source:
            resolved_source = "manual"

    rate_f = float(exchange_rate) if exchange_rate else 0.0

    # 단일 connection으로 shihuo 조회 + UPSERT 처리
    conn = sqlite3.connect(str(PRICE_DB))
    try:
        cur = conn.cursor()

        # manual 미지정 → shihuo 자동 채택 시도
        if resolved_cny is None:
            try:
                size_int = int(str(size).strip())
            except (ValueError, TypeError):
                size_int = None

            if model and size_int is not None:
                row = cur.execute(
                    """SELECT cny_price FROM shihuo_prices
                       WHERE active=1 AND model=? AND kream_mm=?
                       ORDER BY imported_at DESC LIMIT 1""",
                    (model, size_int)
                ).fetchone()
                if row and row[0]:
                    resolved_cny = float(row[0])
                    resolved_source = "shihuo"

        if resolved_cny is None:
            # 매칭 실패 + manual 없음 → 저장 스킵 (기존 동작 유지, 절대 규칙 #4)
            print(f"[bid_cost] 스킵: order_id={order_id} model={model} size={size} — cny_price 없음 + 식货 매칭 실패")
            return None

        if not resolved_source:
            resolved_source = "unknown"

        cur.execute(
            """INSERT INTO bid_cost (order_id, model, size, cny_price, exchange_rate,
                  overseas_shipping, other_costs, cny_source)
               VALUES (?,?,?,?,?,?,?,?)
               ON CONFLICT(order_id) DO UPDATE SET
                 cny_price=excluded.cny_price,
                 exchange_rate=excluded.exchange_rate,
                 overseas_shipping=excluded.overseas_shipping,
                 other_costs=excluded.other_costs,
                 cny_source=excluded.cny_source""",
            (order_id, model or "", size or "", resolved_cny, rate_f,
             int(overseas_shipping), int(other_costs), resolved_source)
        )
        conn.commit()
        return {"cny_price": resolved_cny, "cny_source": resolved_source}
    finally:
        conn.close()
```

> v1과 차이: shihuo 조회용 `with sqlite3.connect(...)` 블록이 따로 있던 것을 제거하고, INSERT까지 같은 connection을 사용한다. 락 경합 완화 + 함수 단일 진입/종료 보장.

### 2-2. 호출자 측 변경 (자동 입찰 계열만)

자동 채택 혜택을 받기 위해 **호출자에서 cny_price 가드를 풀고** _save_bid_cost를 무조건 호출.

#### 2-2-a. 라인 1447-1462 부근 (단일 자동 등록)

```python
# 입찰 성공 시 bid_cost 저장 (식货 매칭 시 자동 채택)
if result and result.get("success"):
    try:
        saved = _save_bid_cost(
            order_id=result.get("orderId") or f"{product_id}_{size}",
            model=model, size=size,
            cny_price=float(cny_price) if cny_price else None,
            exchange_rate=float(exchange_rate) if exchange_rate else 0,
            overseas_shipping=int(overseas_shipping),
            cny_source=("manual" if cny_price and float(cny_price) > 0 else None),
        )
        if not saved:
            print(f"[bid_cost] #{product_id} 원가 미저장 (manual 없음 + 식货 매칭 실패)")
    except Exception as e:
        print(f"[bid_cost] 저장 실패: {e}")
```

#### 2-2-b. 라인 4055-4071 부근 (다중 사이즈 묶음)

```python
if bi_result.get("ok"):
    save_bid_local(pid, model=model, size=bi_result["size"],
                  price=bi_result["price"], source="placed")
    _cny = matched_bi.get("cny_price", 0)
    try:
        saved = _save_bid_cost(
            order_id=bi_result.get("orderId") or f"{pid}_{bi_result['size']}",
            model=model, size=bi_result["size"],
            cny_price=float(_cny) if _cny else None,
            exchange_rate=float(matched_bi.get("exchange_rate", 0)),
            overseas_shipping=int(matched_bi.get("overseas_shipping", 8000)),
            cny_source=("manual" if _cny and float(_cny) > 0 else None),
        )
        if not saved:
            add_log(tid, "warn", f"  [{model} {bi_result['size']}] 원가 미저장 (식货 매칭 실패)")
    except Exception as e:
        add_log(tid, "error", f"  bid_cost 저장 실패: {e}")
```

#### 2-2-c. 라인 4094-4110 부근 (단일 사이즈 분기) — 위와 동일 패턴 적용.

#### 2-2-d. 라인 7206-7227 부근 (auto_rebid) — order_id 안정 키 전환 (수정 3 적용)

> ⚠️ **사용자 결정 필요**
>
> 기존 v1 패턴 `f"{product_id}_{size}_rebid_{int(time.time())}"`은 매 호출마다 timestamp가 바뀌어 UPSERT(`order_id` UNIQUE)가 무력화됨 → bid_cost 행 무한 누적.
> 두 옵션 중 하나를 사용자가 결정해야 한다.
>
> **옵션 A (권장, 코드 변경 최소)**: 안정 키로 전환하여 UPSERT 동작 보존
> ```python
> order_id=f"{product_id}_{size}_rebid"   # timestamp 제거
> ```
> - 장점: bid_cost 행 (product_id, size)당 1행 유지. 자동 재입찰이 반복돼도 누적 없음.
> - 단점: 자동 재입찰 이력(언제 몇 번 재입찰됐는지)을 bid_cost에서는 추적 불가. 단, `_save_bid_cost`의 `created_at`이 갱신되지 않는 점 참고 (UPSERT는 created_at을 건드리지 않음 — 의도된 동작).
>
> **옵션 B (이력 보존이 중요할 때)**: 별도 이력 테이블 신설
> ```sql
> CREATE TABLE rebid_history (
>   id INTEGER PRIMARY KEY AUTOINCREMENT,
>   product_id TEXT, model TEXT, size TEXT,
>   cny_price REAL, exchange_rate REAL, overseas_shipping INTEGER,
>   bid_price INTEGER, sale_price INTEGER,
>   created_at DATETIME DEFAULT CURRENT_TIMESTAMP
> );
> ```
> - 자동 재입찰 시 `bid_cost`에는 안정 키(옵션 A)로 UPSERT, `rebid_history`에는 매 건 INSERT.
> - Step 16-A 본 작업의 범위를 넘는 신규 테이블이라 별도 마이그레이션 단계가 필요.
>
> **이번 v2 본 작업에서는 옵션 A로 진행한다고 가정한 코드를 제공한다.** 사용자가 옵션 B를 원할 경우 별도 작업지시서 11로 분리 발주.

옵션 A 코드:

```python
if success:
    await save_state_with_localstorage(page, context, STATE_FILE, PARTNER_URL)
    settings = {}
    if SETTINGS_FILE.exists():
        try:
            settings = json.loads(SETTINGS_FILE.read_text())
        except Exception:
            pass
    rate = settings.get("cnyRate", 215)
    try:
        saved = _save_bid_cost(
            order_id=f"{product_id}_{size}_rebid",  # v2: timestamp 제거 → UPSERT 보존
            model=model, size=size,
            cny_price=float(cny_price) if cny_price else None,
            exchange_rate=float(rate),
            overseas_shipping=8000,
            cny_source=("manual" if cny_price and float(cny_price) > 0 else None),
        )
    except Exception as e:
        print(f"[auto_rebid] bid_cost 실패: {e}")
```

### 2-3. 수동 입력 API (라인 5074, 5201)는 **변경 없음**

- `api_bid_cost_upsert` / `api_bid_cost_bulk_upsert`은 진입 시 cny_price>0 검증이 있고 사용자 명시 입력이므로 `cny_source='manual'` 명시 전달이 안전.

```python
# 라인 5074 부근
_save_bid_cost(
    order_id=order_id, model=model, size=size,
    cny_price=cny_f,
    exchange_rate=rate_f,
    overseas_shipping=ship_i,
    other_costs=other_i,
    cny_source="manual",   # 추가
)
```

```python
# 라인 5201 부근 (bulk-upsert)
_save_bid_cost(
    order_id=oid, model=model, size=size,
    cny_price=cny_f, exchange_rate=rate_f,
    overseas_shipping=ship_i, other_costs=other_i,
    cny_source="manual",   # 추가
)
```

### 2-4. 검증

```bash
python3 -c "import py_compile; py_compile.compile('kream_server.py', doraise=True)"
# 라우트 충돌 검사
grep -n '@app.route' kream_server.py | sort -t'"' -k2 | uniq -d -f1
```

---

## Step 3 — `/api/shihuo/rollback` 안전화 (activate 리네임 + deactivate 신설)

### 3-1. 정식 명명 라우트 신설 (kream_server.py:8886 부근에 추가)

```python
@app.route("/api/shihuo/activate/<batch_id>", methods=["POST"])
def api_shihuo_activate(batch_id):
    """지정 batch_id를 active=1로, 그 외 active=0으로 전환."""
    with sqlite3.connect(str(PRICE_DB)) as conn:
        existing = conn.execute(
            "SELECT COUNT(*) FROM shihuo_prices WHERE batch_id=?", (batch_id,)
        ).fetchone()[0]
        if existing == 0:
            return jsonify({"ok": False, "error": f"batch_id {batch_id} 존재하지 않음"}), 404
        conn.execute("UPDATE shihuo_prices SET active=0 WHERE batch_id != ?", (batch_id,))
        conn.execute("UPDATE shihuo_prices SET active=1 WHERE batch_id = ?", (batch_id,))
        conn.commit()
    return jsonify({"ok": True, "batch_id": batch_id, "activated": existing})


@app.route("/api/shihuo/deactivate", methods=["POST"])
def api_shihuo_deactivate():
    """현재 active 배치를 모두 끔 — 진짜 비활성화."""
    with sqlite3.connect(str(PRICE_DB)) as conn:
        cur = conn.execute("UPDATE shihuo_prices SET active=0 WHERE active=1")
        conn.commit()
        cnt = cur.rowcount
    return jsonify({"ok": True, "deactivated": cnt})


# 백워드 호환 — 한 분기 유지 후 v17에서 제거 예정
@app.route("/api/shihuo/rollback/<batch_id>", methods=["POST"])
def api_shihuo_rollback(batch_id):
    """[DEPRECATED] /api/shihuo/activate/<batch_id> 사용 권장."""
    return api_shihuo_activate(batch_id)
```

⚠️ 기존 `api_shihuo_rollback`(8886-8898)을 **위 정의로 교체**하되, 함수명/라우트는 유지하고 본문만 `return api_shihuo_activate(batch_id)`로 위임. activate/deactivate는 그 위에 신설.

### 3-2. 검증

```bash
python3 -c "import py_compile; py_compile.compile('kream_server.py', doraise=True)"
# 서버 재시작 후
curl -s -X POST http://localhost:5001/api/shihuo/activate/shihuo_20260501_121000 | head -c 200
curl -s -X POST http://localhost:5001/api/shihuo/rollback/shihuo_20260501_121000 | head -c 200  # 별칭 동작 확인
sqlite3 -header price_history.db "SELECT batch_id, SUM(active) FROM shihuo_prices GROUP BY batch_id ORDER BY batch_id DESC LIMIT 5"
```

---

## Step 4 — `/api/bid-cost/shihuo-diff` 신설 (리포트 API)

### 4-1. 라우트 추가 (kream_server.py:5161 부근, `api_bid_cost_missing` 다음)

```python
@app.route("/api/bid-cost/shihuo-diff")
def api_bid_cost_shihuo_diff():
    """등록된 bid_cost와 식货 활성 배치의 cny_price 차이 리포트.

    매칭: bc.model = sh.model AND CAST(bc.size AS INTEGER) = sh.kream_mm AND sh.active=1.
    가격 차이가 있는 행만 반환. ONE SIZE 등 캐스팅 불가 항목은 자동 제외(매칭 0).
    """
    conn = sqlite3.connect(str(PRICE_DB))
    conn.row_factory = sqlite3.Row
    c = conn.cursor()

    active_batch = c.execute(
        "SELECT batch_id FROM shihuo_prices WHERE active=1 ORDER BY imported_at DESC LIMIT 1"
    ).fetchone()
    active_batch_id = active_batch[0] if active_batch else None

    rows = c.execute("""
        SELECT bc.order_id, bc.model, bc.size,
               bc.cny_price        AS bc_cny,
               bc.cny_source       AS bc_source,
               bc.exchange_rate    AS bc_rate,
               sh.cny_price        AS sh_cny,
               sh.batch_id         AS sh_batch,
               sh.kream_mm         AS sh_kream_mm,
               sh.size_eu          AS sh_size_eu
          FROM bid_cost bc
          JOIN shihuo_prices sh
            ON sh.active=1
           AND sh.model = bc.model
           AND sh.kream_mm IS NOT NULL
           AND sh.kream_mm = CAST(bc.size AS INTEGER)
         WHERE sh.cny_price <> bc.cny_price
         ORDER BY ABS(sh.cny_price - bc.cny_price) DESC
    """).fetchall()
    conn.close()

    items = []
    for r in rows:
        bc_cny = float(r["bc_cny"] or 0)
        sh_cny = float(r["sh_cny"] or 0)
        diff = sh_cny - bc_cny
        diff_pct = (diff / bc_cny * 100.0) if bc_cny else None
        items.append({
            "order_id": r["order_id"],
            "model": r["model"],
            "size": r["size"],
            "bc_cny": bc_cny,
            "bc_source": r["bc_source"],
            "sh_cny": sh_cny,
            "diff_cny": round(diff, 2),
            "diff_pct": round(diff_pct, 2) if diff_pct is not None else None,
            "sh_batch": r["sh_batch"],
            "sh_size_eu": r["sh_size_eu"],
            "sh_kream_mm": r["sh_kream_mm"],
            "exchange_rate": r["bc_rate"],
        })

    return jsonify({
        "ok": True,
        "active_batch_id": active_batch_id,
        "count": len(items),
        "items": items,
    })
```

### 4-2. 검증

```bash
curl -s http://localhost:5001/api/bid-cost/shihuo-diff | python3 -m json.tool | head -40
```

---

## Step 5 — 식货 임포트 + 차이 보기 UI (★ v2: 신규 UI 생성, 수정 6 적용)

### 5-1. 사전 사실 (v2 시점에 확정)

- `kream_dashboard.html` / `tabs/*.html`을 grep한 결과 **식货(shihuo) 관련 UI는 어디에도 존재하지 않는다**.
- 즉 v1의 가정 ("식货 임포트 UI가 어디에 있는지 확인 후 그 자리에 추가")은 성립하지 않는다.
- 백엔드 API만 존재: `/api/shihuo/import`, `/api/shihuo/latest`, `/api/shihuo/by-model/<model>`, `/api/shihuo/unmapped`, `/api/shihuo/rollback/<batch_id>` + (Step 3에서 추가) `/api/shihuo/activate/<batch_id>`, `/api/shihuo/deactivate`.

### 5-2. UI 호스팅 위치 결정

다음 중 하나를 채택 (사용자 결정):

**옵션 A (권장)**: 신규 탭 `tabs/tab_shihuo.html` 생성
- 사이드바에 "식货 시장가" 메뉴 추가 (`kream_dashboard.html`)
- 화면 구성: 엑셀 업로드 폼(`/api/shihuo/import`) + 활성 배치 정보(`/api/shihuo/latest`) + activate/deactivate 버튼 + **차이 보기 모달** + unmapped 목록(`/api/shihuo/unmapped`)
- 장점: 식货 워크플로우 전체를 한 화면에 묶음. 향후 확장 용이.

**옵션 B (최소 작업)**: `tab_settings.html` 또는 `tab_prices.html` 하단에 섹션 추가
- 임포트 폼 + 활성 배치 + 차이 보기 버튼만 노출.
- 장점: 새 탭 추가 작업 생략. 단점: 식货 관련 항목이 흩어져 발견성 낮음.

**이번 v2 본 작업은 옵션 A로 진행하는 것을 권장한다.** 사용자가 옵션 B를 원하면 같은 마크업을 해당 탭에 인라인으로 옮기면 된다.

### 5-3. 옵션 A 구체 작업

#### 5-3-1. 사이드바 메뉴 추가

`kream_dashboard.html` 사이드바 메뉴 영역에서 기존 패턴을 따라 추가:

```html
<a href="#" class="menu-item" data-tab="shihuo">식货 시장가</a>
```

탭 로딩 라우터(JS)에 `shihuo: 'tabs/tab_shihuo.html'` 매핑 추가.

#### 5-3-2. `tabs/tab_shihuo.html` 신규 생성

```html
<section class="card">
  <h2>식货 시장가 임포트</h2>
  <form id="shihuoImportForm">
    <input type="file" id="shihuoFile" accept=".xlsx" required>
    <button type="submit">엑셀 업로드</button>
  </form>
  <div id="shihuoImportResult" style="margin-top:8px"></div>
</section>

<section class="card" style="margin-top:12px">
  <h2>활성 배치 정보</h2>
  <div id="shihuoLatestInfo">로딩 중…</div>
  <div style="margin-top:8px">
    <button onclick="loadShihuoLatest()">새로고침</button>
    <button onclick="deactivateShihuo()" style="margin-left:8px">활성 배치 끄기</button>
    <button onclick="loadShihuoDiff()" style="margin-left:8px">식货 ↔ 등록 원가 차이 보기</button>
  </div>
</section>

<section class="card" style="margin-top:12px">
  <h2>매핑 실패 목록 (unmapped)</h2>
  <div id="shihuoUnmappedInfo">로딩 중…</div>
</section>

<!-- 차이 보기 모달 -->
<div id="shihuoDiffModal" class="modal" style="display:none; position:fixed; top:5%; left:5%; right:5%; bottom:5%; background:#fff; border:1px solid #ccc; padding:16px; overflow:auto; z-index:1000">
  <div class="modal-content">
    <h3>식货 활성 배치 vs bid_cost 가격 차이</h3>
    <div id="shihuoDiffMeta"></div>
    <table id="shihuoDiffTable" border="1" cellpadding="6" style="margin-top:8px; width:100%">
      <thead><tr>
        <th>order_id</th><th>model</th><th>size</th>
        <th>등록 CNY</th><th>source</th>
        <th>식货 CNY</th><th>차이 CNY</th><th>차이 %</th>
      </tr></thead>
      <tbody></tbody>
    </table>
    <button onclick="document.getElementById('shihuoDiffModal').style.display='none'" style="margin-top:8px">닫기</button>
  </div>
</div>

<script>
async function loadShihuoLatest(){
  const r = await fetch('/api/shihuo/latest').then(x=>x.json()).catch(()=>null);
  const el = document.getElementById('shihuoLatestInfo');
  if(!r || !r.ok){ el.textContent = '활성 배치 없음 또는 조회 실패'; return; }
  el.innerHTML = `활성 batch: <b>${r.batch_id || '없음'}</b> | 임포트: ${r.imported_at || '-'} | 총 ${r.total ?? 0}건`;
}

async function deactivateShihuo(){
  if(!confirm('현재 활성 배치를 모두 끕니다. 계속?')) return;
  const r = await fetch('/api/shihuo/deactivate', {method:'POST'}).then(x=>x.json());
  alert(r.ok ? `${r.deactivated}건 비활성화 완료` : '실패');
  loadShihuoLatest();
}

async function loadShihuoDiff(){
  const r = await fetch('/api/bid-cost/shihuo-diff').then(x=>x.json());
  if(!r.ok){ alert('조회 실패'); return; }
  const meta = document.getElementById('shihuoDiffMeta');
  meta.textContent = `활성 batch: ${r.active_batch_id || '없음'} | 차이 ${r.count}건`;
  const tb = document.querySelector('#shihuoDiffTable tbody');
  tb.innerHTML = '';
  r.items.forEach(it=>{
    const tr = document.createElement('tr');
    tr.innerHTML = `
      <td>${it.order_id}</td>
      <td>${it.model}</td>
      <td>${it.size}</td>
      <td>${it.bc_cny.toFixed(2)}</td>
      <td>${it.bc_source||''}</td>
      <td>${it.sh_cny.toFixed(2)}</td>
      <td>${it.diff_cny.toFixed(2)}</td>
      <td>${it.diff_pct!=null ? it.diff_pct.toFixed(2)+'%' : '-'}</td>`;
    tb.appendChild(tr);
  });
  document.getElementById('shihuoDiffModal').style.display='block';
}

async function loadShihuoUnmapped(){
  const r = await fetch('/api/shihuo/unmapped').then(x=>x.json()).catch(()=>null);
  const el = document.getElementById('shihuoUnmappedInfo');
  if(!r || !r.ok){ el.textContent = '조회 실패'; return; }
  if(!r.items || r.items.length === 0){ el.textContent = 'unmapped 0건'; return; }
  el.innerHTML = `<table border="1" cellpadding="4"><thead><tr><th>model</th><th>size_eu</th><th>cny_price</th><th>note</th></tr></thead><tbody>${
    r.items.map(it=>`<tr><td>${it.model}</td><td>${it.size_eu||''}</td><td>${it.cny_price}</td><td>${it.mapping_note||''}</td></tr>`).join('')
  }</tbody></table>`;
}

document.getElementById('shihuoImportForm')?.addEventListener('submit', async (e)=>{
  e.preventDefault();
  const f = document.getElementById('shihuoFile').files[0];
  if(!f) return;
  const fd = new FormData();
  fd.append('file', f);
  document.getElementById('shihuoImportResult').textContent = '업로드 중…';
  const r = await fetch('/api/shihuo/import', {method:'POST', body: fd}).then(x=>x.json());
  document.getElementById('shihuoImportResult').textContent = JSON.stringify(r);
  loadShihuoLatest();
  loadShihuoUnmapped();
});

// 탭 진입 시 자동 로드 (탭 라우터가 inline 스크립트를 실행한다고 가정)
loadShihuoLatest();
loadShihuoUnmapped();
</script>
```

> 주의: 위 마크업은 기존 `tabs/*.html` 패턴(인라인 `<script>` 허용 여부)을 따른다. 라우터가 동적 스크립트 실행을 지원하지 않으면 메인 `kream_dashboard.html`로 함수를 옮긴다.

### 5-4. 검증

- 사이드바 "식货 시장가" 클릭 → 탭 정상 로드, 활성 배치 정보 표시 (45건)
- "차이 보기" 클릭 → 모달 표시, 활성 배치 없으면 `count: 0` 표시
- 콘솔 에러 0건
- 엑셀 업로드 성공 시 활성 배치 정보 갱신 확인

---

## Step 6 — 회귀 테스트 시나리오 (★ v2: A안 — sqlite3 직접 SQL, 수정 2 적용)

> v1의 `from kream_server import _save_bid_cost`는 Flask 앱 초기화 부작용 + 포트 5001 충돌 위험이 있어 v2에서 전면 폐기.
> 모든 시나리오를 sqlite3 직접 SQL과 가동 중인 서버의 HTTP 엔드포인트로 검증한다.
> **현재 가동 중인 서버**는 Step 1~4의 코드 변경이 반영된 상태여야 한다 (Step 1-2, 2-4, 3-2의 서버 재시작 후 진행).

### 6-1. 시나리오 A: 식货 자동 채택 (의사 시뮬레이션)

`_save_bid_cost`의 자동 채택 로직(Step 2-1의 SELECT 절)이 같은 결과를 내는지 SQL로 직접 확인.

```bash
# 1) 식货 active 배치에 존재하는 (model, kream_mm) 찾기
sqlite3 -header price_history.db "
  SELECT model, kream_mm, cny_price
  FROM shihuo_prices
  WHERE active=1 AND kream_mm IS NOT NULL
  ORDER BY imported_at DESC LIMIT 3
"
# 결과 예: JQ1501 | 265 | 380.0  ← (model, kream_mm, cny_price) 메모

# 2) Step 2-1과 같은 SELECT (동일 결과 확인)
sqlite3 price_history.db "
  SELECT cny_price FROM shihuo_prices
  WHERE active=1 AND model='JQ1501' AND kream_mm=265
  ORDER BY imported_at DESC LIMIT 1
"
# 기대: 위에서 본 cny_price와 동일

# 3) _save_bid_cost가 호출됐을 때 INSERT 될 행을 SQL로 직접 시뮬레이션
sqlite3 price_history.db "
  INSERT OR REPLACE INTO bid_cost (order_id, model, size, cny_price, exchange_rate,
    overseas_shipping, other_costs, cny_source)
  VALUES ('TEST_AUTO_001', 'JQ1501', '265',
    (SELECT cny_price FROM shihuo_prices WHERE active=1 AND model='JQ1501' AND kream_mm=265 ORDER BY imported_at DESC LIMIT 1),
    215.0, 8000, 0, 'shihuo')
"

# 4) 자동 채택 결과 확인
sqlite3 -header price_history.db "
  SELECT order_id, model, size, cny_price, cny_source
  FROM bid_cost WHERE order_id='TEST_AUTO_001'
"
# 기대: TEST_AUTO_001 | JQ1501 | 265 | <식货 cny> | shihuo
```

### 6-2. 시나리오 B: 식货 매칭 실패 + manual 입력

```bash
# B-1. manual 입력 (식货에 없는 모델)
sqlite3 price_history.db "
  INSERT OR REPLACE INTO bid_cost (order_id, model, size, cny_price, exchange_rate,
    overseas_shipping, other_costs, cny_source)
  VALUES ('TEST_MANUAL_001', 'ZZZ_NOT_EXIST', '270', 500.0, 215.0, 8000, 0, 'manual')
"

# B-2. manual 없음 + 식货 매칭 실패 → 저장 스킵 시뮬레이션 (실제 _save_bid_cost는 None 반환하고 INSERT 안 함)
# SQL 차원에서는 "조건부로 INSERT 하지 않음"을 직접 확인:
sqlite3 price_history.db "
  SELECT cny_price FROM shihuo_prices
  WHERE active=1 AND model='ZZZ_NOT_EXIST' AND kream_mm=270
  ORDER BY imported_at DESC LIMIT 1
"
# 기대: 빈 결과 (매칭 0건) → 따라서 _save_bid_cost는 저장 스킵됨

# 검증
sqlite3 -header price_history.db "
  SELECT order_id, cny_price, cny_source FROM bid_cost
  WHERE order_id LIKE 'TEST_%' ORDER BY order_id
"
# 기대: TEST_AUTO_001 (shihuo) + TEST_MANUAL_001 (manual) 만 존재. TEST_NONE_xxx 없음.
```

### 6-3. 시나리오 C: shihuo-diff API 응답 구조 검증

```bash
# 매칭은 되지만 가격이 다른 케이스 만들기 (manual 999.0를 식货에 있는 model/size에 박아둠)
sqlite3 price_history.db "
  INSERT OR REPLACE INTO bid_cost (order_id, model, size, cny_price, exchange_rate,
    overseas_shipping, other_costs, cny_source)
  VALUES ('TEST_DIFF_001', 'JQ1501', '265', 999.0, 215.0, 8000, 0, 'manual')
"

curl -s http://localhost:5001/api/bid-cost/shihuo-diff | python3 -m json.tool | head -40
# 기대: items 배열에 TEST_DIFF_001 포함, bc_cny=999.0, sh_cny=<식货 값>, diff_cny<0, bc_source='manual'
```

### 6-4. 시나리오 D: ONE SIZE 처리 (CAST 매칭 0)

```bash
# 'ONE SIZE'는 CAST 시 0으로 매핑되지만 kream_mm=0인 식货 행은 없으므로 매칭 0
sqlite3 price_history.db "
  SELECT cny_price FROM shihuo_prices
  WHERE active=1 AND model='IX7694' AND kream_mm=CAST('ONE SIZE' AS INTEGER)
  LIMIT 1
"
# 기대: 빈 결과 → 자동 채택 실패 → manual 없으면 _save_bid_cost는 None 반환 (저장 안 함)

# 추가로 manual 없이 ONE SIZE를 넣지 않는다는 사실 확인
sqlite3 price_history.db "
  SELECT COUNT(*) FROM bid_cost WHERE order_id='TEST_ONE_001'
"
# 기대: 0 (애초에 INSERT 시도 자체가 _save_bid_cost에서 차단됨)
```

### 6-5. 시나리오 E: shihuo activate/deactivate API

```bash
# 현재 활성 배치 메모
ACTIVE_BATCH=$(sqlite3 price_history.db "SELECT batch_id FROM shihuo_prices WHERE active=1 ORDER BY imported_at DESC LIMIT 1")
echo "현재 활성: $ACTIVE_BATCH"

# 비활성화
curl -s -X POST http://localhost:5001/api/shihuo/deactivate
sqlite3 price_history.db "SELECT SUM(active) FROM shihuo_prices"  # 기대: 0

# 자동 채택 시뮬레이션 — 매칭 0이어야 함
sqlite3 price_history.db "
  SELECT cny_price FROM shihuo_prices
  WHERE active=1 AND model='JQ1501' AND kream_mm=265
  ORDER BY imported_at DESC LIMIT 1
"
# 기대: 빈 결과 (active 없음)

# 다시 활성화
curl -s -X POST "http://localhost:5001/api/shihuo/activate/$ACTIVE_BATCH"
sqlite3 price_history.db "SELECT SUM(active) FROM shihuo_prices WHERE batch_id='$ACTIVE_BATCH'"
# 기대: 45 (또는 원래 활성 행수)

# 백워드 호환 (rollback alias)
curl -s -X POST "http://localhost:5001/api/shihuo/rollback/$ACTIVE_BATCH" | head -c 200
# 기대: {"ok": true, "batch_id": "...", "activated": ...}
```

### 6-6. 시나리오 F (선택): auto_rebid 안정 키 검증

```bash
# 옵션 A 채택 시 — 같은 (product_id, size)로 두 번 호출돼도 한 행만 유지되는지 SQL로 시뮬
sqlite3 price_history.db "
  INSERT OR REPLACE INTO bid_cost (order_id, model, size, cny_price, exchange_rate,
    overseas_shipping, other_costs, cny_source)
  VALUES ('TEST_REBID_99999_265_rebid', 'JQ1501', '265', 380.0, 215.0, 8000, 0, 'shihuo');
  INSERT OR REPLACE INTO bid_cost (order_id, model, size, cny_price, exchange_rate,
    overseas_shipping, other_costs, cny_source)
  VALUES ('TEST_REBID_99999_265_rebid', 'JQ1501', '265', 385.0, 215.0, 8000, 0, 'shihuo');
"
sqlite3 -header price_history.db "
  SELECT COUNT(*), cny_price FROM bid_cost WHERE order_id LIKE 'TEST_REBID_%'
"
# 기대: 1 | 385.0  ← UPSERT로 1행만 유지, 가격은 마지막 값
```

### 6-7. 테스트 정리 (필수)

```bash
sqlite3 price_history.db "DELETE FROM bid_cost WHERE order_id LIKE 'TEST_%'"
sqlite3 -header price_history.db "SELECT COUNT(*) FROM bid_cost"  # 기대: 48 (원본 유지)
```

---

## Step 7 — 검증 후 롤백 시나리오 (이상 발생 시)

### 7-1. 즉시 중단 트리거

다음 중 하나라도 발견되면 작업 중단 + 사용자 보고:

- `bid_cost` 행 수가 48 미만으로 감소
- `cny_source` 값이 `'shihuo' | 'manual' | 'unknown'` 외의 값 등장
- 기존 manual 입력이 'shihuo'로 덮어써진 흔적 (라인 7218 자동 재입찰 후 manual 데이터 손상 등)
- `/api/health` 비정상

### 7-2. 롤백 절차

```bash
# 1) 서버 중지
lsof -ti:5001 | xargs kill -9 2>/dev/null

# 2) DB 원복
cp price_history_backup_step16a_pre.db price_history.db

# 3) 코드 원복 (작업 시작 직전 커밋 SHA로 reset, 사용자 확인 후)
git status                                      # 변경 파일 확인
git diff kream_server.py kream_dashboard.html   # 변경 내역 확인
ls tabs/tab_shihuo.html 2>/dev/null && echo "신규 탭 파일 존재"
# 사용자 OK 시:
git checkout -- kream_server.py kream_dashboard.html
rm -f tabs/tab_shihuo.html   # 신규 파일이라 git checkout으로 원복 안 됨

# 4) 서버 재시작 후 검증
python3 kream_server.py > server.log 2>&1 &
sleep 3
sqlite3 price_history.db "SELECT COUNT(*) FROM bid_cost"  # 48 복원 확인
curl -s http://localhost:5001/api/health
```

### 7-3. cny_source 컬럼 단독 롤백 (코드만 원복하고 컬럼은 유지하고 싶을 때)

- SQLite 3.51.0 (사전-2 결과)이라 `DROP COLUMN` 지원됨. 안전하게 사용 가능:
  ```sql
  ALTER TABLE bid_cost DROP COLUMN cny_source;
  ```
- 단, 이미 운영 중이면 컬럼은 그대로 두고 값만 NULL 처리하는 편이 더 안전:
  ```sql
  UPDATE bid_cost SET cny_source=NULL WHERE cny_source IS NOT NULL;
  ```
- **권장**: 컬럼은 유지(미래에도 유용), 코드만 롤백.

---

## 작업 완료 전 체크리스트

- [ ] `python3 -c "import py_compile; py_compile.compile('kream_server.py', doraise=True)"` 통과
- [ ] `grep -n '@app.route' kream_server.py | sort -t'"' -k2 | uniq -d -f1` → 중복 0
- [ ] `curl -s http://localhost:5001/api/health` 응답 200
- [ ] `curl -s http://localhost:5001/api/bid-cost/shihuo-diff` JSON 응답 (`{ok:true, ...}`)
- [ ] `curl -s -X POST http://localhost:5001/api/shihuo/activate/<batch_id>` 정상
- [ ] `curl -s -X POST http://localhost:5001/api/shihuo/deactivate` 정상
- [ ] 백워드 호환: `curl -s -X POST http://localhost:5001/api/shihuo/rollback/<batch_id>` 동작
- [ ] DB: `cny_source` 컬럼 존재 + 기존 48건 = 'unknown'
- [ ] 회귀 테스트 6-1 ~ 6-5(필수) / 6-6(옵션 A 채택 시) 통과
- [ ] 테스트 데이터 정리: `bid_cost`에 `TEST_%` 0건
- [ ] 신규 탭 `tabs/tab_shihuo.html` 정상 로드 + 콘솔 에러 0건
- [ ] auto_rebid `order_id`가 `f"{product_id}_{size}_rebid"`로 변경됨 (옵션 A)
- [ ] 백업 파일 보존: `price_history_backup_step16a_pre.db`

---

## 커밋 (체크리스트 통과 후)

```bash
git add kream_server.py kream_dashboard.html tabs/tab_shihuo.html \
        작업지시서_10_Step16A_본작업_v2.md 분석보고서_Step16A_v1.md \
        패치지시서_작업지시서10_v2.md
git commit -m "feat: Step 16-A 식货 자동 채택 + cny_source 추적 + activate/deactivate 분리 + 식货 탭 신설

- bid_cost.cny_source 컬럼 추가 (shihuo|manual|unknown)
- _save_bid_cost: cny_price 없을 시 shihuo_prices(active=1) 매칭으로 자동 채택, 단일 connection
- /api/shihuo/activate, /api/shihuo/deactivate 신설, /api/shihuo/rollback 별칭 유지
- /api/bid-cost/shihuo-diff 리포트 API 신설
- tabs/tab_shihuo.html 신규 탭 (임포트/활성 정보/차이 보기)
- auto_rebid order_id 안정 키 전환 (timestamp 누적 방지)"
```

---

## 부록 A — 실제 컬럼명 빠른 참조 (사전-1로 검증)

| 테이블 | 컬럼 | 타입 | 비고 |
|---|---|---|---|
| bid_cost | order_id | TEXT UNIQUE | UPSERT 키 |
| bid_cost | model | TEXT |  |
| bid_cost | size | TEXT | mm 문자열 또는 'ONE SIZE' |
| bid_cost | cny_price | REAL |  |
| bid_cost | exchange_rate | REAL |  |
| bid_cost | overseas_shipping | INTEGER DEFAULT 8000 |  |
| bid_cost | other_costs | INTEGER DEFAULT 0 |  |
| bid_cost | created_at | DATETIME |  |
| bid_cost | **cny_source** | TEXT | 본 작업으로 신설 |
| shihuo_prices | id | INTEGER PK |  |
| shihuo_prices | batch_id | TEXT NOT NULL |  |
| shihuo_prices | active | INTEGER DEFAULT 1 |  |
| shihuo_prices | brand_raw / brand_normalized | TEXT |  |
| shihuo_prices | category | TEXT |  |
| shihuo_prices | model | TEXT NOT NULL |  |
| shihuo_prices | color | TEXT |  |
| shihuo_prices | **size_eu** | TEXT | (eu_size 아님!) |
| shihuo_prices | size_normalized | TEXT |  |
| shihuo_prices | **kream_mm** | INTEGER | bid_cost.size CAST 매칭 대상 |
| shihuo_prices | cny_price | REAL NOT NULL |  |
| shihuo_prices | supplier / platform | TEXT |  |
| shihuo_prices | source_created_at | DATETIME |  |
| shihuo_prices | **imported_at** | DATETIME DEFAULT CURRENT_TIMESTAMP | 사전-1로 실재 확인 |
| shihuo_prices | mapping_status | TEXT |  |
| shihuo_prices | mapping_note | TEXT |  |

## 부록 B — v2 적용 수정 7건 요약

| # | 종류 | 항목 | v1 → v2 변경 |
|---|---|---|---|
| 1 | 치명 | imported_at 컬럼 검증 | 사전-1 결과 실재 확인 → v1 그대로 유지 |
| 2 | 치명 | Step 6 회귀 테스트 방식 | `from kream_server import _save_bid_cost` 폐기 → sqlite3 직접 SQL (A안) |
| 3 | 치명 | auto_rebid order_id 패턴 | `..._rebid_{timestamp}` → `..._rebid` (옵션 A 안정 키, UPSERT 보존) |
| 4 | 치명 | Step 7-3 DROP COLUMN 안내 | SQLite 3.51 확인 → v1 그대로 유지 |
| 5 | 보강 | _save_bid_cost connection 통합 | 두 connection → 단일 connection |
| 6 | 보강 | Step 5 UI 위치 | "기존 UI 옆에 추가" → "신규 탭 신설" (식货 UI 미존재 확인) |
| 7 | 보강 | Step 1 마이그레이션 트랜잭션 | ALTER+UPDATE를 BEGIN/COMMIT으로 명시 묶음 |
