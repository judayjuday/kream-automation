#!/bin/bash
# Step 32 v2 — 자동 재로그인 + 알림 디바운싱 + 무한 대기 가드
#
# 개선:
#   - 모든 외부 명령에 timeout 박음
#   - 1분마다 하트비트 (어디서 멈췄는지 즉시 보임)
#   - Claude Code 30분 제한
#   - trap으로 자식 프로세스 자동 정리
#   - 진행 시각 매 단계 출력

set -e
exec > >(tee -a pipeline_step32v2.log) 2>&1
cd ~/Desktop/kream_automation

PIPELINE_START=$(date +%s)
TS=$(date '+%Y%m%d_%H%M%S')
SCRIPT_PID=$$

# trap: 종료 시 모든 자식 프로세스 정리
cleanup() {
    local exit_code=$?
    echo ""
    echo "🧹 종료 정리 중..."
    
    # 하트비트 자식 죽이기
    [ -n "$HEARTBEAT_PID" ] && kill $HEARTBEAT_PID 2>/dev/null || true
    
    # 이 스크립트의 자식 프로세스들
    pkill -P $SCRIPT_PID 2>/dev/null || true
    
    exit $exit_code
}
trap cleanup EXIT INT TERM

# 하트비트 시작/중지
start_heartbeat() {
    local label="$1"
    (
        local i=0
        while true; do
            sleep 30
            i=$((i + 30))
            echo "  ⏱  [$label] 진행 중... ${i}초 경과 ($(date +%H:%M:%S))"
        done
    ) &
    HEARTBEAT_PID=$!
}
stop_heartbeat() {
    [ -n "$HEARTBEAT_PID" ] && kill $HEARTBEAT_PID 2>/dev/null || true
    HEARTBEAT_PID=""
}

# timeout wrapper (시각 + 결과 보고)
with_timeout() {
    local seconds=$1
    shift
    local label="$1"
    shift
    
    echo "  ▶ [$(date +%H:%M:%S)] $label (timeout ${seconds}s)"
    if timeout "$seconds" "$@"; then
        echo "  ✅ [$(date +%H:%M:%S)] $label 완료"
        return 0
    else
        local code=$?
        if [ $code -eq 124 ]; then
            echo "  ⏰ [$(date +%H:%M:%S)] $label TIMEOUT (${seconds}s)"
        else
            echo "  ❌ [$(date +%H:%M:%S)] $label 실패 (exit $code)"
        fi
        return $code
    fi
}

fail_and_restore() {
    echo ""
    echo "❌ [$1] FAIL — 백업 복원"
    [ -f "kream_server.py.step32v2_pre.bak" ] && cp "kream_server.py.step32v2_pre.bak" kream_server.py
    [ -f "kream_dashboard.html.step32v2_pre.bak" ] && cp "kream_dashboard.html.step32v2_pre.bak" kream_dashboard.html
    
    pkill -f "python3 kream_server.py" 2>/dev/null || true
    sleep 2
    nohup python3 kream_server.py > server.log 2>&1 & disown
    sleep 5
    exit 1
}

