# 작업지시서 10 — Step 16-A 본 작업 (Phase 2) [v3]

> **v3 변경 요약** (2026-05-01 — 패치지시서_작업지시서10_v3_확정.md 반영)
> - 사용자 두 결정 확정 → v2의 옵션 A/B 분기를 단일안으로 정리
> - **확정 1**: Step 2-2-d auto_rebid `order_id` 패턴 → **옵션 A 단일안** (`f"{product_id}_{size}_rebid"`, 안정 키, UPSERT 보존). 옵션 B (별도 이력 테이블) 폐기 → 후속 작업으로 분리.
> - **확정 2**: Step 5 UI → **옵션 B 단일안** (미니멈 인라인, `tabs/tab_adjust.html` 라인 31-33 사이에 "식货 ↔ 등록 원가 차이 보기" 섹션 추가). 옵션 A (신규 `tabs/tab_shihuo.html` + 사이드바 메뉴) 폐기 → 후속 작업으로 분리.
> - **신규**: 본 문서 말미에 "후속 작업 권장" 섹션 추가 (식货 전용 탭, shihuo-diff API v2, 자동 채택 1주 모니터링).
>
> **v2 → v3 외 사항은 전부 v2와 동일** (사전 사실 확인 결과, 절대 규칙, Step 1·2·3·4·6·7, 부록 A 모두 변경 없음).

목적: bid_cost UPSERT 시 shihuo 활성 배치로부터 cny_price 자동 채택 + cny_source 추적 + 리포트 API + shihuo activate/deactivate 분리.

선결: **`분석보고서_Step16A_v1.md` 검토 완료 후 진행.**

---

## 사전 사실 확인 결과 (2026-05-01 시점, v2에서 확정 / v3에서 변동 없음)

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
  대시보드 측 UI는 아직 만들어지지 않았음. v3에서는 미니멈 인라인 (tab_adjust.html에 차이 보기만 추가) 채택. 전용 UI는 후속 작업으로 분리.

auto_rebid 호출 패턴 (kream_server.py:7195~7235):
  order_id=f"{product_id}_{size}_rebid_{int(time.time())}"
  → 매 호출마다 timestamp가 달라 UPSERT 의도가 무력화되어 bid_cost 행이 무한 누적됨.
  v3에서 안정 키(옵션 A)로 단일 확정.
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

기존 함수 끝에 **idempotent 컬럼 추가** 블록을 BEGIN 트랜잭션으로 감싸 덧붙임:

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

### 2-1. 함수 시그니처 변경 (kream_server.py:282-301) — 단일 connection 통합

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

#### 2-2-d. 라인 7206-7227 부근 (auto_rebid) — order_id 안정 키 전환 (★ v3 확정 1: 옵션 A 단일안)

> **v3 확정**: 사용자 결정에 따라 옵션 A(안정 키)로 단일 확정. 옵션 B(별도 이력 테이블)는 폐기 → 본 문서 말미 "후속 작업 권장" 섹션으로 분리.
>
> 기존 v1 패턴 `f"{product_id}_{size}_rebid_{int(time.time())}"`은 매 호출마다 timestamp가 바뀌어 UPSERT(`order_id` UNIQUE)가 무력화됨 → bid_cost 행 무한 누적.
> **v3에서는 안정 키 `f"{product_id}_{size}_rebid"`로 전환하여 UPSERT 동작을 보존한다.**
>
> - 효과: bid_cost 행이 (product_id, size)당 1행 유지. 자동 재입찰이 반복돼도 누적 없음.
> - 트레이드오프: 자동 재입찰 이력(언제 몇 번 재입찰됐는지)을 bid_cost에서는 추적 불가. UPSERT는 `created_at`을 갱신하지 않음 (의도된 동작). 이력 보존이 필요하면 후속 작업의 `rebid_history` 별도 테이블로 처리한다.

확정 코드 (옵션 A):

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
            order_id=f"{product_id}_{size}_rebid",  # v3 확정: timestamp 제거 → UPSERT 보존
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

## Step 5 — 차이 보기 UI 미니멈 인라인 (★ v3 확정 2: 옵션 B 단일안)

### 5-1. 사전 사실

