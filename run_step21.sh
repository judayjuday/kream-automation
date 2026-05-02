#!/bin/bash
# Step 21 통합 — 효과 측정 인프라
#   1. 자본 추이 자동 기록 (매시간 스냅샷)
#   2. 자본 추이 차트 (24h 미니 그래프)
#   3. 모델 포트폴리오 대시보드
#   4. 자본 효율(ROI) 지표

set -e
exec > >(tee -a pipeline_step21.log) 2>&1
cd ~/Desktop/kream_automation

PIPELINE_START=$(date +%s)
TS=$(date '+%Y%m%d_%H%M%S')

echo "================================================================"
echo "🚀 Step 21 Pipeline — $(date '+%Y-%m-%d %H:%M:%S')"
echo "   1) 자본추이기록  2) 차트  3) 포트폴리오  4) ROI"
echo "================================================================"
echo ""

fail_and_restore() {
    echo ""
    echo "❌ [$1] FAIL — 백업 복원"
    [ -f "kream_server.py.step21_pre.bak" ] && cp "kream_server.py.step21_pre.bak" kream_server.py
    [ -f "kream_dashboard.html.step21_pre.bak" ] && cp "kream_dashboard.html.step21_pre.bak" kream_dashboard.html
    
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
    echo "  ❌ HTTP $code" && return 1
}

# ==========================================
# [STAGE 0] 사전 점검
# ==========================================
echo "════════════════════ [STAGE 0] 사전 점검 ════════════════════"
verify_server || fail_and_restore "사전 점검"
echo "  현재 커밋: $(git log --oneline -1)"

