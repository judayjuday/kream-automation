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

### 작업 1: 허브넷 물류 관리 DB 설계
- price_history.db에 물류 관련 테이블 3개 추가:
  - suppliers (협력사 목록): id, name, contact, phone, wechat, notes, created_at
  - shipment_requests (발송 요청): id, order_id, product_id, model, size, supplier_id, hubnet_hbl, request_date, tracking_number, status, proof_image, notes, created_at, updated_at
  - shipment_costs (물류 비용): id, shipment_id, cost_type, amount, currency, notes, created_at

### 작업 2: 대시보드에 "물류 관리" 탭 추가
- 사이드바에 "물류 관리" 메뉴 추가
- tabs/tab_logistics.html 새로 생성
- 화면 구성: 발송 대기 목록, 발송 진행 현황, 협력사 관리

### 작업 3: 발송 요청 워크플로우
- KREAM 체결 → 발송 대기 목록에 자동 추가 (sales_history 연동)
- 발송 요청 폼: 협력사 선택, HBL 번호, 메모, 증거 스크린샷 업로드
- "발송 요청" 버튼 → DB 저장 + 상태 변경
- 협력사별 요청 내역 조회

### 작업 4: 트래킹 번호 입력 + 상태 관리
- 트래킹 번호 입력 → 상태 자동 "발송완료"로 변경
- 상태 변경 이력 기록, HBL 번호로 조회
- API: POST/PUT/GET /api/logistics/request(s), /api/logistics/pending, /api/logistics/supplier(s)

### 작업 5: 물류 현황 대시보드 + 엑셀 연동
- 현황 카드: 발송 대기/진행 중/완료 건수, 이번 달 물류비
- 발송 요청 테이블 + 필터 (상태별/협력사별/기간별)
- 엑셀 내보내기/가져오기 (/api/logistics/import-tracking)

---

## 작업 완료 후
- 모든 작업 결과를 요약해서 출력
- 성공/실패/스킵 현황
- 서버 정상 실행 확인
