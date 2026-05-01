# Step 15 — 識货 시장가 임포트 + 분수 사이즈 매핑 정책 수정

> 작성일: 2026-05-01
> 사전 조사: 완료 (size_converter 분수 처리 버그 발견)
> 예상 작업 시간: 1.5~2시간 (Claude Code 기준)
> 종속성: Step 12 (size_charts/size_converter) 완료됨, Step 13/14는 무관

---

## 0. 핵심 원칙 (절대 위반 금지)

| # | 원칙 |
|---|---|
| 1 | size_charts 테이블 데이터 무수정 (어제 임포트된 ADIDAS 새 표가 정답) |
| 2 | bid_cost 테이블 무수정 (스키마 변경 금지, 인덱스 추가만 허용) |
| 3 | 매핑 실패 시 절대 가짜 mm 값 금지 → NULL 저장 |
| 4 | 옛날 batch는 DELETE 금지 → active=false 마킹만 |
| 5 | KREAM API 호출 금지 (이번 단계는 데이터 임포트만, 입찰 안 함) |
| 6 | settings.auto_* 토글 변경 금지 (자동입찰 활성화는 별도 Step) |
| 7 | git push -f, git reset --hard 금지 |
| 8 | DB 백업 후 작업 시작 |

---

## 1. 작업 범위

### 1-1. size_converter.py 분수 처리 정책 수정 (버그 픽스)

**현재 동작 (사전 조사로 확인):**
- ⅓·⅔ 모두 정수로 깎아냄 → `38⅔ → 38 → 235mm` (오답)

**수정 후 동작:**
- ⅓ → 정수 (예: `39⅓ → 39 → 245mm`)
- ⅔ → 다음 0.5 (예: `38⅔ → 38.5 → 240mm`)
- 매핑 결과가 size_charts에 없으면 → NULL (자동 입찰 제외)

**구체적 규칙:**
```python
# fraction_to_int 룰을 fraction_to_half_or_int로 교체
# - "X⅓" → "X" (정수)
# - "X⅔" → "X.5" (다음 0.5)
# - "X½" → "X.5" (기존 .5 그대로)
# - "X⅕" 등 기타 분수 → 정수 (안전한 기본값)
```

### 1-2. shihuo_prices 테이블 신규 생성

```sql
CREATE TABLE shihuo_prices (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  batch_id TEXT NOT NULL,            -- 임포트 식별 (예: 'shihuo_20260501_103045')
  active BOOLEAN DEFAULT 1,           -- 최신 batch만 1, 옛날 batch는 0
  
  -- 識货 원본 데이터
  brand_raw TEXT,                     -- 品牌名称 원본 (예: "adidas Originals/三叶草", "无品牌")
  brand_normalized TEXT,              -- 정규화 결과 (예: "ADIDAS", "unknown")
  category TEXT,                      -- 鞋子(shoes) / 包包(bags)
  model TEXT NOT NULL,                -- 产品编号 (예: "JQ4110")
  color TEXT,                         -- 产品颜色
  size_eu TEXT,                       -- 产品尺寸欧码 원본 (예: "38⅔", "")
  size_normalized TEXT,               -- 정규화 결과 (예: "38.5", "38", NULL)
  kream_mm INTEGER,                   -- 매핑 결과 (예: 240, NULL)
  
  -- 가격 (모델+사이즈별 최저가만 저장)
  cny_price REAL NOT NULL,
  supplier TEXT,                      -- 供应商名称
  platform TEXT,                      -- 平台名称
  
  -- 시각
  source_created_at DATETIME,         -- 識货 创建时间 (원본)
  imported_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  
  -- 매핑 실패 사유 추적
  mapping_status TEXT,                -- 'mapped' / 'no_size' / 'unknown_brand' / 'no_size_chart' / 'mapping_failed'
  mapping_note TEXT,                  -- 디버그 메모
  
  UNIQUE(batch_id, model, size_eu)    -- 같은 batch 내 모델+사이즈 중복 방지
);

CREATE INDEX idx_shihuo_active_model ON shihuo_prices(active, model);
CREATE INDEX idx_shihuo_active_kream ON shihuo_prices(active, model, kream_mm);
CREATE INDEX idx_shihuo_batch ON shihuo_prices(batch_id);
```

