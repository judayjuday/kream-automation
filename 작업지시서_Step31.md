# Step 31 — 4개 도구 일괄 + 버그 수정

> 환경: 한국, kream.co.kr 접속 가능
> 비즈니스: 구매대행
> 절대 규칙 + 자동 토글 ON 변경 금지

## 버그 수정

### Bug 1: kream_server.py — calc-batch NameError

기존 /api/new-bid/calc-batch 안에서 margin_status_msg 호출하는데 함수가 라우트 _아래_ 정의됨.

해결: 함수를 라우트 _위로_ 이동, 이름을 _calc_margin_status_msg로 변경:

```python
def _calc_margin_status_msg(status, margin, min_margin):
    if status == 'LOW':
        return f'마진 {round(margin):,}원 < {min_margin:,} (단가 협상 필요)'
    if status == 'DEFICIT':
        return f'적자 {round(margin):,}원 (입찰 불가)'
    return ''
```

라우트 안의 호출도 _calc_margin_status_msg(...)로 교체.

### Bug 2: kream_adjuster.py — sync v2 로그 안 보임

collect_my_bids_via_menu 안의 print(...)가 server.log에 안 잡힘.

해결: 모두 다음으로 교체:
```python
import sys  # 파일 상단에 추가 (없으면)
print(..., flush=True, file=sys.stderr)
```

또는 sys.stderr.write("[SYNC-V2] ...\n"); sys.stderr.flush()

## 작업 #1: 신규 입찰 일괄 도구

### POST /api/new-bid/auto-fetch-prices

```python
@app.route('/api/new-bid/auto-fetch-prices', methods=['POST'])
def api_new_bid_auto_fetch():
    data = request.get_json() or {}
    models = data.get('models', [])
    if not models:
        return jsonify({'ok': False, 'error': 'models required'}), 400
    
    results = []
    for model in models[:20]:
        try:
            r = requests.post('http://localhost:5001/api/search', 
                              json={'model': model}, timeout=60)
            if r.status_code == 200:
                d = r.json()
                sizes = d.get('sizes', []) or d.get('size_prices', [])
                results.append({'model': model, 'ok': True, 'sizes': sizes})
            else:
                results.append({'model': model, 'ok': False, 'error': f'HTTP {r.status_code}'})
        except Exception as e:
            results.append({'model': model, 'ok': False, 'error': str(e)})
    
    return jsonify({'ok': True, 'count': len(results), 'results': results})
```

### tabs/tab_new_bid.html 신규 (멱등)

UI 흐름:
1. textarea에 모델/CNY 입력 (한 줄당: 모델 [TAB] CNY숫자)
2. "시장가 수집" 버튼 → /api/new-bid/auto-fetch-prices 호출
3. 받은 시장가로 /api/new-bid/calc-batch 호출 → 결과 테이블 표시
4. GO 항목 자동 체크 → "선택 항목 큐 등록" 버튼

(Claude Code가 이 패턴으로 자유롭게 구현, 사이드바 메뉴 패턴 일치)

## 작업 #2: 마진 계산기 강화

기존 tabs/tab_margin.html 끝에 두 섹션 추가 (id="margin-batch" 있으면 스킵):

1. **margin-batch**: 사이즈별 행 추가 + 일괄 마진 계산
2. **margin-rotation**: 모델 입력 → /api/model/<model>/deep-analysis 호출 → 회전 통계

## 작업 #3: 판매 마진 확정

### GET /api/realized-margin/cumulative

```python
@app.route('/api/realized-margin/cumulative', methods=['GET'])
def api_realized_margin_cumulative():
    try:
        r = requests.get('http://localhost:5001/api/real-margin?days=365', timeout=10)
        rm = r.json()
        if not rm.get('ok'):
            return jsonify({'ok': False, 'error': 'real-margin 호출 실패'}), 500
        
        items = rm.get('items', [])
        from collections import defaultdict
        monthly = defaultdict(lambda: {'count': 0, 'revenue': 0, 'margin': 0, 'unknown_count': 0})
        by_model = defaultdict(lambda: {'count': 0, 'revenue': 0, 'margin': 0, 'has_cost': 0})
        
        for it in items:
            d = it.get('trade_date', '')
            if not d: continue
            month = d[:7]
            monthly[month]['count'] += 1
            monthly[month]['revenue'] += it.get('sale_price', 0)
            if it.get('margin') is not None:
                monthly[month]['margin'] += it['margin']
            else:
                monthly[month]['unknown_count'] += 1
            
            model = it.get('model', '?')
            by_model[model]['count'] += 1
            by_model[model]['revenue'] += it.get('sale_price', 0)
            if it.get('margin') is not None:
                by_model[model]['margin'] += it['margin']
                by_model[model]['has_cost'] += 1
        
        return jsonify({
            'ok': True,
            'monthly': sorted([{'month':k, **v} for k,v in monthly.items()], key=lambda x: x['month']),
            'top_models': sorted(
                [{'model':k, **v, 'avg_margin': round(v['margin']/v['has_cost']) if v['has_cost'] else None} 
                 for k,v in by_model.items()],
                key=lambda x: -x['count']
            )[:10],
            'total_count': len(items),
            'total_revenue': sum(it.get('sale_price', 0) for it in items),
            'total_confirmed_margin': sum(it.get('margin', 0) for it in items if it.get('margin') is not None),
        })
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500
```

