# 작업지시서 — Step 12: 사이즈 변환 시스템 (브랜드별 사이즈표 DB + 변환 함수)

작성일: 2026-04-30
대상 시스템: KREAM 자동화 (`~/Desktop/kream_automation/`)
선행 작업: 없음 (Step 11과 병렬 가능)
관련 문서:
- `KREAM_허브넷통합_인수인계_v5.md`
- `ADIDAS_사이즈표-new.xlsx` (이 작업지시서와 함께 제공된 사이즈표)
예상 소요: 2~3시간 (테이블 신설 + 변환 함수 + 테스트)
다음 단계: Step 13 (识货 시장가 임포트), Step 14 (협력사 약속가), Step 15 (원가 자동 매칭)

---

## 0. 작업 목적

브랜드별 사이즈 변환표를 DB에 저장하고, **EU/US/UK/CM 사이즈를 KREAM mm 사이즈로 변환하는 표준 함수**를 구축한다.
이 함수는 Step 13(识货 임포트), Step 14(협력사 약속가), Step 15(원가 매칭)에서 공통으로 호출되는 핵심 인프라다.

**Step 12는 인프라만 구축**한다. 실제 가격 데이터 임포트나 원가 매칭은 Step 13 이후에 진행.

---

## 1. 핵심 원칙 — 절대 위반 금지

### 1.1 변환 정확성이 최우선
- 변환 실패 시 반드시 `None` 반환. **추측값 금지** (CLAUDE.md 절대 규칙: 가짜 값 사용 금지)
- 변환 정책 모호한 케이스는 None + 로그 기록 → 사용자가 검토

### 1.2 DB 우선 설계
- 사이즈표는 **반드시 DB**에 저장. 코드에 하드코딩 금지
- 사용자가 추후 사이즈표를 추가/수정 가능해야 함 (브랜드별, 성별별, 카테고리별)

### 1.3 변환 함수는 순수 함수
- 입력: `(brand, model, size_str, model_sizes_set)` → 출력: `kream_size_mm` 또는 `None`
- 외부 상태 변경 없음. 입력 같으면 출력 같음
- 변환 사유 로깅은 별도 함수로 분리

### 1.4 sales_history 영향 금지
- 기존 `sales_history`, `bid_cost`, `price_adjustments` 테이블 **무수정**
- 새 테이블만 추가

---

## 2. 변경 사항 — 새 테이블 2개 + 새 모듈 1개

### 2.1 DB 테이블 신설

#### `size_charts` — 브랜드별 사이즈 변환표
```sql
CREATE TABLE IF NOT EXISTS size_charts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    chart_name TEXT NOT NULL,           -- 'ADIDAS_M_1' 같은 식별자
    brand TEXT NOT NULL,                -- 'ADIDAS', 'NIKE', ...
    gender TEXT NOT NULL,               -- 'M', 'F', 'U'(unisex)
    category TEXT NOT NULL DEFAULT 'shoes',  -- 'shoes', 'sandals', 'apparel'
    purchase_country TEXT DEFAULT 'ALL',     -- 'ALL', 'KR', 'JP', 'CN'
    eu_size TEXT NOT NULL,              -- '36', '36.5', '38' (문자열, 분수도 가능)
    us_size TEXT,
    uk_size TEXT,
    kream_mm INTEGER NOT NULL,          -- 215, 220, 225, ... (KREAM 표시 단위)
    notes TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(brand, gender, category, eu_size, purchase_country)
);

CREATE INDEX idx_size_charts_brand ON size_charts(brand, gender, category);
CREATE INDEX idx_size_charts_eu ON size_charts(eu_size);
```

#### `size_conversion_log` — 변환 사유 로그 (선택, 디버깅용)
```sql
CREATE TABLE IF NOT EXISTS size_conversion_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    brand TEXT NOT NULL,
    model TEXT,
    raw_size TEXT NOT NULL,           -- 입력값 ('38⅔')
    normalized_size TEXT,             -- 정규화된 값 ('38' 또는 None)
    kream_mm INTEGER,                 -- 최종 매핑 결과 또는 NULL
    rule_applied TEXT,                -- 'direct_match' / 'fraction_to_int' / 'excluded_dup' / 'no_match'
    decision_notes TEXT,
    logged_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_size_log_brand_model ON size_conversion_log(brand, model);
```

