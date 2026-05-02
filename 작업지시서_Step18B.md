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