- `kream_dashboard.html` / `tabs/*.html`을 grep한 결과 **식货(shihuo) 관련 UI는 어디에도 존재하지 않는다**. (v2 시점에 확정)
- 백엔드 API만 존재: `/api/shihuo/import`, `/api/shihuo/latest`, `/api/shihuo/by-model/<model>`, `/api/shihuo/unmapped`, `/api/shihuo/rollback/<batch_id>` + (Step 3에서 추가) `/api/shihuo/activate/<batch_id>`, `/api/shihuo/deactivate`.
- v3에서는 **차이 보기 기능만 최소 인라인으로 추가**한다 (옵션 B). 식货 임포트 폼/활성 배치 관리/unmapped 목록 등 풀 UI는 후속 작업으로 분리.

### 5-2. UI 호스팅 위치 — 확정

**`tabs/tab_adjust.html`의 라인 31-33 사이** (자동 실행 카드 종료 직후, "자동 실행 이력" 카드 시작 직전).

근거:
- `tab_adjust.html`은 가격 자동 조정 탭이며 bid_cost를 직접 다루는 화면 → 맥락 일치.
- 라인 31-33은 첫 카드(자동 실행) `</div>` 종료 직후의 빈 줄로, 새 카드를 삽입해도 기존 마크업을 건드리지 않는다.
- 사용자 발견성도 충분: 탭 진입 시 상단에서 두 번째 카드로 노출됨.

실측 위치 확인 명령:

```bash
sed -n '28,35p' tabs/tab_adjust.html
# 기대 출력:
#   28:           <div id="aa-disabled-reason" ...></div>
#   29:           <div id="aa-skip-detail" ...></div>
#   30: (이 위에 line 30이 빈 div의 일부이거나 카드 닫힘)
#   31:         </div>                                    ← 자동 실행 카드 닫힘
#   32:                                                   ← 빈 줄 ← 여기 삽입
#   33:         <!-- 자동 실행 이력 -->
#   34:         <div class="card" style="margin-top:16px">
```

### 5-3. 인라인 섹션 마크업 (라인 32 빈 줄 자리에 삽입)