### 2.2 새 모듈: `size_converter.py`

이 모듈이 변환 로직의 단일 진입점.

```python
# size_converter.py — 사이즈 변환 시스템
"""
사이즈 변환 핵심 로직.

흐름:
1. normalize_size(): '38⅔' 같은 분수 사이즈 → '38' 또는 None
2. convert_to_kream_mm(): 정규화된 EU 사이즈 → KREAM mm

사용 예:
    from size_converter import convert_to_kream_mm
    mm = convert_to_kream_mm('ADIDAS', 'M', 'shoes', 'JQ4110', '38⅔', model_sizes={'36','37','38','38⅔'})
    # → None (38이 같은 모델에 있으니 38⅔ 제외)
"""
import re
import sqlite3
from pathlib import Path

DB_PATH = Path(__file__).parent / 'price_history.db'

# 분수 사이즈 패턴 (유니코드 분수 + 1/3, 2/3 표기)
FRACTION_PATTERNS = {
    '⅓': '.333',
    '⅔': '.667',
    '½': '.5',
}
# 1/3, 2/3 표기도 허용
FRACTION_REGEX = re.compile(r'(\d+)\s*[⅓⅔½]|(\d+)\s*(\d+)/(\d+)')


def is_fraction_size(size_str: str) -> bool:
    """⅓·⅔·½ 또는 1/3, 2/3 같은 분수 표기인지 판별. 0.5는 분수 아님(소수)."""
    if size_str is None:
        return False
    s = str(size_str).strip()
    if any(c in s for c in '⅓⅔½'):
        return True
    if re.search(r'\d+\s*/\s*\d+', s):
        return True
    return False


def normalize_size(size_str: str, model_sizes_set: set) -> tuple[str | None, str]:
    """
    분수 사이즈 처리 룰:
    - 정수+0.5 단위는 그대로 (35.5는 분수가 아니라 0.5 단위)
    - ⅓·⅔ 분수: 같은 모델에 정수 EU 있으면 제외, 없으면 정수로 치환

    Returns: (정규화된_사이즈, 적용된_룰명)
    """
    if size_str is None or str(size_str).strip() == '':
        return None, 'empty_input'

    s = str(size_str).strip()

    # 분수 아니면 그대로 통과
    if not is_fraction_size(s):
        return s, 'direct_match'

    # 분수: 베이스 정수 추출
    m = re.match(r'(\d+)', s)
    if not m:
        return None, 'parse_failed'
    base = m.group(1)  # '38⅔' → '38'

    # 같은 모델에 정수 EU가 있으면 → 제외
    if base in model_sizes_set:
        return None, 'excluded_int_exists'

    # 정수도 .5도 없으면 → 정수로 치환 (사용자 정책)
    return base, 'fraction_to_int'


def convert_to_kream_mm(brand: str, gender: str, category: str,
                        model: str, size_str: str,
                        model_sizes_set: set,
                        purchase_country: str = 'ALL',
                        log: bool = True) -> int | None:
    """
    EU 사이즈 → KREAM mm 변환.

    매개변수:
        brand: 'ADIDAS' (대문자 정규화)
        gender: 'M', 'F', 'U'
        category: 'shoes', 'sandals', 'apparel'
        model: 'JQ4110' (로깅용)
        size_str: '38', '36.5', '37⅓' 등
        model_sizes_set: 같은 모델 안의 모든 사이즈 집합 (분수 제외 판단용)

    반환: KREAM mm (정수) 또는 None (변환 실패)
    """
    brand_upper = brand.upper()

    # 1. 정규화
    normalized, rule = normalize_size(size_str, model_sizes_set)
    result_mm = None

    if normalized is not None:
        # 2. DB 조회
        with sqlite3.connect(DB_PATH) as conn:
            c = conn.cursor()
            c.execute("""
                SELECT kream_mm FROM size_charts
                WHERE brand=? AND gender=? AND category=? AND eu_size=?
                  AND purchase_country IN (?, 'ALL')
                ORDER BY CASE purchase_country WHEN ? THEN 0 ELSE 1 END
                LIMIT 1
            """, (brand_upper, gender, category, normalized,
                  purchase_country, purchase_country))
            row = c.fetchone()
            if row:
                result_mm = row[0]
                final_rule = rule
            else:
                final_rule = f'{rule}_no_chart_match'
    else:
        final_rule = rule

    # 3. 로그
    if log:
        try:
            with sqlite3.connect(DB_PATH) as conn:
                conn.execute("""
                    INSERT INTO size_conversion_log
                    (brand, model, raw_size, normalized_size, kream_mm, rule_applied)
                    VALUES (?, ?, ?, ?, ?, ?)
                """, (brand_upper, model, str(size_str), normalized, result_mm, final_rule))
                conn.commit()
        except Exception:
            pass  # 로그 실패는 변환 실패 아님 (격리)

    return result_mm


def import_size_chart_from_xlsx(xlsx_path: str, dry_run: bool = False) -> dict:
    """
    엑셀 파일에서 size_charts 테이블로 임포트.

    엑셀 컬럼 (필수):
        차트명 / 브랜드 / 성별 / 매입국가 / EU / US / UK / CM / 비고

    중복은 UNIQUE 제약으로 차단되므로, 이미 있으면 INSERT OR IGNORE 후 update_count 0.
    """
    from openpyxl import load_workbook

    wb = load_workbook(xlsx_path, read_only=True, data_only=True)
    ws = wb.active
    rows = list(ws.iter_rows(values_only=True))
    if len(rows) < 2:
        return {'ok': False, 'error': '데이터 없음'}

    # 헤더 검증
    expected = ['차트명', '브랜드', '성별', '매입국가', 'EU', 'US', 'UK', 'CM']
    header = [str(c).strip() if c else '' for c in rows[0][:8]]
    if header[:8] != expected:
        return {'ok': False, 'error': f'헤더 불일치: {header}'}

    inserted, skipped, failed = 0, 0, 0
    errors = []

    for i, row in enumerate(rows[1:], start=2):
        if row[0] is None:  # 빈 행
            continue
        try:
            chart_name = str(row[0]).strip()
            brand = str(row[1]).strip().upper()
            gender = str(row[2]).strip().upper()  # M/F/U
            country = str(row[3]).strip().upper() if row[3] else 'ALL'
            eu_size = str(row[4]).strip()
            us_size = str(row[5]).strip() if row[5] else None
            uk_size = str(row[6]).strip() if row[6] else None
            kream_mm = int(str(row[7]).strip())
            notes = str(row[8]).strip() if len(row) > 8 and row[8] else None

            # 카테고리는 차트명으로 추정 (기본 shoes)
            category = 'shoes'
            if 'SANDAL' in chart_name.upper() or 'SANDAL' in (notes or '').upper():
                category = 'sandals'
            elif 'APPAREL' in chart_name.upper() or 'CLOTHING' in chart_name.upper():
                category = 'apparel'

            if dry_run:
                inserted += 1
                continue

            with sqlite3.connect(DB_PATH) as conn:
                cur = conn.execute("""
                    INSERT OR IGNORE INTO size_charts
                    (chart_name, brand, gender, category, purchase_country,
                     eu_size, us_size, uk_size, kream_mm, notes)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, (chart_name, brand, gender, category, country,
                      eu_size, us_size, uk_size, kream_mm, notes))
                if cur.rowcount > 0:
                    inserted += 1
                else:
                    skipped += 1
                conn.commit()
        except Exception as e:
            failed += 1
            errors.append(f'행 {i}: {e}')

    return {
        'ok': True,
        'inserted': inserted,
        'skipped': skipped,
        'failed': failed,
        'errors': errors[:10],  # 처음 10개만
    }
```

