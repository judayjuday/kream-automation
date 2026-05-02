# 작업지시서 — Step 19: 밀린 입찰 진단 + 회수 전략

> 의존: Step 18-D (커밋 0695df0)
> 환경: macbook_overseas (가격수집 차단)
> 절대 규칙 (CLAUDE.md) 모두 준수
> 자동 토글 ON 변경 금지 (자동 입찰/조정/재입찰/정리/PDF OFF 유지)

## 배경

Step 18-D 사전 점검에서 확인:
- 총 입찰 51건 중 39건(76%)이 rank 1 아님
- 가격수집 차단 환경에서 자동조정 못 돌아 누적된 결과
- 그대로 두면 죽은 입찰 → 회전 안 됨

## 작업 #1: 밀린 입찰 상세 진단 API

### kream_server.py 신규 라우트

```python
@app.route('/api/cleanup/diagnose', methods=['GET'])
def api_cleanup_diagnose():
    """rank 밀린 입찰 + 원가 + 마진 분석 → 회수 전략 추천."""
    try:
        from pathlib import Path
        from collections import defaultdict
        
        local_path = Path(__file__).parent / 'my_bids_local.json'
        if not local_path.exists():
            return jsonify({'ok': True, 'items': [], 'note': 'local cache 없음'})
        
        local = json.loads(local_path.read_text(encoding='utf-8'))
        bids = local.get('bids', [])
        
        # 설정값
        try:
            settings = json.loads(Path(__file__).parent.joinpath('settings.json').read_text(encoding='utf-8'))
        except:
            settings = {}
        fee_rate = settings.get('commission_rate', 6) / 100
        fixed_fee = 2500
        min_margin = settings.get('min_margin', 4000)
        undercut = settings.get('undercut_amount', 1000)
        overseas_ship_default = settings.get('overseas_shipping', 8000)
        
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        
        # 판매 완료된 order_id 추출 (절대 건드리지 않음)
        try:
            c.execute("SELECT DISTINCT order_id FROM sales_history WHERE order_id IS NOT NULL")
            sold_ids = {row[0] for row in c.fetchall()}
        except:
            sold_ids = set()
        
        # rank 밀린 입찰만 필터
        items = []
        by_size_count = defaultdict(int)  # (model, size) → 입찰 건수 (ONE SIZE 안전장치용)
        
        # 전체 입찰 (밀리지 않은 것 포함, ONE SIZE 카운트용)
        for b in bids:
            key = (b.get('model'), b.get('size'))
            by_size_count[key] += 1
        
        for b in bids:
            rank = b.get('rank')
            if not rank or rank == 1:
                continue  # 1위는 대상 아님
            
            order_id = b.get('orderId')
            if order_id in sold_ids:
                continue  # 판매 완료 제외
            
            model = b.get('model', '-')
            size = b.get('size', '-')
            price = b.get('price') or 0
            
            # 원가 조회
            cost_data = None
            cny_price = exchange_rate = overseas_ship = None
            try:
                c.execute("""
                    SELECT cny_price, exchange_rate, overseas_shipping, other_costs
                    FROM bid_cost WHERE order_id = ?
                """, (order_id,))
                row = c.fetchone()
                if row:
                    cny_price, exchange_rate, overseas_ship, other_costs = row
            except:
                pass
            
            # 마진 계산
            cost = None
            margin = None
            margin_status = 'no_cost'  # no_cost / ok / low / deficit
            
            if cny_price is not None and exchange_rate is not None:
                try:
                    ship = overseas_ship if overseas_ship is not None else overseas_ship_default
                    cost = round(float(cny_price) * float(exchange_rate) * 1.03 + float(ship))
                    settlement = price * (1 - fee_rate * 1.1) - fixed_fee
                    margin = round(settlement - cost)
                    
                    if margin >= min_margin:
                        margin_status = 'ok'
                    elif margin >= 0:
                        margin_status = 'low'
                    else:
                        margin_status = 'deficit'
                except Exception:
                    pass
            
            # 추천 액션 결정
            recommendation = 'hold'  # 기본: 보류
            recommendation_reason = ''
            
            if margin_status == 'no_cost':
                recommendation = 'need_cost'
                recommendation_reason = '원가 미등록 → CNY 입력 후 재진단'
            elif margin_status == 'deficit':
                recommendation = 'withdraw'
                recommendation_reason = f'적자 ({margin:,}원) → 회수 권장'
            elif margin_status == 'low':
                # 가격조정해도 4000원 마진 안 나오면 회수
                # 현재 가격 - undercut 적용했을 때 마진
                hypothetical_price = price - undercut
                hyp_settlement = hypothetical_price * (1 - fee_rate * 1.1) - fixed_fee
                hyp_margin = hyp_settlement - cost
                if hyp_margin >= min_margin:
                    recommendation = 'adjust'
                    recommendation_reason = f'-{undercut}원 조정 시 마진 {round(hyp_margin):,}원 (충분)'
                else:
                    recommendation = 'withdraw'
                    recommendation_reason = f'조정해도 마진 {round(hyp_margin):,}원 (미달) → 회수 권장'
            elif margin_status == 'ok':
                # 마진 충분 → 가격조정 가능
                recommendation = 'adjust'
                recommendation_reason = f'마진 {margin:,}원 → 가격수집 복원 후 자동조정'
            
            # ONE SIZE 안전장치: 같은 model+size에 입찰 1건만 남으면 회수 보류
            same_size_total = by_size_count[(model, size)]
            is_last_in_size = (same_size_total <= 1)
            if recommendation == 'withdraw' and is_last_in_size:
                recommendation = 'withdraw_blocked'
                recommendation_reason += ' (단 마지막 재고라 안전장치 발동, 강제 회수만 가능)'
            
            items.append({
                'orderId': order_id,
                'model': model,
                'size': size,
                'price': price,
                'rank': rank,
                'cny_price': cny_price,
                'exchange_rate': exchange_rate,
                'cost': cost,
                'margin': margin,
                'margin_status': margin_status,
                'recommendation': recommendation,
                'reason': recommendation_reason,
                'is_last_in_size': is_last_in_size,
            })
        
        conn.close()
        
        # 통계 집계
        stats = defaultdict(int)
        for it in items:
            stats[it['recommendation']] += 1
            stats[f"margin_{it['margin_status']}"] += 1
        
        # 모델별 그룹
        by_model = defaultdict(list)
        for it in items:
            by_model[it['model']].append(it)
        
        return jsonify({
            'ok': True,
            'total': len(items),
            'stats': dict(stats),
            'items': items,
            'by_model': dict(by_model),
            'settings_used': {
                'min_margin': min_margin,
                'undercut': undercut,
                'fee_rate': fee_rate,
                'overseas_ship_default': overseas_ship_default,
            }
        })
    except Exception as e:
        import traceback
        return jsonify({'ok': False, 'error': str(e), 'trace': traceback.format_exc()}), 500
```

