# 클로드 코드 작업 지시서 v2 — 운영 안정화 + 인기 정의 시스템

**프로젝트**: KREAM 자동화 (~/Desktop/kream_automation/)  
**작성일**: 2026-04-19  
**v1 대비 변경**:
- 1차 작업: bid_competition_log에 `my_margin`, `competitor_count` 필드 추가
- **4차 작업 신설**: 인기 정의 시스템 (4축 점수 + 호버 툴팁 + 수동 승인 + 변경 이력)
- 4차는 1~3차 완료 후 + 2주 데이터 축적 후 진행

**전체 일정**:
- 이번 주: 1~3차 (총 2.5~3시간)
- 2주 후: 4차 (총 2~3시간)

---

## 사용 방법

1. 터미널에서 `cd ~/Desktop/kream_automation && claude --dangerously-skip-permissions`
2. 1차 프롬프트 복사 → 클로드 코드에 붙여넣기 → 완료 확인
3. 1차 검증 후 2차 프롬프트 진행
4. 2차 검증 후 3차 프롬프트 진행
5. **2주 데이터 축적 대기**
6. 4차 프롬프트 진행

---

## 1차 작업 (예상 30분): WAL + SQL 분석 + 탈환률 추적 기반

### 프롬프트

```
~/Desktop/kream_automation/ 작업.

먼저 ~/Desktop/kream_automation/KREAM_인수인계서_v4.md를 읽고,
kream_server.py, kream_dashboard.html, price_history.db 스키마, tabs/ 폴더의
기존 파일들을 모두 확인한 후 작업 계획을 알려줘.
계획 승인 후 코드 작성 시작.

=== 작업 1: SQLite WAL 모드 활성화 ===
- price_history.db를 WAL 모드로 변경 (PRAGMA journal_mode=WAL)
- kream_server.py 시작 시 항상 WAL 모드 보장하도록 코드 추가
  (DB 연결 직후 PRAGMA 실행)
- 변경 전후 PRAGMA journal_mode 결과 콘솔에 출력해서 확인

=== 작업 2: 판매 패턴 분석 기능 ===
- 새 API: GET /api/sales/pattern-analysis
  반환:
  {
    "models": [
      {
        "model": "...",
        "sales_count": N,
        "first_sale": "...",
        "last_sale": "...",
        "span_days": N,
        "avg_hours_between_sales": N,
        "recommended_monitoring": "30분" | "1시간" | "3시간"
      }
    ],
    "hourly_distribution": [{ "hour": 0~23, "count": N }],
    "summary": {
      "total_models": N,
      "models_recommended_30min": N,
      "data_period_days": N
    }
  }

- 추천 모니터링 간격 로직:
  - 평균 간격 < 4시간 → "30분"
  - 평균 간격 < 12시간 → "1시간"
  - 그 이상 → "3시간"
  - 데이터 3건 미만 → 분석 대상 제외

- 새 탭 파일: tabs/tab_pattern.html
  - 메뉴 이름: "📊 판매 패턴"
  - 상단: 요약 카드 (총 모델 수, 30분 추천 모델 수, 분석 기간)
  - 중간: 테이블 (모델 / 판매수 / 평균 간격 / 추천 모니터링)
  - 하단: 시간대별 체결 분포 (0~23시 막대 그래프)
  - 인수인계서의 기존 탭 구조 따라서 만들 것
  - kream_dashboard.html 메뉴에 새 탭 등록

=== 작업 3: 탈환률 추적 기반 (데이터 수집만) ===
- 새 테이블 생성: bid_competition_log
  CREATE TABLE IF NOT EXISTS bid_competition_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    product_id TEXT,
    model TEXT,
    size TEXT,
    my_price INTEGER,
    market_lowest INTEGER,
    am_i_lowest BOOLEAN,
    my_margin INTEGER,           -- ★ v2 추가: 입찰 시점 예상 마진(원)
    competitor_count INTEGER,    -- ★ v2 추가: 같은 사이즈 경쟁 입찰 수
    checked_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );
  CREATE INDEX idx_bid_comp_model ON bid_competition_log(model, checked_at);
  CREATE INDEX idx_bid_comp_checked ON bid_competition_log(checked_at);

- 기존 입찰 모니터링 스케줄러(매일 8,10,12,14,16,18,20,22시)에 통합
- 모니터링 시 각 입찰별로 한 줄씩 기록
- my_margin 계산: 입찰가에서 수수료(6% + 부가세) + 고정수수료(2,500원) 차감 후
  원가(CNY × 환율 × 1.03 + 해외배송비) 차감
  계산 불가 시 NULL 저장 (NULL 허용)
- competitor_count: 해당 사이즈의 판매 입찰 총 개수 (가능하면 수집,
  안 되면 NULL 허용)
- 분석 기능은 만들지 않음 (지금은 데이터 수집만)
- 2주 후 4차 작업에서 이 데이터로 4축 점수 분석 예정

=== 원칙 (반드시 지킬 것) ===
- 데이터 없으면 "데이터 부족" 명시. 다른 데이터로 대체 금지.
- my_margin, competitor_count 계산 실패 시 NULL 저장 (가짜 값 금지)
- 기존 동작 깨지 않도록 주의. 변경 전 git diff로 확인.
- 작업 완료 후 서버 재시작:
  lsof -ti:5001 | xargs kill -9 2>/dev/null; python3 kream_server.py > server.log 2>&1 &
- 변경된 파일 목록과 핵심 변경사항 요약 후 git commit
  (메시지: "feat: WAL 모드 + 판매 패턴 분석 + 탈환률 추적 기반(마진/경쟁자 포함)")
- 단일 커밋으로 묶을 것 (롤백 용이성)
```