```html
        <!-- ── Step 16-A: 식货 ↔ 등록 원가 차이 보기 (미니멈 인라인) ── -->
        <div class="card" style="margin-top:16px; border-left:3px solid var(--info, #3b82f6)">
          <div class="card-title" style="display:flex; justify-content:space-between; align-items:center">
            <span><span class="icon">🔍</span> 식货 ↔ 등록 원가 차이</span>
            <div style="display:flex; gap:8px; align-items:center">
              <span id="shihuo-diff-meta" style="font-size:12px; color:var(--text3)">활성 batch: 로딩 중…</span>
              <button class="btn btn-outline btn-sm" onclick="loadShihuoDiff()" style="font-size:12px">차이 보기</button>
            </div>
          </div>
          <div id="shihuo-diff-empty" style="display:none; font-size:12px; color:var(--text3); margin-top:8px">차이 없음</div>
        </div>

        <!-- 차이 보기 모달 -->
        <div id="shihuoDiffModal" style="display:none; position:fixed; top:5%; left:5%; right:5%; bottom:5%; background:var(--bg1, #fff); border:1px solid var(--border, #ccc); border-radius:8px; padding:16px; overflow:auto; z-index:1000; box-shadow:0 8px 32px rgba(0,0,0,.25)">
          <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:12px">
            <h3 style="margin:0">식货 활성 배치 vs bid_cost 가격 차이</h3>
            <button class="btn btn-outline btn-sm" onclick="document.getElementById('shihuoDiffModal').style.display='none'">닫기</button>
          </div>
          <div id="shihuoDiffMetaModal" style="font-size:13px; color:var(--text2); margin-bottom:8px"></div>
          <table id="shihuoDiffTable" style="width:100%; border-collapse:collapse; font-size:13px">
            <thead>
              <tr style="background:var(--bg2, #f3f4f6)">
                <th style="padding:6px; border:1px solid var(--border)">order_id</th>
                <th style="padding:6px; border:1px solid var(--border)">model</th>
                <th style="padding:6px; border:1px solid var(--border)">size</th>
                <th style="padding:6px; border:1px solid var(--border)">등록 CNY</th>
                <th style="padding:6px; border:1px solid var(--border)">source</th>
                <th style="padding:6px; border:1px solid var(--border)">식货 CNY</th>
                <th style="padding:6px; border:1px solid var(--border)">차이 CNY</th>
                <th style="padding:6px; border:1px solid var(--border)">차이 %</th>
              </tr>
            </thead>
            <tbody></tbody>
          </table>
        </div>

        <script>
        async function loadShihuoDiff(){
          const r = await fetch('/api/bid-cost/shihuo-diff').then(x=>x.json()).catch(()=>null);
          if(!r || !r.ok){ alert('shihuo-diff API 조회 실패'); return; }
          const meta = document.getElementById('shihuo-diff-meta');
          meta.textContent = `활성 batch: ${r.active_batch_id || '없음'} | 차이 ${r.count}건`;
          const metaModal = document.getElementById('shihuoDiffMetaModal');
          metaModal.textContent = `활성 batch: ${r.active_batch_id || '없음'} | 차이 ${r.count}건`;
          const tb = document.querySelector('#shihuoDiffTable tbody');
          tb.innerHTML = '';
          const empty = document.getElementById('shihuo-diff-empty');
          if(r.count === 0){
            empty.style.display = 'block';
            empty.textContent = '차이 없음';
            document.getElementById('shihuoDiffModal').style.display = 'block';
            return;
          }
          empty.style.display = 'none';
          r.items.forEach(it=>{
            const tr = document.createElement('tr');
            // bc_source='manual' + 차이 발생 → ⚠️ 표시 (사용자 명시 입력은 자동 갱신 대상 아님)
            const warn = (it.bc_source === 'manual') ? ' ⚠️' : '';
            tr.innerHTML = `
              <td style="padding:6px; border:1px solid var(--border)">${it.order_id}</td>
              <td style="padding:6px; border:1px solid var(--border)">${it.model}</td>
              <td style="padding:6px; border:1px solid var(--border)">${it.size}</td>
              <td style="padding:6px; border:1px solid var(--border); text-align:right">${it.bc_cny.toFixed(2)}</td>
              <td style="padding:6px; border:1px solid var(--border)">${(it.bc_source||'')}${warn}</td>
              <td style="padding:6px; border:1px solid var(--border); text-align:right">${it.sh_cny.toFixed(2)}</td>
              <td style="padding:6px; border:1px solid var(--border); text-align:right">${it.diff_cny.toFixed(2)}</td>
              <td style="padding:6px; border:1px solid var(--border); text-align:right">${it.diff_pct!=null ? it.diff_pct.toFixed(2)+'%' : '-'}</td>`;
            tb.appendChild(tr);
          });
          document.getElementById('shihuoDiffModal').style.display = 'block';
        }

        // 탭 진입 시 자동으로 메타 갱신 (활성 batch / 차이 건수만)
        async function refreshShihuoDiffMeta(){
          const r = await fetch('/api/bid-cost/shihuo-diff').then(x=>x.json()).catch(()=>null);
          const meta = document.getElementById('shihuo-diff-meta');
          if(!r || !r.ok){ meta.textContent = '활성 batch: 조회 실패'; return; }
          meta.textContent = `활성 batch: ${r.active_batch_id || '없음'} | 차이 ${r.count}건`;
        }
        refreshShihuoDiffMeta();
        </script>
```

> 주의: 위 `<script>`는 `tabs/tab_adjust.html`이 인라인 스크립트 실행을 지원한다는 가정 하에 그대로 둔다. 실행되지 않으면 함수만 `kream_dashboard.html` 글로벌 스코프로 옮기고, 인라인은 마크업만 남긴다.

### 5-4. UI 사양 요약

- 버튼: "차이 보기"
- 표시: 활성 batch_id + 차이 건수 (탭 진입 시 자동 갱신)
- 모달: order_id, model, size, bc_cny, bc_source, sh_cny, diff_cny, diff_pct
- 차이 0건이면 "차이 없음" 메시지
- 차이가 있는데 `bc_source='manual'`인 경우 행에 ⚠️ 표시 (사용자 명시 입력이라 자동 갱신 대상 아님)

### 5-5. 검증

- 가격 자동 조정 탭 진입 → 두 번째 카드로 "식货 ↔ 등록 원가 차이" 표시
- 탭 진입 직후 활성 batch 메타 자동 채워짐 (45건 활성 시 `차이 N건`)
- "차이 보기" 클릭 → 모달 표시, 차이 0건이면 "차이 없음"
- 차이 행 중 `bc_source='manual'`이면 ⚠️ 마크
- 콘솔 에러 0건

---

## Step 6 — 회귀 테스트 시나리오 (sqlite3 직접 SQL)

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

