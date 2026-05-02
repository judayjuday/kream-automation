#!/bin/bash
# Step 18-C 통합 — 환경 비의존 가치 작업 4건
#   1. 내 입찰 실시간 모니터 위젯
#   2. 마진 시뮬레이터 강화 (역산 + 시나리오)
#   3. 판매 분석 강화 (회전율 + 매출 추이)
#   4. 작업 일지 자동 생성
#
# 사용법: bash run_step18c.sh

set -e
exec > >(tee -a pipeline_step18c.log) 2>&1

cd ~/Desktop/kream_automation

PIPELINE_START=$(date +%s)
TS=$(date '+%Y%m%d_%H%M%S')

echo "================================================================"
echo "🚀 Step 18-C 통합 Pipeline — $(date '+%Y-%m-%d %H:%M:%S')"
echo "   1) 입찰모니터  2) 마진시뮬  3) 판매분석  4) 작업일지"
echo "================================================================"
echo ""

fail_and_restore() {
    local stage=$1
    echo ""
    echo "❌ [$stage] FAIL — 백업 복원"
    [ -f "kream_server.py.step18c_pre.bak" ] && cp "kream_server.py.step18c_pre.bak" kream_server.py
    [ -f "kream_dashboard.html.step18c_pre.bak" ] && cp "kream_dashboard.html.step18c_pre.bak" kream_dashboard.html
    for f in tabs/*.step18c_pre.bak; do
        [ -f "$f" ] && cp "$f" "${f%.step18c_pre.bak}"
    done
    
    lsof -ti:5001 | xargs kill -9 2>/dev/null || true
    sleep 2
    nohup python3 kream_server.py > server.log 2>&1 & disown
    sleep 5
    
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
echo ""

# ==========================================
# [STAGE 1] 백업
# ==========================================
echo "════════════════════ [STAGE 1] 백업 ════════════════════"
cp kream_server.py "kream_server.py.step18c_pre.bak"
cp kream_dashboard.html "kream_dashboard.html.step18c_pre.bak"
[ -f tabs/tab_margin.html ] && cp tabs/tab_margin.html "tabs/tab_margin.html.step18c_pre.bak"
[ -f tabs/tab_pattern.html ] && cp tabs/tab_pattern.html "tabs/tab_pattern.html.step18c_pre.bak"
[ -f tabs/tab_mybids.html ] && cp tabs/tab_mybids.html "tabs/tab_mybids.html.step18c_pre.bak"
sqlite3 /Users/iseungju/Desktop/kream_automation/price_history.db ".backup '/Users/iseungju/Desktop/kream_automation/price_history_step18c_${TS}.db'"
echo "  ✅ 백업 완료"
echo ""

# ==========================================
# [STAGE 2] 작업지시서
# ==========================================
echo "════════════════════ [STAGE 2] 작업지시서 ════════════════════"

cat > "작업지시서_Step18C.md" <<'MDEOF'
# 작업지시서 — Step 18-C: 환경 비의존 가치 작업 4건

> 의존: Step 18-B (커밋 900e6f6)
> 환경: macbook_overseas (kream.co.kr 차단)
> 절대 규칙 (CLAUDE.md) 모두 준수

## 작업 #1: 내 입찰 실시간 모니터 (rank 추적)

판매자센터 접근은 가능하므로 my_bids 동기화는 정상 작동.
rank 변화 추적해서 떨어진 건 알림.

### 신규 라우트: /api/my-bids/rank-changes

```python
@app.route('/api/my-bids/rank-changes', methods=['GET'])
def api_rank_changes():
    """내 입찰 중 rank가 1이 아닌 건 + 최근 변동 표시."""
    try:
        from pathlib import Path
        local_path = Path(__file__).parent / 'my_bids_local.json'
        if not local_path.exists():
            return jsonify({'ok': True, 'items': [], 'note': 'local cache 없음'})
        
        local = json.loads(local_path.read_text(encoding='utf-8'))
        bids = local.get('bids', [])
        
        # rank 1 아닌 건 추출
        not_first = [b for b in bids if b.get('rank') and b.get('rank') > 1]
        # rank 없는 건 별도
        unknown = [b for b in bids if not b.get('rank')]
        
        # 모델별 그룹화
        from collections import defaultdict
        by_model = defaultdict(list)
        for b in not_first:
            by_model[b.get('model', '?')].append(b)
        
        return jsonify({
            'ok': True,
            'total_bids': len(bids),
            'rank_1_count': sum(1 for b in bids if b.get('rank') == 1),
            'rank_lost_count': len(not_first),
            'unknown_count': len(unknown),
            'rank_lost_by_model': dict(by_model),
            'last_sync': local.get('last_sync') or local.get('updated_at'),
        })
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500
```

### 대시보드 "내 입찰 현황" 카드 (daily-summary-cards 옆 또는 아래)

대시보드 적절한 위치에 새 영역 추가 (이미 id="my-bids-monitor"가 있으면 스킵):

```html
<div id="my-bids-monitor" style="background:#fff; border:1px solid #e5e7eb; border-radius:8px; padding:16px; margin:16px 0;">
  <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:12px;">
    <h3 style="margin:0; font-size:16px; color:#111;">📂 내 입찰 현황</h3>
    <button onclick="loadMyBidsMonitor()" style="font-size:12px; padding:4px 10px; background:#f3f4f6; border:1px solid #d1d5db; border-radius:4px; cursor:pointer;">새로고침</button>
  </div>
  <div id="mbm-stats" style="display:flex; gap:16px; flex-wrap:wrap; font-size:14px;">
    <span>총 <strong id="mbm-total">-</strong>건</span>
    <span style="color:#059669;">1위 <strong id="mbm-first">-</strong></span>
    <span style="color:#dc2626;">밀린 입찰 <strong id="mbm-lost">-</strong></span>
    <span style="color:#6b7280;">동기화: <span id="mbm-sync">-</span></span>
  </div>
  <div id="mbm-lost-detail" style="margin-top:12px; font-size:13px; color:#7f1d1d; display:none;"></div>
</div>

<script>
async function loadMyBidsMonitor() {
  try {
    const r = await fetch('/api/my-bids/rank-changes');
    const d = await r.json();
    if (!d.ok) return;
    document.getElementById('mbm-total').textContent = d.total_bids ?? '-';
    document.getElementById('mbm-first').textContent = d.rank_1_count ?? '-';
    document.getElementById('mbm-lost').textContent = d.rank_lost_count ?? '-';
    if (d.last_sync) {
      const dt = new Date(d.last_sync);
      const mins = Math.floor((Date.now() - dt.getTime()) / 60000);
      document.getElementById('mbm-sync').textContent = mins + '분 전';
    }
    
    const detail = document.getElementById('mbm-lost-detail');
    if (d.rank_lost_count > 0 && d.rank_lost_by_model) {
      const lines = [];
      for (const [model, bids] of Object.entries(d.rank_lost_by_model)) {
        lines.push(`<strong>${model}</strong>: ${bids.length}건 (` + 
          bids.slice(0,3).map(b => `${b.size||'-'} ${b.price}원 r=${b.rank}`).join(', ') + 
          (bids.length > 3 ? ' 외' : '') + ')');
      }
      detail.innerHTML = '⚠️ 순위 밀린 입찰:<br>' + lines.join('<br>');
      detail.style.display = 'block';
    } else {
      detail.style.display = 'none';
    }
  } catch(e) { console.warn('mybids monitor:', e); }
}
document.addEventListener('DOMContentLoaded', () => {
  loadMyBidsMonitor();
  setInterval(loadMyBidsMonitor, 60000);
});
</script>
```

## 작업 #2: 마진 시뮬레이터 강화 (역산 + 시나리오)

tabs/tab_margin.html에 추가 섹션 (이미 id="margin-reverse"가 있으면 스킵):

```html
<div id="margin-reverse" style="background:#f9fafb; border:1px solid #e5e7eb; border-radius:8px; padding:16px; margin-top:16px;">
  <h3 style="margin:0 0 12px 0; font-size:15px;">🔄 역산 — 목표 마진에서 판매가 계산</h3>
  <div style="display:flex; gap:8px; flex-wrap:wrap; align-items:center;">
    <label>CNY 원가 <input type="number" id="rev-cny" style="width:80px;" placeholder="예: 350"></label>
    <label>목표 마진(원) <input type="number" id="rev-margin" value="4000" style="width:80px;"></label>
    <button onclick="calcReverse()" style="padding:4px 12px; background:#2563eb; color:#fff; border:none; border-radius:4px; cursor:pointer;">계산</button>
  </div>
  <div id="rev-result" style="margin-top:12px; font-size:13px;"></div>
</div>

<div id="margin-scenarios" style="background:#f9fafb; border:1px solid #e5e7eb; border-radius:8px; padding:16px; margin-top:16px;">
  <h3 style="margin:0 0 12px 0; font-size:15px;">📊 시나리오 비교</h3>
  <div style="display:flex; gap:8px; flex-wrap:wrap; align-items:center;">
    <label>CNY <input type="number" id="sc-cny" style="width:80px;"></label>
    <label>판매가 <input type="number" id="sc-price" style="width:90px;"></label>
    <button onclick="calcScenarios()" style="padding:4px 12px; background:#7c3aed; color:#fff; border:none; border-radius:4px; cursor:pointer;">분석</button>
  </div>
  <table id="sc-table" style="width:100%; margin-top:12px; font-size:12px; border-collapse:collapse;"></table>
</div>

<script>
async function calcReverse() {
  const cny = parseFloat(document.getElementById('rev-cny').value);
  const targetMargin = parseFloat(document.getElementById('rev-margin').value);
  if (!cny || !targetMargin) { alert('CNY와 목표마진 입력'); return; }
  
  const settingsR = await fetch('/api/settings');
  const settings = await settingsR.json();
  const fxR = await fetch('/api/exchange-rate');
  const fx = (await fxR.json()).rate || 216;
  const overseasShip = settings.overseas_shipping || 8000;
  const feeRate = (settings.commission_rate || 6) / 100;
  const fixedFee = 2500;
  
  const cost = cny * fx * 1.03 + overseasShip;
  // settlement = price × (1 - feeRate × 1.1) - fixedFee
  // margin = settlement - cost = price × (1 - feeRate × 1.1) - fixedFee - cost
  // price = (target + fixedFee + cost) / (1 - feeRate × 1.1)
  const requiredPrice = (targetMargin + fixedFee + cost) / (1 - feeRate * 1.1);
  // 1000원 단위 올림
  const roundedPrice = Math.ceil(requiredPrice / 1000) * 1000;
  const settlementAt = roundedPrice * (1 - feeRate * 1.1) - fixedFee;
  const actualMargin = Math.round(settlementAt - cost);
  
  document.getElementById('rev-result').innerHTML = 
    `<div style="background:#fff; padding:12px; border-radius:6px; border:1px solid #d1d5db;">` +
    `<div>원가: <strong>${Math.round(cost).toLocaleString()}원</strong> (CNY ${cny} × ${fx} × 1.03 + 해외배송 ${overseasShip})</div>` +
    `<div>필요 판매가: <strong style="color:#2563eb;">${roundedPrice.toLocaleString()}원</strong></div>` +
    `<div>실제 마진: <strong style="color:#059669;">${actualMargin.toLocaleString()}원</strong></div>` +
    `<div style="font-size:11px; color:#6b7280; margin-top:4px;">※ 1000원 단위 올림 적용</div>` +
    `</div>`;
}

async function calcScenarios() {
  const cny = parseFloat(document.getElementById('sc-cny').value);
  const price = parseFloat(document.getElementById('sc-price').value);
  if (!cny || !price) { alert('CNY와 판매가 입력'); return; }
  
  const fxR = await fetch('/api/exchange-rate');
  const baseFx = (await fxR.json()).rate || 216;
  const fixedFee = 2500;
  const overseasShip = 8000;
  
  const calcMargin = (fx, feePct) => {
    const cost = cny * fx * 1.03 + overseasShip;
    const settlement = price * (1 - feePct * 1.1) - fixedFee;
    return Math.round(settlement - cost);
  };
  
  const rows = [
    ['시나리오', '환율', '수수료', '마진'],
    ['기본', baseFx, '6%', calcMargin(baseFx, 0.06)],
    ['환율 -5%', (baseFx*0.95).toFixed(1), '6%', calcMargin(baseFx*0.95, 0.06)],
    ['환율 +5%', (baseFx*1.05).toFixed(1), '6%', calcMargin(baseFx*1.05, 0.06)],
    ['이벤트 5.5%', baseFx, '5.5%', calcMargin(baseFx, 0.055)],
    ['이벤트 3.5%', baseFx, '3.5%', calcMargin(baseFx, 0.035)],
  ];
  
  const html = rows.map((row, i) => {
    const tag = i === 0 ? 'th' : 'td';
    const bg = i === 0 ? '#e5e7eb' : (i % 2 ? '#fff' : '#f9fafb');
    const cells = row.map((c, j) => {
      let style = `padding:6px 10px; border:1px solid #d1d5db; background:${bg}; text-align:${j === 3 && i > 0 ? 'right' : 'left'};`;
      if (j === 3 && i > 0) {
        const v = parseInt(c);
        const color = v >= 4000 ? '#059669' : (v >= 0 ? '#d97706' : '#dc2626');
        style += `color:${color}; font-weight:bold;`;
        return `<${tag} style="${style}">${v.toLocaleString()}원</${tag}>`;
      }
      return `<${tag} style="${style}">${c}</${tag}>`;
    }).join('');
    return `<tr>${cells}</tr>`;
  }).join('');
  document.getElementById('sc-table').innerHTML = html;
}
</script>
```

## 작업 #3: 판매 분석 강화

### 신규 라우트: /api/sales/analytics

```python
@app.route('/api/sales/analytics', methods=['GET'])
def api_sales_analytics():
    """판매 분석: 회전율, 매출 추이, 모델별 통계."""
    try:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        
        # 최근 7일 일별 판매 건수
        c.execute("""
            SELECT DATE(trade_date) as d, COUNT(*) as cnt, SUM(sale_price) as total
            FROM sales_history
            WHERE DATE(trade_date) > DATE('now', '-7 days')
            GROUP BY DATE(trade_date)
            ORDER BY d
        """)
        daily_7d = [{'date': r[0], 'count': r[1], 'revenue': r[2] or 0} for r in c.fetchall()]
        
        # 최근 30일
        c.execute("""
            SELECT DATE(trade_date) as d, COUNT(*) as cnt, SUM(sale_price) as total
            FROM sales_history
            WHERE DATE(trade_date) > DATE('now', '-30 days')
            GROUP BY DATE(trade_date)
            ORDER BY d
        """)
        daily_30d = [{'date': r[0], 'count': r[1], 'revenue': r[2] or 0} for r in c.fetchall()]
        
        # 모델별 판매량 TOP 10
        c.execute("""
            SELECT model, COUNT(*) as cnt, AVG(sale_price) as avg_price, SUM(sale_price) as total
            FROM sales_history
            GROUP BY model
            ORDER BY cnt DESC
            LIMIT 10
        """)
        top_models = [{'model': r[0], 'count': r[1], 'avg_price': r[2] or 0, 'revenue': r[3] or 0} for r in c.fetchall()]
        
        # 사이즈별 판매량
        c.execute("""
            SELECT size, COUNT(*) as cnt
            FROM sales_history
            GROUP BY size
            ORDER BY cnt DESC
            LIMIT 15
        """)
        size_freq = [{'size': r[0] or '-', 'count': r[1]} for r in c.fetchall()]
        
        # 전체 합계
        c.execute("SELECT COUNT(*), SUM(sale_price) FROM sales_history")
        total_row = c.fetchone()
        
        conn.close()
        
        return jsonify({
            'ok': True,
            'total_count': total_row[0] or 0,
            'total_revenue': total_row[1] or 0,
            'daily_7d': daily_7d,
            'daily_30d': daily_30d,
            'top_models': top_models,
            'size_freq': size_freq,
        })
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500
```

### tabs/tab_pattern.html 분석 위젯 추가

이미 id="sales-analytics-widget"가 있으면 스킵:

```html
<div id="sales-analytics-widget" style="background:#fff; border:1px solid #e5e7eb; border-radius:8px; padding:16px; margin-top:16px;">
  <h3 style="margin:0 0 12px 0; font-size:15px;">📈 판매 분석 (강화)</h3>
  <div id="sa-totals" style="display:flex; gap:16px; margin-bottom:12px; font-size:14px;"></div>
  
  <h4 style="margin:12px 0 8px 0; font-size:13px;">최근 7일 매출</h4>
  <div id="sa-daily" style="display:flex; gap:4px; align-items:flex-end; height:80px; background:#f9fafb; padding:8px; border-radius:6px;"></div>
  
  <h4 style="margin:16px 0 8px 0; font-size:13px;">모델별 판매 TOP 10</h4>
  <table id="sa-models" style="width:100%; font-size:12px; border-collapse:collapse;"></table>
  
  <h4 style="margin:16px 0 8px 0; font-size:13px;">사이즈 회전율</h4>
  <div id="sa-sizes" style="display:flex; gap:4px; flex-wrap:wrap;"></div>
</div>

<script>
async function loadSalesAnalytics() {
  try {
    const r = await fetch('/api/sales/analytics');
    const d = await r.json();
    if (!d.ok) return;
    
    document.getElementById('sa-totals').innerHTML = 
      `<span>총 판매: <strong>${(d.total_count||0).toLocaleString()}건</strong></span>` +
      `<span>총 매출: <strong>${(d.total_revenue||0).toLocaleString()}원</strong></span>`;
    
    // 일별 차트 (간단한 막대)
    const maxCount = Math.max(...d.daily_7d.map(x => x.count), 1);
    document.getElementById('sa-daily').innerHTML = d.daily_7d.length === 0 
      ? '<div style="color:#9ca3af; font-size:12px;">최근 7일 판매 없음</div>'
      : d.daily_7d.map(x => {
          const h = (x.count / maxCount) * 60;
          return `<div style="flex:1; display:flex; flex-direction:column; align-items:center;">
            <div style="font-size:10px; color:#6b7280;">${x.count}</div>
            <div style="width:80%; background:#3b82f6; height:${h}px; border-radius:2px 2px 0 0;"></div>
            <div style="font-size:9px; color:#6b7280;">${x.date.slice(5)}</div>
          </div>`;
        }).join('');
    
    // 모델 테이블
    document.getElementById('sa-models').innerHTML = 
      '<tr style="background:#f3f4f6;"><th style="padding:6px; border:1px solid #d1d5db; text-align:left;">모델</th><th style="padding:6px; border:1px solid #d1d5db;">건수</th><th style="padding:6px; border:1px solid #d1d5db; text-align:right;">평균가</th><th style="padding:6px; border:1px solid #d1d5db; text-align:right;">매출</th></tr>' +
      (d.top_models.length === 0 ? '<tr><td colspan="4" style="padding:12px; text-align:center; color:#9ca3af;">데이터 없음</td></tr>' :
       d.top_models.map(m => 
        `<tr><td style="padding:6px; border:1px solid #d1d5db;">${m.model}</td>` +
        `<td style="padding:6px; border:1px solid #d1d5db; text-align:center;">${m.count}</td>` +
        `<td style="padding:6px; border:1px solid #d1d5db; text-align:right;">${Math.round(m.avg_price).toLocaleString()}원</td>` +
        `<td style="padding:6px; border:1px solid #d1d5db; text-align:right;">${Math.round(m.revenue).toLocaleString()}원</td></tr>`
      ).join(''));
    
    // 사이즈
    document.getElementById('sa-sizes').innerHTML = d.size_freq.length === 0 
      ? '<span style="color:#9ca3af; font-size:12px;">데이터 없음</span>'
      : d.size_freq.map(s => 
          `<span style="background:#dbeafe; color:#1e3a8a; padding:4px 8px; border-radius:12px; font-size:11px;">${s.size} (${s.count})</span>`
        ).join('');
  } catch(e) { console.warn('sales analytics:', e); }
}
document.addEventListener('DOMContentLoaded', loadSalesAnalytics);
</script>
```

## 작업 #4: 작업 일지 자동 생성

### 신규 라우트: /api/daily-log/today, /api/daily-log/<date>

```python
@app.route('/api/daily-log/today', methods=['GET'])
def api_daily_log_today():
    return _api_daily_log(datetime.now().strftime('%Y-%m-%d'))

@app.route('/api/daily-log/<date>', methods=['GET'])
def api_daily_log_by_date(date):
    return _api_daily_log(date)

def _api_daily_log(date):
    """특정 날짜의 작업 일지 마크다운 반환."""
    try:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        
        # 입찰 (executed)
        c.execute("""
            SELECT model, size, new_price, expected_profit
            FROM price_adjustments
            WHERE DATE(executed_at) = ? AND status = 'executed'
            ORDER BY executed_at
        """, (date,))
        bids = c.fetchall()
        
        # 자동 조정
        c.execute("""
            SELECT model, size, old_price, new_price, action
            FROM auto_adjust_log
            WHERE DATE(executed_at) = ?
            ORDER BY executed_at
        """, (date,))
        adjusts = c.fetchall()
        
        # 판매
        c.execute("""
            SELECT model, size, sale_price
            FROM sales_history
            WHERE DATE(trade_date) = ?
            ORDER BY trade_date
        """, (date,))
        sales = c.fetchall()
        
        # 인증 실패
        try:
            c.execute("""
                SELECT subject, body, created_at
                FROM notifications
                WHERE type = 'auth_failure' AND DATE(created_at) = ?
                ORDER BY created_at
            """, (date,))
            auth_fails = c.fetchall()
        except:
            auth_fails = []
        
        conn.close()
        
        # 마크다운 생성
        md = f"# 작업 일지 — {date}\n\n"
        md += f"## 📊 요약\n\n"
        md += f"- 입찰 실행: **{len(bids)}건**\n"
        md += f"- 자동 가격조정: **{len(adjusts)}건**\n"
        md += f"- 판매 체결: **{len(sales)}건**\n"
        md += f"- 인증 실패: **{len(auth_fails)}건**\n\n"
        
        if sales:
            total_rev = sum((s[2] or 0) for s in sales)
            md += f"### 💰 매출\n\n총 {total_rev:,}원 ({len(sales)}건)\n\n"
            md += "| 모델 | 사이즈 | 판매가 |\n|---|---|---|\n"
            for s in sales:
                md += f"| {s[0]} | {s[1] or '-'} | {(s[2] or 0):,}원 |\n"
            md += "\n"
        
        if bids:
            md += f"### 📦 입찰 실행 ({len(bids)}건)\n\n"
            md += "| 모델 | 사이즈 | 가격 | 예상수익 |\n|---|---|---|---|\n"
            for b in bids:
                profit = b[3] if b[3] is not None else '-'
                md += f"| {b[0]} | {b[1] or '-'} | {(b[2] or 0):,}원 | {profit if isinstance(profit, str) else f'{profit:,}원'} |\n"
            md += "\n"
        
        if adjusts:
            md += f"### 🎯 자동 가격 조정 ({len(adjusts)}건)\n\n"
            for a in adjusts:
                md += f"- {a[0]} {a[1] or '-'}: {(a[2] or 0):,} → {(a[3] or 0):,}원 [{a[4]}]\n"
            md += "\n"
        
        if auth_fails:
            md += f"### ⚠️ 인증 실패 ({len(auth_fails)}건)\n\n"
            for af in auth_fails:
                md += f"- [{af[2]}] {af[0]}\n"
            md += "\n"
        
        if not (bids or adjusts or sales or auth_fails):
            md += "_이 날짜에 기록된 작업 없음_\n"
        
        return jsonify({'ok': True, 'date': date, 'markdown': md})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.route('/api/daily-log/save-today', methods=['POST'])
def api_daily_log_save():
    """오늘 일지를 daily_log/YYYY-MM-DD.md 파일로 저장."""
    try:
        from pathlib import Path
        date = datetime.now().strftime('%Y-%m-%d')
        result = _api_daily_log(date)
        if hasattr(result, 'json'):
            data = result.get_json()
        else:
            data = json.loads(result.data)
        if not data.get('ok'):
            return jsonify({'ok': False, 'error': 'log generation failed'}), 500
        
        log_dir = Path(__file__).parent / 'daily_log'
        log_dir.mkdir(exist_ok=True)
        log_path = log_dir / f'{date}.md'
        log_path.write_text(data['markdown'], encoding='utf-8')
        
        return jsonify({'ok': True, 'saved_to': str(log_path), 'date': date})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500
```

## 검증

1. python3 -m py_compile kream_server.py → 0
2. 서버 재시작
3. /api/my-bids/rank-changes → ok=true
4. /api/sales/analytics → ok=true
5. /api/daily-log/today → ok=true, markdown 키 존재
6. /api/daily-log/save-today POST → 파일 저장 성공
7. 대시보드에 my-bids-monitor id 존재
8. tabs/tab_margin.html에 margin-reverse id 존재
9. tabs/tab_pattern.html에 sales-analytics-widget id 존재
10. 회귀: /api/health 200, /api/queue/list 200, /api/help/register ok

## 절대 규칙
- 기존 라우트 시그니처 변경 금지
- 자동 토글 ON 변경 금지
- DB 스키마 변경 금지

## 커밋 메시지
```
feat(Step 18-C): 환경 비의존 가치 작업 4건

- /api/my-bids/rank-changes: 내 입찰 rank 추적
- 대시보드 "내 입찰 현황" 위젯 (1분 자동 갱신)
- 마진 시뮬레이터 강화: 역산 모드 + 환율/수수료 시나리오 비교
- /api/sales/analytics: 7일/30일 일별 + 모델 TOP10 + 사이즈 회전율
- 판매패턴 탭에 분석 위젯 (간단 막대차트 + 테이블)
- /api/daily-log/today, /api/daily-log/<date>, /api/daily-log/save-today
- 작업 일지 마크다운 자동 생성

배경: macbook_overseas 환경에서도 가치 만들 수 있는 4가지 영역
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
작업지시서_Step18C.md 읽고 끝까지 진행. 질문 절대 금지. 사용자 개입 요청 금지.

순서:
1. 작업지시서 읽기

2. kream_server.py에 라우트 추가 (멱등성: 이미 있으면 스킵):
   - GET /api/my-bids/rank-changes
   - GET /api/sales/analytics
   - GET /api/daily-log/today, /api/daily-log/<date>
   - POST /api/daily-log/save-today
   - 헬퍼 함수 _api_daily_log(date)

3. kream_dashboard.html에 my-bids-monitor div + loadMyBidsMonitor JS 주입
   (id="my-bids-monitor" 이미 있으면 스킵)

4. tabs/tab_margin.html에 margin-reverse + margin-scenarios div + JS 주입
   (id="margin-reverse" 이미 있으면 스킵)

5. tabs/tab_pattern.html에 sales-analytics-widget div + loadSalesAnalytics JS 주입
   (id="sales-analytics-widget" 이미 있으면 스킵)

6. 문법 검증:
   python3 -m py_compile kream_server.py

7. 서버 재시작:
   lsof -ti:5001 | xargs kill -9 || true
   sleep 2
   nohup python3 kream_server.py > server.log 2>&1 & disown
   sleep 8

8. API 검증:
   - curl -s http://localhost:5001/api/my-bids/rank-changes | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'); print('rank-changes OK total=', d.get('total_bids'))"
   - curl -s http://localhost:5001/api/sales/analytics | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'); print('analytics OK total=', d.get('total_count'))"
   - curl -s http://localhost:5001/api/daily-log/today | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'); assert 'markdown' in d; print('daily-log OK len=', len(d['markdown']))"
   - curl -s -X POST http://localhost:5001/api/daily-log/save-today | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'); print('save OK', d.get('saved_to'))"

9. HTML 마커 검증:
   - grep -q 'my-bids-monitor' kream_dashboard.html
   - grep -q 'margin-reverse' tabs/tab_margin.html
   - grep -q 'sales-analytics-widget' tabs/tab_pattern.html

10. 회귀:
    - curl -s http://localhost:5001/api/health | grep -q '"status"'
    - curl -s -o /dev/null -w "%{http_code}" http://localhost:5001/api/queue/list → 200
    - curl -s http://localhost:5001/api/help/register | grep -q '"ok": true'
    - curl -s http://localhost:5001/api/daily-summary | grep -q '"ok": true'

11. 모두 PASS면 단일 커밋 + push:
    git add -A
    git commit -m "feat(Step 18-C): 환경 비의존 가치 작업 4건

    - /api/my-bids/rank-changes: 내 입찰 rank 추적
    - 대시보드 '내 입찰 현황' 위젯 (1분 자동 갱신)
    - 마진 시뮬레이터 강화: 역산 모드 + 환율/수수료 시나리오 비교
    - /api/sales/analytics: 7일/30일 일별 + 모델 TOP10 + 사이즈 회전율
    - 판매패턴 탭에 분석 위젯
    - /api/daily-log/today + 자동 저장 API
    - 작업 일지 마크다운 자동 생성

    배경: macbook_overseas 환경에서도 가치 만들 수 있는 4가지 영역"
    git push origin main

12. 끝.

검증 FAIL 시 즉시 종료. 백업 복원은 외부 스크립트가 처리.
질문/확인 요청 절대 금지.
CLAUDE_PROMPT

echo ""
echo "🔍 최종 검증..."
verify_server || fail_and_restore "최종 검증"

# 핵심 API
echo ""
echo "  📋 핵심 API 검증:"

RANK_OK=$(curl -s http://localhost:5001/api/my-bids/rank-changes | python3 -c "
import sys,json
try: print('YES' if json.load(sys.stdin).get('ok') else 'NO')
except: print('NO')
" 2>/dev/null)
echo "    rank-changes: $RANK_OK"
[ "$RANK_OK" != "YES" ] && fail_and_restore "rank-changes 실패"

ANALYTICS_OK=$(curl -s http://localhost:5001/api/sales/analytics | python3 -c "
import sys,json
try: print('YES' if json.load(sys.stdin).get('ok') else 'NO')
except: print('NO')
" 2>/dev/null)
echo "    sales/analytics: $ANALYTICS_OK"
[ "$ANALYTICS_OK" != "YES" ] && fail_and_restore "sales/analytics 실패"

LOG_OK=$(curl -s http://localhost:5001/api/daily-log/today | python3 -c "
import sys,json
try: 
    d=json.load(sys.stdin)
    print('YES' if d.get('ok') and 'markdown' in d else 'NO')
except: print('NO')
" 2>/dev/null)
echo "    daily-log/today: $LOG_OK"
[ "$LOG_OK" != "YES" ] && fail_and_restore "daily-log 실패"

SAVE_OK=$(curl -s -X POST http://localhost:5001/api/daily-log/save-today | python3 -c "
import sys,json
try: 
    d=json.load(sys.stdin)
    print(d.get('saved_to', 'NO') if d.get('ok') else 'NO')
except: print('NO')
" 2>/dev/null)
echo "    daily-log/save-today: $SAVE_OK"

# HTML 검증
grep -q 'my-bids-monitor' kream_dashboard.html && echo "    ✅ my-bids-monitor 주입됨" || echo "    ⚠️ my-bids-monitor 누락"
grep -q 'margin-reverse' tabs/tab_margin.html 2>/dev/null && echo "    ✅ margin-reverse 주입됨" || echo "    ⚠️ margin-reverse 누락"
grep -q 'sales-analytics-widget' tabs/tab_pattern.html 2>/dev/null && echo "    ✅ sales-analytics-widget 주입됨" || echo "    ⚠️ sales-analytics-widget 누락"

FINAL_HASH=$(git log -1 --format=%h)
echo ""
echo "  ✅ 커밋: $FINAL_HASH"
echo ""

# ==========================================
# [STAGE 4] 컨텍스트 v11
# ==========================================
echo "════════════════════ [STAGE 4] 컨텍스트 v11 ════════════════════"

PA_PENDING=$(sqlite3 price_history.db "SELECT COUNT(*) FROM price_adjustments WHERE status='pending'" 2>/dev/null || echo "?")
SALES_COUNT=$(sqlite3 price_history.db "SELECT COUNT(*) FROM sales_history" 2>/dev/null || echo "?")
LATEST_SALE=$(sqlite3 price_history.db "SELECT MAX(trade_date) FROM sales_history" 2>/dev/null || echo "?")

cat > "다음세션_시작_컨텍스트_v11.md" <<MDEOF
# 다음 세션 시작 컨텍스트 v11

> 작성일: $(date '+%Y-%m-%d %H:%M:%S') (자동 생성)
> 직전 커밋: $(git log -1 --format='%h %s')

## 1. 2026-05-02 단일 세션 누적 작업

| 작업 | 커밋 |
|---|---|
| JQ4110 진단 + 130k 삭제 | 490da5a → e5dd7e8 |
| 도움말 시스템 12탭 | 3df382d |
| Step 18-A (삭제검증+환경+요약) | ff97377 |
| Step 18-B (HTTP감지+실전+위젯) | 900e6f6 |
| Step 18-C (입찰모니터+마진시뮬+판매분석+일지) | $FINAL_HASH |

## 2. 환경

- environment: **macbook_overseas** (HTTP timeout 확인)
- 가격 수집: 차단
- 판매자센터/입찰관리/판매수집: 정상

## 3. 신규 API 누적 (Step 18-A/B/C)

- /api/my-bids/verify-deleted, /rank-changes
- /api/env/recheck, /test-price-collection
- /api/daily-summary (확장)
- /api/sales/analytics
- /api/daily-log/today, /<date>, /save-today

## 4. 대시보드 구성

- 상단 카드 6개 (입찰/자동조정/판매/pending/인증실패/가격수집)
- 내 입찰 현황 위젯 (rank 추적)
- ❓ 도움말 12개 탭

## 5. DB 현황

| 테이블 | 건수 |
|---|---|
| pa_pending | $PA_PENDING |
| sales_history | $SALES_COUNT |
| 최근 trade_date | $LATEST_SALE |

## 6. 다음 작업 후보

### 1순위 — Step 18-D: 자동 일지 스케줄러
- 매일 자정에 /api/daily-log/save-today 자동 호출
- daily_log/ 폴더 누적 → 매일 어제 일지 자동 보관

### 2순위 — VPN 켜고 가격수집 복원
- VPN ON → curl -X POST /api/env/recheck
- imac_kr 되면 자동조정 dry_run 시작 가능

### 3순위 — 판매 데이터 누적 후 패턴 분석
- 현재 8건 → 50건+ 누적 시 시간대/요일 인사이트 도출

## 7. 다음 채팅 첫 메시지 템플릿

\`\`\`
다음세션_시작_컨텍스트_v11.md 읽고 현재 상태 파악.
직전 커밋 $FINAL_HASH (Step 18-C 완료).
환경: macbook_overseas

오늘 작업: [기획해서 가져오기 / 구체 지시]

알아서 끝까지. 질문 최소화.
\`\`\`

## 8. 절대 규칙 (CLAUDE.md)

7대 규칙 그대로 유지.
MDEOF

echo "  ✅ 다음세션_시작_컨텍스트_v11.md 생성"
git add 다음세션_시작_컨텍스트_v11.md pipeline_step18c.log 2>/dev/null
git commit -m "docs: 다음세션 컨텍스트 v11 (Step 18-C 완료)" 2>/dev/null || echo "  (변경 없음)"
git push origin main 2>/dev/null || echo "  (push 스킵)"
echo ""

# 최종 요약
PIPELINE_END=$(date +%s)
ELAPSED=$((PIPELINE_END - PIPELINE_START))
ELAPSED_MIN=$((ELAPSED / 60))

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🎉 Step 18-C 완료 — ${ELAPSED_MIN}분 ${ELAPSED}초"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "✅ 결과:"
echo "  - 내 입찰 모니터 위젯 (rank 추적)"
echo "  - 마진 시뮬레이터 (역산 + 시나리오)"
echo "  - 판매 분석 (7일/30일 + 모델 TOP10 + 사이즈)"
echo "  - 작업 일지 자동 생성 ($SAVE_OK)"
echo "  - 커밋: $FINAL_HASH"
echo ""
echo "📋 활용:"
echo "  - 대시보드 새로고침 → 내 입찰 현황 위젯"
echo "  - 마진 계산기 탭 → 역산/시나리오 섹션"
echo "  - 판매 패턴 탭 → 분석 위젯"
echo "  - daily_log/ 폴더 → 오늘부터 일지 누적"
echo ""
echo "📜 로그: pipeline_step18c.log"
echo ""
