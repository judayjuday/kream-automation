# KREAM Automation - Claude Code 작업 규칙

## 기본 규칙
1. 한국어로 작업
2. 작업 완료 후 반드시 구문 확인 (python3 -c "import py_compile; py_compile.compile('파일명', doraise=True)")
3. 구문 확인 통과하면 서버 재시작하고 테스트
4. 테스트 실패하면 스스로 디버깅하고 재시도 (최대 3회)
5. 각 작업 완료 후 결과 요약 출력하고 다음 작업으로 넘어가기
6. 해결 안 되는 문제는 해당 작업에서 멈추고 상세 보고
7. **데이터 수집 실패 시 절대 다른 데이터로 대체하지 마라. 실패는 실패로 표시하고, 사용자가 판단하도록 해라.**
   - 즉시구매가 수집 실패 → "수집 실패" 표시, 입찰 예정가 비움, 자동 입찰에서 제외
   - 전체 상품 최저가를 사이즈별 즉시구매가로 사용 금지
   - API 캡처 실패 → 경고 배너 표시, 세션 확인 유도
   - 마진 계산 불가 → "계산 불가" 표시, 체크박스 해제
8. **모든 수정 후 자가 검증 (커밋 전 필수):**
   - 구문 확인: `python3 -c "import py_compile; py_compile.compile('kream_server.py', doraise=True)"`
   - API 라우트 충돌 검사: `grep -n '@app.route' kream_server.py | sort -t'"' -k2 | uniq -d -f1` → 중복 있으면 수정
   - 서버 재시작 후 핵심 API 테스트:
     - `curl -s http://localhost:5001/api/settings` → JSON 응답 확인
     - `curl -s http://localhost:5001/api/queue/list` → queue 배열 확인
     - `curl -s -X POST http://localhost:5001/api/queue/add -H "Content-Type: application/json" -d '{"model":"TEST","cny":100}' | grep ok` → ok 확인
   - 실패 시 자동 디버깅 3회 재시도, 3회 실패하면 "사용자 확인 필요" 보고 후 멈춤

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

### 작업 1: 작업 예상 시간 표시
- 일괄 실행, 자동 입찰 시 예상 소요 시간을 프로그레스바 옆에 표시
- 계산 방법: 상품 1건당 약 30초 (KREAM 검색 + 마진 계산), 입찰 1건당 약 90초
- 예: "5건 실행 중... 2/5 완료 (40%) | 예상 남은 시간: 약 4분 30초"
- kream_dashboard.html의 기존 프로그레스바 영역에 추가
- 실시간 업데이트 (task 폴링 시 경과 시간 계산)

### 작업 2: 조건부 입찰
- 대시보드 결과 테이블에서 조건 설정 가능:
  "즉시구매가가 X원 이하로 떨어지면 자동 입찰"
  "경쟁자 최저가가 X원 이상이면 자동 입찰"
- price_history.db에 conditional_bids 테이블 추가:
  id, product_id, model, size, condition_type(price_below/competitor_above),
  condition_value, bid_price, status(active/triggered/expired), created_at, triggered_at
- 모니터링 스케줄러(2시간마다)에서 조건 체크 → 충족 시 자동 입찰 실행
- 대시보드에 "조건부 입찰" 섹션 추가 (가격 자동 조정 탭)
- 조건 충족 시 알림 (notifications 테이블에 추가)

### 작업 3: 입찰 만료 자동 갱신
- 내 입찰 중 만료일이 3일 이내인 건 자동 감지
- 대시보드에 "만료 임박 N건" 경고 배지 표시
- "자동 갱신" 버튼 → 동일 가격으로 재입찰
- 모니터링 스케줄러에서 만료 임박 체크 추가
- 알림: "JQ4110 W215 128,000원 입찰이 2일 후 만료됩니다"
- 설정에서 자동 갱신 ON/OFF 가능 (기본 OFF, 수동 승인)

### 작업 4: 마진 시뮬레이터 강화
- 마진 계산기 탭 개선:
  - CNY 가격 입력 → 즉시 원가 계산 (환율 × 1.03 + 배송비)
  - KREAM 판매가 입력 → 정산액, 마진, 마진율 즉시 표시
  - 수수료율 6% 적용
  - "이 가격에 팔면 마진 X원 (Y%)" 한눈에
  - 고객 부담 관부가세도 참고 표시 ($150 초과 여부)
- 역계산 기능: "마진 10,000원 남기려면 최소 판매가 X원"
- 모델번호 입력하면 KREAM 현재 시세 자동 로드

### 작업 5: 수정 이력 로그
- 사용자가 입찰 예정가, 수량, 전략 등을 수정할 때마다 이력 기록
- price_history.db에 edit_log 테이블:
  id, item_type(queue/result/bid), item_id, field_name, old_value, new_value, edited_at
- 대시보드 실행 이력 탭에 "수정 이력" 섹션 추가
- 날짜별 필터링 가능
- 예: "4/19 14:30 | JQ4110 215 | 입찰예정가 | 128,000 → 127,000"

---

## 작업 완료 후
- 모든 작업 결과를 요약해서 출력
- 성공/실패/스킵 현황
- 서버 정상 실행 확인