### tabs/tab_realized.html 신규 (멱등)

월별 막대 차트 + 모델별 ROI 테이블.

## 작업 #4: 시장 모니터링

### DB 마이그레이션

```python
def _migrate_market_price_history():
    try:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("""
            CREATE TABLE IF NOT EXISTS market_price_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                model TEXT NOT NULL,
                size TEXT,
                buy_price INTEGER,
                recent_price INTEGER,
                collected_at TEXT NOT NULL,
                created_at TEXT DEFAULT CURRENT_TIMESTAMP
            )
        """)
        c.execute("CREATE INDEX IF NOT EXISTS idx_mph_model_collected ON market_price_history(model, collected_at)")
        conn.commit()
        conn.close()
        print("[MIGRATE] market_price_history 확인/생성")
    except Exception as e:
        print(f"[MIGRATE] market_price_history 에러: {e}")
```

if __name__ 블록에서 _migrate_market_price_history() 호출.

### 자동 수집

```python
def _collect_active_models_market_prices():
    try:
        from pathlib import Path
        local_path = Path(__file__).parent / 'my_bids_local.json'
        active_models = []
        if local_path.exists():
            local = json.loads(local_path.read_text(encoding='utf-8'))
            active_models = list(set(b.get('model') for b in local.get('bids', []) if b.get('model')))
        
        if not active_models:
            conn = sqlite3.connect(DB_PATH)
            c = conn.cursor()
            c.execute("SELECT DISTINCT model FROM sales_history WHERE model IS NOT NULL ORDER BY trade_date DESC LIMIT 10")
            active_models = [r[0] for r in c.fetchall()]
            conn.close()
        
        if not active_models:
            print("[MARKET-COLLECT] 수집할 모델 없음")
            return
        
        from datetime import datetime
        now_iso = datetime.now().isoformat()
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        success = 0
        for model in active_models[:30]:
            try:
                r = requests.post('http://localhost:5001/api/search', json={'model': model}, timeout=60)
                if r.status_code != 200: continue
                d = r.json()
                sizes = d.get('sizes', []) or d.get('size_prices', [])
                for sz in sizes:
                    c.execute("""
                        INSERT INTO market_price_history 
                        (model, size, buy_price, recent_price, collected_at)
                        VALUES (?, ?, ?, ?, ?)
                    """, (model, sz.get('size'),
                          sz.get('buy_price') or sz.get('buyPrice'),
                          sz.get('recent_price'), now_iso))
                success += 1
            except Exception as e:
                print(f"[MARKET-COLLECT] {model} 실패: {e}")
        conn.commit()
        conn.close()
        print(f"[MARKET-COLLECT] {success}/{len(active_models)} 모델 수집")
    except Exception as e:
        print(f"[MARKET-COLLECT] 에러: {e}")

# scheduler.add_job 2h interval
try:
    scheduler.add_job(
        _collect_active_models_market_prices,
        'interval', hours=2,
        id='market_price_collect',
        replace_existing=True,
        misfire_grace_time=600
    )
    print("[SCHEDULER] market_price_collect 등록 (2h)")
except Exception as e:
    print(f"[SCHEDULER] market_price_collect 실패: {e}")
```

### GET /api/market/history/<model>, /api/market/alerts, POST /api/market/collect-now

(코드는 작업지시서 본문 또는 Claude Code가 작성)

### tabs/tab_market.html 신규 (멱등)

급변 알림 + 모델별 가격 추이 조회.

## 사이드바 + 도움말

kream_dashboard.html에 메뉴 3개 추가 (멱등):
- 🆕 신규 입찰 (data-tab="new_bid")
- 💰 판매 마진 확정 (data-tab="realized")
- 📈 시장 모니터링 (data-tab="market")

help_content.json에 3개 키 추가 (멱등): new_bid / realized / market

## 검증

1. python3 -m py_compile kream_server.py + kream_adjuster.py
2. 서버 재시작 → server.log에 [MIGRATE] market_price_history + [SCHEDULER] market_price_collect
3. /api/new-bid/calc-batch (NameError 수정 확인)
4. /api/new-bid/auto-fetch-prices (시간 걸려도 OK)
5. /api/realized-margin/cumulative
6. /api/market/alerts, /api/market/history/<model>
7. tabs/ 3개 파일 + 200 OK
8. /api/help/<3개> ok
9. 회귀: capital-status, daily-summary, cleanup/diagnose, portfolio/overview

## 절대 규칙
- 자동 토글 ON 변경 금지
- DB CREATE IF NOT EXISTS만
- 기존 라우트 시그니처 변경 금지

## 커밋
```
feat(Step 31): 4개 도구 일괄 + 버그 수정

도구:
- 🆕 신규 입찰 일괄 도구 (모델/CNY → 시장가 자동 → 마진 → 큐)
- 💰 마진 계산기 강화 (사이즈 일괄 + 회전 시간)
- 📊 판매 마진 확정 (월별 + 모델 ROI)
- 📈 시장 모니터링 (DB + 2h 자동 수집 + 알림 + 차트)

버그:
- /api/new-bid/calc-batch margin_status_msg NameError 수정
- collect_my_bids_via_menu 로그 stderr로 (가시성 확보)

배경: 한국 환경 + 구매대행
```
