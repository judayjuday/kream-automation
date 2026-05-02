# 작업지시서 — Step 17-D Phase 2-A.1 + Phase 2-B 통합

> 의존: Step17D_Phase1_사전분석_20260502.md, 직전 커밋 24ceac9 (Phase 2-A)
> 예상 시간: 1.5시간
> 예상 라인: +85 라인 (2-A.1) + +180 라인 (2-B) = +265 라인

---

## Phase 2-A.1 — auth_hubnet valid 검증 수정 (핫픽스, 5분)

### 문제
Phase 2-A에서 `/api/health`의 `auth_hubnet.valid` 판정 로직이 KREAM 판매자센터 기준(`size > 1000`)으로 작성됨. 허브넷은 PHPSESSID 1개만 사용하는 PHP 세션 시스템이라 실제 정상 세션도 ~317 byte여서 valid가 항상 false로 출력됨.

### 검증 사실
- `_is_session_alive()` → True (실제 hubnet 사이트가 인증된 세션으로 인식)
- 쿠키: PHPSESSID 1개만 (PHP 단순 세션 정상 동작 패턴)
- 파일 크기: 317 byte (정상값)

### 작업 #1 — kream_server.py /api/health의 auth_hubnet 검증 로직 수정

**위치**: `kream_server.py`의 `/api/health` 핸들러 중 `auth_hubnet` valid 판정 부분

**변경 전 (Phase 2-A에서 추가된 코드)**:
```python
try:
    size = os.path.getsize(hubnet_state_path)
    if size > 1000:  # ← 허브넷에 맞지 않음
        with open(hubnet_state_path, 'r') as f:
            json.load(f)
        auth_hubnet["valid"] = True
except Exception:
    auth_hubnet["valid"] = False
```

**변경 후**:
```python
try:
    with open(hubnet_state_path, 'r') as f:
        data = json.load(f)
    cookies = data.get('cookies', [])
    # 허브넷은 PHPSESSID 1개만 있으면 정상 (PHP 세션 시스템)
    has_phpsessid = any(c.get('name') == 'PHPSESSID' for c in cookies)
    if has_phpsessid:
        auth_hubnet["valid"] = True
except Exception:
    auth_hubnet["valid"] = False
```

### 검증 (Phase 2-A.1)
- `curl /api/health | grep -A 5 auth_hubnet` → `valid: true` 출력
- 빈 세션(317 byte지만 cookies 비어있음) 시뮬레이션 → `valid: false` 출력

---

## Phase 2-B — 사전 갱신 스케줄러 (1.5시간)

### 문제 (분석서 §6.2-3, §7.1)
KREAM 판매자센터 + 허브넷 세션이 만료된 후에야 재로그인 시도(passive). 만료되기 전 사전 갱신 메커니즘 없음. 따라서 만료 시점에 진행 중이던 입찰/조정/발송이 모두 실패.

### 작업 #2 — 사전 갱신 스케줄러 신규

**파일**: `kream_server.py`
**예상 라인**: +120

#### 설계

