# 작업지시서 — Step 22: 구매대행 모델 반영 + 정리 + 진짜 KPI

> 의존: Step 21 (커밋 771a6d2)
> 환경: macbook_overseas
> 비즈니스 모델: 구매대행 (입찰 체결 시점에 매입, 그 전엔 자본 안 묶임)
> 절대 규칙 (CLAUDE.md) + 자동 토글 ON 변경 금지

## 비즈니스 모델 명확화 (중요)

기존 코드의 "tied_total"은 _묶인 자본_이 아니라 _활성 입찰 노출액_(체결 시 발생할 매입원가)이다.
- 구매대행: 입찰 → 체결 → 그 시점에 매입 → 발송
- 따라서 "회수"는 자본 회수가 아니라 _죽은 입찰 정리_
- ROI보다 중요한 KPI: **체결률**(걸어둔 입찰 중 체결되는 비율) + **건당 실제 마진**

## 작업 #1: 자본 라벨 정정

### kream_server.py - /api/capital-status 응답 확장

기존 라우트의 응답 dict에 라벨 추가 (기존 키 변경 금지):

```python
# 기존 응답 dict에 다음 키 추가:
return jsonify({
    'ok': True,
    'tied_total': round(tied_total),
    'tied_count': len(active_bids),
    # ... 기존 키들 ...
    
    # NEW: 라벨링 (구매대행 모델 반영)
    'labels': {
        'tied_total': '활성 입찰 노출액',
        'tied_count': '활성 입찰',
        'recoverable': '정리 가능 노출액',
        'recoverable_count': '정리 가능 건',
        'business_model': 'consignment_purchase',
        'note': '구매대행: 체결 시점에 매입, 입찰만으로는 자본 미지출'
    }
})
```

### kream_dashboard.html - 카드 텍스트 수정

기존 dsc-card-capital 카드 안의 "묶인 자본" 텍스트 찾아서 "노출 입찰액"으로 변경.
"회수 가능" → "정리 가능"

차트 모달 제목 "💰 자본 추이" → "📊 입찰 노출액 추이"

기존 텍스트 검색 후 일괄 변경 (sed 패턴 활용 가능):
- '묶인 자본' → '노출 입찰액'  
- '회수 가능' → '정리 가능'
- '자본 추이' → '입찰 노출액 추이'
- '💰 자본 추이' → '📊 입찰 노출액 추이'

이미 변경된 곳은 스킵 (멱등성).

## 작업 #2: 실제 체결 기준 마진 + 체결률

### 신규 라우트: /api/real-margin

판매 이력에 join한 _실제 마진_:

```python
@app.route('/api/real-margin', methods=['GET'])
def api_real_margin():
    """판매 체결된 건의 실제 bid_cost join → 진짜 마진."""
    try:
        from datetime import datetime, timedelta
        days = request.args.get('days', 30, type=int)
        since = (datetime.now() - timedelta(days=days)).strftime('%Y-%m-%d')
        
        try:
            settings = json.loads(Path(__file__).parent.joinpath('settings.json').read_text(encoding='utf-8'))
        except:
            settings = {}
        fee_rate = settings.get('commission_rate', 6) / 100
        fixed_fee = 2500
        overseas_ship_default = settings.get('overseas_shipping', 8000)
        
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        
        # sales LEFT JOIN bid_cost
        c.execute("""
            SELECT s.order_id, s.model, s.size, s.sale_price, s.trade_date,
                   b.cny_price, b.exchange_rate, b.overseas_shipping
            FROM sales_history s
            LEFT JOIN bid_cost b ON s.order_id = b.order_id
            WHERE DATE(s.trade_date) >= ?
            ORDER BY s.trade_date DESC
        """, (since,))
        rows = c.fetchall()
        
        items = []
        confirmed_revenue = 0
        confirmed_cost = 0
        confirmed_margin = 0
        confirmed_count = 0
        unknown_cost_count = 0
        unknown_revenue = 0
        
        for r in rows:
            order_id, model, size, sale_price, trade_date, cny, fx, ship = r
            sale_price = sale_price or 0
            
            if cny is not None and fx is not None:
                ship = ship if ship is not None else overseas_ship_default
                cost = float(cny) * float(fx) * 1.03 + float(ship)
                settlement = sale_price * (1 - fee_rate * 1.1) - fixed_fee
                margin = settlement - cost
                items.append({
                    'order_id': order_id,
                    'model': model,
                    'size': size,
                    'sale_price': sale_price,
                    'trade_date': trade_date,
                    'cost': round(cost),
                    'margin': round(margin),
                    'confirmed': True
                })
                confirmed_revenue += sale_price
                confirmed_cost += cost
                confirmed_margin += margin
                confirmed_count += 1
            else:
                items.append({
                    'order_id': order_id,
                    'model': model,
                    'size': size,
                    'sale_price': sale_price,
                    'trade_date': trade_date,
                    'cost': None,
                    'margin': None,
                    'confirmed': False
                })
                unknown_cost_count += 1
                unknown_revenue += sale_price
        
        conn.close()
        
        return jsonify({
            'ok': True,
            'period_days': days,
            'total_sales': len(items),
            'confirmed': {
                'count': confirmed_count,
                'revenue': round(confirmed_revenue),
                'cost': round(confirmed_cost),
                'margin': round(confirmed_margin),
                'avg_margin': round(confirmed_margin / confirmed_count) if confirmed_count else 0,
                'margin_rate_pct': round((confirmed_margin / confirmed_revenue * 100) if confirmed_revenue else 0, 1),
            },
            'unknown_cost': {
                'count': unknown_cost_count,
                'revenue': round(unknown_revenue),
                'note': 'bid_cost 데이터 없어서 마진 계산 불가'
            },
            'items': items[:50],
            'note': '확정값(bid_cost 매칭 건)만 마진 계산. 추정 없음.'
        })
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500
```

