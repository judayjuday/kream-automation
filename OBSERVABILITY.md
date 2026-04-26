# OBSERVABILITY.md
**프로젝트:** 주데이 이커머스 자동화 시스템
**작성일:** 2026-04-24
**버전:** v1.0
**관련 문서:** NORTH_STAR.md (원칙 7), AGENTS_INDEX.md (auditor)

> 이 문서는 **"모든 것을 기록하고 학습하는 시스템"**의 설계입니다.
> 원칙 7 "Observability + Learning Loop"의 구체적 실행 방법입니다.

---

## 1. 핵심 비전

**"시간이 지날수록 시스템이 스스로 똑똑해진다."**

- 모든 행동을 기록
- Claude가 주기적으로 로그 분석
- 실패 패턴 발견 → 자동 수정 제안
- 1년 후 = 엄청난 데이터 자산 + 자가 학습 시스템

---

## 2. 3대 축

### 축 1: Logging (기록)
모든 행동을 로그로 남김

### 축 2: Auto-Diagnosis (자가 진단)
Cron으로 주기적 로그 분석

### 축 3: Time-Travel (되돌리기)
특정 시점 상태 복원

---

## 3. 축 1: Logging

### 3.1 로그 테이블 4종 (필수)

#### execution_log — 모든 자동 실행
```sql
CREATE TABLE execution_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    domain TEXT,              -- kream/ssro/cs/image/crawler
    agent TEXT,               -- 어떤 에이전트가 실행?
    action TEXT,              -- "auto_rebid" / "cleanup_bid" / ...
    input_snapshot TEXT,      -- JSON: 실행 직전 관련 상태
    output TEXT,              -- JSON: 결과
    status TEXT,              -- success / failure / skipped
    error_message TEXT,
    execution_time_ms INTEGER,
    decision_rationale TEXT   -- "왜 이렇게 결정했는지" (중요!)
);

CREATE INDEX idx_exec_timestamp ON execution_log(timestamp);
CREATE INDEX idx_exec_domain_status ON execution_log(domain, status);
CREATE INDEX idx_exec_action ON execution_log(action);
```

**핵심 필드: `decision_rationale`**
- "왜 이 가격으로 입찰했는지"
- "왜 이 건을 skip 했는지"
- 나중에 Claude가 읽고 패턴 파악 가능

#### competitor_activity_log — 경쟁자 행동 (KREAM 전용)
```sql
CREATE TABLE competitor_activity_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    model TEXT,
    size TEXT,
    my_bid_price INTEGER,
    my_rank INTEGER,
    top_competitors TEXT,      -- JSON: [{rank:1, price:50000}, ...]
    detected_change TEXT,      -- "new_competitor" / "price_drop" / ...
    kream_current_price INTEGER
);

CREATE INDEX idx_comp_timestamp ON competitor_activity_log(timestamp);
CREATE INDEX idx_comp_model_size ON competitor_activity_log(model, size, timestamp);
```

**용도:**
- 언제 경쟁자가 들어오는지 패턴 분석
- 경쟁자 가격 움직임 학습
- 선제적 대응 전략 수립

#### diagnosis_log — 자가 진단 결과 (auditor 에이전트)
```sql
CREATE TABLE diagnosis_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    period TEXT,               -- "daily" / "weekly"
    domain TEXT,
    issues_found TEXT,         -- JSON 배열
    recommendations TEXT,      -- JSON: Claude의 수정 제안
    user_notified INTEGER DEFAULT 0,
    action_taken TEXT,         -- 주데이가 취한 조치 기록
    resolved_at DATETIME
);
```

#### failure_patterns — 실패 패턴 축적
```sql
CREATE TABLE failure_patterns (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    first_seen DATETIME,
    last_seen DATETIME,
    occurrence_count INTEGER DEFAULT 1,
    pattern_signature TEXT UNIQUE,   -- 실패 시그니처 (같은 패턴 중복 방지)
    domain TEXT,
    root_cause TEXT,
    resolution TEXT,                  -- 해결 방법 (알고 있다면)
    status TEXT                       -- 'open' / 'resolved' / 'accepted'
);
```

**같은 실수 반복 방지.**
- 첫 발생 시 open
- 해결되면 resolved
- 인지하되 수용하면 accepted

### 3.2 기존 로그와의 관계

