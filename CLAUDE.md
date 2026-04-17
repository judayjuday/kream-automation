# KREAM Automation - Claude Code 작업 규칙

## 기본 규칙
1. 한국어로 작업
2. 작업 완료 후 반드시 구문 확인 (python3 -c "import py_compile; py_compile.compile('파일명', doraise=True)")
3. 구문 확인 통과하면 서버 재시작하고 테스트
4. 테스트 실패하면 스스로 디버깅하고 재시도 (최대 3회)
5. 각 작업 완료 후 결과 요약 출력하고 다음 작업으로 넘어가기
6. 해결 안 되는 문제는 해당 작업에서 멈추고 상세 보고

## 서버 관련
- 서버 재시작: lsof -ti:5001 | xargs kill -9 2>/dev/null; python3 kream_server.py > server.log 2>&1 &
- auth_state.json 절대 빈 세션으로 덮어쓰지 말 것
- 성공 시에만 세션 저장

## 파일 구조
- kream_server.py: Flask 백엔드 (포트 5001)
- kream_bot.py: Playwright 자동화 (로그인/고시정보/입찰)
- kream_dashboard.html: 웹 대시보드 프론트엔드
- kream_collector.py: KREAM 가격 수집
- kream_adjuster.py: 가격 자동 조정
- competitor_analysis.py: 경쟁사 분석
- tabs/: 탭별 HTML 파일
- price_history.db: SQLite DB (가격이력/입찰이력/판매이력)

---

## 순차 작업 큐 (위에서부터 순서대로 진행)

### 작업 1: 즉시구매가 사이즈별 매칭 버그 수정
**문제:** JQ4110 W215의 실제 판매입찰 최저가는 128,000원인데, 대시보드에서 84,000원으로 표시됨. 84,000원은 전체 상품 표시가격(다른 사이즈의 최저가)이지 W215의 가격이 아님.

**수정:**
- kream_collector.py에서 사이즈별 buyPrice 수집 시 전체 instantBuyPrice로 덮어쓰는 곳 찾기
- API 응답의 sizeDeliveryPrices에서 각 사이즈별 buyPrice가 정확히 매핑되는지 확인
- kream_server.py에서 큐 실행 결과의 sizeMargins에 사이즈별 instantBuyPrice가 정확히 들어가는지 확인
- 입찰 예정가 = 해당 사이즈의 즉시구매가 - 1,000원 (언더컷) 자동 계산 확인

**테스트:**
- 서버 재시작 후 JQ4110 큐에 추가 → 일괄 실행
- W215 즉시구매가가 128,000원, 입찰 예정가가 127,000원으로 나오는지 확인
- curl로 API 테스트: curl -s -X POST http://localhost:5001/api/search -H "Content-Type: application/json" -d '{"model": "JQ4110"}'

---

### 작업 2: 기본 전략 "언더컷 -1,000원" 재확인
**문제:** 결과 테이블 상단 "기본 전략" 드롭다운이 아직 "언더컷 -3,000원"으로 보이는 경우가 있음.

**확인/수정:**
- tabs/tab_register.html의 기본 전략 드롭다운 기본 선택값
- kream_dashboard.html의 결과 테이블 상단 드롭다운 기본값
- kream_server.py의 undercutAmount 기본값
- tabs/tab_settings.html의 언더컷 금액 input 기본값
- 모든 fallback 값이 1000인지 확인 (3000이 남아있으면 수정)

---

### 작업 3: 발송관리 데이터 수집 + 판매 이력 추적
**설명:** 판매자센터 /business/shipments 페이지에서 발송완료 내역을 수집하여 판매 실적을 추적.

**구현:**
1. kream_bot.py 또는 새 파일에 collect_shipments() 함수 추가
   - Playwright로 /business/shipments 페이지 접근
   - 발송완료 탭 클릭
   - 테이블 파싱: 주문번호, 상품정보(productId, 모델번호), 사이즈, 거래금액, 거래일시, 발송일시, 발송상태
   - 100개씩 보기 설정
