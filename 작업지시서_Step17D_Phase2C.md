# 작업지시서 — Step 17-D Phase 2-C: 알림 채널 + 대시보드 배너

> 의존: 직전 커밋 ad15be6 (Phase 2-B 사전 갱신 스케줄러)
> 예상: +90 라인 (kream_server.py +60, kream_dashboard.html +30)

## 작업 #1 — 알림 채널 점검 (kream_server.py)

기존 health_alert.py 또는 send_alert 함수가 있는지 확인 후:
1. SMTP 알림 try/except로 감싸서 실패 시 stderr로 fallback
2. 알림 발송 실패해도 서버는 계속 동작 (silent degradation 방지)

```python
def safe_send_alert(subject, body, alert_type='info'):
    """알림 발송 안전 wrapper. 실패해도 서버 동작에 영향 X."""
    import sys
    
    # 1. DB에 알림 누적 (notifications 테이블)
    try:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("""
            INSERT INTO notifications (type, subject, body, created_at)
            VALUES (?, ?, ?, ?)
        """, (alert_type, subject, body, datetime.now().isoformat()))
        conn.commit()
        conn.close()
    except Exception as e:
        print(f"[ALERT-DB-FAIL] {e}", file=sys.stderr)
    
    # 2. 이메일 발송 시도
    try:
        from health_alert import send_alert
        send_alert(subject=subject, body=body)
    except ImportError:
        print(f"[ALERT-EMAIL] (health_alert 없음) {subject}: {body[:200]}", file=sys.stderr)
    except Exception as e:
        print(f"[ALERT-EMAIL-FAIL] {e}", file=sys.stderr)
```

기존 send_alert 호출 부분을 모두 safe_send_alert로 교체 (또는 send_alert 자체를 try/except로 wrap).

## 작업 #2 — auth_failure 누적 알림 API

```python
@app.route('/api/notifications/auth-failures', methods=['GET'])
def api_auth_failures():
    """auth_failure 알림 최근 24시간 조회 (대시보드 배너용)."""
    try:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("""
            SELECT id, subject, body, created_at, dismissed
            FROM notifications
            WHERE type = 'auth_failure'
            AND datetime(created_at) > datetime('now', '-24 hours')
            AND (dismissed IS NULL OR dismissed = 0)
            ORDER BY created_at DESC
            LIMIT 10
        """)
        rows = c.fetchall()
        conn.close()
        return jsonify({
            'ok': True,
            'count': len(rows),
            'items': [
                {'id': r[0], 'subject': r[1], 'body': r[2], 
                 'created_at': r[3], 'dismissed': r[4]}
                for r in rows
            ]
        })
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500

@app.route('/api/notifications/dismiss', methods=['POST'])
def api_notifications_dismiss():
    """알림 dismiss (배너 닫기)."""
    data = request.get_json() or {}
    nid = data.get('id')
    if not nid:
        return jsonify({'ok': False, 'error': 'id required'}), 400
    try:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("UPDATE notifications SET dismissed = 1 WHERE id = ?", (nid,))
        conn.commit()
        conn.close()
        return jsonify({'ok': True})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500
```

notifications 테이블에 dismissed 컬럼이 없으면 ALTER TABLE 추가:
```sql
ALTER TABLE notifications ADD COLUMN dismissed INTEGER DEFAULT 0;
```

## 작업 #3 — _refresh_session_if_stale에 safe_send_alert 연결

Phase 2-B에서 만든 _refresh_session_if_stale에서 action='failed' 시:
```python
if result['action'] == 'failed':
    safe_send_alert(
        subject=f"[KREAM] 세션 사전 갱신 실패: {target}",
        body=f"target={target}\nmessage={result['message']}",
        alert_type='auth_failure'
    )
```

## 작업 #4 — 대시보드 배너 (kream_dashboard.html)

상단 또는 헤더 부분에 경고 배너 컴포넌트 추가:

```html
<div id="auth-failure-banner" 
     style="display:none; background:#fef2f2; border:1px solid #fecaca; 
            color:#991b1b; padding:12px 16px; border-radius:6px; 
            margin:12px 0; font-size:14px;">
  <div style="display:flex; justify-content:space-between; align-items:center;">
    <span>⚠️ <strong>인증 실패 감지</strong> <span id="auth-failure-count">0</span>건</span>
    <span>
      <a href="#" onclick="loadAuthFailures(); return false;" 
         style="color:#991b1b; margin-right:12px;">자세히</a>
      <a href="#" onclick="dismissAllAuthFailures(); return false;" 
         style="color:#991b1b;">모두 닫기</a>
    </span>
  </div>
  <div id="auth-failure-list" style="margin-top:8px; display:none;"></div>
</div>

<script>
async function checkAuthFailures() {
  try {
    const r = await fetch('/api/notifications/auth-failures');
    const d = await r.json();
    if (d.ok && d.count > 0) {
      document.getElementById('auth-failure-banner').style.display = 'block';
      document.getElementById('auth-failure-count').textContent = d.count;
      window._authFailures = d.items;
    } else {
      document.getElementById('auth-failure-banner').style.display = 'none';
    }
  } catch(e) { console.warn('auth-failures check fail:', e); }
}

async function loadAuthFailures() {
  const list = document.getElementById('auth-failure-list');
  if (list.style.display === 'none') {
    list.style.display = 'block';
    list.innerHTML = (window._authFailures || []).map(item => 
      `<div style="padding:6px 0; border-top:1px solid #fecaca;">
         <strong>${item.subject}</strong><br>
         <small>${item.created_at}</small>
         <a href="#" onclick="dismissOne(${item.id}); return false;" 
            style="float:right;">닫기</a>
       </div>`
    ).join('');
  } else {
    list.style.display = 'none';
  }
}

async function dismissOne(id) {
  await fetch('/api/notifications/dismiss', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({id})
  });
  checkAuthFailures();
}

async function dismissAllAuthFailures() {
  for (const item of (window._authFailures || [])) {
    await dismissOne(item.id);
  }
}

// 페이지 로드 시 + 5분마다 체크
document.addEventListener('DOMContentLoaded', () => {
  checkAuthFailures();
  setInterval(checkAuthFailures, 300000);
});
</script>
```

## 검증

1. python3 -m py_compile kream_server.py
2. 서버 재시작 후 /api/health 200
3. /api/notifications/auth-failures → 200 + items 배열
4. /api/notifications/dismiss → POST 200 (테스트 데이터 없으면 400 OK)
5. 브라우저에서 대시보드 열면 콘솔 에러 없음

## 절대 규칙
- 알림 발송 실패해도 메인 로직 계속 동작 (try/except 필수)
- 자동 입찰 트리거 추가 금지
- 기존 send_alert 함수 시그니처 변경 금지

## 커밋 메시지
```
feat(Step 17-D Phase 2-C): 알림 안전 wrapper + auth_failure 배너 + dismiss API

- safe_send_alert: SMTP 실패해도 stderr fallback + DB 누적
- /api/notifications/auth-failures: 24h 내 인증 실패 알림 조회
- /api/notifications/dismiss: 알림 dismiss API
- _refresh_session_if_stale failed 시 auth_failure 알림 발송
- 대시보드 상단 배너: 자동 polling (5분), dismiss 버튼

회귀 테스트: 모두 PASS
```