### 1-3. 임포트 API 신설

**`POST /api/shihuo/import`** — 엑셀 업로드 → 임포트
- multipart 파일 업로드
- 헤더 검증: `产品编号, 产品尺寸欧码, 产品价格, 创建时间, 品牌名称, 产品分类, 供应商名称, 平台名称` 8개 필수
- 처리 순서:
  1. batch_id 생성: `f"shihuo_{datetime.now():%Y%m%d_%H%M%S}"`
  2. 모든 (model, size_eu) 그룹별로 MIN(cny_price) 1건만 추출
  3. brand 정규화 (1-4 정책)
  4. size 정규화 + size_chart 매핑 (1-1 수정된 룰 사용)
  5. shihuo_prices에 INSERT
  6. **모든 INSERT 성공 후** 트랜잭션 내에서 옛날 batch들 active=0 업데이트
  7. 응답: `{batch_id, total_rows, mapped, no_size, mapping_failed, unknown_brand, models_count}`

**`GET /api/shihuo/latest`** — 현재 활성 batch 조회
- 응답: `{batch_id, imported_at, total_count, by_model: {...}, by_status: {...}}`

**`GET /api/shihuo/by-model/<model>`** — 특정 모델의 활성 시장가 조회
- 응답: 사이즈별 최저가 + 매핑 상태 + 출처

**`GET /api/shihuo/unmapped`** — 매핑 실패 건 목록 (사람 검토용)
- 모델별 그룹화, mapping_status='no_size_chart' 또는 'mapping_failed' 또는 'unknown_brand'

**`POST /api/shihuo/rollback/<batch_id>`** — 특정 batch를 다시 active=1로, 그 외 active=0
- 비상 롤백용

### 1-4. 브랜드 정규화 정책

```python
def normalize_brand(brand_raw, supplier_raw):
    """
    1. 品牌名称에 "adidas" 포함 (대소문자 무관) → "ADIDAS"
    2. 品牌名称가 명확한 ADIDAS 표기 ("三叶草" 단독, "ADIDAS" 단독) → "ADIDAS"
    3. 品牌名称가 "无品牌" 또는 비어있음 → 供应商名称에서 추정:
       - supplier에 "adidas" 포함 → "ADIDAS"
       - supplier에 "三叶草" + "官方旗舰店" → "ADIDAS" (공식 패턴)
    4. 그 외 → "unknown" (mapping_status='unknown_brand'로 마킹)
    """
```

**모호한 케이스는 unknown으로 격리** — 잘못된 브랜드 매칭으로 사이즈 매핑 실패하는 것보다 안전.

### 1-5. 사이즈 매핑 정책 (수정된 size_converter 호출)

**가방류 (size_eu가 비어있음):**
- `size_normalized = NULL, kream_mm = NULL, mapping_status = 'no_size'`
- 모델별 단일 가격으로 저장 (사이즈 차원 없음)

**신발 (size_eu 있음):**
- 1-1 수정된 size_converter 호출
- 결과 NULL이면 `mapping_status = 'no_size_chart'` 또는 `'mapping_failed'`
- 결과 mm 값이면 `mapping_status = 'mapped'`

### 1-6. bid_cost (model, size) 복합 인덱스 추가

성능 향상용 (자동 매칭 시 model+size로 자주 조회됨):
```sql
CREATE INDEX IF NOT EXISTS idx_bc_model_size ON bid_cost(model, size);
```

---

## 2. 사전 백업 (필수)

