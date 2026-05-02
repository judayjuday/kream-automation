# 작업지시서 — Step 20: 자본 + 우회 + 모델분석 + 의사결정

> 의존: Step 19 (커밋 358985b)
> 환경: macbook_overseas
> 절대 규칙 (CLAUDE.md) 모두 준수
> 자동 토글 ON 변경 금지 (자동 입찰/조정/재입찰/정리/PDF OFF 유지)
> 모든 신규 기능: 진단/표시만, 자동 액션 없음

## 작업 #1: 묶인 자본 추적

### 신규 라우트: /api/capital-status

```python
@app.route('/api/capital-status', methods=['GET'])
def api_capital_status():
    """현재 입찰에 묶인 자본 + 회수 가능 자본 분석."""
    try:
        from pathlib import Path
        from collections import defaultdict
        
        local_path = Path(__file__).parent / 'my_bids_local.json'
        if not local_path.exists():
            return jsonify({'ok': True, 'tied_total': 0, 'items': []})
        
        local = json.loads(local_path.read_text(encoding='utf-8'))
        bids = local.get('bids', [])
        
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        
        # 판매 완료 제외
        try:
            c.execute("SELECT DISTINCT order_id FROM sales_history WHERE order_id IS NOT NULL")
            sold_ids = {row[0] for row in c.fetchall()}
        except:
            sold_ids = set()
        
        active_bids = [b for b in bids if b.get('orderId') not in sold_ids]
        
        # 입찰 1건당 자본 = 원가(CNY × 환율 × 1.03 + 해외배송)
        # 원가 미등록은 추정치(평균) 사용
        tied_total = 0
        tied_by_model = defaultdict(lambda: {'count': 0, 'capital': 0})
        recoverable = 0  # 회수 권장(rank>1 + 조정해도 마진 미달) 자본
        recoverable_count = 0
        unknown_cost_count = 0
        
        # 회수 권장 판단: cleanup/diagnose의 추천 결과 활용
        # 직접 계산 (cleanup/diagnose 호출 회피)
        try:
            settings = json.loads(Path(__file__).parent.joinpath('settings.json').read_text(encoding='utf-8'))
        except:
            settings = {}
        fee_rate = settings.get('commission_rate', 6) / 100
        fixed_fee = 2500
        min_margin = settings.get('min_margin', 4000)
        undercut = settings.get('undercut_amount', 1000)
        overseas_ship_default = settings.get('overseas_shipping', 8000)
        
        # 평균 원가 추정용
        c.execute("SELECT AVG(cny_price * exchange_rate * 1.03 + COALESCE(overseas_shipping, ?)) FROM bid_cost", 
                  (overseas_ship_default,))
        avg_cost_row = c.fetchone()
        avg_cost = avg_cost_row[0] if avg_cost_row and avg_cost_row[0] else 50000  # 기본 추정
        
        for b in active_bids:
            order_id = b.get('orderId')
            model = b.get('model', '-')
            price = b.get('price') or 0
            rank = b.get('rank')
            
            # 원가 조회
            c.execute("""
                SELECT cny_price, exchange_rate, overseas_shipping
                FROM bid_cost WHERE order_id = ?
            """, (order_id,))
            row = c.fetchone()
            
            if row and row[0] is not None and row[1] is not None:
                ship = row[2] if row[2] is not None else overseas_ship_default
                cost = float(row[0]) * float(row[1]) * 1.03 + float(ship)
                cost_known = True
            else:
                cost = avg_cost
                cost_known = False
                unknown_cost_count += 1
            
            tied_total += cost
            tied_by_model[model]['count'] += 1
            tied_by_model[model]['capital'] += cost
            
            # 회수 권장 여부 (rank>1 + 마진 미달)
            if rank and rank > 1 and cost_known:
                settlement = price * (1 - fee_rate * 1.1) - fixed_fee
                margin = settlement - cost
                # 조정해도 마진 미달
                hyp_settlement = (price - undercut) * (1 - fee_rate * 1.1) - fixed_fee
                hyp_margin = hyp_settlement - cost
                if hyp_margin < min_margin:
                    recoverable += cost
                    recoverable_count += 1
        
        conn.close()
        
        # 모델별 정렬 (자본 큰 순)
        sorted_models = sorted(tied_by_model.items(), key=lambda x: -x[1]['capital'])[:10]
        
        return jsonify({
            'ok': True,
            'tied_total': round(tied_total),
            'tied_count': len(active_bids),
            'unknown_cost_count': unknown_cost_count,
            'recoverable': round(recoverable),
            'recoverable_count': recoverable_count,
            'top_models': [
                {'model': m, 'count': v['count'], 'capital': round(v['capital'])}
                for m, v in sorted_models
            ],
            'avg_cost_estimate': round(avg_cost),
        })
    except Exception as e:
        import traceback
        return jsonify({'ok': False, 'error': str(e), 'trace': traceback.format_exc()}), 500
```