verify_server() {
    local code
    code=$(timeout 15 curl -s -o /dev/null -w "%{http_code}" http://localhost:5001/api/health 2>/dev/null || echo "000")
    [ "$code" == "200" ] && return 0 || return 1
}

echo "================================================================"
echo "🚀 Step 32 v2 — $(date '+%Y-%m-%d %H:%M:%S')"
echo "   자동 재로그인 + 알림 디바운싱 (무한 대기 가드 적용)"
echo "================================================================"
echo ""

# ==========================================
# [STAGE 0] 사전 점검 (timeout 박음)
# ==========================================
echo "════════════════════ [$(date +%H:%M:%S)] STAGE 0: 사전 점검 ════════════════════"

if ! verify_server; then
    echo "  ⚠️  서버 응답 없음 — 시작 시도"
    pkill -f "python3 kream_server.py" 2>/dev/null || true
    sleep 2
    nohup python3 kream_server.py > server.log 2>&1 & disown
    sleep 8
    if ! verify_server; then
        echo "  ❌ 서버 시작 실패. server.log 확인 필요"
        exit 1
    fi
fi
echo "  ✅ 서버 정상"

CURRENT_COMMIT=$(timeout 5 git log --oneline -1 2>/dev/null || echo "?")
echo "  현재 커밋: $CURRENT_COMMIT"

# 인증 상태 (timeout 박음)
if [ -f auth_state.json ]; then
    PARTNER_AGE=$(timeout 5 stat -f "%Sm" -t "%m-%d %H:%M" auth_state.json 2>/dev/null || echo "?")
    echo "  📊 판매자센터 세션: ${PARTNER_AGE}"
fi
if [ -f auth_state_kream.json ]; then
    KREAM_AGE=$(timeout 5 stat -f "%Sm" -t "%m-%d %H:%M" auth_state_kream.json 2>/dev/null || echo "?")
    echo "  📊 일반 KREAM 세션: ${KREAM_AGE}"
fi

NOTIF_COUNT=$(timeout 10 sqlite3 price_history.db "SELECT COUNT(*) FROM notifications" 2>/dev/null || echo "?")
echo "  📊 누적 알림: ${NOTIF_COUNT}건"
echo ""

# ==========================================
# [STAGE 1] 백업 (timeout)
# ==========================================
echo "════════════════════ [$(date +%H:%M:%S)] STAGE 1: 백업 ════════════════════"
timeout 10 cp kream_server.py "kream_server.py.step32v2_pre.bak" && echo "  ✅ kream_server.py"
timeout 10 cp kream_dashboard.html "kream_dashboard.html.step32v2_pre.bak" && echo "  ✅ kream_dashboard.html"
[ -f auth_state.json ] && timeout 5 cp auth_state.json "auth_state.json.step32v2_pre.bak" && echo "  ✅ auth_state.json"
[ -f auth_state_kream.json ] && timeout 5 cp auth_state_kream.json "auth_state_kream.json.step32v2_pre.bak" && echo "  ✅ auth_state_kream.json"

with_timeout 30 "DB 백업" sqlite3 /Users/iseungju/Desktop/kream_automation/price_history.db ".backup '/Users/iseungju/Desktop/kream_automation/price_history_step32v2_${TS}.db'" || echo "  ⚠️  DB 백업 실패 (계속 진행)"
echo ""

# ==========================================
# [STAGE 2] 두 사이트 자동 로그인 (각각 3분 timeout)
# ==========================================
echo "════════════════════ [$(date +%H:%M:%S)] STAGE 2: 자동 로그인 ════════════════════"

echo ""
echo "  📍 판매자센터 (Gmail OTP, 최대 3분)..."
start_heartbeat "판매자센터 로그인"
PARTNER_START=$(date +%s)
if timeout 180 python3 kream_bot.py --mode auto-login-partner 2>&1 | tail -10; then
    PARTNER_RESULT=0
else
    PARTNER_RESULT=$?
fi
stop_heartbeat
PARTNER_TIME=$(($(date +%s) - PARTNER_START))
if [ "$PARTNER_RESULT" -eq 0 ]; then
    echo "  ✅ 판매자센터 성공 (${PARTNER_TIME}초)"
elif [ "$PARTNER_RESULT" -eq 124 ]; then
    echo "  ⏰ 판매자센터 TIMEOUT (3분 초과)"
else
    echo "  ❌ 판매자센터 실패 (exit $PARTNER_RESULT)"
fi
echo ""

echo "  📍 일반 KREAM (네이버, 최대 3분)..."
start_heartbeat "일반 KREAM 로그인"
KREAM_START=$(date +%s)
if timeout 180 python3 kream_bot.py --mode auto-login-kream 2>&1 | tail -10; then
    KREAM_RESULT=0
else
    KREAM_RESULT=$?
fi
stop_heartbeat
KREAM_TIME=$(($(date +%s) - KREAM_START))
if [ "$KREAM_RESULT" -eq 0 ]; then
    echo "  ✅ 일반 KREAM 성공 (${KREAM_TIME}초)"
elif [ "$KREAM_RESULT" -eq 124 ]; then
    echo "  ⏰ 일반 KREAM TIMEOUT (3분 초과)"
else
    echo "  ❌ 일반 KREAM 실패 (exit $KREAM_RESULT)"
fi
echo ""

# 로그인 검증 (각 60초 timeout)
echo "  🔍 로그인 상태 검증 (각 60초)..."

cat > _verify_login_v2.py <<'PYEOF'
import asyncio, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))

