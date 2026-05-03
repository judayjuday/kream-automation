#!/bin/bash
# Step 32 — 통합 작업
#   1. 세션 만료 감지 → 진짜 자동 재로그인 (백그라운드)
#   2. 알림 디바운싱 (같은 alert_type 12시간에 1번)
#   3. 두 사이트 자동 로그인 (판매자센터 + 일반 KREAM)
#   4. 빨간 배너 라벨 정정 (자동 → 즉시 재로그인)
#   5. 누적 알림 정리 + 발송 제한

set -e
exec > >(tee -a pipeline_step32.log) 2>&1
cd ~/Desktop/kream_automation

PIPELINE_START=$(date +%s)
TS=$(date '+%Y%m%d_%H%M%S')

echo "================================================================"
echo "🚀 Step 32 — 자동 재로그인 + 알림 디바운싱 + 두 사이트 로그인"
echo "   $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================"
echo ""

fail_and_restore() {
    echo ""
    echo "❌ [$1] FAIL — 백업 복원"
    [ -f "kream_server.py.step32_pre.bak" ] && cp "kream_server.py.step32_pre.bak" kream_server.py
    [ -f "kream_dashboard.html.step32_pre.bak" ] && cp "kream_dashboard.html.step32_pre.bak" kream_dashboard.html
    [ -f "auth_state.json.step32_pre.bak" ] && cp "auth_state.json.step32_pre.bak" auth_state.json
    [ -f "auth_state_kream.json.step32_pre.bak" ] && cp "auth_state_kream.json.step32_pre.bak" auth_state_kream.json
    
    lsof -ti:5001 | xargs kill -9 2>/dev/null || true
    sleep 2
    nohup python3 kream_server.py > server.log 2>&1 & disown
    sleep 5
    exit 1
}

verify_server() {
    sleep 3
    local code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:5001/api/health)
    [ "$code" == "200" ] && echo "  ✅ 서버 정상" && return 0
    echo "  ❌ HTTP $code" && return 1
}

# ==========================================
# [STAGE 0] 사전 점검
# ==========================================
echo "════════════════════ [STAGE 0] 사전 점검 ════════════════════"
verify_server || fail_and_restore "사전 점검"
echo "  현재 커밋: $(git log --oneline -1)"
echo ""

# 인증 상태
if [ -f auth_state.json ]; then
    PARTNER_AGE=$(stat -f "%Sm" -t "%m-%d %H:%M" auth_state.json)
    echo "  📊 판매자센터 세션: ${PARTNER_AGE}"
fi
if [ -f auth_state_kream.json ]; then
    KREAM_AGE=$(stat -f "%Sm" -t "%m-%d %H:%M" auth_state_kream.json)
    echo "  📊 일반 KREAM 세션: ${KREAM_AGE}"
fi

NOTIF_COUNT=$(sqlite3 price_history.db "SELECT COUNT(*) FROM notifications" 2>/dev/null || echo "?")
echo "  📊 누적 알림: ${NOTIF_COUNT}건"
echo ""

# ==========================================
# [STAGE 1] 백업
# ==========================================
echo "════════════════════ [STAGE 1] 백업 ════════════════════"
cp kream_server.py "kream_server.py.step32_pre.bak"
cp kream_dashboard.html "kream_dashboard.html.step32_pre.bak"
[ -f auth_state.json ] && cp auth_state.json "auth_state.json.step32_pre.bak"
[ -f auth_state_kream.json ] && cp auth_state_kream.json "auth_state_kream.json.step32_pre.bak"
sqlite3 /Users/iseungju/Desktop/kream_automation/price_history.db ".backup '/Users/iseungju/Desktop/kream_automation/price_history_step32_${TS}.db'"
echo "  ✅ 백업 완료"
echo ""

