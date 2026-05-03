# 작업지시서 — Step 32 v3

## 환경
- 한국, 구매대행
- 서버 정상 시작 안 될 수 있음 (좀비 PID 문제, 5001 포트 점유)
- 절대 규칙 + 자동 토글 ON 변경 금지

## 핵심 작업

### 작업 #1: 알림 정리

```python
# 1) 현재 상태 확인
import sqlite3
DB_PATH = '/Users/iseungju/Desktop/kream_automation/price_history.db'
conn = sqlite3.connect(DB_PATH)
c = conn.cursor()

c.execute("SELECT COUNT(*) FROM notifications")
total = c.fetchone()[0]

c.execute("SELECT COUNT(*) FROM notifications WHERE datetime(created_at) > datetime('now', '-7 days')")
recent7 = c.fetchone()[0]

c.execute("SELECT COUNT(*) FROM notifications WHERE datetime(created_at) > datetime('now', '-3 days')")
recent3 = c.fetchone()[0]

c.execute("SELECT COUNT(*) FROM notifications WHERE datetime(created_at) > datetime('now', '-1 day')")
recent1 = c.fetchone()[0]

print(f"전체 {total}건 / 최근 7일 {recent7}건 / 3일 {recent3}건 / 1일 {recent1}건")

# 2) 자동 판단: 최근 1일 50건 넘으면 폭주 → 1일치만 남김 / 아니면 7일치
if recent1 > 50:
    cutoff = '-1 day'
    keep_label = '1일치만'
elif recent7 > 100:
    cutoff = '-3 days'
    keep_label = '3일치만'
else:
    cutoff = '-30 days'
    keep_label = '30일치 유지'

c.execute(f"DELETE FROM notifications WHERE datetime(created_at) < datetime('now', '{cutoff}')")
deleted = c.rowcount
conn.commit()

c.execute("SELECT COUNT(*) FROM notifications")
after = c.fetchone()[0]
conn.close()

print(f"전략: {keep_label} → 삭제 {deleted}건 → 잔여 {after}건")
```

### 작업 #2: 디바운싱 패치

kream_server.py에서 `safe_send_alert` 함수 시그니처를 확인하고 (보통 `def safe_send_alert(subject, body, alert_type='generic', ...)`) — 그 정확한 시그니처에 맞춰 디바운싱 로직 추가.

**주의: 들여쓰기는 기존 코드와 정확히 일치해야 함 (탭 vs 스페이스 확인).**

순서:
1. `grep -n "def safe_send_alert" kream_server.py` 로 함수 위치 확인
2. 함수 정의 위에 `_alert_dedup_lock = {}` + `_should_send_alert_dedupe(alert_type, dedupe_hours=12)` 헬퍼 추가
3. `safe_send_alert` 함수 docstring 다음 첫 코드 라인 _직전에_ 디바운싱 체크 추가:

```python
    # Step 32 hotfix: 12h 디바운싱
    if not _should_send_alert_dedupe(alert_type, 12):
        print(f"[ALERT-DEDUPE] {alert_type} 디바운싱됨 (12h 이내)")
        return
```

들여쓰기 확인 필수. 들여쓰기 깨지면 IndentationError → 즉시 백업 복원하고 다른 방법으로 시도 (라우트 안에서 동적 patch 등).

### 작업 #3: 서버 재시작 + 검증

```bash
# 1) 5001 포트 정리 (좀비 강제)
lsof -nP -iTCP:5001 -sTCP:LISTEN 2>/dev/null | tail -n +2 | awk '{print $2}' | xargs -r kill -9 2>/dev/null
sleep 2

# 2) 시작
nohup python3 kream_server.py > server.log 2>&1 & disown
sleep 8

# 3) 검증
timeout 10 curl -s -o /dev/null -w "%{http_code}" http://localhost:5001/api/health
# 200 나와야 함, 아니면 server.log 30줄 확인 후 백업 복원

# 4) 디바운싱 적용 확인
timeout 10 curl -s http://localhost:5001/api/health | python3 -m json.tool
```

### 작업 #4: 디바운싱 동작 확인

서버 로그에 `[ALERT-DEDUPE]` 메시지 보이는지 확인 (5분 후 health_critical 체크 시점):

```bash
# 5분 안에 health_critical 알림 디바운싱 메시지 보일 것
# 일단은 로그 마지막 30줄로 확인
tail -30 server.log | grep -E "ALERT-DEDUPE|safe_send_alert"
```

### 작업 #5: 커밋

```bash
git add -A
git commit -m "fix(Step 32 v3): 알림 디바운싱 + 누적 정리

- safe_send_alert 12h 디바운싱 (alert_type별)
- 누적 알림 자동 정리 (폭주 시 1일치만 보존)
- 161건 → XX건 감소

배경: 161건 알림 폭주 hotfix"
git push origin main
```

## 절대 규칙
- 들여쓰기 깨지면 즉시 백업 복원
- 파일 편집 후 반드시 `python3 -m py_compile kream_server.py` 검증
- 자동 토글 ON 변경 금지

## 실패 시
- 알림 정리만 적용하고 디바운싱은 다음 채팅으로 미루기
- safe_send_alert가 복잡한 함수라면 monkey-patch 방식도 고려
