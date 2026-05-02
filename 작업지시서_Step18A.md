# 작업지시서 — Step 18-A: 삭제 검증 + 환경 감지 + 일일 요약

> 작성: 자동 생성
> 절대 규칙 (CLAUDE.md) 모두 준수
> 환경: 맥북(해외) — kream.co.kr 차단

## 작업 #1: 삭제 검증 로직 개선

**배경:** 2026-05-02 실증 — KREAM 판매자센터에서 입찰 삭제 시 검색 API 반영까지 약 5분 지연 발생.
직전 단발성 sync로는 잔존 표시되는 가짜 실패 발생함.

**해결:** `/api/my-bids/delete` 응답 시 task_id만 반환하지 말고, **선택적 verify=true 파라미터**로 5분 대기 검증 옵션 제공.

### kream_server.py 수정

기존 `/api/my-bids/delete` 라우트 찾아서:

```python
@app.route('/api/my-bids/delete', methods=['POST'])
def api_delete_bids():
    data = request.get_json() or {}
    order_ids = data.get('orderIds', [])
    verify = data.get('verify', False)  # NEW
    wait_seconds = data.get('wait_seconds', 300)  # NEW: 기본 5분
    
    if not order_ids:
        return jsonify({'ok': False, 'error': 'orderIds required'}), 400
    
    # 기존 삭제 task 시작 로직 그대로 유지 ...
    # 기존 코드의 task_id 반환부에서, verify=True인 경우 추가 검증 정보도 반환
    
    # 응답에 verify 옵션 안내 추가
    response_data = {'taskId': task_id}
    if verify:
        response_data['verify_after_seconds'] = wait_seconds
        response_data['hint'] = f'task 완료 후 {wait_seconds}초 대기 → /api/my-bids/sync 호출 → 잔존 확인 권장'
    return jsonify(response_data)
```

기존 로직 변경 금지. verify/wait_seconds 파라미터 추가만.

### 신규 라우트: 검증 헬퍼

```python
@app.route('/api/my-bids/verify-deleted', methods=['POST'])
def api_verify_deleted():
    """삭제 검증: order_ids 리스트가 my_bids_local.json에서 사라졌는지 확인.
    프론트엔드/스크립트가 삭제 후 호출해서 잔존 여부 빠르게 확인."""
    data = request.get_json() or {}
    order_ids = data.get('orderIds', [])
    if not order_ids:
        return jsonify({'ok': False, 'error': 'orderIds required'}), 400
    
    try:
        from pathlib import Path
        local_path = Path(__file__).parent / 'my_bids_local.json'
        if not local_path.exists():
            return jsonify({'ok': True, 'remaining': [], 'note': 'local cache 없음'})
        
        local = json.loads(local_path.read_text(encoding='utf-8'))
        bids = local.get('bids', [])
        existing_ids = {b.get('orderId') for b in bids}
        remaining = [oid for oid in order_ids if oid in existing_ids]
        
        return jsonify({
            'ok': True,
            'requested': len(order_ids),
            'remaining': remaining,
            'remaining_count': len(remaining),
            'all_deleted': len(remaining) == 0
        })
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500
```

## 작업 #2: 환경 자동 감지

**배경:** 맥북(해외)에서는 kream.co.kr 차단되어 가격 수집 불가능. 사용자가 메뉴 눌렀다가 빈 결과 받는 혼란 제거.

### kream_server.py — 시작 시 1회 체크

서버 시작 함수(if __name__ == '__main__': 또는 app.run() 직전)에 추가:

```python
def detect_environment():
    """kream.co.kr 접근 가능 여부 1회 체크. 결과는 settings.json에 캐시."""
    import socket, json
    from pathlib import Path
    
    settings_path = Path(__file__).parent / 'settings.json'
    try:
        settings = json.loads(settings_path.read_text(encoding='utf-8')) if settings_path.exists() else {}
    except:
        settings = {}
    
    # 5초 타임아웃으로 kream.co.kr 접근 시도
    try:
        socket.setdefaulttimeout(5)
        socket.gethostbyname('kream.co.kr')
        # 추가로 HTTPS 포트 연결 시도
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect(('kream.co.kr', 443))
        s.close()
        accessible = True
    except Exception:
        accessible = False
    finally:
        socket.setdefaulttimeout(None)
    
    settings['kream_main_accessible'] = accessible
    settings['environment'] = 'imac_kr' if accessible else 'macbook_overseas'
    settings['env_checked_at'] = datetime.now().isoformat()
    
    settings_path.write_text(json.dumps(settings, ensure_ascii=False, indent=2), encoding='utf-8')
    print(f"[ENV] kream.co.kr accessible={accessible}, environment={settings['environment']}")
    return accessible

# 서버 실행 직전에 호출:
# detect_environment()
```

