# 작업지시서 10 — Step 16-A 본 작업 (Phase 2)

목적: bid_cost UPSERT 시 shihuo 활성 배치로부터 cny_price 자동 채택 + cny_source 추적 + 리포트 API + shihuo activate/deactivate 분리.

선결: **`분석보고서_Step16A_v1.md` 검토 완료 후 진행.**

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
   - `bid_cost.size` (TEXT, mm 단위 문자열 또는 `'ONE SIZE'`)
   - `bid_cost.cny_price` (REAL)
   - 매칭 시 `CAST(bid_cost.size AS INTEGER) = shihuo_prices.kream_mm` 필수.
7. **테스트는 `TEST_` 접두사 order_id로만**. 끝나면 `DELETE FROM bid_cost WHERE order_id LIKE 'TEST_%'`.

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

기존 함수 끝에 **idempotent 컬럼 추가** 블록을 덧붙임:

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

    # ── Step 16-A: cny_source 컬럼 추가 (idempotent) ──
    cols = [r[1] for r in c.execute("PRAGMA table_info(bid_cost)").fetchall()]
    if "cny_source" not in cols:
        c.execute("ALTER TABLE bid_cost ADD COLUMN cny_source TEXT")
        c.execute("UPDATE bid_cost SET cny_source='unknown' WHERE cny_source IS NULL")

    conn.commit()
    conn.close()
