#!/bin/bash
# Step 18-A 통합 파이프라인
#   1. 삭제 검증 로직 개선 (5분 지연 대응)
#   2. 환경 자동 감지 (맥북/해외 vs iMac/한국)
#   3. 일일 작업 요약 위젯
#
# 사용법: bash run_step18a.sh
# 작성: 2026-05-02

set -e
exec > >(tee -a pipeline_step18a.log) 2>&1

cd ~/Desktop/kream_automation

PIPELINE_START=$(date +%s)
TS=$(date '+%Y%m%d_%H%M%S')

echo "================================================================"
echo "🚀 Step 18-A 통합 Pipeline — $(date '+%Y-%m-%d %H:%M:%S')"
echo "   1) 삭제 검증 개선  2) 환경 감지  3) 일일 요약 위젯"
echo "================================================================"
echo ""

# ==========================================
# 공통 함수
# ==========================================
fail_and_restore() {
    local stage=$1
    echo ""
    echo "❌ [$stage] FAIL — 백업 복원"
    [ -f "kream_server.py.step18a_pre.bak" ] && cp "kream_server.py.step18a_pre.bak" kream_server.py
    [ -f "kream_dashboard.html.step18a_pre.bak" ] && cp "kream_dashboard.html.step18a_pre.bak" kream_dashboard.html
    
    echo "🔄 서버 재시작..."
    lsof -ti:5001 | xargs kill -9 2>/dev/null || true
    sleep 2
    nohup python3 kream_server.py > server.log 2>&1 & disown
    sleep 5
    
    echo "❌ Pipeline 중단 — $stage 단계 실패"
    exit 1
}

verify_server() {
    sleep 3
    local code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:5001/api/health)
    [ "$code" == "200" ] && echo "  ✅ 서버 정상" && return 0
    echo "  ❌ 서버 응답 없음 (HTTP $code)" && return 1
}

# ==========================================
# [STAGE 0] 사전 점검
# ==========================================
echo "════════════════════ [STAGE 0] 사전 점검 ════════════════════"
verify_server || fail_and_restore "사전 점검"
echo "  현재 커밋: $(git log --oneline -1)"