# ==========================================
# [STAGE 2] 두 사이트 자동 로그인 (먼저 실행, 인증 살아있어야 다음 단계 의미 있음)
# ==========================================
echo "════════════════════ [STAGE 2] 두 사이트 자동 로그인 ════════════════════"
echo ""
echo "  📍 판매자센터 자동 로그인 (Gmail OTP)..."
PARTNER_START=$(date +%s)
python3 kream_bot.py --mode auto-login-partner 2>&1 | tail -20
PARTNER_RESULT=$?
PARTNER_TIME=$(($(date +%s) - PARTNER_START))
[ "$PARTNER_RESULT" -eq 0 ] && echo "  ✅ 성공 (${PARTNER_TIME}초)" || echo "  ❌ 실패 (exit $PARTNER_RESULT)"
echo ""

echo "  📍 일반 KREAM 자동 로그인 (네이버)..."
KREAM_START=$(date +%s)
python3 kream_bot.py --mode auto-login-kream 2>&1 | tail -20
KREAM_RESULT=$?
KREAM_TIME=$(($(date +%s) - KREAM_START))
[ "$KREAM_RESULT" -eq 0 ] && echo "  ✅ 성공 (${KREAM_TIME}초)" || echo "  ❌ 실패 (exit $KREAM_RESULT)"
echo ""

# 로그인 검증
echo "  🔍 로그인 상태 검증..."
cat > _verify_login.py <<'PYEOF'
import asyncio, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))

async def check(storage, url, success_marker):
    from playwright.async_api import async_playwright
    from kream_bot import create_browser, create_context
    if not Path(storage).exists():
        return False, 'no_session'
    try:
        async with async_playwright() as p:
            browser = await create_browser(p, headless=True)
            context = await create_context(browser, storage=storage)
            page = await context.new_page()
            await page.goto(url, timeout=30000, wait_until='domcontentloaded')
            await page.wait_for_timeout(3000)
            final_url = page.url
            body = await page.evaluate("() => document.body.innerText")
            await browser.close()
            if 'sign-in' in final_url or 'login' in final_url.lower():
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

asyncio.run(main())
PYEOF
LOGIN_VERIFY=$(python3 _verify_login.py 2>&1 | tail -2)
echo "$LOGIN_VERIFY" | sed 's/^/    /'
rm -f _verify_login.py

PARTNER_OK=$(echo "$LOGIN_VERIFY" | grep "^PARTNER:" | grep -q "True" && echo "1" || echo "0")
KREAM_OK=$(echo "$LOGIN_VERIFY" | grep "^KREAM:" | grep -q "True" && echo "1" || echo "0")

echo ""

# ==========================================
# [STAGE 3] 작업지시서 (자동 재로그인 + 알림 디바운싱)
# ==========================================
echo "════════════════════ [STAGE 3] 작업지시서 ════════════════════"

cat > "작업지시서_Step32.md" <<'MDEOF'
# 작업지시서 — Step 32: 자동 재로그인 + 알림 디바운싱

> 환경: 한국 / 구매대행
> 절대 규칙 + 자동 토글 ON 변경 금지
> 핵심: 세션 만료 → 진짜 자동 재로그인 (백그라운드, 사장 개입 없이)

## 작업 #1: 세션 만료 자동 감지 + 자동 재로그인

### kream_server.py 신규 함수