### `/api/health`에 environment 정보 추가

기존 health 응답 dict에 다음 키 추가:
```python
# 기존 health 응답 생성 부분에서
try:
    settings_data = json.loads(Path(__file__).parent.joinpath('settings.json').read_text(encoding='utf-8'))
    health['environment'] = settings_data.get('environment', 'unknown')
    health['kream_main_accessible'] = settings_data.get('kream_main_accessible', None)
except:
    health['environment'] = 'unknown'
```

## 작업 #3: 일일 작업 요약 위젯

### 신규 라우트: /api/daily-summary

```python
@app.route('/api/daily-summary', methods=['GET'])
def api_daily_summary():
    """오늘 작업 요약: 입찰/삭제/판매/pending/auth 실패."""
    try:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        today = datetime.now().strftime('%Y-%m-%d')
        
        # 오늘 입찰 (price_adjustments에서 executed)
        c.execute("""
            SELECT COUNT(*) FROM price_adjustments 
            WHERE DATE(executed_at) = ? AND status = 'executed'
        """, (today,))
        bids_today = c.fetchone()[0] or 0
        
        # 오늘 자동 조정 실행
        c.execute("""
            SELECT COUNT(*) FROM auto_adjust_log 
            WHERE DATE(executed_at) = ?
        """, (today,))
        auto_adjust_today = c.fetchone()[0] or 0
        
        # 오늘 판매
        c.execute("""
            SELECT COUNT(*) FROM sales_history 
            WHERE DATE(trade_date) = ?
        """, (today,))
        sales_today = c.fetchone()[0] or 0
        
        # 현재 pending
        c.execute("SELECT COUNT(*) FROM price_adjustments WHERE status = 'pending'")
        pending_now = c.fetchone()[0] or 0
        
        # 24h 인증 실패
        try:
            c.execute("""
                SELECT COUNT(*) FROM notifications 
                WHERE type = 'auth_failure' 
                AND datetime(created_at) > datetime('now', '-24 hours')
                AND (dismissed IS NULL OR dismissed = 0)
            """)
            auth_failures = c.fetchone()[0] or 0
        except:
            auth_failures = 0
        
        # 최근 판매 trade_date (활동성 지표)
        c.execute("SELECT MAX(trade_date) FROM sales_history")
        last_sale = c.fetchone()[0] or None
        
        conn.close()
        
        return jsonify({
            'ok': True,
            'date': today,
            'summary': {
                'bids_today': bids_today,
                'auto_adjust_today': auto_adjust_today,
                'sales_today': sales_today,
                'pending_now': pending_now,
                'auth_failures_24h': auth_failures,
                'last_sale_date': last_sale,
            }
        })
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500
```

### kream_dashboard.html — 상단 카드 5개 주입

`<body>` 직후 또는 헤더 다음에 카드 컨테이너 주입:

