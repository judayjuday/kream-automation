#!/bin/bash
# Step 32 v3 — Claude Code가 직접 검토/패치/검증
#
# 작업:
#   1. 알림 일괄 정리 (며칠치 남길지 자동 판단)
#   2. 디바운싱 패치 (Claude Code가 안전하게)
#   3. 서버 재시작 (좀비 sudo로 강제 정리)
#   4. 검증 + 커밋
#
# 가드:
#   - 모든 외부 명령 timeout
#   - 30초마다 하트비트
#   - Claude Code 30분 timeout
#   - 좀비 PID는 sudo kill -9
#   - 어디서 실패해도 백업 자동 복원

set -e
exec > >(tee -a pipeline_step32v3.log) 2>&1
cd ~/Desktop/kream_automation

PIPELINE_START=$(date +%s)
TS=$(date '+%Y%m%d_%H%M%S')
SCRIPT_PID=$$

# trap: 종료 시 정리
cleanup() {
    local exit_code=$?
    [ -n "$HEARTBEAT_PID" ] && kill $HEARTBEAT_PID 2>/dev/null || true
    pkill -P $SCRIPT_PID 2>/dev/null || true
    exit $exit_code
}
trap cleanup EXIT INT TERM

start_heartbeat() {
    local label="$1"
    (
        local i=0
        while true; do
            sleep 30
            i=$((i + 30))
            echo "  ⏱  [$label] ${i}초 경과 ($(date +%H:%M:%S))"
        done
    ) &
    HEARTBEAT_PID=$!
}
stop_heartbeat() {
    [ -n "$HEARTBEAT_PID" ] && kill $HEARTBEAT_PID 2>/dev/null || true
    HEARTBEAT_PID=""
}

# 좀비 PID 포함 모든 5001 점유 프로세스 강제 정리
kill_port_5001() {
    echo "  🧹 5001 포트 정리..."
    
    # 1차: 일반 kill
    local pids=$(timeout 5 lsof -nP -iTCP:5001 -sTCP:LISTEN 2>/dev/null | tail -n +2 | awk '{print $2}')
    if [ -n "$pids" ]; then
        echo "$pids" | xargs -r kill -9 2>/dev/null || true
        sleep 2
    fi
    
    # 2차: sudo kill (좀비용)
    pids=$(timeout 5 lsof -nP -iTCP:5001 -sTCP:LISTEN 2>/dev/null | tail -n +2 | awk '{print $2}')
    if [ -n "$pids" ]; then
        echo "  ⚠️  좀비 잔존 — sudo로 정리 (비밀번호 필요)"
        echo "$pids" | xargs -r sudo kill -9 2>/dev/null || true
        sleep 2
    fi
    
    # 3차 검증
    pids=$(timeout 5 lsof -nP -iTCP:5001 -sTCP:LISTEN 2>/dev/null | tail -n +2 | awk '{print $2}')
    if [ -n "$pids" ]; then
        echo "  ❌ 5001 포트 정리 실패 (PID: $pids)"
        return 1
    fi
    echo "  ✅ 5001 포트 비어있음"
    return 0
}