# 자본 현황
TIED_NOW=$(curl -s http://localhost:5001/api/capital-status | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('tied_total', 0))
except: print(0)
" 2>/dev/null)
echo "  📊 현재 묶인 자본: ${TIED_NOW}원"
echo ""

# ==========================================
# [STAGE 1] 백업
# ==========================================
echo "════════════════════ [STAGE 1] 백업 ════════════════════"
cp kream_server.py "kream_server.py.step21_pre.bak"
cp kream_dashboard.html "kream_dashboard.html.step21_pre.bak"
sqlite3 /Users/iseungju/Desktop/kream_automation/price_history.db ".backup '/Users/iseungju/Desktop/kream_automation/price_history_step21_${TS}.db'"
echo "  ✅ 백업 완료"
echo ""

# ==========================================
# [STAGE 2] 작업지시서
# ==========================================
echo "════════════════════ [STAGE 2] 작업지시서 ════════════════════"

cat > "작업지시서_Step21.md" <<'MDEOF'
# 작업지시서 — Step 21: 효과 측정 인프라

> 의존: Step 20 (커밋 bbc4b83)
> 환경: macbook_overseas
> 절대 규칙 (CLAUDE.md) + 자동 토글 ON 변경 금지

## 작업 #1: 자본 추이 자동 기록

### DB 신규 테이블 (ALTER 아닌 CREATE)

```sql
CREATE TABLE IF NOT EXISTS capital_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    tied_total INTEGER,
    tied_count INTEGER,
    recoverable INTEGER,
    recoverable_count INTEGER,
    unknown_cost_count INTEGER,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_capital_history_ts ON capital_history(timestamp);
```

### 자동 스냅샷 함수 + 스케줄러

```python
def _snapshot_capital():
    """자본 현황 스냅샷을 capital_history에 저장."""
    try:
        # api_capital_status를 직접 호출 (응답 객체 처리)
        with app.app_context():
            resp = api_capital_status()
            if hasattr(resp, 'get_json'):
                data = resp.get_json()
            else:
                data = json.loads(resp.data) if hasattr(resp, 'data') else None
        
        if not data or not data.get('ok'):
            print(f"[CAPITAL-SNAPSHOT] 실패: {data}")
            return
        
        from datetime import datetime
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("""
            INSERT INTO capital_history 
            (timestamp, tied_total, tied_count, recoverable, recoverable_count, unknown_cost_count)
            VALUES (?, ?, ?, ?, ?, ?)
        """, (
            datetime.now().isoformat(),
            data.get('tied_total', 0),
            data.get('tied_count', 0),
            data.get('recoverable', 0),
            data.get('recoverable_count', 0),
            data.get('unknown_cost_count', 0),
        ))
        conn.commit()
        conn.close()
        print(f"[CAPITAL-SNAPSHOT] 기록: tied={data.get('tied_total')}")
    except Exception as e:
        print(f"[CAPITAL-SNAPSHOT] 에러: {e}")

# DB 마이그레이션 (서버 시작 시 1회)
def _migrate_capital_history():
    try:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("""
            CREATE TABLE IF NOT EXISTS capital_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT NOT NULL,
                tied_total INTEGER,
                tied_count INTEGER,
                recoverable INTEGER,
                recoverable_count INTEGER,
                unknown_cost_count INTEGER,
                created_at TEXT DEFAULT CURRENT_TIMESTAMP
            )
        """)
        c.execute("CREATE INDEX IF NOT EXISTS idx_capital_history_ts ON capital_history(timestamp)")
        conn.commit()
        conn.close()
        print("[MIGRATE] capital_history 테이블 확인/생성")
    except Exception as e:
        print(f"[MIGRATE] capital_history 에러: {e}")

# 서버 시작 시 호출 (if __name__ 블록 안)
_migrate_capital_history()

# 스케줄러 등록
try:
    scheduler.add_job(
        _snapshot_capital,
        'interval',
        hours=1,
        id='capital_snapshot',
        replace_existing=True,
        misfire_grace_time=600
    )
    print("[SCHEDULER] capital_snapshot 등록 (1시간 간격)")
    # 첫 스냅샷 즉시 실행 (서버 재시작 시 데이터 누적)
    try:
        _snapshot_capital()
    except: pass
except Exception as e:
    print(f"[SCHEDULER] capital_snapshot 등록 실패: {e}")
```

### 신규 라우트: /api/capital-history

```python
@app.route('/api/capital-history', methods=['GET'])
def api_capital_history():
    """자본 추이 조회. ?hours=24 (기본) ?days=7 등."""
    try:
        from datetime import datetime, timedelta
        hours = request.args.get('hours', type=int)
        days = request.args.get('days', type=int)
        
        if days:
            since = (datetime.now() - timedelta(days=days)).isoformat()
        elif hours:
            since = (datetime.now() - timedelta(hours=hours)).isoformat()
        else:
            since = (datetime.now() - timedelta(hours=24)).isoformat()
        
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("""
            SELECT timestamp, tied_total, tied_count, recoverable, recoverable_count
            FROM capital_history
            WHERE timestamp >= ?
            ORDER BY timestamp ASC
        """, (since,))
        rows = c.fetchall()
        conn.close()
        
        items = [
            {'timestamp': r[0], 'tied_total': r[1], 'tied_count': r[2], 
             'recoverable': r[3], 'recoverable_count': r[4]}
            for r in rows
        ]
        
        # 변화량 계산
        change = None
        if len(items) >= 2:
            change = {
                'tied_delta': items[-1]['tied_total'] - items[0]['tied_total'],
                'recoverable_delta': items[-1]['recoverable'] - items[0]['recoverable'],
                'period_hours': round((datetime.fromisoformat(items[-1]['timestamp']) - datetime.fromisoformat(items[0]['timestamp'])).total_seconds() / 3600, 1)
            }
        
        return jsonify({
            'ok': True,
            'count': len(items),
            'items': items,
            'change': change,
        })
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500
```

## 작업 #2: 자본 미니 차트 (대시보드)

### kream_dashboard.html — 자본 카드 클릭 시 차트 표시

기존 `dsc-card-capital` 카드 수정 + 차트 영역 추가 (이미 id="capital-chart-modal" 있으면 스킵):

dsc-card-capital div의 `style`에 `cursor:pointer;` 추가하고 onclick="showCapitalChart()" 추가.

`</body>` 직전에 모달 추가:

```html
<div id="capital-chart-modal" style="display:none; position:fixed; top:0;left:0;right:0;bottom:0; background:rgba(0,0,0,0.5); z-index:9999; align-items:center; justify-content:center;" onclick="if(event.target===this) closeCapitalChart()">
  <div style="background:#fff; max-width:680px; width:92%; border-radius:12px; padding:20px;">
    <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:12px;">
      <h2 style="margin:0; font-size:17px;">💰 자본 추이</h2>
      <button onclick="closeCapitalChart()" style="background:none; border:none; font-size:22px; cursor:pointer;">×</button>
    </div>
    <div id="cap-chart-stats" style="display:flex; gap:12px; margin-bottom:12px; font-size:13px;"></div>
    <div style="position:relative; height:200px; background:#f9fafb; border-radius:6px; padding:8px;">
      <svg id="cap-chart-svg" width="100%" height="184" viewBox="0 0 600 184" preserveAspectRatio="none"></svg>
    </div>
    <div id="cap-chart-info" style="margin-top:12px; font-size:12px; color:#6b7280;"></div>
    <div style="margin-top:12px; display:flex; gap:8px;">
      <button onclick="loadCapitalChart(24)" style="padding:6px 14px; background:#eff6ff; color:#1e40af; border:1px solid #bfdbfe; border-radius:6px; cursor:pointer;">24시간</button>
      <button onclick="loadCapitalChart(168)" style="padding:6px 14px; background:#eff6ff; color:#1e40af; border:1px solid #bfdbfe; border-radius:6px; cursor:pointer;">7일</button>
      <button onclick="loadCapitalChart(720)" style="padding:6px 14px; background:#eff6ff; color:#1e40af; border:1px solid #bfdbfe; border-radius:6px; cursor:pointer;">30일</button>
    </div>
  </div>
</div>

<script>
function showCapitalChart() {
  document.getElementById('capital-chart-modal').style.display = 'flex';
  loadCapitalChart(24);
}
function closeCapitalChart() {
  document.getElementById('capital-chart-modal').style.display = 'none';
}
async function loadCapitalChart(hours) {
  try {
    const r = await fetch('/api/capital-history?hours=' + hours);
    const d = await r.json();
    if (!d.ok) return;
    
    const svg = document.getElementById('cap-chart-svg');
    const items = d.items || [];
    
    // 통계
    const ch = d.change;
    let statsHtml = `<span>데이터 <strong>${d.count}</strong>건</span>`;
    if (ch && ch.tied_delta !== null) {
      const tdSign = ch.tied_delta >= 0 ? '+' : '';
      const tdColor = ch.tied_delta >= 0 ? '#dc2626' : '#059669';
      statsHtml += `<span>변화: <strong style="color:${tdColor}">${tdSign}${(ch.tied_delta/10000).toFixed(1)}만</strong> (${ch.period_hours}h)</span>`;
    }
    document.getElementById('cap-chart-stats').innerHTML = statsHtml;
    
    if (items.length < 2) {
      svg.innerHTML = '<text x="300" y="92" text-anchor="middle" fill="#9ca3af">데이터 부족 (시간 지나면 누적됩니다)</text>';
      document.getElementById('cap-chart-info').textContent = '매시간 자동 기록되며, 24시간 후부터 차트가 의미 있어집니다.';
      return;
    }
    
    // 정규화
    const values = items.map(it => it.tied_total);
    const max = Math.max(...values);
    const min = Math.min(...values);
    const range = Math.max(max - min, 1);
    const W = 600, H = 184, P = 20;
    
    // 라인 path
    const points = items.map((it, i) => {
      const x = P + (W - 2*P) * (i / (items.length - 1));
      const y = H - P - (H - 2*P) * ((it.tied_total - min) / range);
      return `${x.toFixed(1)},${y.toFixed(1)}`;
    });
    const pathD = 'M ' + points.join(' L ');
    
    // 영역 fill
    const areaD = pathD + ` L ${P + (W-2*P)},${H-P} L ${P},${H-P} Z`;
    
    svg.innerHTML = `
      <defs>
        <linearGradient id="capGrad" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stop-color="#7c3aed" stop-opacity="0.3"/>
          <stop offset="100%" stop-color="#7c3aed" stop-opacity="0"/>
        </linearGradient>
      </defs>
      <line x1="${P}" y1="${H-P}" x2="${W-P}" y2="${H-P}" stroke="#e5e7eb"/>
      <path d="${areaD}" fill="url(#capGrad)"/>
      <path d="${pathD}" fill="none" stroke="#7c3aed" stroke-width="2"/>
      <text x="${P}" y="14" font-size="10" fill="#6b7280">${(max/10000).toFixed(0)}만</text>
      <text x="${P}" y="${H-4}" font-size="10" fill="#6b7280">${(min/10000).toFixed(0)}만</text>
    `;
    
    document.getElementById('cap-chart-info').textContent = 
      `최저 ${(min/10000).toFixed(1)}만 / 최고 ${(max/10000).toFixed(1)}만 / 첫 기록 ${items[0].timestamp.slice(5,16)} / 최근 ${items[items.length-1].timestamp.slice(5,16)}`;
  } catch(e) {
    console.warn('capital chart:', e);
  }
}
</script>
```

## 작업 #3: 모델 포트폴리오

### 신규 라우트: /api/portfolio/overview

```python
@app.route('/api/portfolio/overview', methods=['GET'])
def api_portfolio_overview():
    """모든 활성 모델 자동 분류."""
    try:
        from pathlib import Path
        from collections import defaultdict
        
        local_path = Path(__file__).parent / 'my_bids_local.json'
        if not local_path.exists():
            return jsonify({'ok': True, 'models': [], 'note': 'no bids'})
        
        local = json.loads(local_path.read_text(encoding='utf-8'))
        bids = local.get('bids', [])
        
        # 활성 모델 추출
        active_models = set(b.get('model') for b in bids if b.get('model'))
        
        # sales_history에 있는 모델도 포함 (입찰 없어도 판매 이력 있으면 분석)
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("SELECT DISTINCT model FROM sales_history WHERE model IS NOT NULL")
        sold_models = set(r[0] for r in c.fetchall())
        
        all_models = active_models | sold_models
        
        # 각 모델 deep-analysis (간소화 버전)
        models_info = []
        for model in all_models:
            # 활성 입찰
            mb = [b for b in bids if b.get('model') == model]
            active_count = len(mb)
            rank_1 = sum(1 for b in mb if b.get('rank') == 1)
            
            # 판매
            c.execute("SELECT COUNT(*), SUM(sale_price), MAX(trade_date) FROM sales_history WHERE model = ?", (model,))
            row = c.fetchone()
            sales_count = row[0] or 0
            revenue = row[1] or 0
            last_sale = row[2]
            
            # 추천
            rec = 'monitor'
            rec_priority = 3  # 1=high, 2=medium, 3=low
            if sales_count == 0 and active_count > 0:
                rec = 'no_data'
                rec_priority = 3
            elif active_count == 0 and sales_count > 2:
                rec = 'restock'
                rec_priority = 1
            elif active_count > 0 and rank_1 == 0:
                rec = 'review_pricing'
                rec_priority = 2
            elif sales_count > 5 and active_count > 0 and rank_1 >= active_count * 0.5:
                rec = 'expand'
                rec_priority = 1
            elif sales_count == 0 and active_count == 0:
                rec = 'archive'
                rec_priority = 3
            
            models_info.append({
                'model': model,
                'active_bids': active_count,
                'rank_1_bids': rank_1,
                'sales_count': sales_count,
                'revenue': revenue,
                'last_sale': last_sale,
                'recommendation': rec,
                'priority': rec_priority,
            })
        
        conn.close()
        
        # 추천별 그룹
        by_rec = defaultdict(list)
        for m in models_info:
            by_rec[m['recommendation']].append(m)
        
        # 우선순위 정렬
        models_info.sort(key=lambda x: (x['priority'], -x['sales_count']))
        
        return jsonify({
            'ok': True,
            'total_models': len(models_info),
            'by_recommendation': dict(by_rec),
            'models': models_info,
            'stats': {
                'expand': len(by_rec.get('expand', [])),
                'restock': len(by_rec.get('restock', [])),
                'review_pricing': len(by_rec.get('review_pricing', [])),
                'monitor': len(by_rec.get('monitor', [])),
                'no_data': len(by_rec.get('no_data', [])),
                'archive': len(by_rec.get('archive', [])),
            }
        })
    except Exception as e:
        import traceback
        return jsonify({'ok': False, 'error': str(e), 'trace': traceback.format_exc()}), 500
```

### tabs/tab_portfolio.html 신규

```html
<div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:12px; padding:8px 0; border-bottom:1px solid #e5e7eb;">
  <span style="font-size:14px; color:#6b7280;">현재 메뉴</span>
  <button onclick="showHelp('portfolio')" style="background:#f3f4f6; border:1px solid #d1d5db; border-radius:20px; padding:4px 12px; font-size:13px; cursor:pointer;">❓ 도움말</button>
</div>

<h2 style="margin:0 0 16px 0;">📊 모델 포트폴리오</h2>

<div id="port-stats" style="display:flex; gap:8px; flex-wrap:wrap; margin-bottom:16px;"></div>

<button onclick="loadPortfolio()" style="padding:6px 14px; background:#2563eb; color:#fff; border:none; border-radius:6px; cursor:pointer; margin-bottom:12px;">🔄 새로고침</button>

<div id="port-grid" style="display:grid; grid-template-columns:repeat(auto-fill, minmax(260px, 1fr)); gap:12px;"></div>

<script>
const REC_INFO = {
  'expand': {label: '확대', color: '#059669', bg: '#ecfdf5', icon: '📈'},
  'restock': {label: '재입찰', color: '#d97706', bg: '#fffbeb', icon: '🔄'},
  'review_pricing': {label: '가격재검토', color: '#dc2626', bg: '#fef2f2', icon: '⚠️'},
  'monitor': {label: '유지', color: '#374151', bg: '#f9fafb', icon: '👁'},
  'no_data': {label: '데이터부족', color: '#9ca3af', bg: '#f3f4f6', icon: '❓'},
  'archive': {label: '접기', color: '#6b7280', bg: '#f3f4f6', icon: '📦'},
};

async function loadPortfolio() {
  document.getElementById('port-grid').innerHTML = '<div style="grid-column:1/-1; padding:24px; text-align:center;">⏳ 분석 중...</div>';
  try {
    const r = await fetch('/api/portfolio/overview');
    const d = await r.json();
    if (!d.ok) {
      document.getElementById('port-grid').innerHTML = `<div style="grid-column:1/-1; color:#dc2626;">에러: ${d.error}</div>`;
      return;
    }
    
    // 통계
    const s = d.stats;
    document.getElementById('port-stats').innerHTML = 
      `<div style="background:#fff; border:1px solid #e5e7eb; padding:8px 12px; border-radius:6px;">총 <strong>${d.total_models}</strong>개 모델</div>` +
      Object.entries(REC_INFO).map(([key, info]) => 
        `<div style="background:${info.bg}; padding:8px 12px; border-radius:6px; color:${info.color};">${info.icon} ${info.label} <strong>${s[key]||0}</strong></div>`
      ).join('');
    
    // 카드 그리드
    if (d.models.length === 0) {
      document.getElementById('port-grid').innerHTML = '<div style="grid-column:1/-1; padding:24px; text-align:center; color:#9ca3af;">분석할 모델 없음</div>';
      return;
    }
    
    document.getElementById('port-grid').innerHTML = d.models.map(m => {
      const rec = REC_INFO[m.recommendation] || REC_INFO.monitor;
      const lastSale = m.last_sale ? m.last_sale.slice(0,10) : '-';
      return `<div style="background:#fff; border:1px solid #e5e7eb; border-left:4px solid ${rec.color}; border-radius:6px; padding:12px;">
        <div style="display:flex; justify-content:space-between; align-items:flex-start; margin-bottom:8px;">
          <strong style="font-size:13px;">${m.model}</strong>
          <span style="background:${rec.bg}; color:${rec.color}; padding:2px 8px; border-radius:10px; font-size:11px; font-weight:bold;">${rec.icon} ${rec.label}</span>
        </div>
        <div style="font-size:11px; color:#6b7280; line-height:1.6;">
          입찰 ${m.active_bids}건 (1위 ${m.rank_1_bids}) · 판매 ${m.sales_count}건<br>
          매출 ${(m.revenue/10000).toFixed(0)}만원 · 최근 ${lastSale}
        </div>
        <button onclick="loadModelDeep('${m.model}')" style="margin-top:8px; padding:4px 10px; background:#f3f4f6; border:1px solid #d1d5db; border-radius:4px; font-size:11px; cursor:pointer;">상세</button>
      </div>`;
    }).join('');
  } catch(e) {
    document.getElementById('port-grid').innerHTML = `<div style="grid-column:1/-1; color:#dc2626;">로드 실패: ${e.message}</div>`;
  }
}

async function loadModelDeep(model) {
  try {
    const r = await fetch('/api/model/' + encodeURIComponent(model) + '/deep-analysis');
    const d = await r.json();
    if (!d.ok) { alert('실패'); return; }
    const s = d.summary || {};
    let msg = `📊 ${model}\n\n`;
    msg += `활성 입찰: ${s.active_bids} (1위 ${s.rank_1_bids})\n`;
    msg += `판매 누적: ${s.total_sales}건 / ${(s.total_revenue||0).toLocaleString()}원\n`;
    msg += `평균 판매가: ${(s.avg_sale_price||0).toLocaleString()}원\n`;
    msg += `원가 데이터: ${s.has_cost_data ? 'O' : 'X'}\n\n`;
    msg += `추천: ${d.recommendation}\n${d.recommendation_reason || ''}`;
    alert(msg);
  } catch(e) { alert('실패: ' + e.message); }
}

document.addEventListener('DOMContentLoaded', loadPortfolio);
</script>
```

### help_content.json에 portfolio 추가

```json
"portfolio": {
  "icon": "📊",
  "title": "모델 포트폴리오",
  "what": "모든 활성 모델을 자동 분석하고 확대/재입찰/가격재검토/유지/접기로 자동 분류",
  "why": "어떤 모델에 자본 더 투입할지, 어떤 모델 정리할지 한 화면에 보고 결정. 모델별 매출/회전율/원가 데이터 종합 평가",
  "how": [
    "1. 새로고침 누르면 모든 모델 자동 분석",
    "2. 색깔별 추천: 📈확대 / 🔄재입찰 / ⚠️가격재검토 / 👁유지 / 📦접기",
    "3. 카드 클릭하면 상세 분석",
    "4. 우선순위 높은 모델부터 의사결정"
  ],
  "warn": "추천은 데이터 기반 자동 분류. 최종 의사결정은 사장 책임. 데이터 부족 모델은 '데이터부족'으로 표시됨."
}
```

### 사이드바 메뉴 추가

kream_dashboard.html에 "📊 모델 포트폴리오" 메뉴 추가 (이미 portfolio 있으면 스킵).
기존 다른 탭 메뉴 패턴 그대로.

## 작업 #4: 자본 효율 (ROI)

### 신규 라우트: /api/capital-efficiency

```python
@app.route('/api/capital-efficiency', methods=['GET'])
def api_capital_efficiency():
    """30일 ROI 추정 + 모델별 효율."""
    try:
        from datetime import datetime, timedelta
        from collections import defaultdict
        
        thirty_days_ago = (datetime.now() - timedelta(days=30)).strftime('%Y-%m-%d')
        
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        
        # 30일 매출
        c.execute("""
            SELECT model, COUNT(*) as cnt, SUM(sale_price) as revenue
            FROM sales_history
            WHERE DATE(trade_date) >= ?
            GROUP BY model
        """, (thirty_days_ago,))
        sales_by_model = {r[0]: {'count': r[1], 'revenue': r[2] or 0} for r in c.fetchall()}
        
        # 평균 자본 (capital_history 30일)
        c.execute("""
            SELECT AVG(tied_total) FROM capital_history
            WHERE DATE(timestamp) >= ?
        """, (thirty_days_ago,))
        avg_row = c.fetchone()
        avg_capital = avg_row[0] if avg_row and avg_row[0] else None
        
        # 평균 자본 데이터 없으면 현재 자본 사용
        if not avg_capital:
            with app.app_context():
                cap_resp = api_capital_status()
                cap_data = cap_resp.get_json() if hasattr(cap_resp, 'get_json') else json.loads(cap_resp.data)
            avg_capital = cap_data.get('tied_total', 1) if cap_data.get('ok') else 1
            data_source = 'current_only (capital_history 누적 부족)'
        else:
            data_source = '30day_avg'
        
        # 전체 매출
        total_sales = sum(s['count'] for s in sales_by_model.values())
        total_revenue = sum(s['revenue'] for s in sales_by_model.values())
        
        # 원가 추정 (bid_cost 평균)
        c.execute("""
            SELECT AVG(cny_price * exchange_rate * 1.03 + COALESCE(overseas_shipping, 8000))
            FROM bid_cost
        """)
        avg_cost_row = c.fetchone()
        avg_cost = avg_cost_row[0] if avg_cost_row and avg_cost_row[0] else 50000
        
        estimated_total_cost = avg_cost * total_sales
        gross_profit = total_revenue - estimated_total_cost
        
        # ROI = 순이익 / 평균 자본
        roi_30d = (gross_profit / avg_capital) if avg_capital else 0
        
        # 모델별 ROI (간이)
        model_roi = []
        for model, sales in sales_by_model.items():
            est_cost = avg_cost * sales['count']
            profit = sales['revenue'] - est_cost
            # 모델별 자본은 추정 (평균 원가 × 입찰 수 기준)
            from pathlib import Path
            local_path = Path(__file__).parent / 'my_bids_local.json'
            try:
                local = json.loads(local_path.read_text(encoding='utf-8'))
                model_bids = sum(1 for b in local.get('bids', []) if b.get('model') == model)
            except:
                model_bids = 1
            model_capital_est = max(avg_cost * model_bids, 1)
            model_roi.append({
                'model': model,
                'sales_count': sales['count'],
                'revenue': sales['revenue'],
                'est_profit': round(profit),
                'est_capital': round(model_capital_est),
                'roi_estimate': round(profit / model_capital_est, 3),
            })
        
        # ROI 순 정렬
        model_roi.sort(key=lambda x: -x['roi_estimate'])
        
        conn.close()
        
        return jsonify({
            'ok': True,
            'period_days': 30,
            'avg_capital': round(avg_capital),
            'data_source': data_source,
            'total_sales': total_sales,
            'total_revenue': round(total_revenue),
            'estimated_cost': round(estimated_total_cost),
            'gross_profit': round(gross_profit),
            'roi_30d': round(roi_30d, 3),
            'roi_30d_pct': round(roi_30d * 100, 1),
            'top_models_by_roi': model_roi[:10],
            'note': '원가는 bid_cost 평균치 기반 추정. 정확도는 bid_cost 입력률에 의존.'
        })
    except Exception as e:
        import traceback
        return jsonify({'ok': False, 'error': str(e), 'trace': traceback.format_exc()}), 500
```

## 검증

1. python3 -m py_compile kream_server.py → 0
2. 서버 재시작 후 server.log에 "[MIGRATE] capital_history" + "[SCHEDULER] capital_snapshot 등록"
3. /api/capital-history?hours=24 → ok=true (count >= 1, 첫 스냅샷 즉시 실행이라)
4. /api/portfolio/overview → ok=true, total_models, stats 객체
5. /api/capital-efficiency → ok=true, roi_30d_pct 키, top_models_by_roi 배열
6. /api/help/portfolio → ok=true
7. tabs/tab_portfolio.html 존재 + /tabs/tab_portfolio.html 200
8. 대시보드에 capital-chart-modal 마커
9. 회귀: capital-status, daily-summary, cleanup/diagnose, model/JQ4110/deep-analysis 모두 ok

## 절대 규칙
- 자동 액션 금지 (모두 표시/진단)
- 자동 토글 ON 변경 금지
- DB 마이그레이션은 CREATE TABLE IF NOT EXISTS만 (DROP/ALTER 금지)
- 기존 라우트 변경 금지

## 커밋 메시지
```
feat(Step 21): 효과 측정 인프라 (자본추이+포트폴리오+ROI)

- capital_history 테이블 + 매시간 자동 스냅샷
- /api/capital-history: 자본 추이 조회 (hours/days)
- 자본 카드 클릭 → 차트 모달 (24h/7d/30d 토글)
- /api/portfolio/overview: 모든 모델 자동 분류
  expand/restock/review_pricing/monitor/no_data/archive
- tabs/tab_portfolio.html: 카드 그리드 + 상세 분석
- /api/capital-efficiency: 30일 ROI + 모델별 순위

배경: 정리 효과 시각화 + 모델 의사결정 도구 + 자본 ROI
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
작업지시서_Step21.md 읽고 끝까지 진행. 질문 절대 금지. 사용자 개입 요청 금지.

순서:
1. 작업지시서 읽기

2. kream_server.py에 추가:
   a. _migrate_capital_history() 함수 (CREATE TABLE IF NOT EXISTS)
   b. _snapshot_capital() 함수
   c. /api/capital-history GET 라우트
   d. /api/portfolio/overview GET 라우트
   e. /api/capital-efficiency GET 라우트
   f. 서버 시작 시 _migrate_capital_history() 호출 (if __name__ 블록)
   g. scheduler.add_job으로 capital_snapshot 1시간 간격 등록 + 즉시 1회 실행
   
   멱등성: 이미 함수/라우트 있으면 스킵

3. tabs/tab_portfolio.html 신규 생성 (이미 있으면 스킵)

4. kream_dashboard.html 수정:
   a. dsc-card-capital div에 onclick="showCapitalChart()" + cursor:pointer 추가
      이미 있으면 스킵
   b. </body> 직전에 capital-chart-modal 추가 + showCapitalChart/closeCapitalChart/loadCapitalChart JS
      이미 id="capital-chart-modal" 있으면 스킵
   c. 사이드바에 "📊 모델 포트폴리오" 메뉴 추가 (data-tab="portfolio" 등 기존 패턴)
      이미 portfolio 메뉴 있으면 스킵

5. help_content.json에 "portfolio" 키 추가 (이미 있으면 스킵)

6. 문법:
   python3 -m py_compile kream_server.py

7. 서버 재시작:
   lsof -ti:5001 | xargs kill -9 || true
   sleep 2
   nohup python3 kream_server.py > server.log 2>&1 & disown
   sleep 8

8. API 검증:
   - curl -s http://localhost:5001/api/capital-history?hours=24 | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'); print('history OK count=', d.get('count'))"
   - curl -s http://localhost:5001/api/portfolio/overview | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'); print('portfolio OK total=', d.get('total_models'), 'stats=', d.get('stats'))"
   - curl -s http://localhost:5001/api/capital-efficiency | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'); print('roi OK pct=', d.get('roi_30d_pct'), 'sales=', d.get('total_sales'))"
   - curl -s http://localhost:5001/api/help/portfolio | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok'); print('help OK')"

9. 파일/HTML 검증:
   - test -f tabs/tab_portfolio.html
   - curl -s -o /dev/null -w "%{http_code}" http://localhost:5001/tabs/tab_portfolio.html → 200
   - grep -q 'capital-chart-modal' kream_dashboard.html
   - grep -q 'showCapitalChart' kream_dashboard.html

10. 스케줄러 등록 + 즉시 스냅샷 확인:
    - tail -100 server.log | grep -E "(capital_snapshot|MIGRATE.*capital|CAPITAL-SNAPSHOT)"

11. 회귀:
    - curl -s http://localhost:5001/api/capital-status | grep -q '"ok": true'
    - curl -s http://localhost:5001/api/cleanup/diagnose | grep -q '"ok": true'
    - curl -s http://localhost:5001/api/daily-summary | grep -q '"ok": true'
    - curl -s -o /dev/null -w "%{http_code}" http://localhost:5001/api/health → 200
    - curl -s -o /dev/null -w "%{http_code}" http://localhost:5001/admin/status → 200

12. 모두 PASS면 단일 커밋 + push:
    git add -A
    git commit -m "feat(Step 21): 효과 측정 인프라 (자본추이+포트폴리오+ROI)

    - capital_history 테이블 + 매시간 자동 스냅샷
    - /api/capital-history: 자본 추이 조회
    - 자본 카드 클릭 → 차트 모달 (24h/7d/30d)
    - /api/portfolio/overview: 모델 자동 분류 (6개 카테고리)
    - tabs/tab_portfolio.html: 카드 그리드 + 상세
    - /api/capital-efficiency: 30일 ROI + 모델별 순위

    배경: 정리 효과 시각화 + 모델 의사결정 + 자본 ROI"
    git push origin main

13. 끝.

검증 FAIL 시 즉시 종료.
질문/확인 요청 절대 금지.
CLAUDE_PROMPT

echo ""
echo "🔍 최종 검증..."
verify_server || fail_and_restore "최종 검증"

echo ""
echo "  📋 핵심 검증:"

HIST_OK=$(curl -s http://localhost:5001/api/capital-history?hours=24 | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(f\"count={d.get('count',0)}\" if d.get('ok') else 'FAIL')
except: print('ERROR')
" 2>/dev/null)
echo "    capital-history: $HIST_OK"
[[ "$HIST_OK" == "FAIL" ]] && fail_and_restore "history 실패"

PORT_OK=$(curl -s http://localhost:5001/api/portfolio/overview | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    if d.get('ok'):
        s=d.get('stats',{})
        print(f\"total={d.get('total_models')} expand={s.get('expand',0)} restock={s.get('restock',0)} review={s.get('review_pricing',0)} monitor={s.get('monitor',0)} archive={s.get('archive',0)}\")
    else: print('FAIL')
except: print('ERROR')
" 2>/dev/null)
echo "    portfolio: $PORT_OK"
[[ "$PORT_OK" == "FAIL" ]] && fail_and_restore "portfolio 실패"

ROI_OK=$(curl -s http://localhost:5001/api/capital-efficiency | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    if d.get('ok'):
        print(f\"roi={d.get('roi_30d_pct')}% sales={d.get('total_sales')} revenue={d.get('total_revenue'):,} src={d.get('data_source')}\")
    else: print('FAIL')
except: print('ERROR')
" 2>/dev/null)
echo "    ROI: $ROI_OK"
[[ "$ROI_OK" == "FAIL" ]] && fail_and_restore "ROI 실패"

[ -f "tabs/tab_portfolio.html" ] && echo "    ✅ tab_portfolio.html" || fail_and_restore "tab_portfolio 누락"
grep -q 'capital-chart-modal' kream_dashboard.html && echo "    ✅ 차트 모달 주입됨" || fail_and_restore "차트 모달 누락"

echo ""
echo "  📅 capital_snapshot 로그:"
tail -200 server.log 2>/dev/null | grep -E "(capital_snapshot|MIGRATE.*capital|CAPITAL-SNAPSHOT)" | tail -5 || echo "    (로그 없음)"

FINAL_HASH=$(git log -1 --format=%h)
echo ""
echo "  ✅ 커밋: $FINAL_HASH"
echo ""

# ==========================================
# [STAGE 4] 컨텍스트 v15
# ==========================================
echo "════════════════════ [STAGE 4] 컨텍스트 v15 ════════════════════"

PORT_TOTAL=$(echo "$PORT_OK" | sed -n 's/.*total=\([0-9]*\).*/\1/p')
PORT_RESTOCK=$(echo "$PORT_OK" | sed -n 's/.*restock=\([0-9]*\).*/\1/p')
PORT_REVIEW=$(echo "$PORT_OK" | sed -n 's/.*review=\([0-9]*\).*/\1/p')
ROI_PCT=$(echo "$ROI_OK" | sed -n 's/.*roi=\([0-9.\-]*\)%.*/\1/p')

PA_PENDING=$(sqlite3 price_history.db "SELECT COUNT(*) FROM price_adjustments WHERE status='pending'" 2>/dev/null || echo "?")
SALES_COUNT=$(sqlite3 price_history.db "SELECT COUNT(*) FROM sales_history" 2>/dev/null || echo "?")

cat > "다음세션_시작_컨텍스트_v15.md" <<MDEOF
# 다음 세션 시작 컨텍스트 v15

> 작성일: $(date '+%Y-%m-%d %H:%M:%S') (자동 생성)
> 직전 커밋: $(git log -1 --format='%h %s')

## 1. 2026-05-02 단일 세션 누적

| Step | 커밋 |
|---|---|
| JQ4110 + 도움말 | 490da5a → 3df382d |
| 18-A/B/C/D | ff97377 → 0695df0 |
| 19 (정리도구) | 358985b |
| 20 (자본+의사결정) | bbc4b83 |
| **21 (효과측정)** | **$FINAL_HASH** |

## 2. Step 21 측정값 (방금)

- **포트폴리오**: 총 ${PORT_TOTAL:-?}개 모델 / 재입찰 ${PORT_RESTOCK:-?} / 가격재검토 ${PORT_REVIEW:-?}
- **30일 ROI**: ${ROI_PCT:-?}%
- **자본 추이**: 첫 스냅샷 기록됨 (24시간 후부터 차트 의미)

## 3. 신규 인프라 (Step 21)

- DB 테이블: capital_history (1시간 자동 스냅샷)
- 스케줄러: capital_snapshot (1h)
- 신규 API:
  - /api/capital-history (?hours= ?days=)
  - /api/portfolio/overview
  - /api/capital-efficiency
- 신규 탭: 📊 모델 포트폴리오
- 자본 카드 클릭 → 차트 모달 (24h/7d/30d)

## 4. 자동 스케줄러 누적 (4개)

| 작업 | 주기 |
|---|---|
| 사전 갱신 | 12h |
| 입찰 sync + rank 알림 | 30분 |
| 일지 자동 저장 | 23:55 |
| 주간 리포트 | 월 0:05 |
| **자본 스냅샷 (NEW)** | **1h** |

## 5. DB 현황

| 테이블 | 건수 |
|---|---|
| pa_pending | $PA_PENDING |
| sales_history | $SALES_COUNT |
| capital_history | (시작) |

## 6. 다음 작업 후보

### 1순위 — 회수 7건 정리 실행 (사장)
- 사이드바 → 🧹 입찰 정리
- 회수 권장 전체 선택 → 일괄 회수
- 자본 카드 즉시 갱신 + 1시간 후 차트 변화 기록

### 2순위 — 포트폴리오 우선순위 액션
- "재입찰" 모델 → 재고 확보 후 입찰
- "가격재검토" 모델 → 가격 조정

### 3순위 — Step 22: 24시간 후 효과 측정
- capital_history 24h 데이터 누적 → 차트 의미
- 정리 전후 변화 자동 분석

## 7. 다음 채팅 첫 메시지

\`\`\`
다음세션_시작_컨텍스트_v15.md 읽고 현재 상태 파악.
직전 커밋 $FINAL_HASH (Step 21 완료).
환경: macbook_overseas

오늘 작업: [기획 / 구체 지시]

알아서 끝까지. 질문 최소화.
\`\`\`

## 8. 절대 규칙

7대 규칙 + 자동 토글 ON 금지 유지.
MDEOF

echo "  ✅ 다음세션_시작_컨텍스트_v15.md 생성"
git add 다음세션_시작_컨텍스트_v15.md pipeline_step21.log 2>/dev/null
git commit -m "docs: 다음세션 컨텍스트 v15 (Step 21 완료)" 2>/dev/null || echo "  (변경 없음)"
git push origin main 2>/dev/null || echo "  (push 스킵)"
echo ""

PIPELINE_END=$(date +%s)
ELAPSED=$((PIPELINE_END - PIPELINE_START))
ELAPSED_MIN=$((ELAPSED / 60))

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🎉 Step 21 완료 — ${ELAPSED_MIN}분 ${ELAPSED}초"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "✅ 결과:"
echo "  - 자본 추이: $HIST_OK"
echo "  - 포트폴리오: $PORT_OK"
echo "  - ROI: $ROI_OK"
echo "  - 커밋: $FINAL_HASH"
echo ""
echo "📋 활용:"
echo "  - 대시보드 → 자본 카드 클릭 → 추이 차트 (24h 후 의미 있음)"
echo "  - 사이드바 → 📊 모델 포트폴리오 → 카테고리별 의사결정"
echo "  - 정리 도구로 7건 회수 → 자본 추이에 즉시 반영"
echo ""
echo "📜 로그: pipeline_step21.log"
echo ""