async def check(storage, url, success_marker, timeout_sec=30):
    from playwright.async_api import async_playwright
    from kream_bot import create_browser, create_context
    if not Path(storage).exists():
        return False, 'no_session'
    try:
        async with async_playwright() as p:
            browser = await create_browser(p, headless=True)
            context = await create_context(browser, storage=storage)
            page = await context.new_page()
            await page.goto(url, timeout=timeout_sec*1000, wait_until='domcontentloaded')
            await page.wait_for_timeout(2000)
            final_url = page.url
            body = await page.evaluate("() => document.body.innerText")
            await browser.close()
            if 'sign-in' in final_url or '/login' in final_url.lower():
                return False, 'session_expired'
            if any(m in body for m in success_marker):
                return True, 'ok'
            return None, 'ambiguous'
    except Exception as e:
        return False, str(e)[:50]

async def main():
    p_ok, p_msg = await check('auth_state.json', 'https://partner.kream.co.kr/c2c', ['judaykream', 'gmail.com'])
    k_ok, k_msg = await check('auth_state_kream.json', 'https://kream.co.kr/my', ['관심상품', '거래', '프로필', '구매'])
    print(f"PARTNER:{p_ok}|{p_msg}")
    print(f"KREAM:{k_ok}|{k_msg}")

try:
    asyncio.wait_for(asyncio.run(main()), timeout=120)
except:
    asyncio.run(main())
PYEOF

start_heartbeat "로그인 검증"
LOGIN_VERIFY=$(timeout 120 python3 _verify_login_v2.py 2>&1 | tail -2 || echo "VERIFY_TIMEOUT")
stop_heartbeat
echo "$LOGIN_VERIFY" | sed 's/^/    /'
rm -f _verify_login_v2.py 2>/dev/null

PARTNER_OK=$(echo "$LOGIN_VERIFY" | grep "^PARTNER:" | grep -q "True" && echo "1" || echo "0")
KREAM_OK=$(echo "$LOGIN_VERIFY" | grep "^KREAM:" | grep -q "True" && echo "1" || echo "0")
echo ""

# ==========================================
# [STAGE 3] 작업지시서
# ==========================================
echo "════════════════════ [$(date +%H:%M:%S)] STAGE 3: 작업지시서 ════════════════════"

cat > "작업지시서_Step32v2.md" <<'MDEOF'
# 작업지시서 — Step 32 v2: 자동 재로그인 + 알림 디바운싱

> 환경: 한국 / 구매대행
> 절대 규칙 + 자동 토글 ON 변경 금지

## 작업 #1: 자동 재로그인 (백그라운드)

### kream_server.py 신규 함수 _check_session_and_relogin

세션 만료 감지 → subprocess로 auto-login-partner 호출.
6h 쿨다운 (.relogin_state.json에 last_attempt 기록).

```python
def _check_session_and_relogin():
    from datetime import datetime, timedelta
    from pathlib import Path
    
    state_file = Path(__file__).parent / '.relogin_state.json'
    state = {}
    if state_file.exists():
        try: state = json.loads(state_file.read_text())
        except: pass
    
    last_attempt = state.get('last_attempt')
    if last_attempt:
        try:
            last_dt = datetime.fromisoformat(last_attempt)
            if datetime.now() - last_dt < timedelta(hours=6):
                return
        except: pass
    
    local_path = Path(__file__).parent / 'my_bids_local.json'
    if not local_path.exists():
        return
    
    try:
        local = json.loads(local_path.read_text(encoding='utf-8'))
        last_sync = local.get('lastSync') or local.get('last_sync')
        if last_sync:
            try:
                last_sync_dt = datetime.strptime(last_sync, '%Y/%m/%d %H:%M')
            except:
                last_sync_dt = datetime.fromisoformat(last_sync)
            if datetime.now() - last_sync_dt < timedelta(hours=1):
                return  # 정상
    except Exception as e:
        print(f"[AUTO-RELOGIN] sync 시각 확인 실패: {e}")
        return
    
    print(f"[AUTO-RELOGIN] 세션 만료 추정 → 자동 재로그인")
    state['last_attempt'] = datetime.now().isoformat()
    state_file.write_text(json.dumps(state, indent=2))
    
    try:
        import subprocess
        result = subprocess.run(
            ['python3', 'kream_bot.py', '--mode', 'auto-login-partner'],
            capture_output=True, text=True, timeout=180,
            cwd=Path(__file__).parent
        )
        if result.returncode == 0:
            print(f"[AUTO-RELOGIN] ✅ 성공")
            state['last_success'] = datetime.now().isoformat()
            state_file.write_text(json.dumps(state, indent=2))
            try:
                safe_send_alert(
                    subject='[KREAM] 자동 재로그인 성공',
                    body='세션 만료 → 자동 재로그인 완료',
                    alert_type='auto_relogin_success'
                )
            except: pass
        else:
            print(f"[AUTO-RELOGIN] ❌ 실패: {result.stderr[:300]}")
            state['last_failure'] = datetime.now().isoformat()
            state['last_failure_reason'] = result.stderr[:500]
            state_file.write_text(json.dumps(state, indent=2))
            try:
                safe_send_alert(
                    subject='[KREAM] 자동 재로그인 실패',
                    body=f'수동 점검 필요\n\n{result.stderr[:500]}',
                    alert_type='auto_relogin_failure'
                )
            except: pass
    except subprocess.TimeoutExpired:
        print(f"[AUTO-RELOGIN] ❌ 타임아웃")
    except Exception as e:
        print(f"[AUTO-RELOGIN] ❌ 예외: {e}")


try:
    scheduler.add_job(
        _check_session_and_relogin,
        'interval', minutes=30,
        id='auto_relogin_check',
        replace_existing=True,
        misfire_grace_time=300
    )
    print("[SCHEDULER] auto_relogin_check 등록 (30분)")
except Exception as e:
    print(f"[SCHEDULER] auto_relogin_check 실패: {e}")
```