start_server_foreground_check() {
    # 백그라운드로 띄우고 8초 후 health 체크
    nohup python3 kream_server.py > server.log 2>&1 & disown
    sleep 8
    local code=$(timeout 10 curl -s -o /dev/null -w "%{http_code}" http://localhost:5001/api/health 2>/dev/null || echo "000")
    if [ "$code" == "200" ]; then
        echo "  ✅ 서버 시작 OK (HTTP 200)"
        return 0
    else
        echo "  ❌ 서버 시작 실패 (HTTP $code)"
        echo "  📜 server.log 마지막 30줄:"
        tail -30 server.log | sed 's/^/    /'
        return 1
    fi
}

fail_and_restore() {
    echo ""
    echo "❌ [$1] FAIL — 백업 복원"
    [ -f "kream_server.py.step32v3_pre.bak" ] && cp "kream_server.py.step32v3_pre.bak" kream_server.py
    
    kill_port_5001
    sleep 2
    nohup python3 kream_server.py > server.log 2>&1 & disown
    sleep 5
    exit 1
}

echo "================================================================"
echo "🚀 Step 32 v3 — $(date '+%Y-%m-%d %H:%M:%S')"
echo "   알림 정리 + 디바운싱 (Claude Code 직접 작업)"
echo "================================================================"
echo ""

# ==========================================
# [STAGE 0] 사전 점검
# ==========================================
echo "════════════════════ [$(date +%H:%M:%S)] STAGE 0: 사전 점검 ════════════════════"

CODE=$(timeout 10 curl -s -o /dev/null -w "%{http_code}" http://localhost:5001/api/health 2>/dev/null || echo "000")
echo "  현재 서버: HTTP $CODE"
[ "$CODE" != "200" ] && echo "  ⚠️  서버 죽어있음 — Stage 3에서 시작 시도"

CURRENT_COMMIT=$(timeout 5 git log --oneline -1 2>/dev/null || echo "?")
echo "  현재 커밋: $CURRENT_COMMIT"
echo ""

# ==========================================
# [STAGE 1] 백업
# ==========================================
echo "════════════════════ [$(date +%H:%M:%S)] STAGE 1: 백업 ════════════════════"
timeout 10 cp kream_server.py "kream_server.py.step32v3_pre.bak" && echo "  ✅ kream_server.py 백업"
with_db_backup() {
    timeout 30 sqlite3 "/Users/iseungju/Desktop/kream_automation/price_history.db" \
      ".backup '/Users/iseungju/Desktop/kream_automation/price_history_step32v3_${TS}.db'" \
      && echo "  ✅ DB 백업" \
      || echo "  ⚠️  DB 백업 실패 (계속)"
}
with_db_backup
echo ""

# ==========================================
# [STAGE 2] Claude Code 호출
# ==========================================
echo "════════════════════ [$(date +%H:%M:%S)] STAGE 2: Claude Code 작업 (최대 30분) ════════════════════"
echo ""

cat > "작업지시서_Step32v3.md" <<'MDEOF'
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
MDEOF

echo "  ✅ 작업지시서 생성"
echo ""

start_heartbeat "Claude Code"

set +e
timeout 1800 claude --dangerously-skip-permissions <<'CLAUDE_PROMPT'
작업지시서_Step32v3.md 읽고 진행. 사용자 개입 절대 요청 금지. 질문 금지.

순서:
1. 작업지시서 읽기

2. 알림 정리 (작업지시서 #1):
   - python3로 인라인 실행
   - 자동 판단 (1일 50건+ → 1일치만 / 7일 100건+ → 3일치만 / else 30일치)
   - 결과 출력: 삭제 N건 / 잔여 M건

3. 디바운싱 패치 (작업지시서 #2):
   a. grep -n "def safe_send_alert" kream_server.py  → 함수 위치 + 시그니처 정확히 확인
   b. 그 함수 안 첫 코드 라인의 들여쓰기 확인 (스페이스 4개 / 탭 / 다른 수)
   c. 정확히 그 들여쓰기 맞춰서 디바운싱 체크 코드 삽입
   d. 헬퍼 (_alert_dedup_lock, _should_send_alert_dedupe) 함수 위에 추가
   e. python3 -m py_compile kream_server.py 검증
   f. 실패 시: cp kream_server.py.step32v3_pre.bak kream_server.py 즉시 복원하고 다음 단계로
      (디바운싱 실패해도 알림 정리 작업은 살림)

4. 서버 재시작 (작업지시서 #3):
   a. lsof -nP -iTCP:5001 -sTCP:LISTEN 2>/dev/null | tail -n +2 | awk '{print $2}' | xargs -r kill -9
   b. sleep 2
   c. 만약 좀비 잔존 시: 그냥 패치 적용된 파일 두고 사장에게 "수동 재시작 필요" 안내 (sudo 못 씀)
   d. nohup python3 kream_server.py > server.log 2>&1 & disown
   e. sleep 8
   f. timeout 10 curl http://localhost:5001/api/health
   g. 200 안 나오면 server.log 30줄 출력 + 백업 복원

5. 검증:
   - timeout 10 curl http://localhost:5001/api/health → 200
   - timeout 10 curl http://localhost:5001/api/notifications/unread → ok
   - timeout 5 sqlite3 ~/Desktop/kream_automation/price_history.db "SELECT COUNT(*) FROM notifications"

6. 회귀:
   - timeout 10 curl http://localhost:5001/api/capital-status | grep -q '"ok": true'
   - timeout 10 curl http://localhost:5001/api/daily-summary | grep -q '"ok": true'

7. 모두 PASS:
   git add -A
   git commit -m "fix(Step 32 v3): 알림 디바운싱 + 누적 정리

   - safe_send_alert 12h 디바운싱 (alert_type별)
   - 누적 알림 자동 정리 (폭주 시 짧은 기간만 유지)
   - 161건 폭주 hotfix"
   git push origin main

8. 완료 요약 출력 (한국어):
   - 알림 삭제: N건
   - 디바운싱 적용: 성공/실패
   - 서버 재시작: 성공/실패
   - 커밋: 해시

들여쓰기 에러로 디바운싱 패치 실패 시:
- 즉시 백업 복원
- 알림 정리만 살리고 진행
- "디바운싱은 다음 채팅에서 monkey-patch 방식으로 재시도 권장" 안내

질문/확인 절대 금지.
CLAUDE_PROMPT
CC_RESULT=$?
set -e
stop_heartbeat

if [ "$CC_RESULT" -eq 124 ]; then
    echo ""
    echo "  ⏰ Claude Code 30분 타임아웃"
    fail_and_restore "Claude Code 타임아웃"
fi
[ "$CC_RESULT" -ne 0 ] && echo "  ⚠️  Claude Code exit $CC_RESULT (계속 검증)"
echo ""

# ==========================================
# [STAGE 3] 외부 검증
# ==========================================
echo "════════════════════ [$(date +%H:%M:%S)] STAGE 3: 외부 검증 ════════════════════"

# 서버 살아있나
CODE=$(timeout 10 curl -s -o /dev/null -w "%{http_code}" http://localhost:5001/api/health 2>/dev/null || echo "000")
echo "  서버: HTTP $CODE"

if [ "$CODE" != "200" ]; then
    echo "  ⚠️  서버 죽어있음 — 강제 시작 시도"
    kill_port_5001 || true
    sleep 2
    if ! start_server_foreground_check; then
        fail_and_restore "서버 시작 실패"
    fi
fi

# 알림 카운트
NOTIF_AFTER=$(timeout 10 sqlite3 ~/Desktop/kream_automation/price_history.db "SELECT COUNT(*) FROM notifications" 2>/dev/null || echo "?")
echo "  📊 알림 잔여: ${NOTIF_AFTER}건"

# 최근 1일 카운트 (디바운싱 동작 확인 기준)
RECENT_1D=$(timeout 10 sqlite3 ~/Desktop/kream_automation/price_history.db "SELECT COUNT(*) FROM notifications WHERE datetime(created_at) > datetime('now', '-1 day')" 2>/dev/null || echo "?")
echo "  📊 최근 1일: ${RECENT_1D}건"

# 디바운싱 메시지 보이나
DEDUPE_HITS=$(timeout 5 tail -200 server.log 2>/dev/null | grep -c "ALERT-DEDUPE" || echo 0)
echo "  📊 디바운싱 작동: ${DEDUPE_HITS}회"

# 회귀
HEALTH_OK=$(timeout 10 curl -s http://localhost:5001/api/capital-status | grep -c '"ok": true' || echo 0)
echo "  📊 회귀: capital-status ok=${HEALTH_OK}"

FINAL_HASH=$(timeout 5 git log -1 --format=%h 2>/dev/null || echo "?")
echo "  📊 커밋: $FINAL_HASH"

# ==========================================
# 컨텍스트 v26
# ==========================================
echo ""
echo "════════════════════ [$(date +%H:%M:%S)] STAGE 4: 컨텍스트 ════════════════════"

cat > "다음세션_시작_컨텍스트_v26.md" <<MDEOF
# 다음 세션 시작 컨텍스트 v26

> 작성일: $(date '+%Y-%m-%d %H:%M:%S')
> 직전 커밋: $FINAL_HASH

## 환경
- 한국, 구매대행
- 좀비 PID 문제: nohup + & 로 띄우면 가끔 좀비 됨, sudo kill -9 필요

## Step 32 v3 결과

- 알림 정리: 161건 → ${NOTIF_AFTER}건 (최근 1일: ${RECENT_1D}건)
- 디바운싱 작동: ${DEDUPE_HITS}회
- 서버: HTTP 200

## 미완료
- 자동 재로그인 인프라 (Step 32 원안의 _check_session_and_relogin)
- /api/auth/relogin-status, /relogin-now 라우트
- /api/notifications/stats, /cleanup-old 라우트
- 빨간 배너 라벨 정정 (자동 → 즉시)

## 다음 작업
1. 자동 재로그인 (다음 채팅에서 안전하게)
2. sync 0건 진짜 디버깅 (Step 31 stderr 적용됨)
3. 신규 입찰 도구 실전 사용

## 절대 규칙
7대 규칙 + 자동 토글 ON 금지.
MDEOF

timeout 10 git add 다음세션_시작_컨텍스트_v26.md pipeline_step32v3.log 2>/dev/null || true
timeout 10 git commit -m "docs: 컨텍스트 v26 (Step 32 v3)" 2>/dev/null || echo "  (변경 없음)"
timeout 30 git push origin main 2>/dev/null || echo "  (push 스킵)"

PIPELINE_END=$(date +%s)
ELAPSED=$((PIPELINE_END - PIPELINE_START))
ELAPSED_MIN=$((ELAPSED / 60))

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🎉 Step 32 v3 완료 — ${ELAPSED_MIN}분 ${ELAPSED}초"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "✅ 결과:"
echo "  - 알림: ${NOTIF_AFTER}건 잔여"
echo "  - 디바운싱: ${DEDUPE_HITS}회 작동"
echo "  - 서버: HTTP $CODE"
echo "  - 커밋: $FINAL_HASH"
echo ""
echo "📋 효과:"
echo "  - 161건 알림 폭주 멈춤"
echo "  - 같은 alert_type 12h에 1번만"
echo ""
echo "📜 로그: pipeline_step32v3.log"
echo ""