### 6-6. 시나리오 F: auto_rebid 안정 키 검증 (★ v3 옵션 A 단일안 → 필수)

> v2에서는 옵션 A 채택 시 선택 시나리오였으나, v3에서는 옵션 A로 단일 확정되었으므로 **필수 시나리오**로 격상.

```bash
# 같은 (product_id, size)로 두 번 호출돼도 한 행만 유지되는지 SQL로 시뮬
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
git diff kream_server.py tabs/tab_adjust.html   # 변경 내역 확인
# 사용자 OK 시:
git checkout -- kream_server.py tabs/tab_adjust.html

# 4) 서버 재시작 후 검증
python3 kream_server.py > server.log 2>&1 &
sleep 3
sqlite3 price_history.db "SELECT COUNT(*) FROM bid_cost"  # 48 복원 확인
curl -s http://localhost:5001/api/health
```

> v3 변경: 신규 탭 파일을 만들지 않으므로 `rm -f tabs/tab_shihuo.html` 단계 제거. 대신 `tabs/tab_adjust.html`을 git checkout으로 원복.

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
- [ ] 회귀 테스트 6-1 ~ 6-6 모두 통과 (★ v3: 6-6 필수로 격상)
- [ ] 테스트 데이터 정리: `bid_cost`에 `TEST_%` 0건
- [ ] `tabs/tab_adjust.html` 라인 31-33 사이에 차이 보기 카드 + 모달 + 스크립트 삽입 → 가격 자동 조정 탭 진입 시 정상 노출, 콘솔 에러 0건
- [ ] auto_rebid `order_id`가 `f"{product_id}_{size}_rebid"`로 변경됨 (★ v3 확정 1)
- [ ] 백업 파일 보존: `price_history_backup_step16a_pre.db`

---

## 커밋 (체크리스트 통과 후)

```bash
git add kream_server.py tabs/tab_adjust.html \
        작업지시서_10_Step16A_본작업_v3.md 분석보고서_Step16A_v1.md \
        패치지시서_작업지시서10_v3_확정.md
git commit -m "feat: Step 16-A 식货 자동 채택 + cny_source 추적 + activate/deactivate 분리 + 차이 보기 인라인

- bid_cost.cny_source 컬럼 추가 (shihuo|manual|unknown)
- _save_bid_cost: cny_price 없을 시 shihuo_prices(active=1) 매칭으로 자동 채택, 단일 connection
- /api/shihuo/activate, /api/shihuo/deactivate 신설, /api/shihuo/rollback 별칭 유지
- /api/bid-cost/shihuo-diff 리포트 API 신설
- tabs/tab_adjust.html에 식货 차이 보기 카드 + 모달 인라인 추가 (미니멈 UI)
- auto_rebid order_id 안정 키 전환 (timestamp 누적 방지, UPSERT 보존)"
```

---

## 후속 작업 권장 (★ v3 신규 섹션)

본 작업(Phase 2)에서 의도적으로 범위 밖으로 분리한 항목들. 우선순위 순.

### 후속 1. 자동 채택 동작 1주 모니터링 후 dry-run 결과 검토 (필수)

- 본 작업 배포 후 1주간 다음 지표 추적:
  - `cny_source='shihuo'`로 저장된 행 비율 (목표 50% 이상)
  - `cny_source='manual'`로 저장된 행 중 식货 차이가 큰 건수 (`/api/bid-cost/shihuo-diff` 모니터)
  - `_save_bid_cost`가 None 반환한 빈도 (server.log의 `[bid_cost] 스킵` 라인 카운트)
- 1주 후 `/api/bid-cost/shihuo-diff`로 누적 차이를 검토하고, 차이가 큰 manual 입력은 사용자에게 갱신 권고.
- 산출물: 1주 모니터링 보고서 (별도 작업지시서).

### 후속 2. 식货 전용 탭 신설 (`tabs/tab_shihuo.html`)

- 본 작업의 옵션 A로 검토했다가 v3에서 폐기한 풀 UI를 별도 작업으로 분리.
- 화면 구성:
  - 엑셀 업로드 폼 (`/api/shihuo/import`)
  - 활성 배치 정보 (`/api/shihuo/latest`) + activate/deactivate 버튼
  - 차이 보기 (본 작업의 인라인을 신규 탭으로 이전 또는 양쪽 유지)
  - unmapped 목록 (`/api/shihuo/unmapped`) + 매핑 수동 보정 UI
