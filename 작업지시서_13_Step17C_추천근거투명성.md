# 작업지시서 13 — Step 17-C 추천 근거 투명성 + IX7694 등록

## 목적

가격 자동 조정 추천 결과를 사용자가 합리성 판단할 수 있도록 정보 노출.

문제 사례: JQ4110 ONE SIZE 추천 80,000원 → 사용자가 "왜 80,000원인지" 판단 불가
- 실제 근거: competitor_price 81,000 - 1,000 언더컷 = 80,000
- 이 근거가 대시보드에 안 보임

## 절대 규칙

1. price_history.db DROP/DELETE 금지
2. 자동 입찰 트리거 추가 금지
3. 백엔드 로직 변경 금지 (Step 16-A의 _save_bid_cost, /api/bid-cost/shihuo-diff 등 그대로)
4. UI 표시만 추가. 새 데이터 저장 X
5. settings.json, auth_state.json 변경 금지

## 사전 백업

```bash
cp tabs/tab_adjust.html tabs/tab_adjust.html.step17c_pre.bak
```

## Phase 1: 사전 분석

### 1-1. 현재 자동 실행 이력 표시 코드 위치
```bash
grep -n "자동 실행 이력\|auto-adjust/history\|loadAutoAdjustHistory\|autoAdjustHistoryTable" tabs/tab_adjust.html | head -20
```

### 1-2. /api/auto-adjust/history 응답 구조 확인
```bash
curl -s "http://localhost:5001/api/auto-adjust/history?limit=5" | python3 -m json.tool
```

기록할 것:
- 응답에 competitor_price 있는지 (price_adjustments 테이블에 있음)
- bc_cny_source 있는지
- 없다면 어디 SQL JOIN 추가 필요

### 1-3. /api/adjust/pending 응답 구조 확인
```bash
curl -s "http://localhost:5001/api/adjust/pending" | python3 -m json.tool | head -50
```

조정 대기 목록에도 competitor_price/bc_cny_source 노출되는지 확인. 노출 안 되면 같이 수정.

## Phase 2: 본 작업

### Step C-1: 자동 실행 이력 테이블에 컬럼 추가

기존 컬럼: 시각 / 모델 / 사이즈 / 가격 변경 / 예상수익 / 결과

추가:
- **경쟁자가** (competitor_price)
- **원가 출처** (bc_cny_source: 시장가/수동/미설정 한글화)

기존 4번째 컬럼 "가격 변경"의 표시도 보강:
- 변경 전 → 변경 후 + 작은 글씨로 "(경쟁자 81,000 - 1,000)"

### Step C-2: 조정 대기 목록에도 같은 정보 표시

조정 대기 테이블 (이미 보이는 추천가/예상수익 옆에) 추가:
- **경쟁자가**
- **원가 출처** (이전 17-A에서 만든 model_category와 함께 신뢰도 표시)

### Step C-3: API 응답에 컬럼 누락된 경우 SQL JOIN 추가

만약 /api/auto-adjust/history 또는 /api/adjust/pending 응답에 competitor_price/bc_cny_source가 없으면:
- price_adjustments에 이미 competitor_price 컬럼 있음 → SELECT에 추가만 하면 됨
- bc_cny_source는 bid_cost LEFT JOIN으로 가져옴 (이미 Step 16-A에서 cny_source 컬럼 추가했음)

```sql
-- 예시 (실제 쿼리는 사전 분석 결과 보고 결정)
SELECT pa.*, bc.cny_source AS bc_cny_source
FROM price_adjustments pa
LEFT JOIN bid_cost bc ON bc.order_id = pa.order_id
WHERE ...
```

### Step C-4: 한글화 매핑

bc_cny_source 값 한글화:
- 'shihuo' → '시장가' (Step 16-A UI 패치 때 식货→시장가 통일)
- 'manual' → '수동입력'
- 'unknown' → '미설정'
- NULL → '없음'

### Step C-5: IX7694 manual 등록

```bash
sqlite3 price_history.db "
INSERT OR REPLACE INTO model_category 
(model, category, source, needs_size, cached_at, notes) 
VALUES ('IX7694','bags','manual',0,datetime('now'),'사용자 확인 가방 (Step 17-C)')
"

# 검증
sqlite3 -header price_history.db "SELECT * FROM model_category WHERE model='IX7694'"
```

### Step C-6: 검증

```bash
# HTML 문법
python3 -c "from html.parser import HTMLParser; HTMLParser().feed(open('tabs/tab_adjust.html').read()); print('OK')"

# 서버 재시작
lsof -ti:5001 | xargs kill -9 2>/dev/null
sleep 1
nohup python3 kream_server.py > server.log 2>&1 & disown
sleep 3
curl -s http://localhost:5001/api/health | head -c 100
```

## Phase 3: 사용자 브라우저 검증 가이드

1. Cmd+Shift+R 강력 새로고침
2. "가격 자동 조정" 탭 진입
3. 자동 실행 이력 테이블 확인:
   - 새 컬럼 "경쟁자가", "원가 출처" 보이는지
   - JQ4110 행에 competitor 81,000 표시되는지
   - bc_cny_source가 한글로 표시되는지 (시장가/수동입력/미설정)
4. 조정 대기 목록도 같은 정보 표시 확인
5. F12 콘솔 에러 0건

## 보고

[Step 17-C + IX7694 완료]
1. 자동 실행 이력: 컬럼 추가 (경쟁자가, 원가 출처)
2. 조정 대기 목록: 컬럼 추가
3. API 응답: SQL JOIN 추가 / 이미 있음
4. 한글화 매핑: shihuo→시장가, manual→수동입력, unknown→미설정
5. IX7694 manual 등록: ✓ (model_category에 bags/manual 등록)
6. 서버 정상 재시작

[변경 파일]
- tabs/tab_adjust.html: +N
- (필요 시) kream_server.py: SQL JOIN 보강

[다음 액션]
- 사용자 브라우저 검증 → OK면 Step 17 전체 통합 커밋