## 작업 #2: 판매자센터 경쟁가 추출 (가격수집 우회)

판매자센터 my-bids 페이지에서 sync할 때 _경쟁자 최저가_도 같이 가져옴.
이미 sync는 정상 동작하니까, 추출 정보만 확장.

### kream_bot.py — collect_my_bids 함수 확장

기존 my-bids 수집 로직(보통 collect_my_bids 또는 sync_my_bids)을 찾아서:

```python
# 기존 _parse_bid_row 또는 비슷한 함수에서 cells 파싱 시 추가:
# 판매자센터 입찰 테이블에 경쟁자 최저가가 있으면 추출
# 보통 "현재 최저가 N원" 또는 별도 컬럼으로 표시됨

# 셀 텍스트에서 패턴 매칭:
import re

def _extract_competitor_price(row_text_or_cells):
    """행 전체 텍스트나 셀에서 경쟁가 추출. 없으면 None."""
    if isinstance(row_text_or_cells, list):
        text = ' '.join(str(c) for c in row_text_or_cells)
    else:
        text = str(row_text_or_cells)
    
    # 패턴: "최저가 123,456원" / "현재 123,456원" / "시세 123,456원" 등
    patterns = [
        r'최저가?\s*([\d,]+)\s*원',
        r'시세\s*([\d,]+)\s*원',
        r'현재\s*([\d,]+)\s*원',
    ]
    for p in patterns:
        m = re.search(p, text)
        if m:
            try:
                return int(m.group(1).replace(',', ''))
            except:
                pass
    return None
```

기존 sync 결과 dict에 `market_lowest_price` 키 추가 (있으면).
이미 패턴 매칭이 있다면 변경 금지.

이 작업은 데이터 추출 가능성이 KREAM 페이지 구조에 의존하므로, **best-effort로 구현 + 실패 시 None 저장**.

### 신규 라우트: /api/market-prices/from-bids

기존 my_bids_local.json에서 market_lowest_price 추출:

```python
@app.route('/api/market-prices/from-bids', methods=['GET'])
def api_market_prices_from_bids():
    """my_bids_local에서 추출한 경쟁가 (가격수집 우회 데이터)."""
    try:
        from pathlib import Path
        from collections import defaultdict
        
        local_path = Path(__file__).parent / 'my_bids_local.json'
        if not local_path.exists():
            return jsonify({'ok': True, 'items': [], 'note': 'local cache 없음'})
        
        local = json.loads(local_path.read_text(encoding='utf-8'))
        bids = local.get('bids', [])
        
        # market_lowest_price가 있는 건만
        items = []
        for b in bids:
            mlp = b.get('market_lowest_price') or b.get('marketLowestPrice')
            if mlp:
                items.append({
                    'orderId': b.get('orderId'),
                    'model': b.get('model'),
                    'size': b.get('size'),
                    'my_price': b.get('price'),
                    'market_lowest': mlp,
                    'rank': b.get('rank'),
                    'gap': mlp - (b.get('price') or 0),
                })
        
        # 모델별 그룹
        by_model = defaultdict(list)
        for it in items:
            by_model[it['model']].append(it)
        
        return jsonify({
            'ok': True,
            'count': len(items),
            'items': items,
            'by_model': dict(by_model),
            'last_sync': local.get('last_sync') or local.get('updated_at'),
            'note': '판매자센터에서 sync 시 추출한 경쟁가. KREAM 일반사이트 수집 우회'
        })
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500
```