## 작업 #2: 일괄 액션 라우트 (안전장치 포함)

```python
@app.route('/api/cleanup/bulk-withdraw', methods=['POST'])
def api_cleanup_bulk_withdraw():
    """선택한 order_id 일괄 회수. force 미지정 시 ONE SIZE 마지막 재고 안전장치 발동."""
    data = request.get_json() or {}
    order_ids = data.get('orderIds', [])
    force = data.get('force', False)  # ONE SIZE 마지막 재고도 강제 회수
    
    if not order_ids:
        return jsonify({'ok': False, 'error': 'orderIds required'}), 400
    
    try:
        from pathlib import Path
        from collections import defaultdict
        
        # 진단 재실행해서 안전장치 확인
        diag_resp = api_cleanup_diagnose()
        if hasattr(diag_resp, 'get_json'):
            diag = diag_resp.get_json()
        else:
            diag = json.loads(diag_resp.data) if hasattr(diag_resp, 'data') else diag_resp
        
        # 판매 완료 ID 차단
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        try:
            c.execute("SELECT DISTINCT order_id FROM sales_history WHERE order_id IS NOT NULL")
            sold_ids = {row[0] for row in c.fetchall()}
        except:
            sold_ids = set()
        conn.close()
        
        # 안전장치 적용
        items_map = {it['orderId']: it for it in (diag.get('items') or [])}
        approved_ids = []
        blocked = []
        
        for oid in order_ids:
            # 판매 완료 차단 (절대 규칙)
            if oid in sold_ids:
                blocked.append({'orderId': oid, 'reason': '판매 완료 건 (보호)'})
                continue
            
            it = items_map.get(oid)
            if not it:
                # 진단 결과에 없으면 1위거나 모르는 상태 → 보류
                blocked.append({'orderId': oid, 'reason': '진단 대상 아님 (1위거나 알 수 없음)'})
                continue
            
            # ONE SIZE 마지막 재고 + force 미지정
            if it.get('is_last_in_size') and not force:
                blocked.append({'orderId': oid, 'reason': '같은 사이즈 마지막 재고 (force=true 필요)'})
                continue
            
            approved_ids.append(oid)
        
        # 승인된 건만 기존 /api/my-bids/delete로 위임
        delete_result = None
        if approved_ids:
            try:
                import requests as rq
                r = rq.post('http://localhost:5001/api/my-bids/delete',
                            json={'orderIds': approved_ids}, timeout=10)
                delete_result = r.json()
            except Exception as e:
                delete_result = {'error': str(e)}
        
        return jsonify({
            'ok': True,
            'requested': len(order_ids),
            'approved': len(approved_ids),
            'blocked': blocked,
            'delete_task': delete_result,
            'note': 'task 완료 후 5분 대기 → /api/my-bids/verify-deleted로 확인 권장'
        })
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.route('/api/cleanup/bulk-adjust', methods=['POST'])
def api_cleanup_bulk_adjust():
    """선택한 order_id 일괄 가격 -N원 조정. 마진 사전 체크."""
    data = request.get_json() or {}
    order_ids = data.get('orderIds', [])
    decrement = data.get('decrement', 1000)  # 기본 1000원 내림
    
    if not order_ids:
        return jsonify({'ok': False, 'error': 'orderIds required'}), 400
    
    try:
        # 진단 결과 가져와서 각 건의 마진 사전 체크
        diag_resp = api_cleanup_diagnose()
        if hasattr(diag_resp, 'get_json'):
            diag = diag_resp.get_json()
        else:
            diag = json.loads(diag_resp.data) if hasattr(diag_resp, 'data') else diag_resp
        
        items_map = {it['orderId']: it for it in (diag.get('items') or [])}
        
        # 판매 완료 차단
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        try:
            c.execute("SELECT DISTINCT order_id FROM sales_history WHERE order_id IS NOT NULL")
            sold_ids = {row[0] for row in c.fetchall()}
        except:
            sold_ids = set()
        conn.close()
        
        try:
            settings = json.loads(Path(__file__).parent.joinpath('settings.json').read_text(encoding='utf-8'))
        except:
            settings = {}
        fee_rate = settings.get('commission_rate', 6) / 100
        fixed_fee = 2500
        min_margin = settings.get('min_margin', 4000)
        
        # 각 건 검증
        approved = []
        blocked = []
        
        for oid in order_ids:
            if oid in sold_ids:
                blocked.append({'orderId': oid, 'reason': '판매 완료 (보호)'})
                continue
            
            it = items_map.get(oid)
            if not it:
                blocked.append({'orderId': oid, 'reason': '진단 결과에 없음'})
                continue
            
            cost = it.get('cost')
            if cost is None:
                blocked.append({'orderId': oid, 'reason': '원가 미등록 → 조정 불가'})
                continue
            
            new_price = it['price'] - decrement
            # 1000원 단위 올림
            import math
            new_price = math.ceil(new_price / 1000) * 1000
            
            settlement = new_price * (1 - fee_rate * 1.1) - fixed_fee
            new_margin = settlement - cost
            
            if new_margin < min_margin:
                blocked.append({
                    'orderId': oid, 
                    'reason': f'조정 후 마진 {round(new_margin):,}원 < {min_margin:,} (미달)'
                })
                continue
            
            approved.append({
                'orderId': oid,
                'old_price': it['price'],
                'new_price': new_price,
                'expected_margin': round(new_margin)
            })
        
        # 승인된 건 modify (기존 my-bids/modify 활용, 단건씩)
        modify_results = []
        if approved:
            try:
                import requests as rq
                for app_item in approved:
                    try:
                        r = rq.post('http://localhost:5001/api/my-bids/modify',
                                    json={'orderId': app_item['orderId'], 
                                          'newPrice': app_item['new_price']},
                                    timeout=10)
                        modify_results.append({
                            'orderId': app_item['orderId'],
                            'status': r.status_code,
                            'response': r.json() if r.status_code == 200 else None
                        })
                    except Exception as e:
                        modify_results.append({'orderId': app_item['orderId'], 'error': str(e)})
            except Exception as e:
                pass
        
        return jsonify({
            'ok': True,
            'requested': len(order_ids),
            'approved': approved,
            'blocked': blocked,
            'modify_results': modify_results,
            'note': '가격 수정은 5분 후 sync에 반영됨'
        })
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500
```