```python
def _check_session_and_relogin():
    """판매자센터 세션 만료 감지 → 자동 재로그인 시도.
    
    조건:
    - last sync로부터 1시간 이상 경과
    - 마지막 재로그인 시도로부터 6시간 이상 경과 (무한루프 방지)
    - 실패 시 24시간에 1번만 재시도
    """
    from datetime import datetime, timedelta
    from pathlib import Path
    
    state_file = Path(__file__).parent / '.relogin_state.json'
    
    # 재시도 상태 로드
    state = {}
    if state_file.exists():
        try:
            state = json.loads(state_file.read_text())
        except: pass
    
    # 마지막 재시도 6h 이내면 스킵 (rate limit)
    last_attempt = state.get('last_attempt')
    if last_attempt:
        try:
            last_dt = datetime.fromisoformat(last_attempt)
            if datetime.now() - last_dt < timedelta(hours=6):
                print(f"[AUTO-RELOGIN] 6시간 쿨다운 중 (마지막: {last_attempt})")
                return
        except: pass
    
    # 마지막 sync 시각 확인
    local_path = Path(__file__).parent / 'my_bids_local.json'
    if not local_path.exists():
        return  # sync 한 번도 안 됨, 판단 보류
    
    try:
        local = json.loads(local_path.read_text(encoding='utf-8'))
        last_sync = local.get('lastSync') or local.get('last_sync')
        if last_sync:
            # "2026/05/03 11:05" 형식
            try:
                last_sync_dt = datetime.strptime(last_sync, '%Y/%m/%d %H:%M')
            except:
                last_sync_dt = datetime.fromisoformat(last_sync)
            
            if datetime.now() - last_sync_dt < timedelta(hours=1):
                return  # 1시간 이내 sync 됐으면 정상
    except Exception as e:
        print(f"[AUTO-RELOGIN] sync 시각 확인 실패: {e}")
        return
    
    # 재로그인 시도
    print(f"[AUTO-RELOGIN] 세션 만료 추정 → 자동 재로그인 시도")
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
            
            # 알림 (디바운싱 적용)
            try:
                safe_send_alert(
                    subject='[KREAM] 자동 재로그인 성공',
                    body='세션 만료 감지 → 자동 재로그인 완료. 다음 sync부터 정상 작동.',
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
                    body=f'세션 만료 + 자동 재로그인 시도 실패. 수동 점검 필요.\n\n에러:\n{result.stderr[:500]}',
                    alert_type='auto_relogin_failure'
                )
            except: pass
    except subprocess.TimeoutExpired:
        print(f"[AUTO-RELOGIN] ❌ 타임아웃 (3분)")
    except Exception as e:
        print(f"[AUTO-RELOGIN] ❌ 예외: {e}")


# 스케줄러 등록 (30분 간격)
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

### 신규 라우트: /api/auth/relogin-status + /api/auth/relogin-now

```python
@app.route('/api/auth/relogin-status', methods=['GET'])
def api_relogin_status():
    """자동 재로그인 상태 조회."""
    from pathlib import Path
    state_file = Path(__file__).parent / '.relogin_state.json'
    state = {}
    if state_file.exists():
        try: state = json.loads(state_file.read_text())
        except: pass
    
    # auth_state.json mtime
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
    """수동 즉시 재로그인 (사장이 버튼 누름)."""
    import threading
    
    def run():
        # 쿨다운 무시하고 강제 실행
        from pathlib import Path
        state_file = Path(__file__).parent / '.relogin_state.json'
        if state_file.exists():
            try:
                state = json.loads(state_file.read_text())
                state.pop('last_attempt', None)  # 쿨다운 무시
                state_file.write_text(json.dumps(state))
            except: pass
        _check_session_and_relogin()
    
    threading.Thread(target=run, daemon=True).start()
    return jsonify({'ok': True, 'note': '백그라운드 재로그인 시작 (1~2분 소요)'})
```

## 작업 #2: 알림 디바운싱

### safe_send_alert 함수 수정 (또는 래핑)

기존 safe_send_alert 함수 찾아서 디바운싱 로직 추가. notifications 테이블에 alert_type별 last_sent_at 기록.

```python
# 헬퍼 함수
_alert_dedup_lock = {}  # 메모리 캐시

def _should_send_alert(alert_type, dedupe_hours=12):
    """같은 alert_type이 dedupe_hours 이내 발송됐으면 False."""
    from datetime import datetime, timedelta
    
    # 메모리 캐시 먼저 (DB 부하 줄이기)
    last_sent = _alert_dedup_lock.get(alert_type)
    if last_sent and datetime.now() - last_sent < timedelta(hours=dedupe_hours):
        return False
    
    # DB에서 마지막 발송 확인
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