### 신규 라우트: /api/conversion-rate

체결률 추이:

```python
@app.route('/api/conversion-rate', methods=['GET'])
def api_conversion_rate():
    """체결률: 활성 입찰 → 판매로 가는 비율 추이."""
    try:
        from datetime import datetime, timedelta
        days = request.args.get('days', 30, type=int)
        since_date = datetime.now() - timedelta(days=days)
        since = since_date.strftime('%Y-%m-%d')
        
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        
        # 일별 판매
        c.execute("""
            SELECT DATE(trade_date) as d, COUNT(*) as cnt
            FROM sales_history
            WHERE DATE(trade_date) >= ?
            GROUP BY DATE(trade_date)
            ORDER BY d
        """, (since,))
        daily_sales = {r[0]: r[1] for r in c.fetchall()}
        
        # 현재 활성 입찰 수
        from pathlib import Path
        local_path = Path(__file__).parent / 'my_bids_local.json'
        active_bids = 0
        if local_path.exists():
            try:
                local = json.loads(local_path.read_text(encoding='utf-8'))
                active_bids = len(local.get('bids', []))
            except:
                pass
        
        # 누적 체결률 = 기간 내 판매 / (현재 활성 + 기간 내 판매)
        total_sales = sum(daily_sales.values())
        total_pool = active_bids + total_sales
        conversion_pct = (total_sales / total_pool * 100) if total_pool else 0
        
        # 일별 (단순화: 매일 활성 입찰을 일정하게 가정)
        items = []
        cur = since_date
        end = datetime.now()
        while cur <= end:
            d = cur.strftime('%Y-%m-%d')
            sales = daily_sales.get(d, 0)
            items.append({'date': d, 'sales': sales})
            cur += timedelta(days=1)
        
        conn.close()
        
        return jsonify({
            'ok': True,
            'period_days': days,
            'active_bids_now': active_bids,
            'total_sales_period': total_sales,
            'conversion_pct': round(conversion_pct, 1),
            'daily': items,
            'note': '체결률 = 기간 내 체결 / (현재 활성 + 기간 내 체결). 구매대행 모델의 핵심 KPI.'
        })
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500
```

## 작업 #3: 회수 권장 자동 정리

### 신규 라우트: /api/cleanup/auto-execute

```python
@app.route('/api/cleanup/auto-execute', methods=['POST'])
def api_cleanup_auto_execute():
    """회수 권장 자동 정리. 안전장치는 bulk-withdraw 그대로 사용."""
    data = request.get_json() or {}
    dry_run = data.get('dry_run', False)
    
    try:
        # 1. 진단 실행
        diag_resp = api_cleanup_diagnose()
        if hasattr(diag_resp, 'get_json'):
            diag = diag_resp.get_json()
        else:
            diag = json.loads(diag_resp.data) if hasattr(diag_resp, 'data') else None
        
        if not diag or not diag.get('ok'):
            return jsonify({'ok': False, 'error': 'diagnose 실패'}), 500
        
        # 2. 회수 권장 추출 (withdraw_blocked는 제외, 마지막 재고 보호)
        target_ids = [
            it['orderId'] for it in diag.get('items', [])
            if it.get('recommendation') == 'withdraw'
        ]
        
        if not target_ids:
            return jsonify({
                'ok': True,
                'dry_run': dry_run,
                'targets': [],
                'note': '회수 권장 건 없음'
            })
        
        if dry_run:
            return jsonify({
                'ok': True,
                'dry_run': True,
                'targets': target_ids,
                'count': len(target_ids),
                'note': '실행하려면 dry_run=false로 다시 호출'
            })
        
        # 3. 정리 직전 자본 스냅샷
        cap_before_resp = api_capital_status()
        cap_before_data = cap_before_resp.get_json() if hasattr(cap_before_resp, 'get_json') else json.loads(cap_before_resp.data)
        capital_before = cap_before_data.get('tied_total', 0) if cap_before_data.get('ok') else 0
        
        # 4. bulk-withdraw 위임 (force=false → 마지막 재고 자동 보호)
        import requests as rq
        r = rq.post('http://localhost:5001/api/cleanup/bulk-withdraw',
                    json={'orderIds': target_ids, 'force': False},
                    timeout=30)
        result = r.json()
        
        return jsonify({
            'ok': True,
            'dry_run': False,
            'requested': len(target_ids),
            'result': result,
            'capital_before': capital_before,
            'note': '5분 후 /api/cleanup/effect-report로 효과 확인'
        })
    except Exception as e:
        import traceback
        return jsonify({'ok': False, 'error': str(e), 'trace': traceback.format_exc()}), 500


@app.route('/api/cleanup/effect-report', methods=['GET'])
def api_cleanup_effect():
    """capital_history에서 최근 변화 자동 분석."""
    try:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("""
            SELECT timestamp, tied_total, tied_count, recoverable, recoverable_count
            FROM capital_history
            ORDER BY timestamp DESC LIMIT 10
        """)
        rows = c.fetchall()
        conn.close()
        
        if len(rows) < 2:
            return jsonify({
                'ok': True,
                'sufficient_data': False,
                'note': 'capital_history 데이터 부족. 1시간 후 재시도.'
            })
        
        # 가장 최신과 가장 오래된 비교
        latest = rows[0]
        oldest = rows[-1]
        
        return jsonify({
            'ok': True,
            'sufficient_data': True,
            'before': {
                'timestamp': oldest[0], 'tied_total': oldest[1], 
                'tied_count': oldest[2], 'recoverable': oldest[3]
            },
            'after': {
                'timestamp': latest[0], 'tied_total': latest[1], 
                'tied_count': latest[2], 'recoverable': latest[3]
            },
            'delta': {
                'tied_total': latest[1] - oldest[1],
                'tied_count': latest[2] - oldest[2],
                'recoverable': latest[3] - oldest[3],
            },
            'snapshots_count': len(rows)
        })
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500
```