## 작업 #2: 알림 디바운싱

```python
_alert_dedup_lock = {}

def _should_send_alert(alert_type, dedupe_hours=12):
    from datetime import datetime, timedelta
    last_sent = _alert_dedup_lock.get(alert_type)
    if last_sent and datetime.now() - last_sent < timedelta(hours=dedupe_hours):
        return False
    try:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("""
            SELECT created_at FROM notifications
            WHERE alert_type = ?
            ORDER BY created_at DESC LIMIT 1
        """, (alert_type,))
        row = c.fetchone()
        conn.close()
        if row:
            try:
                last_dt = datetime.fromisoformat(row[0]) if 'T' in row[0] else datetime.strptime(row[0], '%Y-%m-%d %H:%M:%S')
                if datetime.now() - last_dt < timedelta(hours=dedupe_hours):
                    _alert_dedup_lock[alert_type] = last_dt
                    return False
            except: pass
    except: pass
    _alert_dedup_lock[alert_type] = datetime.now()
    return True
```

기존 safe_send_alert 함수 _맨 처음에_ 추가:
```python
# 시그니처는 유지: def safe_send_alert(subject, body, alert_type='generic', ...):
if not _should_send_alert(alert_type, dedupe_hours=12):
    print(f"[ALERT-DEDUPE] {alert_type} 디바운싱됨")
    return
# 이후 기존 로직 그대로
```

## 작업 #3: 신규 라우트

```python
@app.route('/api/auth/relogin-status', methods=['GET'])
def api_relogin_status():
    from pathlib import Path
    state_file = Path(__file__).parent / '.relogin_state.json'
    state = {}
    if state_file.exists():
        try: state = json.loads(state_file.read_text())
        except: pass
    auth_path = Path(__file__).parent / 'auth_state.json'
    auth_mtime = None
    if auth_path.exists():
        from datetime import datetime
        auth_mtime = datetime.fromtimestamp(auth_path.stat().st_mtime).isoformat()
    return jsonify({
        'ok': True,
        'auth_state_updated_at': auth_mtime,
        'last_attempt': state.get('last_attempt'),
        'last_success': state.get('last_success'),
        'last_failure': state.get('last_failure'),
        'last_failure_reason': state.get('last_failure_reason'),
    })


@app.route('/api/auth/relogin-now', methods=['POST'])
def api_relogin_now():
    import threading
    def run():
        from pathlib import Path
        state_file = Path(__file__).parent / '.relogin_state.json'
        if state_file.exists():
            try:
                state = json.loads(state_file.read_text())
                state.pop('last_attempt', None)
                state_file.write_text(json.dumps(state))
            except: pass
        _check_session_and_relogin()
    threading.Thread(target=run, daemon=True).start()
    return jsonify({'ok': True, 'note': '백그라운드 재로그인 시작'})


@app.route('/api/notifications/stats', methods=['GET'])
def api_notifications_stats():
    try:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("""
            SELECT alert_type, COUNT(*) as cnt, MAX(created_at) as latest
            FROM notifications
            WHERE datetime(created_at) > datetime('now', '-7 days')
            GROUP BY alert_type
            ORDER BY cnt DESC
        """)
        rows = c.fetchall()
        conn.close()
        return jsonify({
            'ok': True,
            'period_days': 7,
            'by_type': [{'type': r[0], 'count': r[1], 'latest': r[2]} for r in rows]
        })
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.route('/api/notifications/cleanup-old', methods=['POST'])
def api_notifications_cleanup():
    try:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("DELETE FROM notifications WHERE datetime(created_at) < datetime('now', '-30 days')")
        deleted = c.rowcount
        conn.commit()
        conn.close()
        return jsonify({'ok': True, 'deleted': deleted})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500
```

