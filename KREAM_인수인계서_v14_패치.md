# v14 패치 (2026-05-08 후속)

## Step 47 통합 (8개 서브스텝)

### 47-1 비즈니스 인사이트 - 마진 추세
- services/business_insights.py
- 일별 마진 / 카테고리 수익성 / 협력사 ROI

### 47-2 KREAM 시장 가격 추적
- market_price_trend / volatility_top
- price_history 테이블 활용 (collected_at 컬럼 자동 감지)

### 47-3 비즈니스 인사이트 대시보드
- tab_insights.html

### 47-4 전역 검색 시스템
- services/global_search.py
- 7개 테이블 통합 검색 (auto_rebid_log는 original_order_id 컬럼 정합)
- 헤더에 검색 바

### 47-5 데이터 Export (CSV/JSON)
- services/data_export.py
- 화이트리스트 9개 테이블

### 47-6 API 자동 카탈로그
- services/api_catalog.py
- Flask 라우트 자동 스캔 (총 249개 API)
- tab_api_catalog.html

### 47-7 통합 헤드라인 대시보드 (홈)
- services/headline.py
- tab_home.html (1분 자동 갱신)
- 핵심 KPI 한눈에

### 47-8 키보드 단축키 + UX
- Cmd/Ctrl + 키 단축키
- 글로벌 알림 / 저장 경고

## 신규 API: 11개
## 신규 services: 6개 파일
## 신규 탭: 3개 (insights, api_catalog, home)
## 추가 라인: 약 1,500줄

## 절대 규칙 준수
- auto_rebid 미접촉
- sales_history 조회만
- 인보이스 단가 사용 금지

## 다음 액션
- 사장님 송금 데이터 등록 후 인사이트 탭 확인
- 협력사별 ROI 비교 → 협력사 변경 결정
- API 카탈로그로 전체 시스템 파악
- 단축키 활용 (Cmd+H 홈, Cmd+/ 검색)