# 자동 토글 OFF 확인
AUTO_ADJUST=$(curl -s http://localhost:5001/api/settings 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('auto_adjust_enabled', '?'))" 2>/dev/null || echo "?")
echo "  자동 조정: $AUTO_ADJUST"
echo ""

# ==========================================
# [STAGE 1] 백업
# ==========================================
echo "════════════════════ [STAGE 1] 백업 ════════════════════"
cp kream_server.py "kream_server.py.step18a_pre.bak"
cp kream_dashboard.html "kream_dashboard.html.step18a_pre.bak"
sqlite3 /Users/iseungju/Desktop/kream_automation/price_history.db ".backup '/Users/iseungju/Desktop/kream_automation/price_history_step18a_${TS}.db'"
echo "  ✅ kream_server.py + kream_dashboard.html + DB 백업"
echo ""

# ==========================================
# [STAGE 2] 작업지시서
# ==========================================
echo "════════════════════ [STAGE 2] 작업지시서 ════════════════════"

cat > "작업지시서_Step18A.md" <<'MDEOF'
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
MDEOF

echo "  ✅ 작업지시서 생성"
echo ""

# ==========================================
# [STAGE 3] Claude Code 호출
# ==========================================
echo "════════════════════ [STAGE 3] Claude Code 호출 ════════════════════"
echo ""

claude --dangerously-skip-permissions <<'CLAUDE_PROMPT' || fail_and_restore "Claude Code 실행"
작업지시서_Step18A.md 읽고 끝까지 진행. 질문 절대 금지. 사용자 개입 요청 금지.

진행 순서:
1. 작업지시서 읽기

2. kream_server.py 수정:
   a. /api/my-bids/delete 라우트에 verify, wait_seconds 파라미터 추가 (기존 로직 변경 금지)
   b. /api/my-bids/verify-deleted POST 라우트 신규 추가
   c. detect_environment() 함수 신규 추가
   d. 서버 시작 시 detect_environment() 호출 (if __name__ 블록 내)
   e. /api/health 응답에 environment, kream_main_accessible 키 추가
   f. /api/daily-summary GET 라우트 신규 추가
   
   이미 같은 함수/라우트가 있으면 스킵 (멱등성). 기존 라우트 시그니처 변경 금지.

3. kream_dashboard.html 수정:
   a. <body> 직후 또는 적절한 헤더 다음에 daily-summary-cards div 주입
      (이미 id="daily-summary-cards"가 있으면 스킵)
   b. loadDailySummary 스크립트 주입
      (이미 loadDailySummary 함수가 있으면 스킵)

4. tabs/tab_prices.html 첫 부분에 env-block-banner div + 환경 체크 스크립트 주입
   (이미 id="env-block-banner"가 있으면 스킵)

5. tabs/tab_discover.html 첫 부분에 env-block-banner-discover div + 환경 체크 스크립트 주입
   (이미 있으면 스킵)

6. 문법 검증:
   python3 -m py_compile kream_server.py

7. 서버 재시작:
   lsof -ti:5001 | xargs kill -9 || true
   sleep 2
   nohup python3 kream_server.py > server.log 2>&1 & disown
   sleep 8

8. API 검증 (모두 통과해야 함):
   - curl -s http://localhost:5001/api/health | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('status') in ['healthy','critical','warning'], 'health status 비정상'; assert 'environment' in d, 'environment 누락'; print('health OK', d.get('environment'))"
   - curl -s http://localhost:5001/api/daily-summary | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'), 'daily-summary 실패'; assert 'summary' in d; print('summary OK', d['summary'])"
   - curl -s -X POST http://localhost:5001/api/my-bids/verify-deleted -H 'Content-Type: application/json' -d '{"orderIds":["NONEXISTENT_TEST_999"]}' | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'), 'verify 실패'; assert d.get('all_deleted') == True, '존재하지 않는 ID는 all_deleted=true여야 함'; print('verify OK')"

9. 대시보드 HTML 검증:
   - grep -q 'daily-summary-cards' kream_dashboard.html
   - grep -q 'loadDailySummary' kream_dashboard.html

10. 탭 배너 검증:
    - grep -q 'env-block-banner' tabs/tab_prices.html
    - grep -q 'env-block-banner' tabs/tab_discover.html

11. 회귀: 기존 기능 깨지지 않았는지
    - curl -s http://localhost:5001/api/queue/list -o /dev/null -w "%{http_code}" → 200
    - curl -s http://localhost:5001/api/help/register | grep -q '"ok": true'

12. 모두 PASS면 단일 커밋 + push:
    git add -A
    git commit -m "feat(Step 18-A): 삭제 검증 헬퍼 + 환경 자동 감지 + 일일 요약 위젯

    - /api/my-bids/verify-deleted: 삭제 후 잔존 빠른 확인
    - detect_environment(): 시작 시 kream.co.kr 접근성 1회 체크
    - /api/health에 environment + kream_main_accessible 추가
    - /api/daily-summary: 오늘 입찰/판매/조정/pending/인증실패 집계
    - 대시보드 상단 카드 5개 (1분 자동 갱신)
    - tab_prices.html, tab_discover.html에 환경 차단 배너

    배경: 2026-05-02 KREAM 삭제 5분 지연 실증 + 해외 환경 자동 인지"
    git push origin main

13. 끝.

검증 FAIL 시 즉시 종료. 백업 복원은 외부 스크립트가 처리.
질문/확인 요청 절대 금지.
CLAUDE_PROMPT

echo ""
echo "🔍 최종 검증..."
verify_server || fail_and_restore "최종 검증"

# 핵심 API 직접 검증
echo ""
echo "  📋 핵심 API 검증:"

HEALTH_ENV=$(curl -s http://localhost:5001/api/health | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get('environment', 'MISSING'))
except: print('ERROR')
" 2>/dev/null)
echo "    environment: $HEALTH_ENV"
if [ "$HEALTH_ENV" == "MISSING" ] || [ "$HEALTH_ENV" == "ERROR" ]; then
    fail_and_restore "/api/health environment 누락"
fi

SUMMARY_OK=$(curl -s http://localhost:5001/api/daily-summary | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print('YES' if d.get('ok') and 'summary' in d else 'NO')
except: print('NO')
" 2>/dev/null)
echo "    daily-summary: $SUMMARY_OK"
if [ "$SUMMARY_OK" != "YES" ]; then
    fail_and_restore "/api/daily-summary 실패"
fi

VERIFY_OK=$(curl -s -X POST http://localhost:5001/api/my-bids/verify-deleted \
  -H 'Content-Type: application/json' \
  -d '{"orderIds":["NONEXISTENT_TEST_999"]}' | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print('YES' if d.get('ok') and d.get('all_deleted') else 'NO')
except: print('NO')
" 2>/dev/null)
echo "    verify-deleted: $VERIFY_OK"
if [ "$VERIFY_OK" != "YES" ]; then
    fail_and_restore "/api/my-bids/verify-deleted 실패"
fi

# 대시보드 + 탭 검증
grep -q 'daily-summary-cards' kream_dashboard.html && echo "    ✅ 대시보드 카드 주입됨" || fail_and_restore "대시보드 카드 누락"
grep -q 'env-block-banner' tabs/tab_prices.html && echo "    ✅ tab_prices.html 배너 주입됨" || echo "    ⚠️ tab_prices.html 배너 누락 (계속 진행)"

FINAL_HASH=$(git log -1 --format=%h)
echo ""
echo "  ✅ 커밋: $FINAL_HASH"
echo ""

# ==========================================
# [STAGE 4] 다음세션 컨텍스트 v9
# ==========================================
echo "════════════════════ [STAGE 4] 컨텍스트 v9 ════════════════════"

PA_PENDING=$(sqlite3 price_history.db "SELECT COUNT(*) FROM price_adjustments WHERE status='pending'" 2>/dev/null || echo "?")
SALES_COUNT=$(sqlite3 price_history.db "SELECT COUNT(*) FROM sales_history" 2>/dev/null || echo "?")
LATEST_SALE=$(sqlite3 price_history.db "SELECT MAX(trade_date) FROM sales_history" 2>/dev/null || echo "?")

cat > "다음세션_시작_컨텍스트_v9.md" <<MDEOF
# 다음 세션 시작 컨텍스트 v9

> 작성일: $(date '+%Y-%m-%d %H:%M:%S') (자동 생성)
> 직전 커밋: $(git log -1 --format='%h %s')

## 1. 최근 완료 작업 (2026-05-02 단일 세션)

| 작업 | 커밋 | 비고 |
|---|---|---|
| JQ4110 ONE_SIZE 진단 | 490da5a | 입찰 3건 분석 |
| 130k 1차 삭제 시도 | 361254a | sync 너무 빨라 잔존 표시 |
| 130k 재삭제 성공 | e5dd7e8 | 5분 지연 후 반영 확인 |
| 12개 탭 도움말 시스템 | 3df382d | ❓ 버튼 + 모달 |
| Step 18-A 통합 | $FINAL_HASH | 삭제 검증 + 환경 감지 + 일일 요약 |

## 2. 신규 API (Step 18-A)

- POST /api/my-bids/verify-deleted — 삭제 후 잔존 빠른 확인
- GET /api/daily-summary — 오늘 입찰/판매/조정/pending/인증실패
- /api/health에 environment, kream_main_accessible 추가

## 3. 환경 상태

- 환경: $HEALTH_ENV
- kream.co.kr: $([ "$HEALTH_ENV" == "macbook_overseas" ] && echo "차단" || echo "접근 가능")
- 자동 토글 6종: 사전 갱신만 ON, 나머지 OFF

## 4. DB 현황

| 테이블 | 건수 |
|---|---|
| pa_pending | $PA_PENDING |
| sales_history | $SALES_COUNT |
| 최근 trade_date | $LATEST_SALE |

## 5. 다음 작업 후보

### 1순위 — Step 18-B: 자동화 점진 ON
- 자동 조정만 24h dry_run 모드로 켜고 실패 패턴 관찰
- daily-summary 위젯으로 가시성 확보됐으니 모니터링 용이

### 2순위 — 가격 수집 환경 복원
- VPN 또는 사무실 iMac 원격 → kream.co.kr 접근
- 가격 수집 시작하면 자동 조정 의미 있어짐

### 3순위 — 판매 패턴 분석 강화
- sales_history 데이터 누적 → 시간대별/요일별 인사이트
- 입찰 시점 최적화

## 6. 다음 채팅 첫 메시지 템플릿

\`\`\`
다음세션_시작_컨텍스트_v9.md 읽고 현재 상태 파악.
직전 커밋 $FINAL_HASH (Step 18-A 완료).
환경: $HEALTH_ENV.

오늘 작업: [Step 18-B 자동조정 dry_run / VPN 가격수집 / 판매패턴 / 다른 작업]

알아서 끝까지. 질문 최소화.
\`\`\`

## 7. 절대 규칙 (CLAUDE.md)

7대 규칙 그대로 유지.
MDEOF

echo "  ✅ 다음세션_시작_컨텍스트_v9.md 생성"

git add 다음세션_시작_컨텍스트_v9.md pipeline_step18a.log 2>/dev/null
git commit -m "docs: 다음세션 컨텍스트 v9 (Step 18-A 완료)" 2>/dev/null || echo "  (컨텍스트 변경 없음)"
git push origin main 2>/dev/null || echo "  (push 스킵)"
echo ""

# ==========================================
# 최종 요약
# ==========================================
PIPELINE_END=$(date +%s)
ELAPSED=$((PIPELINE_END - PIPELINE_START))
ELAPSED_MIN=$((ELAPSED / 60))

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🎉 Step 18-A 완료 — ${ELAPSED_MIN}분 ${ELAPSED}초"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "✅ 결과:"
echo "  - 삭제 검증 헬퍼: /api/my-bids/verify-deleted"
echo "  - 환경 자동 감지: $HEALTH_ENV"
echo "  - 일일 요약 위젯: /api/daily-summary + 대시보드 카드 5개"
echo "  - 환경 차단 배너: 가격수집/상품발굴 탭"
echo "  - 커밋: $FINAL_HASH"
echo ""
echo "📋 대시보드 확인:"
echo "  http://localhost:5001 새로고침 → 상단에 카드 5개 표시"
echo "  메뉴 우상단 ❓ → 도움말 모달 동작"
echo ""
echo "📜 로그: pipeline_step18a.log"
echo ""