## 작업 #3: 모델 종합 분석

### 신규 라우트: /api/model/<model>/deep-analysis

```python
@app.route('/api/model/<path:model>/deep-analysis', methods=['GET'])
def api_model_deep(model):
    """특정 모델 종합 분석: 입찰/판매이력/마진/추이."""
    try:
        from pathlib import Path
        from collections import defaultdict
        
        # 1. 현재 입찰
        local_path = Path(__file__).parent / 'my_bids_local.json'
        bids = []
        if local_path.exists():
            local = json.loads(local_path.read_text(encoding='utf-8'))
            bids = [b for b in local.get('bids', []) if b.get('model') == model]
        
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        
        # 2. 판매 이력
        c.execute("""
            SELECT size, sale_price, trade_date, ship_status
            FROM sales_history
            WHERE model = ?
            ORDER BY trade_date DESC
        """, (model,))
        sales = [
            {'size': r[0], 'price': r[1], 'date': r[2], 'status': r[3]}
            for r in c.fetchall()
        ]
        
        # 3. 가격 조정 이력
        try:
            c.execute("""
                SELECT old_price, new_price, expected_profit, status, executed_at
                FROM price_adjustments
                WHERE model = ?
                ORDER BY created_at DESC LIMIT 20
            """, (model,))
            adjustments = [
                {'old': r[0], 'new': r[1], 'profit': r[2], 'status': r[3], 'at': r[4]}
                for r in c.fetchall()
            ]
        except:
            adjustments = []
        
        # 4. 원가 정보
        c.execute("""
            SELECT order_id, size, cny_price, exchange_rate, overseas_shipping
            FROM bid_cost
            WHERE model = ?
        """, (model,))
        costs = [
            {'order_id': r[0], 'size': r[1], 'cny': r[2], 'fx': r[3], 'ship': r[4]}
            for r in c.fetchall()
        ]
        
        conn.close()
        
        # 5. 통계 계산
        total_sales = len(sales)
        total_revenue = sum(s.get('price') or 0 for s in sales)
        avg_sale_price = total_revenue / total_sales if total_sales else 0
        
        active_count = len(bids)
        rank_1_count = sum(1 for b in bids if b.get('rank') == 1)
        
        # 사이즈별 판매량
        size_freq = defaultdict(int)
        for s in sales:
            size_freq[s.get('size') or '-'] += 1
        
        # 회전 시간 계산 (입찰 등록 → 판매 평균)
        # bid_cost에는 created_at, sales_history에 trade_date 있으면 추정
        # 간단히: 최근 판매 5건의 trade_date 분포
        recent_sales_dates = [s['date'] for s in sales[:5] if s.get('date')]
        
        # 6. 추천 액션
        recommendation = 'monitor'
        rec_reason = ''
        if total_sales == 0:
            recommendation = 'no_data'
            rec_reason = '판매 이력 없음 — 충분히 누적 후 재평가'
        elif active_count == 0:
            recommendation = 'restock' if total_sales > 2 else 'consider'
            rec_reason = f'입찰 없음, 판매 {total_sales}건 → 재입찰 고려'
        elif rank_1_count == 0 and active_count > 0:
            recommendation = 'review_pricing'
            rec_reason = f'활성 입찰 {active_count}건 모두 1위 아님 → 가격 재검토'
        elif total_sales > 5 and rank_1_count >= active_count * 0.5:
            recommendation = 'expand'
            rec_reason = f'판매 {total_sales}건, 1위 비율 양호 → 사이즈/수량 확대 검토'
        
        return jsonify({
            'ok': True,
            'model': model,
            'summary': {
                'active_bids': active_count,
                'rank_1_bids': rank_1_count,
                'total_sales': total_sales,
                'total_revenue': total_revenue,
                'avg_sale_price': round(avg_sale_price),
                'has_cost_data': len(costs) > 0,
            },
            'bids': bids,
            'sales': sales[:30],  # 최근 30건
            'adjustments': adjustments,
            'costs': costs,
            'size_frequency': dict(size_freq),
            'recommendation': recommendation,
            'recommendation_reason': rec_reason,
        })
    except Exception as e:
        import traceback
        return jsonify({'ok': False, 'error': str(e), 'trace': traceback.format_exc()}), 500
```