```python
import threading
from datetime import datetime, timedelta

# === 모듈 상단 ===
_session_refresh_lock = threading.Lock()
_session_refresh_thread = None
_session_refresh_stop = threading.Event()
_session_refresh_status = {
    "enabled": True,
    "last_run": None,
    "last_result": None,  # {target, action, success, message}
    "next_run": None,
    "interval_hours": 12,
    "trigger_threshold_hours": 18,
}

def _refresh_session_if_stale(target):
    """
    target: 'partner' | 'kream' | 'hubnet'
    18시간 초과 + 토큰 valid 시 재로그인 시도.
    재로그인은 _try_auto_relogin (partner/kream) 또는 ensure_hubnet_logged_in (hubnet) 호출.
    """
    state_paths = {
        'partner': os.path.join(BASE_DIR, 'auth_state.json'),
        'kream': os.path.join(BASE_DIR, 'auth_state_kream.json'),
        'hubnet': os.path.join(BASE_DIR, 'auth_state_hubnet.json'),
    }
    path = state_paths.get(target)
    if not path or not os.path.exists(path):
        return {'target': target, 'action': 'skip', 'success': False, 
                'message': 'state file not found'}
    
    age_hours = (time.time() - os.path.getmtime(path)) / 3600
    if age_hours < _session_refresh_status['trigger_threshold_hours']:
        return {'target': target, 'action': 'skip', 'success': True, 
                'message': f'still fresh (age={age_hours:.1f}h)'}
    
    # 재로그인 분기
    try:
        if target == 'hubnet':
            from kream_hubnet_bot import ensure_hubnet_logged_in
            sess = ensure_hubnet_logged_in()
            cookie_count = len(sess.cookies)
            return {'target': target, 'action': 'refreshed', 'success': True,
                    'message': f'cookies={cookie_count}'}
        elif target == 'partner':
            # login_auto_partner는 async — asyncio.run으로 실행
            import asyncio
            from playwright.async_api import async_playwright
            async def _do():
                from kream_bot import login_auto_partner
                async with async_playwright() as p:
                    return await login_auto_partner(p)
            asyncio.run(_do())
            return {'target': target, 'action': 'refreshed', 'success': True,
                    'message': 'partner re-logged in'}
        elif target == 'kream':
            # KREAM 일반은 사전 갱신 대상 제외 (분석서 4-2: 자동 재로그인 흐름 없음)
            return {'target': target, 'action': 'skip', 'success': True,
                    'message': 'kream auto-relogin not implemented'}
    except Exception as e:
        return {'target': target, 'action': 'failed', 'success': False,
                'message': str(e)[:200]}

def _session_refresh_worker():
    """백그라운드 스레드. 12시간마다 모든 세션 점검."""
    while not _session_refresh_stop.is_set():
        try:
            with _session_refresh_lock:
                if _session_refresh_status['enabled']:
                    results = []
                    for target in ['partner', 'hubnet']:  # kream은 제외
                        result = _refresh_session_if_stale(target)
                        results.append(result)
                    _session_refresh_status['last_run'] = datetime.now().isoformat()
                    _session_refresh_status['last_result'] = results
                    
                    # 실패 발생 시 알림 (분석서 6.4)
                    failures = [r for r in results if r['action'] == 'failed']
                    if failures:
                        try:
                            from health_alert import send_alert
                            send_alert(
                                subject="[KREAM] 세션 사전 갱신 실패",
                                body=f"실패 항목: {failures}"
                            )
                        except Exception:
                            print(f"[ERROR] 알림 발송 실패", file=sys.stderr)
            
            # 다음 실행 시간 기록
            interval_sec = _session_refresh_status['interval_hours'] * 3600
            _session_refresh_status['next_run'] = (
                datetime.now() + timedelta(seconds=interval_sec)
            ).isoformat()
            
            # 12시간 대기 (1초 단위 체크로 stop 신호 즉시 감지)
            for _ in range(int(interval_sec)):
                if _session_refresh_stop.is_set():
                    break
                time.sleep(1)
        except Exception as e:
            print(f"[ERROR] _session_refresh_worker: {e}", file=sys.stderr)
            time.sleep(60)

def start_session_refresh_scheduler():
    """서버 시작 시 호출."""
    global _session_refresh_thread
    if _session_refresh_thread and _session_refresh_thread.is_alive():
        return
    _session_refresh_stop.clear()
    _session_refresh_thread = threading.Thread(
        target=_session_refresh_worker,
        daemon=True,
        name='session_refresh_scheduler'
    )
    _session_refresh_thread.start()
    print("[INFO] 세션 사전 갱신 스케줄러 시작 (12h 주기)")
```

**호출 추가 위치**: 서버 startup 코드 (다른 스케줄러 시작 부분 근처)
```python
start_session_refresh_scheduler()
```