### 2.3 새 API 엔드포인트 (kream_server.py)

```python
@app.route("/api/size-charts/import", methods=["POST"])
def api_size_charts_import():
    """엑셀 업로드 → size_charts 임포트."""
    if 'file' not in request.files:
        return jsonify({'ok': False, 'error': 'file 필드 없음'}), 400
    f = request.files['file']
    tmp_path = Path(__file__).parent / f'_tmp_size_chart_{int(time.time())}.xlsx'
    try:
        f.save(tmp_path)
        from size_converter import import_size_chart_from_xlsx
        result = import_size_chart_from_xlsx(str(tmp_path))
        return jsonify(result)
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500
    finally:
        if tmp_path.exists():
            tmp_path.unlink()


@app.route("/api/size-charts/list")
def api_size_charts_list():
    """저장된 사이즈표 목록 (그룹화)."""
    with sqlite3.connect(DB_FILE) as conn:
        rows = conn.execute("""
            SELECT brand, gender, category, COUNT(*) AS size_count,
                   MIN(kream_mm) AS min_mm, MAX(kream_mm) AS max_mm
            FROM size_charts
            GROUP BY brand, gender, category
            ORDER BY brand, gender, category
        """).fetchall()
    return jsonify({
        'ok': True,
        'charts': [
            {'brand': r[0], 'gender': r[1], 'category': r[2],
             'size_count': r[3], 'min_mm': r[4], 'max_mm': r[5]}
            for r in rows
        ]
    })


@app.route("/api/size-charts/test", methods=["POST"])
def api_size_charts_test():
    """변환 테스트 (디버깅용). body={brand, gender, category, model, size, model_sizes:[...]}"""
    data = request.get_json() or {}
    from size_converter import convert_to_kream_mm
    mm = convert_to_kream_mm(
        brand=data.get('brand', 'ADIDAS'),
        gender=data.get('gender', 'M'),
        category=data.get('category', 'shoes'),
        model=data.get('model', 'TEST'),
        size_str=data.get('size', ''),
        model_sizes_set=set(data.get('model_sizes', [])),
        purchase_country=data.get('purchase_country', 'ALL'),
        log=False,  # 테스트는 로그 안 남김
    )
    return jsonify({'ok': True, 'kream_mm': mm})
```