Step 1~4에서 이미 만든 로그 테이블들:
- `bid_cost` (원가 로그)
- `sales_history` (판매 로그)
- `auto_adjust_log` (Step 3 실행 로그)
- `auto_rebid_log` (Step 4 실행 로그)
- `price_adjustments` (가격 조정)

**이것들은 유지하면서 execution_log에도 요약 기록.**
- 기존 테이블 = 도메인별 상세
- execution_log = 크로스 도메인 통합 뷰

### 3.3 모든 에이전트 의무

```python
# 모든 액션 실행 시 공통 래퍼

def log_execution(domain, agent, action, input_data, output_data,
                  status, rationale, error=None):
    """의사결정 모두 기록"""
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        INSERT INTO execution_log
        (domain, agent, action, input_snapshot, output,
         status, error_message, decision_rationale)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    """, (domain, agent, action,
          json.dumps(input_data, ensure_ascii=False),
          json.dumps(output_data, ensure_ascii=False),
          status, error, rationale))
    conn.commit()
    conn.close()
```

**모든 중요 의사결정은 이 함수로 기록.**

---

## 4. 축 2: Auto-Diagnosis (자가 진단)

### 4.1 Cron 스케줄

```
┌──────────────────────────────────────────────────┐
│ 매일 새벽 3시                                      │
│   → 어제 하루 execution_log 스캔                   │
│   → 실패/패턴 분석                                 │
│   → diagnosis_log 기록                            │
│   → 이메일 요약 리포트                             │
├──────────────────────────────────────────────────┤
│ 매주 일요일 밤 11시                                │
│   → 주간 종합 분석                                │
│   → KPI 리포트 (매출/자동화 성공률/시간 절약)     │
│   → 개선 제안 Top 3~5                             │
│   → 주데이 승인 대기                              │
├──────────────────────────────────────────────────┤
│ 즉시 감지 (실시간)                                │
│   → 같은 에러 3회 발생 → 즉시 알림               │
│   → 자동화 자동 OFF                              │
│   → 주데이 승인 대기                             │
└──────────────────────────────────────────────────┘
```

### 4.2 auditor 에이전트 (11번째)

```markdown
---
name: auditor
model: opus
tools: [Read, Bash, WebFetch]
---

# 담당 영역
- 파일: apps/auditor/
- DB 읽기 전용: 모든 *_log 테이블, failure_patterns
- Cron: 매일 3시, 매주 일요일 23시

# 주기적 작업

## 일일 (매일 03:00)
1. 어제 00:00 ~ 23:59 execution_log 스캔
2. 실패 건 분석:
   - 같은 에러 반복? → failure_patterns 기록
   - 새로운 패턴? → 시그니처 생성
3. 경쟁자 활동 분석 (KREAM):
   - 새 경쟁자 침입 횟수
   - 평균 가격 변동
4. 리포트 생성 + 이메일

## 주간 (매주 일요일 23:00)
1. 지난 7일 종합 분석
2. KPI 측정:
   - 자동화 성공률 (도메인별)
   - 주데이 수동 개입 횟수
   - 발생 에러 Top 5
3. 개선 제안 Top 3~5 (Claude가 생성)
4. 주데이에게 제안 리스트 (승인 필요)

## 즉시 감지 (5분 간격)
1. 최근 1시간 동일 에러 3+ 회 → failure_patterns 조회
2. 기존 패턴 → 알림만
3. 신규 패턴 → 해당 기능 자동 OFF + 긴급 알림

# 절대 건드리지 말 것
- 실제 코드 (제안만, 수정은 해당 도메인 에이전트)
- *_log 테이블 UPDATE/DELETE (INSERT만)
- 자동 수정 (주데이 승인 없이는 금지)

# 출력 형식 (리포트)
```
# 주데이 자동화 시스템 일일 리포트
## 날짜: 2026-05-15

## ✅ 정상 작동
- KREAM 자동 재입찰: 12건 성공
- SSRO 주문 수집: 45건 수집
- 판매 수집: 3건

## ⚠️ 문제 감지
### 1. [KREAM] 자동 조정 실패 3회
- 동일 에러: "KREAM session expired"
- 패턴 ID: FP_001 (재발 중)
- 제안: auth_state.json 자동 갱신 스크립트 추가