### 1차 검증 체크리스트

```bash
# WAL 모드 확인
sqlite3 ~/Desktop/kream_automation/price_history.db "PRAGMA journal_mode;"
# → "wal" 출력되어야 함

# 새 테이블 확인 (필드 4개 모두 있는지)
sqlite3 ~/Desktop/kream_automation/price_history.db ".schema bid_competition_log"
# → my_margin, competitor_count 칼럼 보여야 함

# API 동작 확인
curl http://localhost:5001/api/sales/pattern-analysis | python3 -m json.tool

# 대시보드에서 "📊 판매 패턴" 탭 보이는지 확인
open http://localhost:5001
```

**검증 통과 조건**: 위 4개 모두 성공 + 기존 기능(입찰, 모니터링) 정상 동작 + 다음 모니터링 사이클(8/10/12/14/16/18/20/22시) 후 bid_competition_log에 데이터 쌓이는지 확인

---

## 2차 작업 (예상 1시간): 백업 + 헬스체크

### 프롬프트

```
~/Desktop/kream_automation/ 작업. 1차 작업 완료된 상태.

먼저 1차에서 추가된 파일들과 현재 DB 상태를 확인한 후 작업 계획 알려줘.

=== 작업 1: 일일 백업 시스템 ===
- 백업 디렉토리: ~/Desktop/kream_backups/ (없으면 생성)
- 백업 스크립트: ~/Desktop/kream_automation/backup_db.sh
  - sqlite3 .backup 명령 사용 (cp 절대 금지, 락 걸림)
  - 파일명: price_history_YYYYMMDD_HHMMSS.db
  - 백업 후 7일 이상 된 파일 자동 삭제 (find -mtime +7 -delete)
  - 성공/실패 로그를 ~/Desktop/kream_automation/backup.log에 기록
  - 디스크 용량 부족 등 실패 시 종료 코드 1
  - 스크립트에 실행 권한 부여 (chmod +x)

- crontab 등록은 사용자가 직접 해야 하니 안내문 출력:
  "다음 명령으로 crontab 편집:
   crontab -e
   
   추가할 라인:
   0 4 * * * /Users/.../Desktop/kream_automation/backup_db.sh
   
   확인:
   crontab -l"

- 즉시 1회 백업 실행해서 정상 동작 확인

=== 작업 2: 헬스체크 시스템 ===
- 새 API: GET /api/health
  반환:
  {
    "status": "healthy" | "warning" | "critical",
    "auth_partner": {
      "exists": bool,
      "last_modified": "ISO datetime",
      "age_hours": N,
      "valid": bool
    },
    "auth_kream": { 동일 구조 },
    "schedulers": {
      "monitor": "running" | "stopped",
      "sales": "running" | "stopped"
    },
    "last_sale_collected": "ISO datetime",
    "last_sale_age_hours": N,
    "db_size_mb": N,
    "last_backup": "ISO datetime" | null,
    "last_backup_age_hours": N
  }

- status 판정 로직:
  - critical: auth 파일 없음 OR 24시간 이상 경과 OR 마지막 판매 수집 24시간 이상
  - warning: auth 12시간 이상 OR 마지막 판매 수집 12시간 이상 OR 백업 25시간 이상
  - healthy: 그 외

- 헬스체크 자체가 실패해도 응답은 200으로 반환:
  { "status": "error", "error": "..." }

=== 작업 3: 대시보드 신호등 ===
- kream_dashboard.html 헤더 영역에 신호등 3개 추가
  - 인증 (auth_partner + auth_kream 종합)
  - 스케줄러 (monitor + sales 종합)
  - 데이터 신선도 (last_sale_age_hours)
- 색상: 초록(healthy) / 노랑(warning) / 빨강(critical)
- 30초마다 폴링
- 클릭 시 /api/health 결과를 모달로 상세 표시
- 모바일 반응형 처리 (이미 모바일 반응형 적용됨, 그 패턴 따를 것)

=== 원칙 ===
- 헬스체크 자체가 실패해도 대시보드는 동작해야 함 (try/catch 필수)
- 폴링 실패 시 신호등 회색 표시 (오류 상태)
- 작업 완료 후 서버 재시작
- 변경된 파일 목록 요약 후 단일 커밋
  ("feat: 일일 백업 + 헬스체크 신호등 추가")
```

