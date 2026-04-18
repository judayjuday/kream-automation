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

### 작업 1: CLAUDE.md 자가 검증 규칙 추가
- 모든 수정 후 구문 확인
- 서버 시작 확인 (curl)
- API 라우트 충돌 확인 (grep으로 중복 @app.route 검사)
- 핵심 API 테스트 (큐 추가/목록/설정)
- 실패 시 자동 디버깅 3회 재시도
- 3회 실패하면 "사용자 확인 필요" 보고 후 멈춤

### 작업 2: 일괄 실행 결과 다중 선택 삭제
- 결과 테이블에서 체크박스로 여러 항목 선택 → "선택 삭제" 버튼으로 일괄 삭제
- 전체 선택/해제 체크박스, 삭제 전 확인 팝업

### 작업 3: Cloudflare Tunnel 자동 실행 스크립트
- start_tunnel.sh 또는 start_server.sh --tunnel 옵션
- 서버 실행 + cloudflared tunnel 자동 연결, URL 표시

### 작업 4: 모바일 반응형 대시보드
- viewport meta, CSS 미디어 쿼리 (max-width: 768px)
- 사이드바 → 하단 네비게이션, 테이블 가로 스크롤, 버튼 크기 확대

### 작업 5: 입찰 순위 변동 실시간 알림 시스템
- 모니터링에서 순위 변동 감지 시 대시보드 알림 배지 + 이메일
- 알림 드롭다운 목록 + "가격 조정" 버튼

### 작업 6: 알림 센터 UI
- 🔔 벨 아이콘 + 배지, 드롭다운 알림 목록
- 순위 변동/판매 체결/세션 만료/환율 변동 알림 통합
- notifications 테이블 (price_history.db)

### 작업 7: 실시간 상태 업데이트 (폴링)
- 10초마다 /api/notifications/unread 폴링
- 벨 배지 업데이트, 자동 입찰 상태, 세션 만료 감지

---

## 작업 완료 후
- 모든 작업 결과를 요약해서 출력
- 성공/실패/스킵 현황
- 서버 정상 실행 확인