```

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

### 2-1. 함수 시그니처 변경 (kream_server.py:282-301)

```python
def _save_bid_cost(order_id, model, size, cny_price, exchange_rate,
                   overseas_shipping=8000, other_costs=0,
                   cny_source=None):
    """입찰 시점의 원가 저장 (UPSERT by order_id).

    cny_price가 None/0이면 shihuo_prices(active=1) 매칭으로 자동 채택 시도.
    매칭 키: model 정확 일치 + CAST(size AS INTEGER) = kream_mm.
    매칭 실패 시 저장 스킵.
    """
    if not order_id:
        return None

    resolved_cny = float(cny_price) if cny_price and float(cny_price) > 0 else None
    resolved_source = cny_source

    # manual 명시 입력이 우선 (이미 resolved_cny 있음)
    if resolved_cny is not None:
        if not resolved_source:
            resolved_source = "manual"
    else:
        # shihuo 자동 채택 시도
        try:
            size_int = int(str(size).strip())
        except (ValueError, TypeError):
            size_int = None

        if model and size_int is not None:
            with sqlite3.connect(str(PRICE_DB)) as _c:
                row = _c.execute(
                    """SELECT cny_price FROM shihuo_prices
                       WHERE active=1 AND model=? AND kream_mm=?
                       ORDER BY imported_at DESC LIMIT 1""",
                    (model, size_int)
                ).fetchone()
            if row and row[0]:
                resolved_cny = float(row[0])
                resolved_source = "shihuo"

    if resolved_cny is None:
        # 매칭 실패 + manual 없음 → 저장 스킵 (기존 동작 유지)
        print(f"[bid_cost] 스킵: order_id={order_id} model={model} size={size} — cny_price 없음 + 식货 매칭 실패")
        return None

    if not resolved_source:
        resolved_source = "unknown"

    rate_f = float(exchange_rate) if exchange_rate else 0.0

    conn = sqlite3.connect(str(PRICE_DB))
    conn.execute(
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
    conn.close()
    return {"cny_price": resolved_cny, "cny_source": resolved_source}
```

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

#### 2-2-d. 라인 7206-7227 부근 (auto_rebid)

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
            order_id=f"{product_id}_{size}_rebid_{int(time.time())}",
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

## Step 5 — 대시보드 UI (식货 탭에 "차이 보기" 버튼)

### 5-1. 호스팅 위치 우선 확인

```bash
grep -rn "/api/shihuo/import\|/api/shihuo/latest" kream_dashboard.html tabs/ | head -10
```

→ 식货 임포트 UI가 어느 파일에 있는지 확인 후 그 위치에 버튼/모달 추가.
(현재 분석 시점에서 tabs/ 중 식货 전용 파일은 없음. `kream_dashboard.html` 내부에 인라인일 가능성 높음 — 임포트 API 호출 코드 위치 기준으로 결정.)

### 5-2. 추가할 UI

- **버튼**: "식货 ↔ 등록 원가 차이 보기" (식货 임포트 결과 표시 영역 근처)
- **모달**: 차이 항목 테이블 (order_id, model, size, bc_cny, bc_source, sh_cny, diff_cny, diff_pct)
- **API 호출**: `fetch('/api/shihuo/shihuo-diff' /* 정확히 /api/bid-cost/shihuo-diff */)`

```html
<button onclick="loadShihuoDiff()">식货 ↔ 등록 원가 차이 보기</button>

<div id="shihuoDiffModal" class="modal" style="display:none">
  <div class="modal-content">
    <h3>식货 활성 배치 vs bid_cost 가격 차이</h3>
    <div id="shihuoDiffMeta"></div>
    <table id="shihuoDiffTable">
      <thead><tr>
        <th>order_id</th><th>model</th><th>size</th>
        <th>등록 CNY</th><th>source</th>
        <th>식货 CNY</th><th>차이 CNY</th><th>차이 %</th>
      </tr></thead>
      <tbody></tbody>
    </table>
    <button onclick="document.getElementById('shihuoDiffModal').style.display='none'">닫기</button>
  </div>
</div>

<script>
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
</script>
```

### 5-3. 검증

- 브라우저에서 식货 탭 진입 → "차이 보기" 클릭 → 모달 정상 표시
- 콘솔 에러 없음
- 활성 배치 없을 때 `active_batch_id: null` + `count: 0` 정상

---

## Step 6 — 회귀 테스트 시나리오

### 6-1. 시나리오 A: 식货에 있는 모델 — 자동 채택 확인

```bash
# 1) 식货 active 배치에 존재하는 (model, kream_mm) 확인
sqlite3 -header price_history.db "SELECT model, kream_mm FROM shihuo_prices WHERE active=1 AND kream_mm IS NOT NULL LIMIT 3"
# 예: JQ1501, 265

# 2) 가상 bid_cost 추가 (cny_price 미지정 → shihuo 자동 채택 기대)
curl -s -X POST http://localhost:5001/api/bid-cost/upsert \
  -H "Content-Type: application/json" \
  -d '{"order_id":"TEST_AUTO_001","model":"JQ1501","size":"265","cny_price":0}' | head -c 200
# 기대: api_bid_cost_upsert는 cny_price>0 검증으로 400. (이 API는 manual 전용)

# 3) 자동 채택은 _save_bid_cost를 직접 호출하는 자동 입찰 경로에서만 발생.
#    Python REPL로 검증:
python3 - <<'PY'
from kream_server import _save_bid_cost
r = _save_bid_cost(order_id="TEST_AUTO_001", model="JQ1501", size="265",
                   cny_price=None, exchange_rate=215.0)
print(r)  # 기대: {"cny_price": <식货 가격>, "cny_source": "shihuo"}
PY

# 4) DB 확인
sqlite3 -header price_history.db "SELECT order_id, cny_price, cny_source FROM bid_cost WHERE order_id='TEST_AUTO_001'"
```

### 6-2. 시나리오 B: 식货에 없는 모델 — manual fallback

```bash
python3 - <<'PY'
from kream_server import _save_bid_cost
# manual 입력
r1 = _save_bid_cost(order_id="TEST_MANUAL_001", model="ZZZ_NOT_EXIST", size="270",
                    cny_price=500.0, exchange_rate=215.0, cny_source="manual")
print("manual:", r1)
# manual 없음 + 식货 매칭 실패
r2 = _save_bid_cost(order_id="TEST_NONE_001", model="ZZZ_NOT_EXIST", size="270",
                    cny_price=None, exchange_rate=215.0)
print("none:", r2)  # 기대: None (스킵)
PY

sqlite3 -header price_history.db "SELECT order_id, cny_price, cny_source FROM bid_cost WHERE order_id LIKE 'TEST_%'"
# 기대: TEST_MANUAL_001만 존재, TEST_NONE_001은 없음
```

### 6-3. 시나리오 C: shihuo-diff API 응답 구조 검증

```bash
# 매칭은 되지만 가격이 다른 케이스 만들기
python3 - <<'PY'
from kream_server import _save_bid_cost
# 식货 활성 배치에 있는 (model, kream_mm) 사용 + 다른 cny_price를 manual로 박음
_save_bid_cost(order_id="TEST_DIFF_001", model="JQ1501", size="265",
               cny_price=999.0, exchange_rate=215.0, cny_source="manual")
PY

curl -s http://localhost:5001/api/bid-cost/shihuo-diff | python3 -m json.tool
# 기대: items 배열에 TEST_DIFF_001 포함, bc_cny=999.0, sh_cny=<식货 값>, diff_cny<0
```

### 6-4. 시나리오 D: ONE SIZE 처리

```bash
python3 - <<'PY'
from kream_server import _save_bid_cost
r = _save_bid_cost(order_id="TEST_ONE_001", model="IX7694", size="ONE SIZE",
                   cny_price=None, exchange_rate=215.0)
print(r)  # 기대: None (CAST('ONE SIZE') 매칭 0 + manual 없음 → 스킵)
PY
```

### 6-5. 시나리오 E: shihuo activate/deactivate

```bash
curl -s -X POST http://localhost:5001/api/shihuo/deactivate
sqlite3 price_history.db "SELECT SUM(active) FROM shihuo_prices"  # 기대: 0
# 자동 채택이 매칭 0건이 되는지 확인
python3 -c "from kream_server import _save_bid_cost; print(_save_bid_cost('TEST_NOACT_001','JQ1501','265', None, 215.0))"
# 기대: None (active 없음 → 매칭 실패)

# 다시 활성화
curl -s -X POST http://localhost:5001/api/shihuo/activate/shihuo_20260501_121000
sqlite3 price_history.db "SELECT SUM(active) FROM shihuo_prices WHERE batch_id='shihuo_20260501_121000'"
```

### 6-6. 테스트 정리 (필수)

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
git status                                   # 변경 파일 확인
git diff kream_server.py kream_dashboard.html # 변경 내역 확인
# 사용자 OK 시:
git checkout -- kream_server.py kream_dashboard.html

# 4) 서버 재시작 후 검증
python3 kream_server.py > server.log 2>&1 &
sleep 3
sqlite3 price_history.db "SELECT COUNT(*) FROM bid_cost"  # 48 복원 확인
curl -s http://localhost:5001/api/health
```

### 7-3. cny_source 컬럼 단독 롤백 (코드만 원복하고 컬럼은 유지하고 싶을 때)

- SQLite는 `DROP COLUMN`이 3.35+에서 지원됨. 안전하게 `ALTER TABLE bid_cost DROP COLUMN cny_source` 사용 가능.
- 단, 이미 운영 중이면 컬럼은 그대로 두고 값만 NULL 처리: `UPDATE bid_cost SET cny_source=NULL`.
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
- [ ] 회귀 테스트 6-1 ~ 6-5 모두 통과
- [ ] 테스트 데이터 정리: `bid_cost`에 `TEST_%` 0건
- [ ] 브라우저 콘솔 에러 0건
- [ ] 백업 파일 보존: `price_history_backup_step16a_pre.db`

---

## 커밋 (체크리스트 통과 후)

```bash
git add kream_server.py kream_dashboard.html 작업지시서_10_Step16A_본작업.md 분석보고서_Step16A_v1.md
git commit -m "feat: Step 16-A 식货 자동 채택 + cny_source 추적 + activate/deactivate 분리

- bid_cost.cny_source 컬럼 추가 (shihuo|manual|unknown)
- _save_bid_cost: cny_price 없을 시 shihuo_prices(active=1) 매칭으로 자동 채택
- /api/shihuo/activate, /api/shihuo/deactivate 신설, /api/shihuo/rollback 별칭 유지
- /api/bid-cost/shihuo-diff 리포트 API 신설
- 식货 탭 '차이 보기' 모달 추가"
```

---

## 부록 — 실제 컬럼명 빠른 참조

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
| shihuo_prices | batch_id | TEXT NOT NULL |  |
| shihuo_prices | active | INTEGER DEFAULT 1 |  |
| shihuo_prices | model | TEXT NOT NULL |  |
| shihuo_prices | **size_eu** | TEXT | (eu_size 아님!) |
| shihuo_prices | size_normalized | TEXT |  |
| shihuo_prices | **kream_mm** | INTEGER | bid_cost.size CAST 매칭 대상 |
| shihuo_prices | cny_price | REAL NOT NULL |  |
| shihuo_prices | mapping_status | TEXT |  |
| shihuo_prices | imported_at | DATETIME |  |
