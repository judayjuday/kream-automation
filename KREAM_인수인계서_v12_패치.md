# v12 패치 (2026-05-07 후속)

## Step 45 통합 (6개 서브스텝)

### 45-1 자동 재입찰 모니터링 대시보드
- services/rebid_monitor.py
- API 4개: realtime-stats / model-stats / skip-reasons / recent-executions
- tab_rebid_monitor.html (자동 30초 상태 갱신)
- 비상 정지 버튼 (ENABLE 시만 표시)

### 45-2 비상 정지 API
- POST /api/auto-rebid/emergency-stop
- 절대 규칙 #7 예외 (안전 우선)
- settings.json 자동 백업

### 45-3 일일 리포트 (Discord)
- services/daily_report.py
- API 2개: preview / send-now
- TOP 모델 / TOP 스킵 / 경고 자동 포함

### 45-4 백테스트 시뮬레이터
- services/rebid_simulator.py
- POST /api/auto-rebid/backtest (days/min_profit/cooldown 가변)
- ENABLE 결정 전 효과 미리 확인

### 45-5 모델별 ROI 분석
- API: /api/auto-rebid/model-roi
- 시도/성공/실패율/총 마진/ROI/시도 집계

### 45-6 알림 시스템 강화
- check_alerts: 실패율 / 일한도 / 음수 마진
- API 2개: check-alerts / send-alerts

## 신규 API 13개
## 신규 services 파일 3개 (rebid_monitor, daily_report, rebid_simulator)
## 신규 탭 1개 (tab_rebid_monitor.html)

## 다음 단계 (사장님 결정)
- Step 44: 자동 재입찰 ENABLE (보수 모드 daily_max=3 시작)
- 매일 자동 재입찰 모니터링 탭 확인
- 실패율 5% 이하면 daily_max 점진 상향