### 2차 검증 체크리스트

```bash
~/Desktop/kream_automation/backup_db.sh
ls -lh ~/Desktop/kream_backups/
curl http://localhost:5001/api/health | python3 -m json.tool
crontab -l | grep backup_db
open http://localhost:5001  # 신호등 3개 확인
```

---

## 3차 작업 (예상 1시간): 실패 알림 시스템

### 프롬프트

```
~/Desktop/kream_automation/ 작업. 2차 작업 완료된 상태.

먼저 2차에서 추가된 헬스체크 API와 기존 이메일 발송 로직 확인 후 작업 계획 알려줘.

=== 작업 1: HealthAlert 클래스 ===
- 새 파일: health_alert.py
- HealthAlert 클래스
  - alert(key, message, cooldown_minutes=60) 메서드
  - 같은 key의 알림은 cooldown 내에 한 번만 발송
  - 알림 이력은 메모리(dict) + 파일(alert_history.json)에 저장
  - 서버 재시작 시 alert_history.json에서 복원
  - 기존 이메일 발송 함수 재사용
  - 이메일 제목: [KREAM 자동화 경보] {key}
  - 이메일 본문: 메시지 + 발생 시각 + 다음 알림 가능 시각

=== 작업 2: 알림 연동 지점 ===
1. 자동 로그인 실패: key="auth_partner_login_failed", "auth_kream_login_failed"
2. 헬스체크 모니터링: 5분마다 /api/health 내부 호출, critical 시 발송
   key="health_critical", cooldown 1시간
3. 입찰 모니터링 3회 연속 실패: key="bid_monitor_consecutive_fail"
4. 판매 수집 12시간 이상 새 데이터 없음: key="sales_no_data_12h"

=== 작업 3: 테스트 모드 ===
- 새 API: POST /api/health/test-alert
  - body: { "key": "test_alert", "message": "테스트 알림입니다" }
  - cooldown 무시하고 즉시 발송
  - 발송 결과 반환

=== 작업 4: 설정 추가 ===
- settings.json에 추가:
  - alert_email (기본값: 기존 이메일)
  - alert_enabled (기본 true)
  - alert_cooldown_minutes (기본 60)
- tab_settings.html에 UI 추가
  - 알림 이메일 입력
  - 알림 활성화 체크박스
  - 쿨다운 시간 입력
  - "테스트 알림 발송" 버튼

=== 원칙 ===
- 알림 시스템 자체가 실패해도 본 작업은 계속 진행 (try/except 필수)
- 알림 발송 실패는 콘솔 로그로만 (이중 알림 방지)
- 작업 완료 후 서버 재시작
- 작업 완료 후 직접 테스트:
  curl -X POST http://localhost:5001/api/health/test-alert \
    -H "Content-Type: application/json" \
    -d '{"key":"test","message":"3차 작업 완료 테스트"}'
- 메일함에서 수신 확인
- 단일 커밋: "feat: 자동화 실패 이메일 알림 시스템"
```

### 3차 검증 체크리스트