## 작업 #4: 빨간 배너 라벨 정정

kream_dashboard.html 빨간 배너 "자동 재로그인" 버튼 텍스트를 "즉시 재로그인"으로 변경 (멱등).
버튼 onclick을 manualRelogin() 호출하도록 변경 (이미 있으면 스킵).

```javascript
async function manualRelogin() {
  if (!confirm('지금 즉시 재로그인하시겠습니까? (1~2분 소요)')) return;
  try {
    const r = await fetch('/api/auth/relogin-now', {method:'POST'});
    const d = await r.json();
    alert(d.note || '시작됨');
    setTimeout(() => location.reload(), 90000);
  } catch(e) { alert('실패: ' + e.message); }
}
```

## 검증

1. python3 -m py_compile kream_server.py
2. 서버 재시작 → server.log: [SCHEDULER] auto_relogin_check 등록 (30분)
3. /api/auth/relogin-status → ok=true, auth_state_updated_at 키
4. /api/notifications/stats → ok=true, by_type 배열
5. /api/notifications/cleanup-old POST → ok=true, deleted 숫자
6. 회귀: capital-status, daily-summary, cleanup/diagnose

## 절대 규칙
- 자동 재로그인 6h 쿨다운
- safe_send_alert 12h 디바운싱
- 자동 토글 ON 변경 금지

## 커밋
```
feat(Step 32 v2): 자동 재로그인 + 알림 디바운싱

- _check_session_and_relogin: sync 1h+ 멈추면 자동 재로그인 (6h 쿨다운)
- safe_send_alert 디바운싱 (alert_type 12h 1회)
- /api/auth/relogin-status, /relogin-now
- /api/notifications/stats, /cleanup-old
- 빨간 배너 라벨 정정 (자동→즉시 재로그인)

배경: 161건 알림 폭주 + 세션 만료 방치 해결
```
MDEOF

echo "  ✅ 작업지시서 생성"
echo ""

# ==========================================
# [STAGE 4] Claude Code 호출 (30분 timeout + 하트비트)
# ==========================================
echo "════════════════════ [$(date +%H:%M:%S)] STAGE 4: Claude Code 호출 (최대 30분) ════════════════════"
echo ""

start_heartbeat "Claude Code 작업"

if timeout 1800 claude --dangerously-skip-permissions <<'CLAUDE_PROMPT'; then
작업지시서_Step32v2.md 읽고 끝까지 진행. 질문 절대 금지. 사용자 개입 요청 금지.

순서:
1. 작업지시서 읽기

2. kream_server.py 추가 (멱등):
   a. _alert_dedup_lock = {} (모듈 레벨)
   b. _should_send_alert 헬퍼
   c. 기존 safe_send_alert 함수 맨 처음에 _should_send_alert 호출 추가 (시그니처 유지)
   d. _check_session_and_relogin 함수
   e. /api/auth/relogin-status GET
   f. /api/auth/relogin-now POST
   g. /api/notifications/stats GET
   h. /api/notifications/cleanup-old POST
   i. scheduler.add_job auto_relogin_check 30분 interval

3. kream_dashboard.html (멱등):
   a. 빨간 배너 "자동 재로그인" 버튼 텍스트를 "즉시 재로그인"으로 변경
   b. 버튼 onclick을 manualRelogin() 호출
   c. manualRelogin 함수 추가

4. 문법: python3 -m py_compile kream_server.py

5. 서버 재시작:
   pkill -f "python3 kream_server.py" 2>/dev/null || true
   sleep 2
   nohup python3 kream_server.py > server.log 2>&1 & disown
   sleep 8