- 사이드바에 "식货 시장가" 메뉴 추가, 라우터에 `shihuo: 'tabs/tab_shihuo.html'` 매핑.
- 본 작업 배포 후 식货 임포트 빈도가 주 1회 이상으로 안정화되면 착수 권장.

### 후속 3. shihuo-diff API v2 (KREAM 입찰가/새 마진 추정 추가)

- 현재 `/api/bid-cost/shihuo-diff`는 cny_price 차이만 반환. 운영 의사결정에는 부족.
- v2 추가 필드:
  - 현재 KREAM 입찰가 (`my_bids_local.json` 합치기)
  - 식货 cny_price를 적용했을 때의 신규 원가/마진 추정
  - 마진 변동분 (현재 vs 식货 적용 시)
- 사용자가 차이 큰 행을 보고 "이 가격으로 일괄 갱신" 결정을 빠르게 할 수 있게 한다.
- 후속 2의 식货 탭과 함께 묶어 발주 권장.

### 후속 4. auto_rebid 이력 보존용 `rebid_history` 테이블 (옵션, 운영 판단)

- v3에서 옵션 B로 폐기한 별도 이력 테이블.
- 자동 재입찰 빈도가 모델/사이즈당 주 5회 이상으로 늘어나면, 어떤 이력이 있는지 추적할 수 없어 운영 분석에 한계가 생김 → 그 시점에 신설.
- 스키마:
  ```sql
  CREATE TABLE rebid_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    product_id TEXT, model TEXT, size TEXT,
    cny_price REAL, exchange_rate REAL, overseas_shipping INTEGER,
    bid_price INTEGER, sale_price INTEGER,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );
  ```
- 본 작업의 `bid_cost` 안정 키(UPSERT)와 병행 — `bid_cost`는 현재 상태, `rebid_history`는 누적 이력.
- 발주 트리거: 후속 1의 1주 모니터링에서 자동 재입찰 빈도가 위 임계를 넘는 경우.

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

## 부록 B — v2 → v3 변경 요약

| # | 종류 | 항목 | v2 → v3 변경 |
|---|---|---|---|
| 1 | 확정 | Step 2-2-d auto_rebid order_id | 옵션 A/B 분기 → **옵션 A 단일 확정** (`f"{product_id}_{size}_rebid"`) |
| 2 | 확정 | Step 5 UI 위치 | 옵션 A(신규 탭)/B(인라인) 분기 → **옵션 B 단일 확정** (`tab_adjust.html` 라인 31-33 사이 인라인) |
| 3 | 신규 | 후속 작업 권장 섹션 | 1주 모니터링 / 식货 전용 탭 / shihuo-diff v2 / rebid_history 4건 명시 |
| 4 | 부수 | Step 6-6 시나리오 | 옵션 A 단일 확정으로 인해 선택 → **필수**로 격상 |
| 5 | 부수 | Step 7-2 롤백 절차 | `tabs/tab_shihuo.html` 신규 파일 제거 단계 → `tabs/tab_adjust.html` git checkout으로 단순화 |
| 6 | 부수 | 커밋 메시지/체크리스트 | 신규 탭 항목 제거, tab_adjust.html 인라인 항목으로 교체 |

## 부록 C — v1 → v2 변경 요약 (참고)

| # | 종류 | 항목 | v1 → v2 변경 |
|---|---|---|---|
| 1 | 치명 | imported_at 컬럼 검증 | 사전-1 결과 실재 확인 → v1 그대로 유지 |
| 2 | 치명 | Step 6 회귀 테스트 방식 | `from kream_server import _save_bid_cost` 폐기 → sqlite3 직접 SQL (A안) |
| 3 | 치명 | auto_rebid order_id 패턴 | `..._rebid_{timestamp}` → `..._rebid` (옵션 A 안정 키, UPSERT 보존) |
| 4 | 치명 | Step 7-3 DROP COLUMN 안내 | SQLite 3.51 확인 → v1 그대로 유지 |
| 5 | 보강 | _save_bid_cost connection 통합 | 두 connection → 단일 connection |
| 6 | 보강 | Step 5 UI 위치 | "기존 UI 옆에 추가" → "신규 탭 신설" (식货 UI 미존재 확인) |
| 7 | 보강 | Step 1 마이그레이션 트랜잭션 | ALTER+UPDATE를 BEGIN/COMMIT으로 명시 묶음 |