## 작업 #4: 체결률 카드 + 대시보드 갱신

### kream_dashboard.html

daily-summary-cards div 안에 8번째 카드 추가 (이미 dsc-card-conversion 있으면 스킵):

```html
<div class="dsc-card" id="dsc-card-conversion" style="flex:1; min-width:160px; background:#fff7ed; border:1px solid #fed7aa; border-radius:8px; padding:12px;">
  <div style="font-size:12px; color:#9a3412;">체결률 (30일)</div>
  <div style="font-size:20px; font-weight:bold; color:#7c2d12;" id="dsc-conv-pct">-</div>
  <div style="font-size:10px; color:#c2410c; margin-top:4px;" id="dsc-conv-detail">-</div>
</div>
```

loadDailySummary 함수에 추가:

```javascript
// 체결률
try {
  const r = await fetch('/api/conversion-rate?days=30');
  const d = await r.json();
  if (d.ok) {
    const pctEl = document.getElementById('dsc-conv-pct');
    const detailEl = document.getElementById('dsc-conv-detail');
    if (pctEl) pctEl.textContent = d.conversion_pct + '%';
    if (detailEl) detailEl.textContent = `활성 ${d.active_bids_now} / 체결 ${d.total_sales_period}`;
  }
} catch(e) {}
```

## 검증

1. python3 -m py_compile kream_server.py → 0
2. 서버 재시작
3. /api/capital-status → response에 labels 키 존재
4. /api/real-margin?days=30 → ok=true, confirmed 객체, unknown_cost 객체
5. /api/conversion-rate?days=30 → ok=true, conversion_pct 키
6. /api/cleanup/auto-execute POST {"dry_run":true} → targets 배열 반환 (실제 실행 X)
7. /api/cleanup/effect-report → ok=true (sufficient_data 키 존재)
8. 대시보드 HTML에 dsc-card-conversion 마커 존재
9. 회귀: capital-status, daily-summary, cleanup/diagnose, portfolio/overview, capital-efficiency 모두 ok

## 자동 정리 실행 단계 (검증 후 별도)

본 스크립트의 외부 검증 단계에서 dry_run으로 먼저 확인 후, 사장 의사를 바탕으로 실행 진행.

## 절대 규칙
- 자동 토글 ON 변경 금지
- bulk-withdraw 안전장치 절대 우회 금지 (force=false 유지)
- DB 스키마 변경 금지 (capital_history는 Step 21에서 이미 생성)
- 판매 완료 건 보호 (CLAUDE.md #2)

## 커밋 메시지
```
feat(Step 22): 구매대행 모델 반영 + 정리 자동화 + 체결률 KPI

- /api/capital-status 응답에 labels 추가 (활성 입찰 노출액)
- 대시보드 텍스트 정정: 묶인 자본 → 노출 입찰액, 회수→정리
- /api/real-margin: bid_cost join한 확정 마진 (추정 제거)
- /api/conversion-rate: 체결률 추이 (구매대행 핵심 KPI)
- 8번째 카드: 체결률
- /api/cleanup/auto-execute: 회수 권장 자동 정리 (dry_run 지원)
- /api/cleanup/effect-report: 정리 전후 변화 자동 비교

배경: 구매대행 모델에서는 입찰 ≠ 자본 지출. 진짜 KPI는 체결률.
```