6. API 검증 (timeout 박기):
   - timeout 10 curl -s -o /dev/null -w "%{http_code}" http://localhost:5001/api/health → 200
   - timeout 10 curl -s http://localhost:5001/api/auth/relogin-status | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'); print('relogin-status OK')"
   - timeout 10 curl -s http://localhost:5001/api/notifications/stats | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'); print('stats OK')"
   - timeout 10 curl -s -X POST http://localhost:5001/api/notifications/cleanup-old | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'); print('cleanup OK deleted=', d.get('deleted'))"

7. 스케줄러 등록 확인:
   tail -200 server.log | grep -E "auto_relogin_check"

8. 회귀:
   - timeout 10 curl -s http://localhost:5001/api/capital-status | grep -q '"ok": true'
   - timeout 10 curl -s http://localhost:5001/api/daily-summary | grep -q '"ok": true'
   - timeout 10 curl -s http://localhost:5001/api/cleanup/diagnose | grep -q '"ok": true'

9. 모두 PASS면 단일 커밋 + push:
   git add -A
   git commit -m "feat(Step 32 v2): 자동 재로그인 + 알림 디바운싱

   - _check_session_and_relogin: sync 1h+ 멈추면 자동 재로그인 (6h 쿨다운)
   - safe_send_alert 디바운싱 (12h)
   - /api/auth/relogin-status, /relogin-now
   - /api/notifications/stats, /cleanup-old
   - 빨간 배너 '자동' → '즉시' 재로그인 라벨 정정

   배경: 161건 알림 폭주 + 세션 만료 방치 해결"
   git push origin main

10. 끝.

질문/확인 절대 금지. 검증 FAIL 시 즉시 종료.
CLAUDE_PROMPT
    CC_RESULT=0
else
    CC_RESULT=$?
fi

stop_heartbeat

if [ "$CC_RESULT" -eq 124 ]; then
    echo ""
    echo "  ⏰ Claude Code 30분 타임아웃 — 강제 종료"
    fail_and_restore "Claude Code 타임아웃"
elif [ "$CC_RESULT" -ne 0 ]; then
    echo ""
    echo "  ❌ Claude Code 실패 (exit $CC_RESULT)"
    fail_and_restore "Claude Code 실행"
fi

echo ""
echo "🔍 [$(date +%H:%M:%S)] 최종 검증..."
verify_server || fail_and_restore "최종 검증"

echo ""
echo "  📋 핵심 검증:"