---

## 3. 구현 순서

1. **사전 백업** (작업지시서 §4와 동일 패턴)
2. **DB 마이그레이션**: `size_charts` + `size_conversion_log` 테이블 생성
3. **size_converter.py 모듈 작성**: §2.2 코드 그대로
4. **API 엔드포인트 추가**: kream_server.py에 §2.3 라우트 3개
5. **adidas 사이즈표 임포트**: 사용자가 제공한 `ADIDAS_사이즈표-new.xlsx` 임포트
6. **검증 시나리오 5종 실행**
7. **서버 재시작**: nohup + disown 패턴
8. **/api/health 정상 확인**
9. **최종 보고**

---

## 4. 검증 시나리오 5종

### 시나리오 1: DB 마이그레이션 검증
```bash
sqlite3 price_history.db ".schema size_charts"
sqlite3 price_history.db ".schema size_conversion_log"
# → 두 테이블 모두 존재. 인덱스도 존재.
```

### 시나리오 2: adidas 사이즈표 임포트
```bash
curl -X POST http://localhost:5001/api/size-charts/import \
  -F "file=@ADIDAS_사이즈표-new.xlsx" | python3 -m json.tool
# → {"ok":true, "inserted":20, "skipped":0, "failed":0}

sqlite3 price_history.db \
  "SELECT brand, gender, category, COUNT(*) FROM size_charts GROUP BY brand, gender, category"
# → ADIDAS|M|shoes|20

# 중복 임포트 (재실행) → skipped:20이 되어야 함
curl -X POST http://localhost:5001/api/size-charts/import \
  -F "file=@ADIDAS_사이즈표-new.xlsx" | python3 -m json.tool
# → {"ok":true, "inserted":0, "skipped":20, "failed":0}
```

