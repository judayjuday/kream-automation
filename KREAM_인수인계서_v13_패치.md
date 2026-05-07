# v13 패치 (2026-05-07 후속)

## Step 46 통합 (8개 서브스텝)

### 46-1 데이터 품질 검증 도구
- services/data_quality.py
- bid_cost 무결성 / 고아 레코드 / 중복 데이터
- 종합 점수 100점 만점

### 46-2 단가표 인텔리전스
- services/price_intelligence.py
- 유사 모델 추론 (bid_cost → price_book → model_avg → prefix_avg)
- 가격 변동 시계열

### 46-3 데이터 품질 통합 대시보드
- tab_data_quality.html

### 46-4 시간별 자동 백업 시스템
- services/backup_manager.py
- SQLite online backup + SHA256

### 46-5 백업 스케줄러
- 4시간마다 hourly + 매일 00:30 정리
- APScheduler 통합 (기존 스케줄러 재사용)

### 46-6 백업 관리 대시보드
- tab_backup.html

### 46-7 외부 백업 가이드 자동화
- rsync / cp 명령어 자동 생성

### 46-8 시스템 모니터링
- services/system_monitor.py
- 디스크/폴더/DB 통계

## 신규 API: 13개
- /api/data-quality/check, integrity, orphans, duplicates (4)
- /api/price-intel/estimate, missing-models, history/<model> (3)
- /api/backup/create-hourly, cleanup, list, verify, external-script (5)
- /api/system/overview (1)

## 신규 services: 4개 파일
- services/data_quality.py
- services/price_intelligence.py
- services/backup_manager.py
- services/system_monitor.py

## 신규 탭: 2개
- tabs/tab_data_quality.html (🔍 데이터 품질)
- tabs/tab_backup.html (💾 백업 관리)

## 절대 규칙 준수
- auto_rebid 코드 미접촉 (조회만)
- 데이터 자동 삭제 금지 (탐지만)
- 인보이스 단가 사용 금지
- 추정값은 'estimated' 명시
- DROP/DELETE 없음
- auth_state.json 보호

## 다음 액션
- 사장님 송금 데이터 등록 + 매칭 진행
- 데이터 품질 탭에서 점수 확인
- 단가표 미등록 모델 정리
- Step 44 ENABLE 사전 조건 검토

## 커밋 체인
- 41375a4 Step 46-1: 데이터 품질 검증 도구
- bb2708e Step 46-2: 단가표 인텔리전스 - 유사 모델 추론
- ae04ceb Step 46-3: 데이터 품질 통합 대시보드
- d58dbd2 Step 46-4: 시간별 자동 백업 시스템
- 14bb15b Step 46-5: 백업 스케줄러 (4시간마다 + 매일 정리)
- cb347c9 Step 46-6: 백업 관리 대시보드
- 378d83f Step 46-7: receipts/ 외부 백업 가이드 자동화
- d8c8bfa Step 46-8: 시스템 모니터링