### 2. [SSRO] 네이버 주문 수집 0건
- 비정상 (평균 15건)
- 가능한 원인: 네이버 API 변경? 인증 만료?
- 즉시 확인 필요

## 📊 주간 지표
- 자동화 성공률: 95% (+2% vs 지난주)
- 주데이 수동 개입: 3회 (-5회 vs 지난주)
- KREAM 매출: 130만원 (목표: 167만원/주)

## 💡 개선 제안 (Claude)
1. [우선순위 상] auth 갱신 자동화 (FP_001 해결)
2. [우선순위 중] 네이버 수집 타임아웃 증가
3. [우선순위 하] 대시보드 색상 컨트라스트 개선
```
```

### 4.3 실패 패턴 학습 로직

```
새 실패 발생
   ↓
시그니처 생성: hash(error_type + domain + action)
   ↓
failure_patterns에서 조회
   ├─ 기존 패턴 있음
   │   └─ occurrence_count + 1
   │      last_seen 업데이트
   │      status == 'resolved' 이면? → 재발 경고
   │
   └─ 새 패턴
       └─ INSERT, status = 'open'
          Claude에게 원인 분석 의뢰
```

---

## 5. 축 3: Time-Travel (되돌리기)

### 5.1 Snapshot 원칙

**모든 변경 작업은 snapshot을 남김.**

```python
# 변경 직전 스냅샷
def take_snapshot(entity_type, entity_id):
    """변경 직전 상태 저장"""
    snapshot = {
        'type': entity_type,     # 'bid', 'product', 'order'
        'id': entity_id,
        'data': current_state,
        'timestamp': datetime.now().isoformat()
    }
    return json.dumps(snapshot)
```

### 5.2 되돌리기 단위

| 단위 | 가능 여부 | 방법 |
|------|---------|------|
| 단일 입찰 복구 | ✅ | snapshot으로 재등록 |
| 특정 시점 상태 | ⚠️ 부분적 | DB 백업 + 로그 롤백 |
| Git 커밋 되돌리기 | ✅ | git revert |
| DB 전체 롤백 | ✅ | backups/에서 복원 |

### 5.3 예시: 입찰 복구

```
주데이: "5분 전에 자동 삭제된 입찰 복구해줘"
   ↓
execution_log 조회: 최근 5분 내 delete 액션
   ↓
해당 snapshot 조회
   ↓
새 입찰로 재등록 (place_bid)
   ↓
복구 이력 기록
```

### 5.4 일일 DB 백업 (자동)

```bash
# cron: 매일 01:00
sqlite3 data/automation.db ".backup data/backups/automation_$(date +%Y%m%d).db"

# 보관: 30일
find data/backups -mtime +30 -delete
```

---

## 6. 구현 우선순위

### Phase 1: 기본 로깅 (M1과 함께)
- [ ] execution_log 테이블 추가
- [ ] log_execution() 헬퍼 함수 구현
- [ ] 기존 자동화 기능에 로깅 추가

### Phase 2: 자가 진단 (M3 이후)
- [ ] failure_patterns 테이블 추가
- [ ] diagnosis_log 테이블 추가
- [ ] auditor 에이전트 구현
- [ ] Cron 설정 (일일 / 주간)
- [ ] 일일 리포트 이메일

### Phase 3: 되돌리기 (M5 이후)
- [ ] snapshot 의무화
- [ ] 복구 API 구현
- [ ] DB 자동 백업

### Phase 4: 고급 학습 (3개월+)
- [ ] 경쟁자 활동 로그
- [ ] 패턴 기반 예측
- [ ] 주데이 만족도 피드백 반영

---

## 7. 변경 이력

| 버전 | 날짜 | 변경 사유 |
|------|------|----------|
| v1.0 | 2026-04-24 | 최초 작성 (원칙 7 구체화) |

---

**🎯 이 문서를 읽고 답할 수 있어야 함:**
- 3대 축은? → Logging / Auto-Diagnosis / Time-Travel
- 필수 로그 테이블 4종은? → execution_log / competitor_activity_log / diagnosis_log / failure_patterns
- auditor 에이전트 하는 일은? → 매일/매주 로그 분석 → 제안 → 주데이 승인
- 되돌리기 기본 단위는? → 단일 입찰 (snapshot 기반)