### 시나리오 3: 직접 매칭 (정수/0.5 단위)
```bash
curl -X POST http://localhost:5001/api/size-charts/test \
  -H "Content-Type: application/json" \
  -d '{"brand":"ADIDAS","gender":"M","model":"TEST","size":"38","model_sizes":["38"]}' | python3 -m json.tool
# → {"ok":true, "kream_mm":235}

curl -X POST http://localhost:5001/api/size-charts/test \
  -H "Content-Type: application/json" \
  -d '{"brand":"ADIDAS","gender":"M","model":"TEST","size":"38.5","model_sizes":["38","38.5"]}' | python3 -m json.tool
# → {"ok":true, "kream_mm":240}

curl -X POST http://localhost:5001/api/size-charts/test \
  -H "Content-Type: application/json" \
  -d '{"brand":"ADIDAS","gender":"M","model":"TEST","size":"35.5","model_sizes":["35.5","36"]}' | python3 -m json.tool
# → {"ok":true, "kream_mm":215}
```

### 시나리오 4 ⭐: 분수 처리 (정책 검증)
**4-1**: 정수 EU가 같은 모델에 있으면 제외
```bash
curl -X POST http://localhost:5001/api/size-charts/test \
  -H "Content-Type: application/json" \
  -d '{"brand":"ADIDAS","gender":"M","model":"JQ4110","size":"38⅔","model_sizes":["36","37","38","38⅔"]}' | python3 -m json.tool
# → {"ok":true, "kream_mm":null}
# 사유: 38이 같은 모델에 있으니 38⅔는 별개 사이즈로 판단, 제외
```

**4-2**: 정수 EU가 같은 모델에 없으면 정수로 치환
```bash
curl -X POST http://localhost:5001/api/size-charts/test \
  -H "Content-Type: application/json" \
  -d '{"brand":"ADIDAS","gender":"M","model":"JQ4110","size":"37⅓","model_sizes":["36","38","37⅓"]}' | python3 -m json.tool
# → {"ok":true, "kream_mm":230}
# 사유: 37이 같은 모델에 없으니 37로 치환 → 230mm
```

**4-3**: 1/3 표기 (유니코드 ⅓ 대신 1/3)
```bash
curl -X POST http://localhost:5001/api/size-charts/test \
  -H "Content-Type: application/json" \
  -d '{"brand":"ADIDAS","gender":"M","model":"JQ4110","size":"39 1/3","model_sizes":["38","40","39 1/3"]}' | python3 -m json.tool
# → {"ok":true, "kream_mm":245}
# 사유: 39 없으니 39로 치환
```

### 시나리오 5: 매칭 실패 케이스 (격리 검증)
```bash
# 사이즈표에 없는 EU
curl -X POST http://localhost:5001/api/size-charts/test \
  -H "Content-Type: application/json" \
  -d '{"brand":"ADIDAS","gender":"M","model":"TEST","size":"50","model_sizes":["50"]}' | python3 -m json.tool
# → {"ok":true, "kream_mm":null}

# 빈 사이즈
curl -X POST http://localhost:5001/api/size-charts/test \
  -H "Content-Type: application/json" \
  -d '{"brand":"ADIDAS","gender":"M","model":"TEST","size":"","model_sizes":[]}' | python3 -m json.tool
# → {"ok":true, "kream_mm":null}

# 알 수 없는 브랜드
curl -X POST http://localhost:5001/api/size-charts/test \
  -H "Content-Type: application/json" \
  -d '{"brand":"UNKNOWN","gender":"M","model":"TEST","size":"40","model_sizes":["40"]}' | python3 -m json.tool
# → {"ok":true, "kream_mm":null}

# size_conversion_log 확인
sqlite3 price_history.db \
  "SELECT brand, raw_size, normalized_size, kream_mm, rule_applied
   FROM size_conversion_log ORDER BY id DESC LIMIT 10"
```

---

## 5. 합격 기준