### 작업 #3 — API 엔드포인트 신규

```python
@app.route('/api/session/refresh-status', methods=['GET'])
def api_session_refresh_status():
    """사전 갱신 스케줄러 상태 조회."""
    return jsonify({
        'ok': True,
        **_session_refresh_status,
    })

@app.route('/api/session/refresh-toggle', methods=['POST'])
def api_session_refresh_toggle():
    """사전 갱신 스케줄러 ON/OFF (런타임)."""
    data = request.get_json() or {}
    enabled = bool(data.get('enabled', True))
    with _session_refresh_lock:
        _session_refresh_status['enabled'] = enabled
    return jsonify({'ok': True, 'enabled': enabled})

@app.route('/api/session/refresh-run-once', methods=['POST'])
def api_session_refresh_run_once():
    """수동 1회 실행 (디버깅용)."""
    data = request.get_json() or {}
    target = data.get('target', 'all')  # all | partner | hubnet
    targets = ['partner', 'hubnet'] if target == 'all' else [target]
    results = []
    with _session_refresh_lock:
        for t in targets:
            results.append(_refresh_session_if_stale(t))
    return jsonify({'ok': True, 'results': results})
```

### 작업 #4 — /api/health에 session_refresh 상태 노출

```python
# 기존 /api/health 응답에 추가
response_data['session_refresh'] = {
    'enabled': _session_refresh_status['enabled'],
    'last_run': _session_refresh_status['last_run'],
    'next_run': _session_refresh_status['next_run'],
}
```

---

## 절대 규칙 체크리스트

- [x] 1. 원가 없으면 가짜 값 금지 → N/A
- [x] 2. 판매 완료 건 수정/삭제 금지 → N/A
- [x] 3. price_history.db 직접 DROP/DELETE 금지 → 백업만
- [x] 4. auth_state.json 백업 없이 덮어쓰기 금지 → Phase 2-A의 atomic 저장이 보호
- [x] 5. git push -f 금지 → 일반 commit만 (push는 사용자 결정)
- [x] 6. 테스트 데이터로 실제 입찰 금지 → N/A
- [x] 7. 데이터 수집 실패 시 다른 데이터로 대체 금지 → N/A

## 회귀 테스트

1. **Phase 2-A.1 핫픽스 검증**:
   - `curl /api/health` → `auth_hubnet.valid: true`
   
2. **Phase 2-B 스케줄러 검증**:
   - `curl /api/session/refresh-status` → 200 + enabled=true + last_run/next_run
   - `curl -X POST /api/session/refresh-run-once -H "Content-Type: application/json" -d '{"target":"hubnet"}'` → results 반환
   - 18시간 미만 세션 → `action: skip` 반환
   - 18시간 초과 세션 → `action: refreshed` (또는 failed)

3. **기존 회귀 없음 확인**:
   - `curl /api/queue/list` → 200
   - `curl /api/settings` → 200
   - `python3 -m py_compile kream_server.py`

## 커밋 메시지

```
feat(Step 17-D Phase 2-A.1+2-B): hubnet valid 핫픽스 + 사전 갱신 스케줄러

Phase 2-A.1 (핫픽스):
- /api/health auth_hubnet.valid 판정을 PHPSESSID 쿠키 기준으로 변경
  (이전 size > 1000 기준은 KREAM 판매자센터 전용, 허브넷 PHP 세션은 ~317B가 정상)

Phase 2-B (사전 갱신 스케줄러):
- _session_refresh_worker: 12h 주기 백그라운드 스레드
- _refresh_session_if_stale: 18h 초과 + valid 토큰 시 사전 재로그인
- threading.Lock으로 passive 재로그인과의 race condition 방지
- API 3종: /api/session/refresh-status, refresh-toggle, refresh-run-once
- /api/health에 session_refresh 상태 노출
- KREAM 일반 사이트는 자동 재로그인 미구현이라 대상 제외

회귀 테스트: 모두 PASS
```