## 작업 #4: 오늘의 의사결정 패널

### /api/daily-summary 확장

기존 daily-summary 핸들러에 decisions_pending 키 추가:

```python
# 기존 daily-summary summary dict에 다음 추가:

# 의사결정 필요 항목 자동 추출
decisions = []

# 1. cleanup/diagnose 결과 활용
try:
    diag_resp = api_cleanup_diagnose()
    if hasattr(diag_resp, 'get_json'):
        diag_data = diag_resp.get_json()
    else:
        diag_data = json.loads(diag_resp.data) if hasattr(diag_resp, 'data') else None
    
    if diag_data and diag_data.get('ok'):
        stats = diag_data.get('stats', {})
        if stats.get('withdraw', 0) > 0:
            decisions.append({
                'type': 'cleanup_withdraw',
                'priority': 'high',
                'count': stats['withdraw'],
                'message': f"회수 권장 입찰 {stats['withdraw']}건 — 적자 또는 조정 후 마진 미달",
                'action_url': '#cleanup'
            })
        if stats.get('need_cost', 0) > 0:
            decisions.append({
                'type': 'cleanup_need_cost',
                'priority': 'medium',
                'count': stats['need_cost'],
                'message': f"원가 입력 필요 {stats['need_cost']}건",
                'action_url': '#cleanup'
            })
except:
    pass

# 2. 환경 차단 알림
try:
    settings_data = json.loads(Path(__file__).parent.joinpath('settings.json').read_text(encoding='utf-8'))
    if not settings_data.get('kream_main_accessible'):
        decisions.append({
            'type': 'env_blocked',
            'priority': 'medium',
            'count': 1,
            'message': 'kream.co.kr 접근 차단 — 가격수집/자동조정 제한',
            'action_url': '#settings'
        })
except:
    pass

# 3. 인증 만료 임박
auth_dir = Path(__file__).parent
for name in ['auth_state.json', 'auth_state_kream.json']:
    p = auth_dir / name
    if p.exists():
        from datetime import datetime
        age_h = (datetime.now() - datetime.fromtimestamp(p.stat().st_mtime)).total_seconds() / 3600
        if age_h > 18:
            decisions.append({
                'type': 'auth_aging',
                'priority': 'high',
                'count': 1,
                'message': f"{name} {round(age_h)}시간 경과 — 곧 만료",
                'action_url': None
            })

# summary dict에 추가
# summary['decisions_pending'] = decisions
# summary['decisions_count'] = len(decisions)
```

기존 daily-summary의 summary dict에 위 두 키 병합. 기존 키 변경 금지.

### 대시보드 의사결정 패널

kream_dashboard.html, daily-summary-cards 위 또는 아래에 추가 (이미 id="decisions-panel"이 있으면 스킵):