```bash
curl -X POST http://localhost:5001/api/health/test-alert \
  -H "Content-Type: application/json" -d '{"key":"test","message":"테스트"}'
# 메일함에서 1~5분 내 수신 확인
cat ~/Desktop/kream_automation/alert_history.json
# 같은 key로 2번 호출 → 두 번째는 안 와야 함
```

---

# ⏸️ 여기서 2주 대기 ⏸️

**이유**: 4차 작업은 bid_competition_log 데이터를 분석합니다.  
2주(약 100~150건의 모니터링 기록)는 쌓여야 의미 있는 분석이 가능합니다.

**대기 기간 동안 할 일**:
- 매일 헬스체크 신호등 확인 (모바일에서)
- 알림 이메일 도착 시 즉시 대응
- bid_competition_log 데이터 쌓이는지 가끔 확인:
  ```
  sqlite3 ~/Desktop/kream_automation/price_history.db \
    "SELECT COUNT(*), MIN(checked_at), MAX(checked_at) FROM bid_competition_log;"
  ```
- 쌓이는 데이터 100건 이상 + 7일 이상 경과 시 4차 진행 가능

---

## 4차 작업 (예상 2~3시간): 인기 정의 시스템

**전제 조건**:
- 1~3차 완료
- bid_competition_log 데이터 100건 이상
- 7일 이상 데이터 축적

### 프롬프트