```bash
cd ~/Desktop/kream_automation

# DB 백업
sqlite3 price_history.db ".backup '/Users/iseungju/Desktop/kream_automation/price_history_backup_step15_pre.db'"

# 코드 백업
cp size_converter.py size_converter.py.step15_pre.bak
cp kream_server.py kream_server.py.step15_pre.bak

# settings는 이번 Step에서 변경 없음 (백업 불필요, 그래도 안전 위해)
cp settings.json settings.json.step15_pre.bak

ls -la *step15_pre.bak price_history_backup_step15_pre.db
```

---

## 3. 변경 위치 명시

| 파일 | 변경 내용 | 예상 라인 |
|---|---|---|
| size_converter.py | normalize_size 함수 내 fraction_to_int 룰을 fraction_to_half_or_int로 교체 | 기존 함수 수정 |
| kream_server.py | shihuo_prices 테이블 init 함수 추가 (기존 _init_*_table 패턴 따라) | 새 함수 신설 |
| kream_server.py | normalize_brand 함수 신설 | 새 함수 신설 |
| kream_server.py | /api/shihuo/* API 5개 신설 | 새 라우트 |
| kream_server.py | bid_cost 인덱스 추가 (마이그레이션) | 기존 init 함수 보강 |
| (테이블) | shihuo_prices 테이블 신설 + 인덱스 3개 | DB |

---

## 4. 검증 시나리오 (6종)

### 시나리오 1: 분수 매핑 정책 수정 검증

```bash
# 서버 재시작 후 즉시 테스트
for size in "38⅔" "36⅔" "44⅔" "46⅔" "37⅓" "39⅓" "45⅓"; do
  echo "=== $size ==="
  curl -s -X POST http://localhost:5001/api/size-charts/test \
    -H "Content-Type: application/json" \
    -d "{\"brand\":\"ADIDAS\",\"gender\":\"M\",\"model\":\"TEST\",\"size\":\"$size\",\"model_sizes\":[\"$size\"]}" | python3 -m json.tool
done
```

**기대값:**
| 입력 | normalize 결과 | kream_mm |
|---|---|---|
| 38⅔ | 38.5 | 240 ⚠️ (어제 235였음) |
| 36⅔ | 36.5 | 225 ⚠️ |
| 44⅔ | 44.5 | 285 ⚠️ |
| 46⅔ | 46.5 | 300 ⚠️ |
| 37⅓ | 37 | 230 |
| 39⅓ | 39 | 245 |
| 45⅓ | 45 | 290 |

### 시나리오 2: shihuo_prices 테이블 마이그레이션

```bash
sqlite3 price_history.db ".schema shihuo_prices"
sqlite3 price_history.db "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='shihuo_prices'"
sqlite3 price_history.db ".schema bid_cost" | grep -i "model_size"
```

**기대값:** shihuo_prices 테이블 + 인덱스 3개, bid_cost에 idx_bc_model_size 인덱스 존재.

### 시나리오 3: 識货 엑셀 임포트 (실데이터)

사용자가 받은 엑셀 2개를 한꺼번에 또는 순차 임포트.

```bash
# 첫 번째 엑셀 임포트
curl -X POST http://localhost:5001/api/shihuo/import \
  -F "file=@/path/to/shihuo_1.xlsx" | python3 -m json.tool

# 두 번째 엑셀 임포트 (옵션)
curl -X POST http://localhost:5001/api/shihuo/import \
  -F "file=@/path/to/shihuo_2.xlsx" | python3 -m json.tool
```

**기대값:**
- 첫 임포트: total_rows=210, mapped=신발건수, no_size=가방건수, unknown_brand=일부 (无品牌 케이스)
- 두 번째 임포트: 활성 batch가 두 번째로 교체됨, 첫 batch는 active=0
- mapping_failed > 0이면 보고 (어떤 사이즈가 실패했는지)

### 시나리오 4: 활성 batch만 노출 검증

```bash
# 두 번째 임포트 후
curl -s http://localhost:5001/api/shihuo/latest | python3 -m json.tool
# → 두 번째 batch_id만 반환되어야 함

sqlite3 price_history.db "SELECT batch_id, COUNT(*), SUM(active) FROM shihuo_prices GROUP BY batch_id"
# → 두 번째 batch만 active=1 합계가 양수
```

### 시나리오 5: 모델별 조회 + 매핑 실패 조회

```bash
curl -s http://localhost:5001/api/shihuo/by-model/JQ4110 | python3 -m json.tool
curl -s http://localhost:5001/api/shihuo/unmapped | python3 -m json.tool
```

**기대값:**
- by-model/JQ4110: 사이즈별 최저가 + kream_mm 매핑 결과
- unmapped: 매핑 실패 건 목록 (있다면)

### 시나리오 6: 롤백 검증

```bash
# 첫 번째 batch_id로 롤백
FIRST_BATCH=$(sqlite3 price_history.db "SELECT batch_id FROM shihuo_prices WHERE batch_id LIKE 'shihuo_%' GROUP BY batch_id ORDER BY MIN(imported_at) ASC LIMIT 1")
curl -X POST http://localhost:5001/api/shihuo/rollback/$FIRST_BATCH | python3 -m json.tool

# 다시 latest 확인
curl -s http://localhost:5001/api/shihuo/latest | python3 -m json.tool
# → 첫 번째 batch_id 반환되어야 함
```

---

## 5. 합격 기준

| # | 기준 | 통과 조건 |
|---|---|---|
| 1 | size_converter 분수 정책 수정 | 38⅔ → 240mm, 37⅓ → 230mm |
| 2 | shihuo_prices 테이블 생성 | 스키마 + 인덱스 3개 정확 |
| 3 | bid_cost 복합 인덱스 추가 | idx_bc_model_size 존재 |
| 4 | 識货 엑셀 임포트 동작 | 첨부 엑셀 2개 모두 임포트 성공 |
| 5 | 신선도 정책 (b) 동작 | 새 임포트 후 옛날 batch active=0 |
| 6 | 가방류 처리 | size_eu 빈 건 → no_size 마킹 + 모델별 1건 저장 |
| 7 | 브랜드 정규화 | 无品牌 → 供应商으로 추정 또는 unknown 격리 |
| 8 | 매핑 실패 격리 | 사이즈 매핑 실패 시 NULL 저장, 자동입찰 대상 제외 |
| 9 | py_compile | size_converter.py + kream_server.py 통과 |
| 10 | /api/health | status=healthy 또는 warning(last_sale 사유만) 유지 |
| 11 | 기존 라우트 무영향 | 변경 후 /api/auto-adjust/status, /api/auto-rebid/status 정상 동작 |
| 12 | 기존 size_converter 호출처 무영향 | 다른 함수에서 size_converter 호출 결과 동일 (분수 외 케이스) |

---

## 6. 절대 금지 사항

- ⚠️ size_charts 테이블 데이터 변경 금지 (덮어쓰기 금지)
- ⚠️ bid_cost 스키마 변경 금지 (인덱스 추가만 허용)
- ⚠️ shihuo_prices에서 옛날 batch DELETE 금지 (active=0만)
- ⚠️ 매핑 실패 시 가짜 mm 값 입력 금지 → NULL
- ⚠️ KREAM 자동 입찰 트리거 금지 (이 Step은 데이터만)
- ⚠️ settings.auto_* 변경 금지
- ⚠️ git push -f, git reset --hard 금지

---

## 7. 자동 롤백 트리거

다음 발견 즉시 작업 중단 + 백업 복원:

| 트리거 | 복원 명령 |
|---|---|
| 시나리오 1 실패 (38⅔ ≠ 240) | size_converter.py 백업 복원 |
| 시나리오 2 실패 (테이블 스키마 어긋남) | DB 백업 복원 |
| 기존 라우트 회귀 (시나리오 11) | kream_server.py 백업 복원 |
| /api/health status=critical | 모든 백업 복원 |
| 임포트 중 예외로 부분 INSERT 발생 | 트랜잭션 롤백 + 해당 batch DELETE |

복원 명령:
```bash
cd ~/Desktop/kream_automation
cp size_converter.py.step15_pre.bak size_converter.py
cp kream_server.py.step15_pre.bak kream_server.py
cp price_history_backup_step15_pre.db price_history.db
lsof -ti:5001 | xargs kill -9 2>/dev/null
sleep 1
nohup python3 kream_server.py > server.log 2>&1 &
disown
sleep 3
curl -s http://localhost:5001/api/health | python3 -m json.tool
```

---

## 8. 보고 형식

```markdown
## Step 15 완료 보고

### 변경 파일 + 라인 번호
- size_converter.py: normalize_size 함수 (라인 NN~NN), fraction_to_half_or_int 룰 추가
- kream_server.py: shihuo_prices init 함수 (라인 NN~NN), API 5개 (라인 NN~NN), normalize_brand (라인 NN~NN)
- DB: shihuo_prices 테이블 신설, idx_bc_model_size 인덱스 추가

### 시나리오 6종 결과
| 시나리오 | 결과 | 핵심 발견 |
|---|---|---|
| 1 분수 매핑 수정 | ✅/❌ | 38⅔=240, 37⅓=230 등 |
| 2 테이블 마이그레이션 | ✅/❌ | shihuo_prices + 인덱스 3개 |
| 3 엑셀 임포트 | ✅/❌ | 1차 N건, 2차 M건 |
| 4 신선도 (b) | ✅/❌ | active 마킹 정확 |
| 5 모델별/실패 조회 | ✅/❌ | 매핑 실패 N건 |
| 6 롤백 | ✅/❌ | 옛날 batch 복원 가능 |

### 합격 기준 12개 체크
| # | 기준 | 결과 |
|---|---|---|
| ... | ... | ✅/❌ |

### 임포트 결과 통계
- 첫 번째 엑셀 (shihuo_1.xlsx): total=NN, mapped=NN, no_size=NN, unknown_brand=NN, mapping_failed=NN
- 두 번째 엑셀 (shihuo_2.xlsx): total=NN, mapped=NN, no_size=NN, unknown_brand=NN, mapping_failed=NN
- 매핑 실패 모델/사이즈 목록 (사람 검토용):
  - ...

### git diff --stat
...

### 다음 단계 후보
- Step 16: 만료 갱신 재입찰 (识货 시장가 참조)
- Step 13 dry-run 결과 검토 후 실입찰 전환
```

---

## 9. 부록 A — 識货 엑셀 양식 (확인된 8컬럼 필수 + 6 옵션)

필수 (없으면 임포트 거부):
- 产品编号 (model)
- 产品尺寸欧码 (size_eu)
- 产品价格 (cny_price)
- 创建时间 (source_created_at)
- 品牌名称 (brand_raw)
- 产品分类 (category)
- 供应商名称 (supplier)
- 平台名称 (platform)

옵션 (있으면 저장, 없어도 진행):
- 主键, 产品颜色, 销售数量, 产品尺寸长宽高, 产品尺寸, 更新时间

미래 양식 변경 대비: 컬럼 추가는 수용, 필수 컬럼 삭제는 거부.

---

## 10. 부록 B — 다음 Step 예고 (Step 16, 별도 작업)

이번 Step 15가 시장가 데이터 인프라이고, **자동 입찰 활용은 Step 16부터**:

- Step 16-A: 만료 갱신 재입찰 (입찰 만료 임박 → 識货 최저가 참조해 가격 재산정)
- Step 16-B: 자동 가격 조정 + 識货 시장가 통합 (현재 KREAM 시장가 외에 識货도 참조)

이번 Step에서는 **이런 통합 절대 하지 않음**. 데이터만 쌓음.