## 작업 #3: 일괄 정리 도구 탭

### tabs/tab_cleanup.html 신규 생성

```html
<div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:12px; padding:8px 0; border-bottom:1px solid #e5e7eb;">
  <span style="font-size:14px; color:#6b7280;">현재 메뉴</span>
  <button onclick="showHelp('cleanup')" style="background:#f3f4f6; border:1px solid #d1d5db; border-radius:20px; padding:4px 12px; font-size:13px; cursor:pointer; color:#374151;" title="도움말">❓ 도움말</button>
</div>

<h2 style="margin:0 0 16px 0;">🧹 입찰 정리 도구</h2>

<div id="cleanup-stats" style="display:flex; gap:12px; flex-wrap:wrap; margin-bottom:16px;"></div>

<div style="margin-bottom:12px;">
  <button onclick="loadCleanupData()" style="padding:6px 14px; background:#2563eb; color:#fff; border:none; border-radius:6px; cursor:pointer;">🔄 새로고침</button>
  <button onclick="selectByRecommendation('withdraw')" style="padding:6px 14px; background:#fef2f2; color:#991b1b; border:1px solid #fecaca; border-radius:6px; cursor:pointer;">회수 권장 전체 선택</button>
  <button onclick="selectByRecommendation('adjust')" style="padding:6px 14px; background:#eff6ff; color:#1e40af; border:1px solid #bfdbfe; border-radius:6px; cursor:pointer;">조정 가능 전체 선택</button>
  <button onclick="clearSelection()" style="padding:6px 14px; background:#f3f4f6; color:#374151; border:1px solid #d1d5db; border-radius:6px; cursor:pointer;">선택 해제</button>
</div>

<div id="cleanup-actions" style="background:#f9fafb; padding:12px; border-radius:6px; margin-bottom:12px; display:none;">
  <strong>선택 <span id="selected-count">0</span>건</strong>
  <button onclick="bulkWithdraw()" style="margin-left:12px; padding:6px 14px; background:#dc2626; color:#fff; border:none; border-radius:6px; cursor:pointer;">🗑 일괄 회수</button>
  <button onclick="bulkAdjust(1000)" style="margin-left:8px; padding:6px 14px; background:#7c3aed; color:#fff; border:none; border-radius:6px; cursor:pointer;">📉 -1000원 조정</button>
  <span style="margin-left:12px; font-size:12px; color:#6b7280;">※ 판매 완료/마지막 재고/마진 미달은 자동 차단</span>
</div>

<div style="overflow-x:auto;">
<table id="cleanup-table" style="width:100%; font-size:12px; border-collapse:collapse;">
  <thead>
    <tr style="background:#f3f4f6;">
      <th style="padding:8px; border:1px solid #d1d5db;"><input type="checkbox" id="select-all" onchange="toggleAll(this.checked)"></th>
      <th style="padding:8px; border:1px solid #d1d5db;">모델</th>
      <th style="padding:8px; border:1px solid #d1d5db;">사이즈</th>
      <th style="padding:8px; border:1px solid #d1d5db; text-align:right;">현재가</th>
      <th style="padding:8px; border:1px solid #d1d5db;">rank</th>
      <th style="padding:8px; border:1px solid #d1d5db; text-align:right;">원가</th>
      <th style="padding:8px; border:1px solid #d1d5db; text-align:right;">마진</th>
      <th style="padding:8px; border:1px solid #d1d5db;">추천</th>
      <th style="padding:8px; border:1px solid #d1d5db;">사유</th>
    </tr>
  </thead>
  <tbody id="cleanup-tbody">
    <tr><td colspan="9" style="padding:24px; text-align:center; color:#9ca3af;">새로고침 누르면 진단 시작</td></tr>
  </tbody>
</table>
</div>

<script>
let cleanupItems = [];
const REC_LABEL = {
  'withdraw': {text: '회수', color: '#991b1b', bg: '#fef2f2'},
  'withdraw_blocked': {text: '회수(잠김)', color: '#92400e', bg: '#fef3c7'},
  'adjust': {text: '조정', color: '#1e40af', bg: '#eff6ff'},
  'hold': {text: '보류', color: '#374151', bg: '#f3f4f6'},
  'need_cost': {text: '원가입력', color: '#86198f', bg: '#fdf4ff'},
};
const STATUS_LABEL = {
  'ok': {text: 'OK', color: '#059669'},
  'low': {text: '낮음', color: '#d97706'},
  'deficit': {text: '적자', color: '#dc2626'},
  'no_cost': {text: '원가없음', color: '#9ca3af'},
};

async function loadCleanupData() {
  document.getElementById('cleanup-tbody').innerHTML = '<tr><td colspan="9" style="padding:24px; text-align:center;">⏳ 진단 중...</td></tr>';
  try {
    const r = await fetch('/api/cleanup/diagnose');
    const d = await r.json();
    if (!d.ok) {
      document.getElementById('cleanup-tbody').innerHTML = `<tr><td colspan="9" style="padding:24px; color:#dc2626;">에러: ${d.error}</td></tr>`;
      return;
    }
    cleanupItems = d.items || [];
    
    // 통계
    const stats = d.stats || {};
    document.getElementById('cleanup-stats').innerHTML = `
      <div style="background:#fff; border:1px solid #e5e7eb; padding:8px 14px; border-radius:6px;">총 <strong>${d.total}</strong>건</div>
      <div style="background:#fef2f2; border:1px solid #fecaca; padding:8px 14px; border-radius:6px; color:#991b1b;">회수 권장 <strong>${stats.withdraw||0}</strong></div>
      <div style="background:#fef3c7; border:1px solid #fde68a; padding:8px 14px; border-radius:6px; color:#92400e;">잠김 <strong>${stats.withdraw_blocked||0}</strong></div>
      <div style="background:#eff6ff; border:1px solid #bfdbfe; padding:8px 14px; border-radius:6px; color:#1e40af;">조정 가능 <strong>${stats.adjust||0}</strong></div>
      <div style="background:#fdf4ff; border:1px solid #f0abfc; padding:8px 14px; border-radius:6px; color:#86198f;">원가 입력 필요 <strong>${stats.need_cost||0}</strong></div>
      <div style="background:#f3f4f6; border:1px solid #d1d5db; padding:8px 14px; border-radius:6px;">보류 <strong>${stats.hold||0}</strong></div>
    `;
    
    renderTable();
  } catch(e) {
    document.getElementById('cleanup-tbody').innerHTML = `<tr><td colspan="9" style="padding:24px; color:#dc2626;">로드 실패: ${e.message}</td></tr>`;
  }
}

function renderTable() {
  if (cleanupItems.length === 0) {
    document.getElementById('cleanup-tbody').innerHTML = '<tr><td colspan="9" style="padding:24px; text-align:center; color:#059669;">✅ rank 밀린 입찰 없음</td></tr>';
    return;
  }
  
  const rows = cleanupItems.map(it => {
    const rec = REC_LABEL[it.recommendation] || REC_LABEL.hold;
    const stat = STATUS_LABEL[it.margin_status] || STATUS_LABEL.no_cost;
    const margin = it.margin !== null && it.margin !== undefined ? `${it.margin.toLocaleString()}원` : '-';
    const cost = it.cost ? `${it.cost.toLocaleString()}원` : '-';
    return `<tr>
      <td style="padding:6px; border:1px solid #d1d5db; text-align:center;">
        <input type="checkbox" class="cleanup-cb" data-oid="${it.orderId}" data-rec="${it.recommendation}" onchange="updateSelection()">
      </td>
      <td style="padding:6px; border:1px solid #d1d5db;">${it.model}</td>
      <td style="padding:6px; border:1px solid #d1d5db;">${it.size}${it.is_last_in_size ? ' 🔒' : ''}</td>
      <td style="padding:6px; border:1px solid #d1d5db; text-align:right;">${it.price.toLocaleString()}원</td>
      <td style="padding:6px; border:1px solid #d1d5db; text-align:center;">${it.rank}</td>
      <td style="padding:6px; border:1px solid #d1d5db; text-align:right;">${cost}</td>
      <td style="padding:6px; border:1px solid #d1d5db; text-align:right; color:${stat.color}; font-weight:bold;">${margin}</td>
      <td style="padding:6px; border:1px solid #d1d5db; background:${rec.bg}; color:${rec.color}; font-weight:bold; text-align:center;">${rec.text}</td>
      <td style="padding:6px; border:1px solid #d1d5db; font-size:11px; color:#6b7280;">${it.reason || '-'}</td>
    </tr>`;
  }).join('');
  document.getElementById('cleanup-tbody').innerHTML = rows;
}

function toggleAll(checked) {
  document.querySelectorAll('.cleanup-cb').forEach(cb => cb.checked = checked);
  updateSelection();
}

function selectByRecommendation(rec) {
  document.querySelectorAll('.cleanup-cb').forEach(cb => {
    cb.checked = (cb.dataset.rec === rec);
  });
  updateSelection();
}

function clearSelection() {
  document.getElementById('select-all').checked = false;
  toggleAll(false);
}

function updateSelection() {
  const selected = document.querySelectorAll('.cleanup-cb:checked');
  document.getElementById('selected-count').textContent = selected.length;
  document.getElementById('cleanup-actions').style.display = selected.length > 0 ? 'block' : 'none';
}

function getSelectedIds() {
  return [...document.querySelectorAll('.cleanup-cb:checked')].map(cb => cb.dataset.oid);
}

async function bulkWithdraw() {
  const ids = getSelectedIds();
  if (ids.length === 0) return;
  if (!confirm(`${ids.length}건 회수하시겠습니까?\n(판매 완료/마지막 재고는 자동 차단됨)`)) return;
  
  try {
    const r = await fetch('/api/cleanup/bulk-withdraw', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({orderIds: ids, force: false})
    });
    const d = await r.json();
    let msg = `요청: ${d.requested}건\n승인: ${d.approved}건\n차단: ${(d.blocked||[]).length}건`;
    if (d.blocked && d.blocked.length) {
      msg += '\n\n차단 사유:\n' + d.blocked.map(b => `• ${b.orderId}: ${b.reason}`).join('\n');
    }
    msg += '\n\n5분 후 자동 새로고침으로 결과 확인하세요.';
    alert(msg);
    setTimeout(loadCleanupData, 5 * 60 * 1000);
  } catch(e) {
    alert('실패: ' + e.message);
  }
}

async function bulkAdjust(decrement) {
  const ids = getSelectedIds();
  if (ids.length === 0) return;
  if (!confirm(`${ids.length}건 가격 -${decrement}원 조정?\n(마진 미달은 자동 차단됨)`)) return;
  
  try {
    const r = await fetch('/api/cleanup/bulk-adjust', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({orderIds: ids, decrement})
    });
    const d = await r.json();
    let msg = `요청: ${d.requested}건\n승인: ${(d.approved||[]).length}건\n차단: ${(d.blocked||[]).length}건`;
    if (d.blocked && d.blocked.length) {
      msg += '\n\n차단 사유:\n' + d.blocked.map(b => `• ${b.orderId}: ${b.reason}`).join('\n');
    }
    alert(msg);
    setTimeout(loadCleanupData, 5 * 60 * 1000);
  } catch(e) {
    alert('실패: ' + e.message);
  }
}
</script>
```

