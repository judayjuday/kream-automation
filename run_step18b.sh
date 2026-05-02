#!/bin/bash
# Step 18-B 통합 파이프라인
#   1. 환경 감지 강화 (HTTP 응답 기반)
#   2. 가격 수집 실전 테스트 (JQ4110)
#   3. 가격 수집 상태 위젯 (대시보드 6번째 카드)
#
# 사용법: bash run_step18b.sh
# 작성: 2026-05-02

set -e
exec > >(tee -a pipeline_step18b.log) 2>&1

cd ~/Desktop/kream_automation

PIPELINE_START=$(date +%s)
TS=$(date '+%Y%m%d_%H%M%S')

echo "================================================================"
echo "🚀 Step 18-B 통합 Pipeline — $(date '+%Y-%m-%d %H:%M:%S')"
echo "   1) 환경 감지 강화  2) 가격수집 실전  3) 수집상태 위젯"
echo "================================================================"
echo ""

fail_and_restore() {
    local stage=$1
    echo ""
    echo "❌ [$stage] FAIL — 백업 복원"
    [ -f "kream_server.py.step18b_pre.bak" ] && cp "kream_server.py.step18b_pre.bak" kream_server.py
    [ -f "kream_dashboard.html.step18b_pre.bak" ] && cp "kream_dashboard.html.step18b_pre.bak" kream_dashboard.html
    
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
# [STAGE 0] 사전 점검 + 직전 환경 감지 결과
# ==========================================
echo "════════════════════ [STAGE 0] 사전 점검 ════════════════════"
verify_server || fail_and_restore "사전 점검"

PREV_ENV=$(curl -s http://localhost:5001/api/health | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('environment','unknown'))
except: print('error')
" 2>/dev/null)
echo "  직전 감지 환경: $PREV_ENV (TCP 기반)"
echo "  현재 커밋: $(git log --oneline -1)"
echo ""

# ==========================================
# [STAGE 1] 백업
# ==========================================
echo "════════════════════ [STAGE 1] 백업 ════════════════════"
cp kream_server.py "kream_server.py.step18b_pre.bak"
cp kream_dashboard.html "kream_dashboard.html.step18b_pre.bak"
sqlite3 /Users/iseungju/Desktop/kream_automation/price_history.db ".backup '/Users/iseungju/Desktop/kream_automation/price_history_step18b_${TS}.db'"
echo "  ✅ 백업 완료"
echo ""

# ==========================================
# [STAGE 2] 작업지시서
# ==========================================
echo "════════════════════ [STAGE 2] 작업지시서 ════════════════════"

cat > "작업지시서_Step18B.md" <<'MDEOF'
# 작업지시서 — Step 18-B: 환경 감지 강화 + 가격 수집 실전 + 수집 위젯

> 작성: 자동 생성
> 절대 규칙 (CLAUDE.md) 모두 준수
> 의존: Step 18-A (커밋 ff97377)

## 배경

Step 18-A에서 `detect_environment()`가 TCP 연결만 확인 → `imac_kr` 판정.
하지만 사용자 메모리에는 "맥북(해외) kream.co.kr 차단"으로 기록됨.
TCP 연결만 통과하고 실제 HTTP 응답은 차단(Cloudflare 지역 차단)일 가능성 → HTTP 레벨로 강화.

## 작업 #1: 환경 감지 강화 (HTTP 기반)

### kream_server.py 수정

기존 `detect_environment()` 함수를 HTTP 기반으로 교체:

```python
def detect_environment():
    """kream.co.kr 실제 HTTP 응답 확인. settings.json에 캐시."""
    import json
    from pathlib import Path
    from datetime import datetime
    
    settings_path = Path(__file__).parent / 'settings.json'
    try:
        settings = json.loads(settings_path.read_text(encoding='utf-8')) if settings_path.exists() else {}
    except:
        settings = {}
    
    accessible = False
    detection_detail = 'unknown'
    
    try:
        import requests
        # 일반 사이트 메인 페이지 GET (User-Agent 정상값)
        headers = {
            'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
            'Accept-Language': 'ko-KR,ko;q=0.9,en;q=0.8',
        }
        r = requests.get('https://kream.co.kr', timeout=10, headers=headers, allow_redirects=True)
        
        if r.status_code == 200:
            # KREAM 마커 확인 (페이지에 KREAM 관련 키워드)
            body_lower = r.text.lower()[:5000]  # 앞 5KB만 확인
            if 'kream' in body_lower and ('한정판' in r.text[:5000] or 'application' in body_lower or '<title' in body_lower):
                accessible = True
                detection_detail = f'http_200_kream_marker'
            else:
                detection_detail = f'http_200_but_no_marker'
        elif r.status_code in (403, 451):
            detection_detail = f'blocked_http_{r.status_code}'
        else:
            detection_detail = f'http_{r.status_code}'
    except requests.exceptions.Timeout:
        detection_detail = 'timeout'
    except requests.exceptions.ConnectionError as e:
        detection_detail = f'connection_error'
    except Exception as e:
        detection_detail = f'error_{type(e).__name__}'
    
    settings['kream_main_accessible'] = accessible
    settings['environment'] = 'imac_kr' if accessible else 'macbook_overseas'
    settings['env_checked_at'] = datetime.now().isoformat()
    settings['env_detection_detail'] = detection_detail
    
    settings_path.write_text(json.dumps(settings, ensure_ascii=False, indent=2), encoding='utf-8')
    print(f"[ENV] HTTP-check: accessible={accessible}, detail={detection_detail}, env={settings['environment']}")
    return accessible
```

기존 함수 시그니처 유지. 내부 로직만 교체.

### /api/health에 detail 추가

기존 health 응답에 다음 키 추가:

```python
# 기존 environment 키 옆에
try:
    settings_data = json.loads(Path(__file__).parent.joinpath('settings.json').read_text(encoding='utf-8'))
    health['environment'] = settings_data.get('environment', 'unknown')
    health['kream_main_accessible'] = settings_data.get('kream_main_accessible', None)
    health['env_detection_detail'] = settings_data.get('env_detection_detail', None)  # NEW
    health['env_checked_at'] = settings_data.get('env_checked_at', None)  # NEW
except:
    pass
```

## 작업 #2: 가격 수집 실전 테스트 + 결과 캐시

### 신규 라우트: /api/env/recheck

```python
@app.route('/api/env/recheck', methods=['POST'])
def api_env_recheck():
    """환경 감지 수동 재실행 (VPN 켜고/끄고 후 사용)."""
    try:
        accessible = detect_environment()
        from pathlib import Path
        settings = json.loads(Path(__file__).parent.joinpath('settings.json').read_text(encoding='utf-8'))
        return jsonify({
            'ok': True,
            'environment': settings.get('environment'),
            'accessible': accessible,
            'detail': settings.get('env_detection_detail'),
            'checked_at': settings.get('env_checked_at')
        })
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500
```

### 신규 라우트: /api/env/test-price-collection

JQ4110으로 실제 가격 수집 1회 시도해서 결과 검증:

```python
@app.route('/api/env/test-price-collection', methods=['POST'])
def api_test_price_collection():
    """실전 가격 수집 테스트. JQ4110으로 1회 수집 후 결과 분석."""
    try:
        import subprocess
        # /api/search 내부 호출
        from pathlib import Path
        
        # 직접 search 함수 재사용 또는 동일 동작
        # 간단한 방법: requests로 자기 자신 호출
        import requests as rq
        r = rq.post('http://localhost:5001/api/search', 
                    json={'model': 'JQ4110'}, 
                    timeout=60)
        
        if r.status_code != 200:
            return jsonify({
                'ok': False,
                'test_result': 'api_failed',
                'http_status': r.status_code
            })
        
        d = r.json()
        sizes = d.get('sizes', []) or d.get('size_prices', [])
        has_data = len(sizes) > 0 and any(
            (s.get('buy_price') or s.get('buyPrice')) for s in sizes
        )
        
        # 결과 캐시
        from pathlib import Path
        from datetime import datetime
        cache_path = Path(__file__).parent / 'kream_prices.json'
        try:
            cache = json.loads(cache_path.read_text(encoding='utf-8')) if cache_path.exists() else {}
        except:
            cache = {}
        cache['_last_test'] = {
            'at': datetime.now().isoformat(),
            'model': 'JQ4110',
            'has_data': has_data,
            'sizes_count': len(sizes),
        }
        cache_path.write_text(json.dumps(cache, ensure_ascii=False, indent=2), encoding='utf-8')
        
        return jsonify({
            'ok': True,
            'test_result': 'success' if has_data else 'empty_result',
            'has_data': has_data,
            'sizes_count': len(sizes),
            'sample': sizes[:3] if sizes else [],
            'note': '환경 차단 시 sizes_count=0 또는 buy_price 없음'
        })
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500
```

## 작업 #3: 일일 요약에 가격 수집 상태 추가

기존 `/api/daily-summary`에 키 추가:

```python
# 기존 daily-summary 핸들러 안에서, 응답 dict에 추가
        from pathlib import Path
        last_collection_at = None
        prices_collected_today = 0
        
        cache_path = Path(__file__).parent / 'kream_prices.json'
        if cache_path.exists():
            try:
                cache = json.loads(cache_path.read_text(encoding='utf-8'))
                last_test = cache.get('_last_test', {})
                last_collection_at = last_test.get('at')
                if last_collection_at and last_collection_at.startswith(today):
                    prices_collected_today = 1
                # 다른 가격 데이터 키 카운트 (모델별 캐시 가정)
                model_keys = [k for k in cache.keys() if not k.startswith('_')]
                # 오늘 수집된 모델 수 추정 (수집된 시간 정보 있으면)
                for k in model_keys:
                    v = cache.get(k, {})
                    if isinstance(v, dict):
                        collected_at = v.get('collected_at') or v.get('updated_at')
                        if collected_at and str(collected_at).startswith(today):
                            prices_collected_today += 1
            except:
                pass
        
        # summary dict에 추가
        # 기존 summary 객체에 다음 키 병합:
        #   'last_collection_at': last_collection_at,
        #   'prices_collected_today': prices_collected_today,
```

기존 summary 응답 구조 유지하면서 위 2개 키만 추가.

### 대시보드 카드 6번째 추가

`kream_dashboard.html`의 `daily-summary-cards` div 안에 카드 추가 (이미 있으면 스킵):

```html
<div class="dsc-card" data-key="prices_collected_today" id="dsc-card-prices" style="flex:1; min-width:140px; background:#ecfeff; border:1px solid #a5f3fc; border-radius:8px; padding:12px;">
  <div style="font-size:12px; color:#155e75;">오늘 가격수집</div>
  <div style="font-size:24px; font-weight:bold; color:#164e63;" id="dsc-prices">-</div>
  <div style="font-size:10px; color:#0e7490; margin-top:4px;" id="dsc-prices-last">최근: -</div>
</div>
```

`loadDailySummary()` 함수 안에 다음 라인 추가 (기존 코드 끝부분):

```javascript
// 가격수집 카드 업데이트
const pricesEl = document.getElementById('dsc-prices');
const lastEl = document.getElementById('dsc-prices-last');
if (pricesEl) pricesEl.textContent = s.prices_collected_today ?? '-';
if (lastEl && s.last_collection_at) {
  const dt = new Date(s.last_collection_at);
  const hoursAgo = Math.floor((Date.now() - dt.getTime()) / 3600000);
  lastEl.textContent = `최근: ${hoursAgo}h 전`;
  // 24h 이상이면 카드 노란색 경고
  const card = document.getElementById('dsc-card-prices');
  if (card && hoursAgo > 24) {
    card.style.background = '#fef3c7';
    card.style.borderColor = '#fde68a';
  }
} else if (lastEl) {
  lastEl.textContent = '최근: 없음';
}
```

## 검증

1. `python3 -m py_compile kream_server.py` → 0
2. 서버 재시작
3. 환경 재감지: `curl -X POST /api/env/recheck` → ok=true, detail 키 존재
4. 가격 수집 테스트: `curl -X POST /api/env/test-price-collection` → ok=true, has_data 키 존재
5. `/api/daily-summary` → summary에 last_collection_at, prices_collected_today 키 존재
6. `/api/health` → env_detection_detail 키 존재
7. 대시보드 HTML에 dsc-card-prices id 존재
8. 회귀: /api/queue/list 200, /api/help/register ok

## 절대 규칙
- 기존 라우트 시그니처 변경 금지
- 자동 토글 ON 변경 금지
- 가격 수집 테스트 실패해도 panic 금지 (그냥 결과 보고)
- requests 모듈 없으면 import 에러 처리

## 커밋 메시지
```
feat(Step 18-B): 환경 감지 HTTP 강화 + 가격수집 실전테스트 + 수집위젯

- detect_environment(): TCP → HTTP 응답 기반 (User-Agent + 마커 검증)
- /api/health에 env_detection_detail, env_checked_at 추가
- /api/env/recheck: 수동 재감지 (VPN 토글 후 사용)
- /api/env/test-price-collection: JQ4110으로 실전 가격수집 1회
- /api/daily-summary에 last_collection_at, prices_collected_today
- 대시보드 6번째 카드 (24h 이상 미수집 시 노란색 경고)

배경: TCP만으로는 Cloudflare 지역차단 미감지 → HTTP 레벨로 정확화
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
작업지시서_Step18B.md 읽고 끝까지 진행. 질문 절대 금지. 사용자 개입 요청 금지.

순서:
1. 작업지시서 읽기

2. kream_server.py 수정:
   a. 기존 detect_environment() 함수 내부 교체 (HTTP requests 기반)
      - requests 모듈 import (미존재 시 try/except로 fallback)
      - User-Agent 헤더 + KREAM 마커 검증
      - settings.json에 env_detection_detail 추가
   b. /api/health에 env_detection_detail, env_checked_at 키 추가
   c. /api/env/recheck POST 라우트 신규
   d. /api/env/test-price-collection POST 라우트 신규
   e. 기존 /api/daily-summary 핸들러에 last_collection_at, prices_collected_today 키 추가
   
   이미 같은 함수/라우트가 있으면 스킵 (멱등성).

3. kream_dashboard.html 수정:
   a. daily-summary-cards div 안에 6번째 카드 (id=dsc-card-prices) 추가
      이미 dsc-card-prices id 있으면 스킵
   b. loadDailySummary 함수에 가격수집 카드 업데이트 코드 추가
      이미 dsc-prices 처리 코드 있으면 스킵

4. 문법 검증:
   python3 -m py_compile kream_server.py

5. 서버 재시작:
   lsof -ti:5001 | xargs kill -9 || true
   sleep 2
   nohup python3 kream_server.py > server.log 2>&1 & disown
   sleep 8

6. API 검증:
   - curl -s http://localhost:5001/api/health | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'env_detection_detail' in d, 'detail 누락'; print('health OK', d.get('env_detection_detail'))"
   - curl -s -X POST http://localhost:5001/api/env/recheck | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'), 'recheck 실패'; print('recheck OK', d.get('detail'))"
   - curl -s http://localhost:5001/api/daily-summary | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'prices_collected_today' in d.get('summary',{}), 'prices_collected_today 누락'; print('summary OK')"
   
7. 가격 수집 실전 테스트 (실패해도 진행):
   - curl -s -X POST http://localhost:5001/api/env/test-price-collection -H 'Content-Type: application/json' -d '{}' | python3 -c "import sys,json; d=json.load(sys.stdin); print('test-price:', 'ok=', d.get('ok'), 'has_data=', d.get('has_data'), 'sizes=', d.get('sizes_count'))"

8. 대시보드 검증:
   - grep -q 'dsc-card-prices' kream_dashboard.html
   - grep -q 'dsc-prices-last' kream_dashboard.html

9. 회귀:
   - curl -s -o /dev/null -w "%{http_code}" http://localhost:5001/api/queue/list → 200
   - curl -s http://localhost:5001/api/help/register | grep -q '"ok": true'

10. 모두 PASS면 단일 커밋:
    git add -A
    git commit -m "feat(Step 18-B): 환경 감지 HTTP 강화 + 가격수집 실전테스트 + 수집위젯

    - detect_environment(): TCP → HTTP 응답 기반 (User-Agent + 마커 검증)
    - /api/health에 env_detection_detail, env_checked_at 추가
    - /api/env/recheck: 수동 재감지 (VPN 토글 후 사용)
    - /api/env/test-price-collection: JQ4110으로 실전 가격수집 1회
    - /api/daily-summary에 last_collection_at, prices_collected_today
    - 대시보드 6번째 카드 (24h 이상 미수집 시 노란색 경고)

    배경: TCP만으로는 Cloudflare 지역차단 미감지 → HTTP 레벨로 정확화"

11. git push origin main

12. 끝.

검증 FAIL 시 즉시 종료. 백업 복원은 외부 스크립트가 처리.
질문/확인 요청 절대 금지.
CLAUDE_PROMPT

echo ""
echo "🔍 최종 검증..."
verify_server || fail_and_restore "최종 검증"

# 핵심 API 검증
echo ""
echo "  📋 핵심 API 검증:"

ENV_DETAIL=$(curl -s http://localhost:5001/api/health | python3 -c "
import sys,json
try: 
    d=json.load(sys.stdin)
    print(d.get('env_detection_detail','MISSING'))
except: print('ERROR')
" 2>/dev/null)
echo "    env_detection_detail: $ENV_DETAIL"
if [ "$ENV_DETAIL" == "MISSING" ] || [ "$ENV_DETAIL" == "ERROR" ]; then
    fail_and_restore "env_detection_detail 누락"
fi

# 환경 재감지 결과
RECHECK=$(curl -s -X POST http://localhost:5001/api/env/recheck | python3 -c "
import sys,json
try: 
    d=json.load(sys.stdin)
    print(f\"env={d.get('environment')} accessible={d.get('accessible')} detail={d.get('detail')}\")
except: print('ERROR')
" 2>/dev/null)
echo "    recheck: $RECHECK"

# 실전 가격 수집 테스트
echo ""
echo "  🔬 실전 가격 수집 테스트 (JQ4110)..."
TEST_RESULT=$(curl -s -X POST http://localhost:5001/api/env/test-price-collection \
  -H 'Content-Type: application/json' -d '{}' \
  --max-time 90 | python3 -c "
import sys,json
try: 
    d=json.load(sys.stdin)
    has_data = d.get('has_data', False)
    sizes = d.get('sizes_count', 0)
    print(f\"has_data={has_data} sizes={sizes}\")
except: print('ERROR')
" 2>/dev/null)
echo "    결과: $TEST_RESULT"

# 일일 요약 확인
SUMMARY_HAS_PRICES=$(curl -s http://localhost:5001/api/daily-summary | python3 -c "
import sys,json
try: 
    d=json.load(sys.stdin)
    print('YES' if 'prices_collected_today' in d.get('summary',{}) else 'NO')
except: print('NO')
" 2>/dev/null)
echo "    daily-summary에 prices_collected_today: $SUMMARY_HAS_PRICES"

if [ "$SUMMARY_HAS_PRICES" != "YES" ]; then
    fail_and_restore "daily-summary 가격수집 키 누락"
fi

grep -q 'dsc-card-prices' kream_dashboard.html && echo "    ✅ 대시보드 6번째 카드 주입됨" || echo "    ⚠️  6번째 카드 누락"

FINAL_HASH=$(git log -1 --format=%h)
echo ""
echo "  ✅ 커밋: $FINAL_HASH"
echo ""

# ==========================================
# [STAGE 4] 환경 결과 분석 + 컨텍스트 v10
# ==========================================
echo "════════════════════ [STAGE 4] 환경 결과 분석 ════════════════════"

CURRENT_ENV=$(curl -s http://localhost:5001/api/health | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('environment','unknown'))
except: print('error')
" 2>/dev/null)

CURRENT_DETAIL=$(curl -s http://localhost:5001/api/health | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('env_detection_detail','unknown'))
except: print('error')
" 2>/dev/null)

echo ""
echo "  📊 최종 환경 판정:"
echo "    environment: $CURRENT_ENV"
echo "    detection_detail: $CURRENT_DETAIL"

# TCP는 통과하지만 HTTP 차단인 경우 안내
if [ "$PREV_ENV" == "imac_kr" ] && [ "$CURRENT_ENV" == "macbook_overseas" ]; then
    echo ""
    echo "  💡 분석: TCP 연결은 통과했지만 HTTP 응답에서 차단 확인됨"
    echo "     → Cloudflare 지역 차단 가능성 높음. 메모리 기록과 일치."
elif [ "$CURRENT_ENV" == "imac_kr" ]; then
    echo ""
    echo "  💡 분석: HTTP까지 통과 → kream.co.kr 실제 접근 가능"
    echo "     → VPN 켜져있거나 차단 풀린 상태. 가격 수집 활용 가능."
fi
echo ""

# 컨텍스트 v10
PA_PENDING=$(sqlite3 price_history.db "SELECT COUNT(*) FROM price_adjustments WHERE status='pending'" 2>/dev/null || echo "?")
SALES_COUNT=$(sqlite3 price_history.db "SELECT COUNT(*) FROM sales_history" 2>/dev/null || echo "?")
LATEST_SALE=$(sqlite3 price_history.db "SELECT MAX(trade_date) FROM sales_history" 2>/dev/null || echo "?")

cat > "다음세션_시작_컨텍스트_v10.md" <<MDEOF
# 다음 세션 시작 컨텍스트 v10

> 작성일: $(date '+%Y-%m-%d %H:%M:%S') (자동 생성)
> 직전 커밋: $(git log -1 --format='%h %s')

## 1. 최근 작업 (2026-05-02 단일 세션, 누적)

| 작업 | 커밋 | 비고 |
|---|---|---|
| JQ4110 ONE_SIZE 진단 | 490da5a | 입찰 3건 분석 |
| 130k 1차 삭제 | 361254a | 5분 지연 미반영 |
| 130k 재삭제 성공 | e5dd7e8 | 5분 후 반영 확인 |
| 도움말 시스템 12개 탭 | 3df382d | ❓ 버튼 + 모달 |
| Step 18-A | ff97377 | 삭제검증+환경감지+요약위젯 |
| Step 18-B | $FINAL_HASH | 환경HTTP강화+실전테스트+수집위젯 |

## 2. 현재 환경 (HTTP 기반 정확 감지)

- environment: **$CURRENT_ENV**
- detection_detail: $CURRENT_DETAIL
- 가격 수집 가능 여부: $([ "$CURRENT_ENV" == "imac_kr" ] && echo "✅ 가능" || echo "🚫 차단")

## 3. 신규 API (Step 18-B)

- POST /api/env/recheck — 수동 환경 재감지 (VPN 토글 후 사용)
- POST /api/env/test-price-collection — JQ4110으로 실전 수집 1회
- /api/health에 env_detection_detail, env_checked_at 추가
- /api/daily-summary에 last_collection_at, prices_collected_today

## 4. DB 현황

| 테이블 | 건수 |
|---|---|
| pa_pending | $PA_PENDING |
| sales_history | $SALES_COUNT |
| 최근 trade_date | $LATEST_SALE |

## 5. 다음 작업 후보

$(if [ "$CURRENT_ENV" == "imac_kr" ]; then
echo "### 1순위 — 가격 수집 본격 가동
- 환경 정상 → 자동 조정 dry_run 모드 24h 가동
- pending 7건 실제 시장 분석"
else
echo "### 1순위 — VPN 켜고 환경 복원
- 한국 VPN 연결 후 \`curl -X POST /api/env/recheck\`
- accessible=true 되면 가격 수집 자동 활성화"
fi)

### 2순위 — Step 18-C 자동 조정 dry_run
- auto_adjust_enabled=false 유지하고 _dry_run 플래그로 시뮬레이션
- 실제 가격 수정은 안 하고 결정만 로그
- 24h 패턴 분석 후 실제 ON 검토

### 3순위 — 판매 패턴 분석 강화
- sales_history 8건 → 누적 후 시간대/요일 인사이트

## 6. 다음 채팅 첫 메시지 템플릿

\`\`\`
다음세션_시작_컨텍스트_v10.md 읽고 현재 상태 파악.
직전 커밋 $FINAL_HASH (Step 18-B 완료).
환경: $CURRENT_ENV ($CURRENT_DETAIL)

오늘 작업: [기획해서 가져오기 / 구체 지시]

알아서 끝까지. 질문 최소화.
\`\`\`

## 7. 절대 규칙 (CLAUDE.md)

7대 규칙 그대로 유지.
MDEOF

echo "  ✅ 다음세션_시작_컨텍스트_v10.md 생성"
git add 다음세션_시작_컨텍스트_v10.md pipeline_step18b.log 2>/dev/null
git commit -m "docs: 다음세션 컨텍스트 v10 (Step 18-B 완료)" 2>/dev/null || echo "  (변경 없음)"
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
echo "🎉 Step 18-B 완료 — ${ELAPSED_MIN}분 ${ELAPSED}초"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "✅ 결과:"
echo "  - 환경 감지: TCP → HTTP 강화"
echo "  - 최종 판정: $CURRENT_ENV ($CURRENT_DETAIL)"
echo "  - 가격수집 실전 테스트: $TEST_RESULT"
echo "  - 대시보드 6번째 카드 (가격수집 상태)"
echo "  - 커밋: $FINAL_HASH"
echo ""
echo "📋 활용:"
echo "  - VPN 켜고/끄고 → curl -X POST http://localhost:5001/api/env/recheck"
echo "  - 가격수집 테스트 → curl -X POST http://localhost:5001/api/env/test-price-collection"
echo "  - 대시보드 새로고침 → 카드 6개 (오늘 가격수집 포함)"
echo ""
echo "📜 로그: pipeline_step18b.log"
echo ""