2. price_history.db에 sales_history 테이블 추가:
   - id, order_id, product_id, model, size, sale_price, trade_date, ship_date, ship_status, collected_at
3. kream_server.py에 스케줄러 추가 (1시간마다, 24시간 운영)
4. API 엔드포인트:
   - GET /api/sales/recent — 최근 판매 내역
   - POST /api/sales/sync — 수동 동기화
   - GET /api/sales/stats — 판매 통계
   - GET /api/sales/scheduler/status — 스케줄러 상태
   - POST /api/sales/scheduler/start, stop — 스케줄러 제어
5. 대시보드에 "최근 판매" 섹션 추가 (실행 이력 탭 또는 새 탭)

---

### 작업 4: 판매 완료 → 자동 재입찰 추천
**설명:** 새로 체결된 건이 감지되면 동일 조건 재입찰을 추천.

**구현:**
1. 발송관리 수집 시 이전 수집과 비교 → 새 체결건 감지
2. 새 체결건 발견 시:
   - 대시보드에 알림 배지 표시 ("새 판매 N건")
   - 재입찰 추천 목록: "JQ4110 W220 109,000원 체결 → 재입찰하시겠습니까?"
   - 승인 버튼 클릭 → 같은 상품+사이즈+가격으로 자동 입찰
3. 재입찰 시 현재 시장 가격도 함께 표시 (가격이 변했을 수 있으니)

---

### 작업 5: 득물 가격 데이터 연동 제거
**설명:** 시장 체크에서 "득물 가격 데이터가 없습니다" 메시지 개선.

**수정:**
- 득물 가격 없어도 KREAM 시세 기반으로 경쟁력 분석 정상 동작하도록
- "데이터 부족" 대신 KREAM 데이터만으로 분석 결과 표시
- 득물 가격이 있으면 추가 정보로 표시, 없으면 KREAM 데이터만으로 판단

---

### 작업 6: 상품 발굴 자동화 기초
**설명:** KREAM에서 마진이 남을 가능성이 높은 상품을 자동으로 찾는 기능.

**구현:**
1. /api/discovery/auto-scan 엔드포인트 추가
2. KREAM 키워드 검색으로 카테고리별 인기 상품 수집:
   - "오니츠카 타이거", "뉴발란스 1906", "미즈노" 등 키워드
   - 거래량 많은 순 정렬
3. 각 상품별로:
   - 해외배송 판매입찰 수 확인 (적을수록 좋음)
   - 국내배송 vs 해외배송 가격 차이 확인
   - 거래량 확인
4. 점수 계산: 거래량 높음 + 해외배송 경쟁자 적음 + 가격차이 적절 = 높은 점수
5. 대시보드 상품 발굴 탭에 자동 스캔 결과 표시

---

### 작업 7: 인수인계서 v4 업데이트
**설명:** KREAM_인수인계서_v3.md를 v4로 업데이트. 4/14 이후 변경사항이 매우 많음.

**추가할 내용:**
- 자동 로그인 (Gmail IMAP + 네이버)
- 여러 사이즈 한 번에 입찰 (place_bids_batch)
- 사이즈별 가격 수집 (배송타입별 최저가)
- SQLite 가격 이력 DB
- 입찰 순위 모니터링 + 이메일 알림
- 경쟁사 분석 스크립트
- 시장 분류 시스템
- 해외배송 경쟁력 분석
- 원가 계산 변경 (관부가세 제외)
- 발송관리 수집 + 재입찰 추천
- 대시보드 파일 분리 구조
- 새 API 엔드포인트 전체 목록
- 새 DB 테이블 구조

---

## 작업 완료 후
- 모든 작업 결과를 요약해서 출력
- 성공/실패/스킵 현황
- 서버 정상 실행 확인