```html
<div id="decisions-panel" style="display:none; background:#fef3c7; border:1px solid #fde68a; border-radius:8px; padding:14px 18px; margin:16px 0;">
  <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:8px;">
    <strong style="color:#92400e; font-size:15px;">📋 오늘 결정 필요한 사항 <span id="decisions-count">0</span>건</strong>
    <button onclick="document.getElementById('decisions-list').style.display = document.getElementById('decisions-list').style.display === 'none' ? 'block' : 'none';" style="background:none; border:1px solid #92400e; color:#92400e; padding:2px 10px; border-radius:4px; cursor:pointer; font-size:12px;">상세</button>
  </div>
  <div id="decisions-list" style="margin-top:8px; font-size:13px; color:#78350f;"></div>
</div>

<script>
async function loadDecisions() {
  try {
    const r = await fetch('/api/daily-summary');
    const d = await r.json();
    if (!d.ok) return;
    const decisions = (d.summary && d.summary.decisions_pending) || [];
    const panel = document.getElementById('decisions-panel');
    if (!panel) return;
    
    if (decisions.length === 0) {
      panel.style.display = 'none';
      return;
    }
    
    panel.style.display = 'block';
    document.getElementById('decisions-count').textContent = decisions.length;
    
    const html = decisions.map(d => {
      const icon = d.priority === 'high' ? '🔴' : (d.priority === 'medium' ? '🟡' : '🟢');
      return `<div style="padding:6px 0; border-top:1px solid #fde68a;">${icon} ${d.message}</div>`;
    }).join('');
    document.getElementById('decisions-list').innerHTML = html;
  } catch(e) {}
}
document.addEventListener('DOMContentLoaded', () => {
  loadDecisions();
  setInterval(loadDecisions, 5 * 60 * 1000); // 5분마다
});
</script>
```

### 자본 카드 (대시보드 카드 7번째)

daily-summary-cards div 안에 추가 (이미 id="dsc-card-capital"이 있으면 스킵):

```html
<div class="dsc-card" id="dsc-card-capital" data-key="capital" style="flex:1; min-width:160px; background:#f5f3ff; border:1px solid #ddd6fe; border-radius:8px; padding:12px;">
  <div style="font-size:12px; color:#5b21b6;">묶인 자본</div>
  <div style="font-size:20px; font-weight:bold; color:#4c1d95;" id="dsc-capital-tied">-</div>
  <div style="font-size:10px; color:#7c3aed; margin-top:4px;" id="dsc-capital-detail">회수 가능: -</div>
</div>
```

loadDailySummary 함수에 추가 (기존 함수 끝부분):

```javascript
// 자본 카드 별도 호출 (자체 API)
try {
  const r = await fetch('/api/capital-status');
  const d = await r.json();
  if (d.ok) {
    const tiedEl = document.getElementById('dsc-capital-tied');
    const detailEl = document.getElementById('dsc-capital-detail');
    if (tiedEl) tiedEl.textContent = (d.tied_total/10000).toFixed(0) + '만';
    if (detailEl) detailEl.textContent = `회수 가능: ${(d.recoverable/10000).toFixed(0)}만 (${d.recoverable_count}건)`;
  }
} catch(e) {}
```

## 검증

1. python3 -m py_compile kream_server.py → 0
2. 서버 재시작
3. /api/capital-status → ok=true, tied_total 숫자, recoverable 숫자
4. /api/market-prices/from-bids → ok=true, items 배열 (비어있어도 OK)
5. /api/model/JQ4110/deep-analysis → ok=true, summary 객체, recommendation 키
6. /api/daily-summary → summary.decisions_pending 배열 존재
7. 대시보드 HTML에 dsc-card-capital, decisions-panel 마커 존재
8. 회귀: /api/health, /api/cleanup/diagnose, /api/sales/analytics, /admin/status

## 절대 규칙
- 자동 액션 금지 (모든 신규 기능은 진단/표시만)
- 자동 토글 ON 변경 금지
- DB 스키마 변경 금지
- kream_bot.py 수정은 best-effort, 실패 시 None 저장하고 진행

## 커밋 메시지
```
feat(Step 20): 자본 가시성 + 가격수집 우회 + 모델분석 + 의사결정 패널

- /api/capital-status: 묶인 자본 + 회수 가능 자본 + 모델별 분포
- 대시보드 7번째 카드: 묶인 자본 (만 단위)
- /api/market-prices/from-bids: my-bids에서 경쟁가 추출 (우회 데이터)
- /api/model/<model>/deep-analysis: 모델 종합 분석 + 추천
- /api/daily-summary에 decisions_pending 자동 추출
  (회수 권장, 원가 누락, 환경 차단, 인증 만료 임박)
- 대시보드 "오늘 결정 필요한 사항" 노란 배너

배경: 사장이 매일 30초로 결정 가능하게 + 자본 가시성 확보
모든 신규 기능은 표시/진단만, 자동 액션 없음
```