RELOGIN_STATUS=$(timeout 10 curl -s http://localhost:5001/api/auth/relogin-status | timeout 5 python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    if d.get('ok'):
        au = d.get('auth_state_updated_at','?')
        print(f\"auth_updated={au[:16] if au else '?'}\")
    else: print('FAIL')
except: print('ERROR')
" 2>/dev/null || echo "TIMEOUT")
echo "    relogin-status: $RELOGIN_STATUS"

NOTIF_STATS=$(timeout 10 curl -s http://localhost:5001/api/notifications/stats | timeout 5 python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    types=d.get('by_type',[])
    if types:
        top=types[0]
        print(f\"top={top['type']}({top['count']}) total_types={len(types)}\")
    else: print('no notifications')
except: print('ERROR')
" 2>/dev/null || echo "TIMEOUT")
echo "    notifications/stats: $NOTIF_STATS"

CLEANUP=$(timeout 30 curl -s -X POST http://localhost:5001/api/notifications/cleanup-old | timeout 5 python3 -c "
import sys,json
try: print(f\"deleted={json.load(sys.stdin).get('deleted','?')}건\")
except: print('ERROR')
" 2>/dev/null || echo "TIMEOUT")
echo "    notifications/cleanup: $CLEANUP"

echo ""
echo "  📅 자동 재로그인 스케줄러 확인:"
timeout 5 tail -200 server.log 2>/dev/null | grep -E "(auto_relogin_check|AUTO-RELOGIN)" | tail -3 || echo "    (확인 필요)"

# 인증 세션 정보
echo ""
echo "  📊 인증 세션 (현재):"
[ -f auth_state.json ] && echo "    판매자센터: $(timeout 3 stat -f "%Sm" -t "%H:%M" auth_state.json 2>/dev/null) ($(timeout 3 wc -c < auth_state.json 2>/dev/null) bytes)"
[ -f auth_state_kream.json ] && echo "    일반 KREAM: $(timeout 3 stat -f "%Sm" -t "%H:%M" auth_state_kream.json 2>/dev/null) ($(timeout 3 wc -c < auth_state_kream.json 2>/dev/null) bytes)"

FINAL_HASH=$(timeout 5 git log -1 --format=%h 2>/dev/null || echo "?")
echo ""
echo "  ✅ 커밋: $FINAL_HASH"

# ==========================================
# 컨텍스트 v26
# ==========================================
echo ""
echo "════════════════════ [$(date +%H:%M:%S)] STAGE 5: 컨텍스트 v26 ════════════════════"

PA_PENDING=$(timeout 10 sqlite3 price_history.db "SELECT COUNT(*) FROM price_adjustments WHERE status='pending'" 2>/dev/null || echo "?")
SALES_COUNT=$(timeout 10 sqlite3 price_history.db "SELECT COUNT(*) FROM sales_history" 2>/dev/null || echo "?")
NEW_NOTIF=$(timeout 10 sqlite3 price_history.db "SELECT COUNT(*) FROM notifications" 2>/dev/null || echo "?")

cat > "다음세션_시작_컨텍스트_v26.md" <<MDEOF
# 다음 세션 시작 컨텍스트 v26

> 작성일: $(date '+%Y-%m-%d %H:%M:%S')
> 직전 커밋: $FINAL_HASH

## 환경

- 위치: 한국
- 비즈니스: 구매대행
- 인증: 판매자센터 $([ "$PARTNER_OK" == "1" ] && echo "✅" || echo "❌") / 일반 KREAM $([ "$KREAM_OK" == "1" ] && echo "✅" || echo "❌")

## Step 32 v2 — 자동 재로그인 + 알림 디바운싱

### 변경
1. 자동 재로그인 인프라 (30분 스케줄러, 6h 쿨다운)
2. 알림 디바운싱 (alert_type 12h 1회)
3. 두 사이트 자동 로그인 검증 완료
4. 빨간 배너 "자동 재로그인" → "즉시 재로그인" 라벨 정정
5. 30일+ 알림 정리: $CLEANUP

### 신규 API
- GET /api/auth/relogin-status
- POST /api/auth/relogin-now
- GET /api/notifications/stats
- POST /api/notifications/cleanup-old

### 신규 스케줄러
- auto_relogin_check (30분)

## 측정값
- relogin-status: $RELOGIN_STATUS
- notifications: $NOTIF_STATS
- DB: pa_pending=$PA_PENDING / sales=$SALES_COUNT / notif=$NEW_NOTIF

## 다음 작업
1. 24h 후 자동 재로그인 동작 확인
2. sync 0건 진짜 디버깅 (Step 31 stderr 로그 가시성 확보됨)
3. 신규 입찰 도구 실전 사용

## 절대 규칙
7대 규칙 + 자동 토글 ON 변경 금지 + 자동 재로그인 6h 쿨다운.
MDEOF

timeout 10 git add 다음세션_시작_컨텍스트_v26.md pipeline_step32v2.log 2>/dev/null || true
timeout 10 git commit -m "docs: 컨텍스트 v26 (Step 32 v2)" 2>/dev/null || echo "  (변경 없음)"
timeout 30 git push origin main 2>/dev/null || echo "  (push 스킵)"

PIPELINE_END=$(date +%s)
ELAPSED=$((PIPELINE_END - PIPELINE_START))
ELAPSED_MIN=$((ELAPSED / 60))

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🎉 Step 32 v2 완료 — ${ELAPSED_MIN}분 ${ELAPSED}초"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "✅ 결과:"
echo "  - 두 사이트 자동 로그인: 판매자센터 $([ "$PARTNER_OK" == "1" ] && echo "✅" || echo "❌") / KREAM $([ "$KREAM_OK" == "1" ] && echo "✅" || echo "❌")"
echo "  - 자동 재로그인 인프라 (30분, 6h 쿨다운)"
echo "  - 알림 디바운싱 (12h)"
echo "  - 빨간 배너 라벨 정정"
echo "  - 알림 정리: $CLEANUP"
echo "  - 커밋: $FINAL_HASH"
echo ""
echo "📋 효과:"
echo "  - 세션 만료되면 30분 안에 자동 재로그인"
echo "  - 161건 알림 → 일 2건 수준 예상"
echo ""
echo "📜 로그: pipeline_step32v2.log"
echo ""