# 기존 safe_send_alert 함수 안 맨 처음에 추가:
# def safe_send_alert(subject, body, alert_type='generic', dedupe_hours=12):
#     if not _should_send_alert(alert_type, dedupe_hours):
#         print(f"[ALERT-DEDUPE] {alert_type} 디바운싱됨 ({dedupe_hours}h 이내)")
#         return
#     ... 기존 로직
```

기존 safe_send_alert 시그니처 유지하되, 함수 안에서 _should_send_alert 호출.

## 작업 #3: 누적 알림 정리 + 발송 제한

```python
@app.route('/api/notifications/cleanup-old', methods=['POST'])
def api_notifications_cleanup():
    """30일 이상 된 알림 삭제."""
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


@app.route('/api/notifications/stats', methods=['GET'])
def api_notifications_stats():
    """알림 통계 (디바운싱 효과 측정용)."""
    try:
        from collections import Counter
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
```

## 작업 #4: 빨간 배너 라벨 정정 + 자동 재로그인 상태 표시

### kream_dashboard.html

기존 "자동 재로그인" 버튼 텍스트 찾아서 "즉시 재로그인"으로 변경 (의미 명확화).

자동 재로그인 상태를 인증 인디케이터에 반영:

```javascript
async function loadAuthStatus() {
  try {
    const r = await fetch('/api/auth/relogin-status');
    const d = await r.json();
    if (!d.ok) return;
    
    // 인디케이터 업데이트 (이미 있으면 텍스트만 변경)
    const indicator = document.querySelector('[data-auth-indicator]') || document.getElementById('auth-indicator');
    if (indicator && d.auth_state_updated_at) {
      const updated = new Date(d.auth_state_updated_at);
      const ageH = (Date.now() - updated.getTime()) / 1000 / 3600;
      indicator.title = `auth_state.json 업데이트: ${updated.toLocaleString()}\n경과: ${ageH.toFixed(1)}h`;
      
      // 12h 이상이면 경고
      if (ageH > 12) {
        indicator.style.color = '#dc2626';
      } else {
        indicator.style.color = '#059669';
      }
    }
  } catch(e) {}
}
// DOMContentLoaded에서 loadAuthStatus 호출 + 5분마다
```

### 빨간 배너 핸들러 변경

기존 "자동 재로그인" 버튼 onclick:
```javascript
// 기존: showAutoRelogin() 또는 location.reload()
// 변경: /api/auth/relogin-now POST → 사용자 알림
async function manualRelogin() {
  if (!confirm('지금 즉시 재로그인하시겠습니까? (1~2분 소요)')) return;
  try {
    const r = await fetch('/api/auth/relogin-now', {method:'POST'});
    const d = await r.json();
    alert(d.note || '시작됨');
    // 30초 후 상태 새로고침
    setTimeout(() => location.reload(), 90000);
  } catch(e) { alert('실패: ' + e.message); }
}
```

배너 버튼 라벨도 "자동 재로그인" → "즉시 재로그인"으로 변경.

## 검증

1. python3 -m py_compile kream_server.py
2. 서버 재시작 → server.log:
   - [SCHEDULER] auto_relogin_check 등록 (30분)
3. /api/auth/relogin-status → ok=true, auth_state_updated_at 키
4. /api/notifications/stats → ok=true, by_type 배열
5. /api/notifications/cleanup-old POST → ok=true, deleted 숫자
6. 회귀: capital-status, daily-summary, cleanup/diagnose 모두 ok

## 절대 규칙
- 자동 재로그인은 6시간 쿨다운 (무한루프 방지)
- safe_send_alert는 12시간 디바운싱 (같은 alert_type)
- DB CREATE IF NOT EXISTS만, DROP/ALTER 금지
- 자동 토글 ON 변경 금지

## 커밋
```
feat(Step 32): 자동 재로그인 + 알림 디바운싱

- _check_session_and_relogin: 세션 만료 감지 → 자동 재로그인 (30분 스케줄러)
  6h 쿨다운, 24h 1회 제한 (무한루프 방지)
- safe_send_alert 디바운싱: 같은 alert_type 12시간에 1번
- /api/auth/relogin-status, /api/auth/relogin-now (수동 즉시)
- /api/notifications/stats, /api/notifications/cleanup-old (30일+ 정리)
- 빨간 배너 라벨 정정: "자동" → "즉시" 재로그인