| # | 기준 | 통과 조건 |
|---|---|---|
| 1 | DB 마이그레이션 | size_charts + size_conversion_log 테이블 존재, 인덱스 4개 |
| 2 | adidas 임포트 | inserted=20, failed=0 |
| 3 | 중복 임포트 | skipped=20, failed=0 (UNIQUE 제약 동작) |
| 4 | 정수/0.5 매칭 | EU 38=235, 38.5=240, 35.5=215 정확 |
| 5 | 분수 제외 | 38⅔ + 38 동시 → null |
| 6 | 분수 치환 | 37⅓ + 37 없음 → 230mm |
| 7 | 매칭 실패 격리 | None 반환, 예외 없음 |
| 8 | py_compile | kream_server.py + size_converter.py 통과 |
| 9 | 라우트 충돌 | 변경 후 라우트 수 = 변경 전 + 3 |
| 10 | /api/health | status=healthy 유지 |

---

## 6. 절대 규칙

- ⚠️ 변환 실패 시 None 반환 (절대 가짜 값 금지)
- ⚠️ 사이즈표 코드 하드코딩 금지 (DB만 사용)
- ⚠️ 기존 테이블 무수정 (sales_history, bid_cost, price_adjustments)
- ⚠️ size_charts UNIQUE 제약 유지 (중복 방지)
- ⚠️ size_converter.py는 순수 함수 유지
- ⚠️ kream_hubnet_bot.py 무수정
- ⚠️ git push -f, git reset --hard 금지

---

## 7. 보고 형식

```markdown
## Step 12 완료 보고

### 변경 파일 + 라인 번호
- price_history.db: 새 테이블 2개 (size_charts, size_conversion_log)
- size_converter.py: 신규 모듈, NN줄
- kream_server.py: API 라우트 3개 추가, 라인 NNNN~NNNN

### 시나리오 5종 결과
| 시나리오 | 결과 | 핵심 발견 |
|---|---|---|
| 1 마이그레이션 | ✅/❌ | 테이블 N개 |
| 2 adidas 임포트 | ✅/❌ | inserted=20 |
| 3 중복 차단 | ✅/❌ | skipped=20 |
| 4 직접 매칭 | ✅/❌ | 5건 모두 정확 |
| 4 분수 처리 | ✅/❌ | 정책 4-1, 4-2, 4-3 모두 통과 |
| 5 매칭 실패 | ✅/❌ | None 반환, 예외 없음 |

### 합격 기준
| # | 기준 | 결과 |
|---|---|---|
| ... | ... | ✅/❌ |

### git diff --stat
...

### 다음 단계
Step 13 (识货 시장가 임포트) 진행 가능.
```

---

## 8. 다음 단계

Step 12 완료 후 즉시 Step 13 가능:
- Step 13: 识货 엑셀 임포트 (size_converter 호출하여 model+size → kream_mm 매핑)
- Step 14: 협력사 약속가 수동 등록 시스템
- Step 15: 원가 자동 매칭 (1순위 협력사, 2순위 识货, MIN(둘))

여성용 사이즈표, 샌들 사이즈표, 기타 브랜드 사이즈표는 같은 임포트 API로 추가 가능 (size_charts 테이블이 brand+gender+category로 구분).

---

## 9. 부록 A — 명세 외 보강 후보 (Claude Code 판단)

다음 항목은 명세에 없지만 추가 시 안전성/편의성 향상. 진행 여부는 Claude Code가 판단:

- **브랜드 별칭**: `ADIDAS`, `Adidas`, `adidas Originals/三叶草` 등 다양한 표기를 표준 `ADIDAS`로 정규화하는 별칭 테이블
- **사이즈표 export API**: `/api/size-charts/export?brand=ADIDAS` → 엑셀 다운로드 (사용자가 수정해서 재업로드)
- **model_sizes_set 자동 조회**: 호출자가 매번 model_sizes를 넘기지 않아도, model로 size_conversion_log에서 자동 조회

이런 보강 추가 시 명세 외 항목으로 명시하고 보고에 포함.