```
~/Desktop/kream_automation/ 작업. 1~3차 완료된 상태.
2주간 bid_competition_log 데이터가 쌓였음.

먼저 다음을 확인하고 계획 알려줘:
1. bid_competition_log 데이터 양 (COUNT, 기간)
2. sales_history 데이터 양
3. 각 모델별 데이터 분포
4. 기존 tab_pattern.html (1차에서 만든 것) 구조

=== 작업 1: 4축 점수 체계 (popularity_definition 테이블) ===

- 새 테이블: popularity_definition
  CREATE TABLE IF NOT EXISTS popularity_definition (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    weight_frequency INTEGER NOT NULL,    -- 거래 빈도 가중치 (%)
    weight_loss_rate INTEGER NOT NULL,    -- 탈환률 가중치 (%)
    weight_margin INTEGER NOT NULL,       -- 마진 가치 가중치 (%)
    weight_size_focus INTEGER NOT NULL,   -- 사이즈 집중도 가중치 (%)
    threshold_30min INTEGER DEFAULT 80,   -- 30분 모니터링 점수 기준
    threshold_1hour INTEGER DEFAULT 60,   -- 1시간 모니터링 점수 기준
    threshold_3hour INTEGER DEFAULT 40,   -- 3시간 모니터링 점수 기준
    is_active BOOLEAN DEFAULT 0,          -- 현재 사용 중인 정의는 1
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    created_by TEXT DEFAULT 'manual',     -- 'manual' | 'quarterly_auto'
    note TEXT
  );
  
- 초기 데이터 삽입 (기본 정의):
  INSERT INTO popularity_definition 
  (weight_frequency, weight_loss_rate, weight_margin, weight_size_focus, 
   is_active, created_by, note)
  VALUES (30, 35, 20, 15, 1, 'manual', '초기 기본 정의');

- 가중치 합계는 항상 100이어야 함 (저장 시 검증)

=== 작업 2: 점수 계산 엔진 ===

- 새 함수: calculate_popularity_scores(period_days=14)
  - 최근 N일간 sales_history + bid_competition_log 분석
  - 각 모델별 4축 점수 계산:
  
  1) 거래 빈도 점수 (0~100):
     - 평균 체결 간격(시간) 기반
     - 4시간 이하 → 100점
     - 24시간 → 50점
     - 72시간 이상 → 0점
     - 선형 보간
  
  2) 탈환률 점수 (0~100):
     - bid_competition_log에서 am_i_lowest=false 비율
     - 50% 이상 → 100점
     - 0% → 0점
     - 데이터 5건 미만 → NULL (점수 산정 제외)
  
  3) 마진 점수 (0~100):
     - bid_competition_log.my_margin 평균
     - 50,000원 이상 → 100점
     - 0원 → 0점
     - NULL 다수면 sales_history로 대체 계산
  
  4) 사이즈 집중도 점수 (0~100):
     - 가장 많이 팔린 사이즈가 전체에서 차지하는 비율
     - 70% 이상 → 100점
     - 25% (균등 분포) → 0점
  
  - 최종 점수 = Σ(축 점수 × 가중치) / 100
  - 데이터 부족 시 NULL인 축은 제외하고 나머지 가중치 재정규화
  
- 새 API: GET /api/popularity/scores
  - ?period_days=14 (기본 14일)
  - 모든 모델의 4축 점수 + 최종 점수 + 추천 모니터링
  - 정렬: 최종 점수 내림차순
  - 각 점수의 raw 데이터도 같이 반환 (호버 툴팁용)

=== 작업 3: 인기 정의 UI (tab_pattern.html 확장) ===

- 1차에서 만든 tab_pattern.html을 확장
- 상단에 "현재 인기 정의" 패널 추가:
  ┌─────────────────────────────────┐
  │ 현재 인기 정의 [편집]           │
  │ 거래빈도 30% ━━━━━━━━           │
  │ 탈환률  35% ━━━━━━━━━           │
  │ 마진    20% ━━━━━              │
  │ 사이즈  15% ━━━                │
  │ 마지막 변경: 2026-04-19         │
  │ [변경 이력 보기]                │
  └─────────────────────────────────┘

- "편집" 클릭 시 모달 열림:
  - 4개 슬라이더 (각 0~100)
  - 합계 100 강제 (실시간 표시, 100 아니면 저장 불가)
  - 임계값 3개 입력 (30분/1시간/3시간 점수)
  - 변경 사유 입력 (필수)
  - "시뮬레이션" 버튼: 새 가중치로 점수 재계산해서 미리보기
  - "적용" 버튼: 기존 is_active=0으로, 새 정의 is_active=1로

- 모델 테이블 확장:
  | 모델 | 점수 | 추천 | 상세 | 액션 |
  - "상세" 칼럼: ⓘ 아이콘 호버 시 툴팁
    툴팁 내용:
    ┌──────────────────────────┐
    │ ka9266 점수 상세          │
    │                           │
    │ 거래빈도: 85점 × 30% = 25.5│
    │   (8시간마다 1건 판매)    │
    │                           │
    │ 탈환률: 95점 × 35% = 33.25│
    │   (최근 5건 중 3건 뺏김)  │
    │                           │
    │ 마진: 70점 × 20% = 14.0   │
    │   (평균 25,000원)         │
    │                           │
    │ 사이즈집중: 75점 × 15% = 11.25│
    │   (260 사이즈 60%)        │
    │                           │
    │ 합계: 84점                 │
    │ → 30분 모니터링 추천      │
    └──────────────────────────┘
    
  - 호버 툴팁은 CSS hover + 절대 위치 div 방식 (Bootstrap tooltip 사용해도 됨)
  - 모바일에서는 탭 시 표시
  
  - "액션" 칼럼: [승인] [거절] 버튼
    - 승인: monitoring_targets 테이블에 추가
    - 거절: 7일간 추천 안 함 (rejection_log 테이블)

=== 작업 4: 변경 이력 시스템 ===

- 새 테이블: definition_change_log
  CREATE TABLE IF NOT EXISTS definition_change_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    changed_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    trigger TEXT,                  -- 'manual' | 'quarterly_auto'
    reason TEXT,                   -- 변경 사유
    before_definition_id INTEGER,
    after_definition_id INTEGER,
    expected_impact TEXT,          -- JSON: 시뮬레이션 결과
    actual_impact TEXT,            -- JSON: 30일 후 실제 결과 (NULL로 시작)
    actual_impact_calculated_at DATETIME
  );

- 정의 변경 시 자동 기록
- "변경 이력 보기" 모달:
  - 시간순 리스트
  - 각 항목 클릭 시 상세 (Before/After 가중치, 사유, 예상 영향, 실제 영향)
  - "되돌리기" 버튼: 해당 정의를 다시 활성화

=== 작업 5: monitoring_targets 테이블 ===

- 새 테이블: monitoring_targets
  CREATE TABLE IF NOT EXISTS monitoring_targets (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    model TEXT NOT NULL,
    interval_minutes INTEGER NOT NULL,  -- 30, 60, 180
    approved_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    approved_score INTEGER,             -- 승인 시점 점수
    expires_at DATETIME,                -- 14일 후
    is_active BOOLEAN DEFAULT 1
  );

- 만료된 항목은 자동 비활성화 (헬스체크에 추가)
- 만료 후 다시 추천 받을 수 있음

=== 작업 6: 자동 분기 조정 (구조만, 기본 OFF) ===

- 새 함수: quarterly_auto_adjust() (스케줄러 등록 X, 수동 실행만)
- 새 API: POST /api/popularity/auto-adjust-preview
  - 자동 조정 알고리즘 실행 (적용 X, 미리보기만)
  - 반환: 추천 가중치 + 변경 사유 + 예상 영향
  - 사용자가 검토 후 수동 적용 결정
- settings.json에 quarterly_auto_enabled (기본 false)
- 6개월 후 데이터 충분해지면 활성화 검토

=== 작업 7: 30일 후 영향 검증 (스케줄러) ===

- 매일 새벽 5시 실행
- definition_change_log에서 changed_at 기준 30일 지난 변경 찾기
- actual_impact 비어있으면 계산해서 채움:
  - 변경 후 30일간 탈환 방어율
  - 변경 전 30일간 탈환 방어율
  - 차이 + ROI 점수
- 결과를 actual_impact JSON으로 저장

=== 원칙 ===
- 데이터 부족 시 절대 가짜 점수 만들지 말 것 (NULL 명시)
- 가중치 합계 100 항상 검증
- 모든 변경은 definition_change_log에 기록
- 작업 완료 후 서버 재시작
- 단일 커밋: "feat: 인기 정의 시스템 (4축 점수 + 호버 툴팁 + 변경 이력)"
```