```html
<!-- ========== Daily Summary Cards (auto-injected) ========== -->
<div id="daily-summary-cards" style="display:flex; gap:12px; margin:16px 0; flex-wrap:wrap;">
  <div class="dsc-card" data-key="bids_today" style="flex:1; min-width:140px; background:#eff6ff; border:1px solid #bfdbfe; border-radius:8px; padding:12px;">
    <div style="font-size:12px; color:#1e40af;">오늘 입찰</div>
    <div style="font-size:24px; font-weight:bold; color:#1e3a8a;" id="dsc-bids-today">-</div>
  </div>
  <div class="dsc-card" data-key="auto_adjust_today" style="flex:1; min-width:140px; background:#f0fdf4; border:1px solid #bbf7d0; border-radius:8px; padding:12px;">
    <div style="font-size:12px; color:#166534;">오늘 자동조정</div>
    <div style="font-size:24px; font-weight:bold; color:#14532d;" id="dsc-auto-today">-</div>
  </div>
  <div class="dsc-card" data-key="sales_today" style="flex:1; min-width:140px; background:#fefce8; border:1px solid #fde68a; border-radius:8px; padding:12px;">
    <div style="font-size:12px; color:#854d0e;">오늘 판매</div>
    <div style="font-size:24px; font-weight:bold; color:#713f12;" id="dsc-sales-today">-</div>
  </div>
  <div class="dsc-card" data-key="pending_now" style="flex:1; min-width:140px; background:#fdf4ff; border:1px solid #f0abfc; border-radius:8px; padding:12px;">
    <div style="font-size:12px; color:#86198f;">조정 대기</div>
    <div style="font-size:24px; font-weight:bold; color:#701a75;" id="dsc-pending">-</div>
  </div>
  <div class="dsc-card" data-key="auth_failures_24h" style="flex:1; min-width:140px; background:#fef2f2; border:1px solid #fecaca; border-radius:8px; padding:12px;">
    <div style="font-size:12px; color:#991b1b;">인증 실패 (24h)</div>
    <div style="font-size:24px; font-weight:bold; color:#7f1d1d;" id="dsc-auth-fail">-</div>
  </div>
</div>

<script>
async function loadDailySummary() {
  try {
    const r = await fetch('/api/daily-summary');
    const d = await r.json();
    if (!d.ok) return;
    const s = d.summary;
    document.getElementById('dsc-bids-today').textContent = s.bids_today ?? '-';
    document.getElementById('dsc-auto-today').textContent = s.auto_adjust_today ?? '-';
    document.getElementById('dsc-sales-today').textContent = s.sales_today ?? '-';
    document.getElementById('dsc-pending').textContent = s.pending_now ?? '-';
    document.getElementById('dsc-auth-fail').textContent = s.auth_failures_24h ?? '-';
  } catch(e) { console.warn('daily summary load fail:', e); }
}
document.addEventListener('DOMContentLoaded', () => {
  loadDailySummary();
  setInterval(loadDailySummary, 60000); // 1분마다 갱신
});
</script>
```

### 가격 수집 탭에 환경 차단 배너 (멱등성)

tabs/tab_prices.html 첫 번째 div 시작 부분에 (이미 있으면 스킵):

```html
<div id="env-block-banner" style="display:none; background:#fef2f2; border:1px solid #fecaca; color:#991b1b; padding:12px; border-radius:6px; margin-bottom:12px;">
  🚫 <strong>현재 환경에서 가격 수집 불가</strong><br>
  <small>kream.co.kr 접근 차단됨 (해외 환경). 사무실 iMac 또는 VPN 환경에서만 동작합니다.</small>
</div>
<script>
(async () => {
  try {
    const r = await fetch('/api/health');
    const d = await r.json();
    if (d.environment === 'macbook_overseas' || d.kream_main_accessible === false) {
      document.getElementById('env-block-banner').style.display = 'block';
    }
  } catch(e) {}
})();
</script>
```

tabs/tab_discover.html에도 동일 배너 (id 다르게: env-block-banner-discover) 추가.

## 검증

1. python3 -m py_compile kream_server.py → 0
2. 서버 재시작
3. /api/health → 200 + environment 키 존재
4. /api/daily-summary → 200 + summary 객체
5. /api/my-bids/verify-deleted POST {"orderIds":["TEST123"]} → 200, all_deleted=true
6. 대시보드 HTML에 daily-summary-cards id 존재
7. tabs/tab_prices.html에 env-block-banner 존재

## 절대 규칙
- 기존 라우트 시그니처 변경 금지 (추가 파라미터만)
- 자동 토글 ON 변경 금지
- 입찰 삭제 동작 자체는 변경 금지 (검증 헬퍼만 추가)
- DB 스키마 변경 시 ALTER만 (DROP/DELETE 금지)

## 커밋 메시지
```
feat(Step 18-A): 삭제 검증 헬퍼 + 환경 자동 감지 + 일일 요약 위젯

- /api/my-bids/verify-deleted: 삭제 후 잔존 빠른 확인
- detect_environment(): 시작 시 kream.co.kr 접근성 1회 체크
- /api/health에 environment + kream_main_accessible 추가
- /api/daily-summary: 오늘 입찰/판매/조정/pending/인증실패 집계
- 대시보드 상단 카드 5개 (1분 자동 갱신)
- tab_prices.html, tab_discover.html에 환경 차단 배너

배경: 5분 지연 패턴 실증 + 해외 환경 자동 인지 + 일일 가시성 확보
```