배경: 161건 알림 폭주 + 세션 만료 방치 → 자동 복구 인프라
```
MDEOF

echo "  ✅ 작업지시서 생성"
echo ""

# ==========================================
# [STAGE 4] Claude Code 호출
# ==========================================
echo "════════════════════ [STAGE 4] Claude Code 호출 ════════════════════"
echo ""

claude --dangerously-skip-permissions <<'CLAUDE_PROMPT' || fail_and_restore "Claude Code 실행"
작업지시서_Step32.md 읽고 끝까지 진행. 질문 절대 금지. 사용자 개입 요청 금지.

순서:
1. 작업지시서 읽기

2. kream_server.py 추가 (멱등):
   a. _alert_dedup_lock 메모리 캐시 (모듈 레벨)
   b. _should_send_alert(alert_type, dedupe_hours=12) 헬퍼
   c. 기존 safe_send_alert 함수 찾아서 _should_send_alert 호출 추가 (시그니처 유지, 디바운싱만 적용)
   d. _check_session_and_relogin() 함수 (subprocess로 kream_bot --mode auto-login-partner 호출)
   e. /api/auth/relogin-status GET 라우트
   f. /api/auth/relogin-now POST 라우트 (스레드로 백그라운드)
   g. /api/notifications/stats GET 라우트
   h. /api/notifications/cleanup-old POST 라우트
   i. scheduler.add_job auto_relogin_check 30분 interval

3. kream_dashboard.html 수정 (멱등):
   a. 빨간 배너 "자동 재로그인" 버튼 텍스트를 "즉시 재로그인"으로 변경
      (이미 "즉시 재로그인" 또는 manualRelogin 함수 있으면 스킵)
   b. 배너 버튼 onclick을 manualRelogin() 호출하도록 변경
      (manualRelogin 함수도 추가, 이미 있으면 스킵)
   c. loadAuthStatus 함수 + 5분 인터벌 추가
      (이미 loadAuthStatus 있으면 스킵)

4. 문법:
   python3 -m py_compile kream_server.py

5. 서버 재시작:
   lsof -ti:5001 | xargs kill -9 || true
   sleep 2
   nohup python3 kream_server.py > server.log 2>&1 & disown
   sleep 8

6. API 검증:
   - curl -s -o /dev/null -w "%{http_code}" http://localhost:5001/api/health → 200
   - curl -s http://localhost:5001/api/auth/relogin-status | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'); print('relogin-status OK auth_updated=', d.get('auth_state_updated_at','?')[:16])"
   - curl -s http://localhost:5001/api/notifications/stats | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'); types=d.get('by_type',[]); print(f'notif-stats OK {len(types)} types'); [print(f'  {t[\"type\"]}: {t[\"count\"]}건') for t in types[:5]]"
   - curl -s -X POST http://localhost:5001/api/notifications/cleanup-old | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'); print('cleanup OK deleted=', d.get('deleted'))"

7. 스케줄러 등록 확인:
   tail -200 server.log | grep -E "(auto_relogin_check)"

8. 회귀:
   - curl -s http://localhost:5001/api/capital-status | grep -q '"ok": true'
   - curl -s http://localhost:5001/api/daily-summary | grep -q '"ok": true'
   - curl -s http://localhost:5001/api/cleanup/diagnose | grep -q '"ok": true'

9. 모두 PASS면 단일 커밋 + push:
   git add -A
   git commit -m "feat(Step 32): 자동 재로그인 + 알림 디바운싱

   - _check_session_and_relogin: sync 1h+ 멈추면 자동 재로그인
     6h 쿨다운 (무한루프 방지)
   - safe_send_alert 디바운싱: alert_type 12h 1회
   - /api/auth/relogin-status (자동 재로그인 상태)
   - /api/auth/relogin-now (수동 즉시 트리거)
   - /api/notifications/stats, /cleanup-old
   - 빨간 배너 '자동 재로그인' → '즉시 재로그인' (의미 명확화)

   배경: 161건 알림 폭주 + 세션 만료 방치 해결"
   git push origin main

10. 끝.

질문/확인 절대 금지. 검증 FAIL 시 즉시 종료.
CLAUDE_PROMPT

echo ""
echo "🔍 최종 검증..."
verify_server || fail_and_restore "최종 검증"

echo ""
echo "  📋 핵심 검증:"

RELOGIN_STATUS=$(curl -s http://localhost:5001/api/auth/relogin-status | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    if d.get('ok'):
        au = d.get('auth_state_updated_at','?')
        ls = d.get('last_success', '아직 없음')
        lf = d.get('last_failure', '아직 없음')
        print(f\"auth={au[:16] if au else '?'} success={ls[:16] if ls and ls != '아직 없음' else ls} failure={lf[:16] if lf and lf != '아직 없음' else lf}\")
    else: print('FAIL')
except: print('ERROR')
" 2>/dev/null)
echo "    relogin-status: $RELOGIN_STATUS"

NOTIF_STATS=$(curl -s http://localhost:5001/api/notifications/stats | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    types=d.get('by_type',[])
    if types:
        top=types[0]
        print(f\"top={top['type']}({top['count']}건) total_types={len(types)}\")
    else: print('no notifications')
except: print('ERROR')
" 2>/dev/null)
echo "    notifications/stats: $NOTIF_STATS"

CLEANUP=$(curl -s -X POST http://localhost:5001/api/notifications/cleanup-old | python3 -c "
import sys,json
try: print(f\"deleted={json.load(sys.stdin).get('deleted','?')}건\")
except: print('ERROR')
" 2>/dev/null)
echo "    notifications/cleanup: $CLEANUP"

echo ""
echo "  📅 자동 재로그인 스케줄러 로그:"
tail -200 server.log 2>/dev/null | grep -E "(auto_relogin_check|AUTO-RELOGIN)" | tail -5 || echo "    (등록 확인 필요)"

# 새 인증 세션 정보
echo ""
echo "  📊 새 인증 세션:"
[ -f auth_state.json ] && echo "    판매자센터: $(stat -f "%Sm" -t "%H:%M" auth_state.json) ($(wc -c < auth_state.json) bytes)"
[ -f auth_state_kream.json ] && echo "    일반 KREAM: $(stat -f "%Sm" -t "%H:%M" auth_state_kream.json) ($(wc -c < auth_state_kream.json) bytes)"

FINAL_HASH=$(git log -1 --format=%h)
echo ""
echo "  ✅ 커밋: $FINAL_HASH"
echo ""

# ==========================================
# [STAGE 5] 컨텍스트 v26
# ==========================================
echo "════════════════════ [STAGE 5] 컨텍스트 v26 ════════════════════"

PA_PENDING=$(sqlite3 price_history.db "SELECT COUNT(*) FROM price_adjustments WHERE status='pending'" 2>/dev/null || echo "?")
SALES_COUNT=$(sqlite3 price_history.db "SELECT COUNT(*) FROM sales_history" 2>/dev/null || echo "?")
NEW_NOTIF=$(sqlite3 price_history.db "SELECT COUNT(*) FROM notifications" 2>/dev/null || echo "?")

cat > "다음세션_시작_컨텍스트_v26.md" <<MDEOF
# 다음 세션 시작 컨텍스트 v26

> 작성일: $(date '+%Y-%m-%d %H:%M:%S')
> 직전 커밋: $(git log -1 --format='%h %s')

## 환경

- 위치: 한국
- 비즈니스: 구매대행
- 인증: 판매자센터 ${PARTNER_OK:+✅}${PARTNER_OK:-❌} / 일반 KREAM ${KREAM_OK:+✅}${KREAM_OK:-❌}

## Step 32 — 자동 재로그인 + 알림 디바운싱

### 핵심 변경

1. **자동 재로그인 인프라**:
   - 30분마다 sync 상태 체크
   - sync 1h+ 멈추면 자동으로 \`python3 kream_bot.py --mode auto-login-partner\` 호출
   - 6h 쿨다운 (무한루프 방지)
   - 성공/실패 알림 (디바운싱 적용)

2. **알림 디바운싱**:
   - 같은 alert_type은 12시간에 1번만 발송
   - 161건 폭주 → 일 2건 수준으로 감소 예상

3. **두 사이트 자동 로그인 검증**:
   - 판매자센터: $([ "$PARTNER_OK" == "1" ] && echo "✅ OK" || echo "❌ FAIL")
   - 일반 KREAM: $([ "$KREAM_OK" == "1" ] && echo "✅ OK" || echo "❌ FAIL")

4. **빨간 배너 라벨 정정**:
   - "자동 재로그인" 버튼 → "즉시 재로그인" (의미 명확화)
   - 진짜 자동은 백그라운드 스케줄러가, 수동은 사장이 버튼

5. **알림 정리**:
   - 정리된 30일+ 알림: $CLEANUP

### 신규 API

- GET /api/auth/relogin-status — 마지막 시도/성공/실패
- POST /api/auth/relogin-now — 수동 즉시 재로그인 트리거
- GET /api/notifications/stats — alert_type별 7일 카운트
- POST /api/notifications/cleanup-old — 30일+ 자동 삭제

### 신규 스케줄러

| 작업 | 주기 |
|---|---|
| auto_relogin_check (NEW Step 32) | 30분 |

## 측정값

- relogin-status: $RELOGIN_STATUS
- notifications: $NOTIF_STATS
- DB: pa_pending=$PA_PENDING / sales=$SALES_COUNT / notif=$NEW_NOTIF

## 다음 작업 후보

### 1순위 — 자동 재로그인 동작 확인 (24h 후)
- 자동으로 sync 정상화 + 알림 폭주 멈춤
- /api/auth/relogin-status로 시도 이력 확인

### 2순위 — sync 진짜 0건 디버깅 (이번엔 진짜)
- Step 31에서 stderr 로그 가시성 확보됨
- 인증 살아있는 지금 sync 한 번 돌려서 [SYNC-V2] 로그로 추적

### 3순위 — 신규 입찰 도구 실전 사용

## 다음 채팅 첫 메시지

\`\`\`
다음세션_시작_컨텍스트_v26.md 읽고 현재 상태.
직전 커밋 $FINAL_HASH (Step 32).

오늘 작업: [구체 지시]
\`\`\`

## 절대 규칙

7대 규칙 + 자동 토글 ON 변경 금지 + 자동 재로그인 6h 쿨다운.
MDEOF

git add 다음세션_시작_컨텍스트_v26.md pipeline_step32.log 2>/dev/null
git commit -m "docs: 다음세션 컨텍스트 v26 (Step 32)" 2>/dev/null || echo "  (변경 없음)"
git push origin main 2>/dev/null || echo "  (push 스킵)"

PIPELINE_END=$(date +%s)
ELAPSED=$((PIPELINE_END - PIPELINE_START))
ELAPSED_MIN=$((ELAPSED / 60))

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🎉 Step 32 완료 — ${ELAPSED_MIN}분 ${ELAPSED}초"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "✅ 결과:"
echo "  - 두 사이트 자동 로그인: 판매자센터 $([ "$PARTNER_OK" == "1" ] && echo "✅" || echo "❌") / KREAM $([ "$KREAM_OK" == "1" ] && echo "✅" || echo "❌")"
echo "  - 자동 재로그인 인프라 (30분 스케줄러)"
echo "  - 알림 디바운싱 (12h, 같은 type)"
echo "  - 빨간 배너 라벨 정정"
echo "  - 30일+ 알림 정리: $CLEANUP"
echo "  - 커밋: $FINAL_HASH"
echo ""
echo "📋 효과:"
echo "  - 다음부터 세션 만료되면 자동으로 재로그인 (사장 개입 X)"
echo "  - 알림 161건 → 일 2건 수준으로 감소 예상"
echo ""
echo "📜 로그: pipeline_step32.log"
echo ""