### 4차 검증 체크리스트

```bash
# 4축 점수 API 동작
curl "http://localhost:5001/api/popularity/scores?period_days=14" | python3 -m json.tool

# 새 테이블 4개 확인
sqlite3 ~/Desktop/kream_automation/price_history.db ".tables" | grep -E "popularity|definition_change|monitoring_targets"

# 초기 정의 활성화 확인
sqlite3 ~/Desktop/kream_automation/price_history.db \
  "SELECT * FROM popularity_definition WHERE is_active=1;"

# 대시보드에서 확인:
# - 호버 툴팁 작동 여부
# - 가중치 슬라이더 합계 100 강제
# - 시뮬레이션 미리보기
# - 변경 이력 모달
# - [승인] 버튼 → monitoring_targets에 추가됨
```

**검증 통과 조건**: 4축 점수 정상 계산 + 호버 툴팁 표시 + 가중치 변경 가능 + 변경 이력 기록

---

## 전체 작업 후 최종 점검

```bash
# Git 이력 확인 (4개 커밋)
cd ~/Desktop/kream_automation && git log --oneline -10

# 모든 API 동작 확인
curl http://localhost:5001/api/health
curl http://localhost:5001/api/sales/pattern-analysis
curl http://localhost:5001/api/popularity/scores

# DB 테이블 전체 확인
sqlite3 ~/Desktop/kream_automation/price_history.db ".tables"
# 추가 테이블: bid_competition_log, popularity_definition, 
#            definition_change_log, monitoring_targets

# 서버 로그 확인
tail -50 ~/Desktop/kream_automation/server.log
```

---

## 문제 발생 시 롤백

```bash
cd ~/Desktop/kream_automation
git log --oneline -10
git revert <해시>  # 특정 커밋만 되돌리기

# DB 복원
ls ~/Desktop/kream_backups/
cp ~/Desktop/kream_backups/price_history_YYYYMMDD_HHMMSS.db \
   ~/Desktop/kream_automation/price_history.db
```

---

## 4차 이후 다음 단계

1. **3개월 데이터 축적** — 자동 분기 조정 알고리즘 검증용
2. **자동 분기 조정 활성화 검토** (6개월 후)
   - quarterly_auto_enabled = true
   - 단, 결과는 "추천만 표시", 적용은 수동 승인 유지
3. **자동 적용 검토** (1년 후, 충분한 신뢰 데이터 있을 때만)

---

## 인수인계서 업데이트

4차 완료 후 KREAM_인수인계서_v5.md 작성:
- 1~3차: WAL, 백업, 헬스체크, 알림, 신호등
- 4차: 4축 점수 체계, 호버 툴팁, 변경 이력
- 새 API 7개
- 새 테이블 4개
- 허브넷, 모바일 반응형, Cloudflare Tunnel (v4 누락분)