## 작업 #4: 사이드바 메뉴 + 도움말 등록

### kream_dashboard.html

사이드바에 "🧹 입찰 정리" 메뉴 항목 추가 (관리 섹션 아래쪽 or 별도 섹션).
이미 cleanup 관련 메뉴 있으면 스킵.

기존 메뉴 패턴 따라서 추가 (탭 로딩 패턴은 기존 코드 그대로 활용).

### help_content.json에 cleanup 항목 추가

기존 help_content.json 끝에 (settings 다음에) 추가:

```json
,
"cleanup": {
  "icon": "🧹",
  "title": "입찰 정리 도구",
  "what": "rank가 밀린 내 입찰을 진단하고 회수/조정 일괄 처리하는 도구",
  "why": "가격수집 차단 환경 또는 자동조정 미가동 기간 누적된 죽은 입찰을 정리해서 자본 회전율 회복하기 위해. 39건 등 대량 정리 시 수동으로는 불가능",
  "how": [
    "1. 새로고침 누르면 rank 1 아닌 입찰 전체 자동 진단 (원가/마진/추천 액션 표시)",
    "2. 추천 액션: 회수(적자/조정해도 마진 미달) / 조정(마진 OK, -1000원 가능) / 보류 / 원가입력",
    "3. '회수 권장 전체 선택' 또는 '조정 가능 전체 선택' 버튼으로 일괄",
    "4. '🗑 일괄 회수' 또는 '📉 -1000원 조정' 실행",
    "5. 5분 후 자동 새로고침으로 결과 확인"
  ],
  "warn": "판매 완료 건은 자동 차단됨 (절대 규칙). 같은 사이즈에 마지막 재고 1건만 남으면 회수 안전장치 발동. 가격 수정은 KREAM 반영까지 5분 걸림."
}
```

