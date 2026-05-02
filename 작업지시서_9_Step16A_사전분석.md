# 작업지시서 9 — Step 16-A 사전 분석 (Phase 1)

목적: Step 16-A 본 작업 전에 코드 구조를 정확히 파악하고, 본 작업지시서(Phase 2)를 자동 생성한다.

작업 모드: 분석 + 문서 작성만. 코드/DB 수정 절대 금지.

## Step 16-A 범위 (확정)

1. bid_cost UPSERT 시 shihuo_prices.active=1 매칭 시 cny_price 자동 채택
2. bid_cost에 cny_source 컬럼 추가 (shihuo | manual | unknown)
3. 식货 임포트 후 "기존 bid_cost와 가격 차이" 리포트 API + 대시보드 모달
4. /api/shihuo/rollback → /api/shihuo/activate 리네임 + 진짜 비활성화용 별도 API

## 분석 항목 — 다음을 모두 확인하고 결과를 보고서로 작성

### A. bid_cost 테이블 정밀 분석

```bash
sqlite3 -header price_history.db ".schema bid_cost"
sqlite3 -header price_history.db "SELECT COUNT(*), COUNT(cny_price) FROM bid_cost;"
sqlite3 -header price_history.db "SELECT * FROM bid_cost ORDER BY created_at DESC LIMIT 3;"
```

기록할 것:
- 정확한 컬럼명/타입/제약
- 인덱스 구조
- UNIQUE 제약 위치 (order_id?)
- created_at만 있는지 updated_at도 있는지
- cny_source 컬럼 추가 시 ALTER TABLE 영향도

### B. _save_bid_cost 함수 (또는 동등한 UPSERT 함수) 위치와 시그니처

```bash
grep -n "INSERT OR REPLACE INTO bid_cost\|INSERT INTO bid_cost\|UPDATE bid_cost\|def.*bid_cost" kream_server.py | head -20
```

각 호출 지점에 대해:
- 함수명, 라인 범위
- 입력 파라미터 (model, size, cny_price, exchange_rate 등)
- 호출 컨텍스트 (어느 API/함수에서 호출되는가)
- 호출 빈도 (단건/대량/스케줄러)

### C. shihuo_prices와의 매칭 키 정합성 확인

bid_cost와 shihuo_prices의 매칭 키 후보:
- 후보 1: (model, size) ↔ (model, kream_mm)
- 후보 2: (model, size_normalized)

확인할 점:
- bid_cost.size 데이터 타입 (INTEGER? TEXT?)
- bid_cost.size 값 분포 (실제 데이터 샘플 10건)
- shihuo_prices.kream_mm 데이터 타입 (INTEGER)
- 매칭 시 캐스팅 필요 여부

```bash
sqlite3 -header price_history.db "SELECT order_id, model, size, typeof(size) FROM bid_cost LIMIT 10;"
sqlite3 -header price_history.db "SELECT model, kream_mm, typeof(kream_mm) FROM shihuo_prices WHERE active=1 LIMIT 5;"
```

### D. 리포트 API 설계 검토

"기존 bid_cost와 식货 가격 차이" 리포트가 보여줄 정보:
- bid_cost.order_id
- bid_cost.model, size
- bid_cost.cny_price (현재 등록된 원가)
- shihuo_prices.cny_price (식货 활성 batch 가격)
- 차이 (절대값, %)
- 매칭 입찰의 현재 KREAM 입찰가 (my_bids_local.json)
- 새 마진 추정값

확인할 점:
- 단일 SELECT JOIN으로 가능한지 (성능)
- my_bids_local.json은 파일이라 JOIN 불가 → Python에서 합쳐야 하는지
- N건 처리 시 성능 (bid_cost 현재 6건, shihuo 활성 45건 → 부담 없음)

### E. /api/shihuo/rollback 현재 동작 정밀 확인

```bash
grep -n "api_shihuo_rollback\|@app.route.*shihuo/rollback" kream_server.py
# 함수 본문 확인
```

확인할 점:
- 정확한 SQL 동작
- 응답 포맷
- 호출하는 프런트엔드 코드 위치 (`grep -rn "shihuo/rollback" tabs/ kream_dashboard.html`)
- 리네임 시 영향받는 호출자 수

### F. 위험 분석

각 변경에 대한 위험도 평가:

1. ALTER TABLE bid_cost ADD COLUMN cny_source TEXT
   - SQLite WAL 모드에서 안전한가
   - DEFAULT 값 설정 (기존 6건은 어떻게 처리)
   - 마이그레이션 시점 (서버 시작 시 _init_bid_cost_table에 추가)

2. _save_bid_cost 분기 추가
   - shihuo 매칭 실패 시 fallback (현재 입력값 사용)
   - 사용자가 명시적으로 cny_price 입력한 경우 우선순위 (manual 우선?)
   - 로그 어디에 남길지

3. /api/shihuo/rollback 리네임
   - 백워드 호환 유지 (이전 URL도 당분간 살림)
   - 프런트엔드 동시 변경 필요

## 산출물

분석 끝나면 다음 두 파일을 생성:

### 산출물 1: 분석 보고서
파일: 분석보고서_Step16A_v1.md
다음 섹션 포함:
- A~F 각 분석 결과
- 발견된 의외점/리스크
- 본 작업지시서 작성에 필요한 결정 사항 정리

### 산출물 2: Phase 2 본 작업지시서 자동 생성
파일: 작업지시서_10_Step16A_본작업.md
다음 포함:
- 절대 규칙 (DROP/DELETE 금지, 자동 입찰 트리거 추가 금지 등)
- 사전 백업 명령
- Step 1: bid_cost 스키마 마이그레이션 (cny_source 추가)
- Step 2: _save_bid_cost 함수 분기 추가
- Step 3: /api/shihuo/rollback 안전화 (activate 리네임 + deactivate 신설)
- Step 4: /api/bid-cost/shihuo-diff 신설 (리포트 API)
- Step 5: 대시보드 UI (식货 임포트 탭에 "차이 보기" 버튼 추가)
- Step 6: 회귀 테스트 시나리오
  - ID6016 EU 35.5 / 36 임포트 후 가상 bid_cost 추가 → 자동 채택 확인
  - 매칭 실패 케이스 (식货에 없는 모델 입찰) → manual fallback 확인
  - shihuo-diff API 응답 구조 검증
- Step 7: 검증 후 롤백 시나리오
- 모든 SQL/API 호출은 실제 컬럼명 사용 (Step 8에서 발견된 size_eu→eu_size 같은 오타 금지)

## 보고

분석 보고서와 작업지시서 두 파일이 준비되면, 사용자에게 다음 형식으로 알림:

[Phase 1 완료]
- 분석 보고서: 분석보고서_Step16A_v1.md (요약 5줄)
- 본 작업지시서: 작업지시서_10_Step16A_본작업.md (Step 수, 예상 변경 라인 수)

[주요 결정 사항 N개]
- ...

[리스크 N개]
- ...

[다음 액션]
사용자가 작업지시서 검토 후 OK 하면 Phase 2 실행