## 검증

1. python3 -m py_compile kream_server.py → 0
2. 서버 재시작
3. /api/cleanup/diagnose → ok=true, total>=0, items 배열, stats 객체
4. /api/cleanup/bulk-withdraw POST {"orderIds":["TEST_FAKE"]} → blocked에 포함됨 (실제 삭제 X)
5. /api/cleanup/bulk-adjust POST {"orderIds":["TEST_FAKE"]} → blocked에 포함됨
6. tabs/tab_cleanup.html 파일 존재
7. /tabs/tab_cleanup.html GET → 200
8. /api/help/cleanup → ok=true, help.title='입찰 정리 도구'
9. 회귀: /api/health 200, /admin/status 200, /api/queue/list 200, /api/daily-summary ok

## 절대 규칙
- 판매 완료 건은 어떤 액션에서도 차단 (CLAUDE.md #2)
- 자동 입찰/조정/재입찰/정리/PDF 토글 ON 변경 금지
- 기존 라우트 변경 금지 (추가만)
- 일괄 회수는 force=true 명시 안 하면 마지막 재고 보호
- 일괄 조정은 마진 4000원 미만 자동 차단

## 커밋 메시지
```
feat(Step 19): 밀린 입찰 진단 + 회수 전략 도구

- /api/cleanup/diagnose: rank 밀린 입찰 + 원가 + 마진 → 추천 액션
- /api/cleanup/bulk-withdraw: 일괄 회수 (안전장치 포함)
  - 판매 완료 건 자동 차단
  - 같은 사이즈 마지막 재고 보호 (force=true 시만 강제)
- /api/cleanup/bulk-adjust: 일괄 가격 -N원 조정
  - 마진 4000원 미만 자동 차단
  - 1000원 단위 올림 적용
- tabs/tab_cleanup.html: 체크박스 + 추천 액션 + 통계 패널
- 사이드바 메뉴 + 도움말 추가

배경: rank 밀린 입찰 39건(76%) 누적 → 죽은 입찰 정리 도구
실제 액션은 사장 의사결정, 안전장치 다중 적용
```
