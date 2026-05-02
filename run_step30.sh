#!/bin/bash
# Step 30 — 둘 다 한 번에
#   A) sync 진짜 복구 — 메뉴 클릭 방식으로 수집
#   B) 신규 입찰 도구 — 모델별 일괄 입찰 헬퍼
#
# 화면 분석 결과 (사장 스크린샷):
# - 메뉴 경로: 통합 입찰 관리 → 입찰 내역 관리
# - 컬럼: 주문/보관번호 | 판매유형 | 상품정보 | 옵션 | 자동조정 | 판매희망가 | 매입가 | 마진 | 발매가 | 거래가
# - 데이터: 60+건 입찰 중, 페이지네이션 6페이지

set -e
exec > >(tee -a pipeline_step30.log) 2>&1
cd ~/Desktop/kream_automation

PIPELINE_START=$(date +%s)
TS=$(date '+%Y%m%d_%H%M%S')

echo "================================================================"
echo "🚀 Step 30 — sync 복구 + 신규 입찰 도구"
echo "================================================================"
echo ""

fail_and_restore() {
    echo ""
    echo "❌ [$1] FAIL — 백업 복원"
    [ -f "kream_adjuster.py.step30_pre.bak" ] && cp "kream_adjuster.py.step30_pre.bak" kream_adjuster.py
    [ -f "kream_server.py.step30_pre.bak" ] && cp "kream_server.py.step30_pre.bak" kream_server.py
    
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
echo ""

# ==========================================
# [STAGE 1] 백업
# ==========================================
echo "════════════════════ [STAGE 1] 백업 ════════════════════"
cp kream_adjuster.py "kream_adjuster.py.step30_pre.bak"
cp kream_server.py "kream_server.py.step30_pre.bak"
echo "  ✅ 백업 완료"
echo ""

# ==========================================
# [STAGE 2] sync 복구 — 메뉴 클릭 방식 직접 구현
# ==========================================
echo "════════════════════ [STAGE 2] sync 복구 ════════════════════"

# 새 collect_my_bids_v2 함수를 kream_adjuster.py 끝에 추가
python3 <<'PYEOF'
"""kream_adjuster.py에 메뉴 클릭 방식 sync 함수 추가."""
from pathlib import Path

p = Path('kream_adjuster.py')
text = p.read_text(encoding='utf-8')

# 이미 collect_my_bids_via_menu 있으면 스킵
if 'async def collect_my_bids_via_menu' in text:
    print("  ✅ collect_my_bids_via_menu 이미 존재 — 스킵")
else:
    NEW_FUNC = '''


async def collect_my_bids_via_menu(headless=True) -> list:
    """메뉴 클릭 방식으로 입찰 내역 관리 페이지 진입 → 데이터 수집.
    
    Step 30: 사장 스크린샷 분석 결과 정확한 메뉴 경로 + 컬럼 확정.
    경로: 메인 → '통합 입찰 관리' 클릭 → '입찰 내역 관리' 클릭
    
    화면 컬럼:
      주문/보관번호 | 판매유형 | 상품정보 | 옵션 | 자동조정 | 판매희망가 |
      매입가 | 예상마진 | 마진율 | 발매가 | 일반판매최근가 | 보관(100) | 보관(95)
    """
    from playwright.async_api import async_playwright
    from playwright_stealth import stealth_async as stealth
    from kream_bot import create_browser, create_context, ensure_logged_in, dismiss_popups
    import re
    
    bids = []
    
    async with async_playwright() as p:
        browser = await create_browser(p, headless=headless)
        context = await create_context(browser, storage='auth_state.json')
        page = await context.new_page()
        await stealth(page)
        
        # 1. 메인 페이지 진입
        print("[SYNC-V2] 메인 페이지 이동...")
        await page.goto('https://partner.kream.co.kr/c2c', wait_until='domcontentloaded', timeout=30000)
        await page.wait_for_timeout(3000)
        
        await ensure_logged_in(page, context)
        try: await dismiss_popups(page)
        except: pass
        await page.wait_for_timeout(2000)
        
        # 2. '통합 입찰 관리' 메뉴 클릭 (확장)
        # 사이드바 안의 정확한 a/button만 노림 — ASIDE 자체 클릭 회피
        print("[SYNC-V2] '통합 입찰 관리' 메뉴 확장...")
        clicked = await page.evaluate("""
            () => {
                // a, button, [role="link"]만 대상
                const cands = Array.from(document.querySelectorAll(
                    'aside a, aside button, aside [role="link"], aside [role="menuitem"], aside [role="button"]'
                ));
                for (const el of cands) {
                    const text = (el.textContent || '').trim();
                    if (text === '통합 입찰 관리' || text === '입찰 내역 관리') {
                        el.click();
                        return text;
                    }
                }
                return null;
            }
        """)
        print(f"[SYNC-V2] 1차 클릭: {clicked}")
        await page.wait_for_timeout(2000)
        
        # 3. '입찰 내역 관리' 메뉴 클릭 (서브메뉴)
        if clicked != '입찰 내역 관리':
            print("[SYNC-V2] '입찰 내역 관리' 서브메뉴 클릭...")
            clicked2 = await page.evaluate("""
                () => {
                    const cands = Array.from(document.querySelectorAll(
                        'aside a, aside button, aside [role="link"], aside [role="menuitem"]'
                    ));
                    for (const el of cands) {
                        const text = (el.textContent || '').trim();
                        if (text === '입찰 내역 관리') {
                            el.click();
                            return text;
                        }
                    }
                    return null;
                }
            """)
            print(f"[SYNC-V2] 2차 클릭: {clicked2}")
        
        # 4. 페이지 로드 대기
        await page.wait_for_timeout(5000)
        
        # 데이터 행이 나타날 때까지 대기 (최대 15초)
        try:
            await page.wait_for_function("""
                () => {
                    const text = document.body.innerText;
                    return /A-SN\\d|A-AC\\d|입찰 순번/.test(text);
                }
            """, timeout=15000)
            print("[SYNC-V2] 데이터 감지됨")
        except:
            print("[SYNC-V2] 데이터 대기 timeout (계속 진행)")
        
        await page.wait_for_timeout(2000)
        print(f"[SYNC-V2] 최종 URL: {page.url}")
        
        # 5. 페이지네이션 — '10개씩 보기' → '50개씩 보기' 변경 시도
        try:
            await page.evaluate("""
                () => {
                    // select 박스 또는 dropdown 찾기
                    const selects = document.querySelectorAll('select');
                    for (const s of selects) {
                        const opts = Array.from(s.options || []);
                        const opt50 = opts.find(o => o.text.includes('50') || o.value === '50');
                        if (opt50) {
                            s.value = opt50.value;
                            s.dispatchEvent(new Event('change', { bubbles: true }));
                            return true;
                        }
                    }
                    return false;
                }
            """)
            await page.wait_for_timeout(2000)
        except: pass
        
        # 6. 데이터 추출 (모든 페이지 순회)
        all_rows = []
        page_num = 1
        max_pages = 10
        
        while page_num <= max_pages:
            print(f"[SYNC-V2] 페이지 {page_num} 추출 중...")
            
            # 행 데이터 추출 (텍스트 기반 파싱 — HTML 구조 변경에 강함)
            rows_data = await page.evaluate("""
                () => {
                    // 주문번호 패턴이 있는 모든 element 찾기
                    const orderPattern = /A-(SN|AC|BK)\\d{5,}/;
                    const allText = document.body.innerText;
                    const matches = [...allText.matchAll(/(A-(?:SN|AC|BK)\\d{5,})/g)];
                    const orderIds = [...new Set(matches.map(m => m[1]))];
                    
                    // 각 주문번호 주변 텍스트로 입찰 정보 추출
                    const rows = [];
                    for (const oid of orderIds) {
                        // 주문번호 포함하는 행 element 찾기
                        const xpath = `//*[contains(text(), "${oid}")]`;
                        const result = document.evaluate(xpath, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null);
                        const node = result.singleNodeValue;
                        if (!node) continue;
                        
                        // 가장 가까운 row element 추적
                        let rowEl = node;
                        let depth = 0;
                        while (rowEl && depth < 10) {
                            const txt = rowEl.innerText || '';
                            if (txt.includes('원') && (txt.match(/입찰 순번/) || txt.length > 100)) {
                                break;
                            }
                            rowEl = rowEl.parentElement;
                            depth++;
                        }
                        if (!rowEl) continue;
                        
                        const rowText = rowEl.innerText || '';
                        
                        // 모델번호 (예: 1183B938-100, JQ4110, IX7693)
                        const modelMatch = rowText.match(/([A-Z0-9]{4,}[-]?[A-Z0-9]*)\\s*\\(\\d+\\)/) 
                                          || rowText.match(/^([A-Z]{2,}[0-9]+)/m);
                        const model = modelMatch ? modelMatch[1] : '';
                        
                        // 사이즈 (예: 260, 245, ONE SIZE, W215)
                        const sizeMatch = rowText.match(/\\b(W?\\d{2,3}(?:\\.\\d)?|ONE SIZE)\\b/);
                        const size = sizeMatch ? sizeMatch[1] : '';
                        
                        // 판매희망가 (입찰가)
                        const priceMatches = [...rowText.matchAll(/([\\d,]+)\\s*원/g)];
                        const prices = priceMatches.map(m => parseInt(m[1].replace(/,/g, '')));
                        const myPrice = prices.find(p => p > 10000 && p < 10000000) || 0;
                        
                        // 입찰 순번
                        const rankMatch = rowText.match(/입찰 순번\\s*(\\d+)/);
                        const rank = rankMatch ? parseInt(rankMatch[1]) : null;
                        
                        // 상품명
                        const nameMatch = rowText.match(/Onitsuka|New Balance|Mizuno|Adidas|Nike|[가-힣]{3,}/);
                        const nameKr = nameMatch ? nameMatch[0] : '';
                        
                        rows.push({
                            orderId: oid,
                            model: model,
                            size: size,
                            bidPrice: myPrice,
                            bidRank: rank,
                            nameKr: nameKr,
                            rawText: rowText.substring(0, 300)
                        });
                    }
                    return rows;
                }
            """)
            
            print(f"[SYNC-V2] 페이지 {page_num}: {len(rows_data)}건 추출")
            all_rows.extend(rows_data)
            
            # 다음 페이지 클릭
            has_next = await page.evaluate("""
                () => {
                    // 페이지네이션 버튼 (다음 페이지 또는 ›)
                    const buttons = Array.from(document.querySelectorAll('button, a, [role="button"]'));
                    for (const b of buttons) {
                        const text = (b.textContent || '').trim();
                        const aria = b.getAttribute('aria-label') || '';
                        if ((text === '›' || text === '>' || aria.includes('다음') || aria.includes('Next'))
                            && !b.disabled && !b.getAttribute('aria-disabled')) {
                            b.click();
                            return true;
                        }
                    }
                    return false;
                }
            """)
            
            if not has_next:
                print(f"[SYNC-V2] 마지막 페이지 도달")
                break
            
            await page.wait_for_timeout(2500)
            page_num += 1
        
        # 중복 제거
        seen = set()
        unique_rows = []
        for r in all_rows:
            key = r.get('orderId')
            if key and key not in seen:
                seen.add(key)
                unique_rows.append(r)
        
        bids = unique_rows
        print(f"[SYNC-V2] 총 {len(bids)}건 (중복 제거 후)")
        
        await browser.close()
    
    return bids
'''
    text = text.rstrip() + NEW_FUNC + '\n'
    p.write_text(text, encoding='utf-8')
    print("  ✅ collect_my_bids_via_menu 추가됨")

# kream_server.py에서 sync 라우트가 새 함수 사용하도록 변경
ks = Path('kream_server.py')
ks_text = ks.read_text(encoding='utf-8')

if 'collect_my_bids_via_menu' in ks_text:
    print("  ✅ server.py 이미 v2 사용 중")
else:
    # from kream_adjuster import collect_my_bids 라인을 v2로 교체
    old_import = "from kream_adjuster import collect_my_bids\n            bids = loop.run_until_complete(collect_my_bids(headless=get_headless()))"
    new_import = "from kream_adjuster import collect_my_bids_via_menu\n            bids = loop.run_until_complete(collect_my_bids_via_menu(headless=get_headless()))"
    
    if old_import in ks_text:
        ks_text = ks_text.replace(old_import, new_import, 1)
        ks.write_text(ks_text, encoding='utf-8')
        print("  ✅ server.py sync 라우트가 v2 사용하도록 변경")
    else:
        print("  ⚠️ server.py 패치 패턴 못 찾음 — 수동 점검 필요")
PYEOF
echo ""

# 문법 검증
echo "  🔍 문법 검증..."
python3 -m py_compile kream_adjuster.py && echo "  ✅ kream_adjuster.py" || fail_and_restore "kream_adjuster 문법"
python3 -m py_compile kream_server.py && echo "  ✅ kream_server.py" || fail_and_restore "kream_server 문법"
echo ""

# ==========================================
# [STAGE 3] 신규 입찰 도구 (간단한 일괄 입찰 검산기)
# ==========================================
echo "════════════════════ [STAGE 3] 신규 입찰 도구 추가 ════════════════════"

# kream_server.py에 일괄 검산 라우트 추가
python3 <<'PYEOF'
"""신규 입찰 일괄 마진 검산 라우트 추가."""
from pathlib import Path

ks = Path('kream_server.py')
text = ks.read_text(encoding='utf-8')

if '/api/new-bid/calc-batch' in text:
    print("  ✅ /api/new-bid/calc-batch 이미 존재 — 스킵")
else:
    NEW_ROUTE = '''


@app.route('/api/new-bid/calc-batch', methods=['POST'])
def api_new_bid_calc_batch():
    """신규 입찰 일괄 마진 계산. 모델/사이즈/판매가/CNY 리스트 받아서 마진 계산.
    
    입력: {"items": [{"model": "JQ4110", "size": "215", "sale_price": 130000, "cny": 350}, ...]}
    출력: 각 항목별 원가/정산액/마진/추천(GO/SKIP)
    """
    try:
        data = request.get_json() or {}
        items = data.get('items', [])
        
        if not items:
            return jsonify({'ok': False, 'error': 'items required'}), 400
        
        try:
            settings = json.loads(Path(__file__).parent.joinpath('settings.json').read_text(encoding='utf-8'))
        except:
            settings = {}
        fee_rate = settings.get('commission_rate', 6) / 100
        fixed_fee = 2500
        min_margin = settings.get('min_margin', 4000)
        overseas_ship = settings.get('overseas_shipping', 8000)
        undercut = settings.get('undercut_amount', 1000)
        
        # 환율
        try:
            fx_resp = requests.get('http://localhost:5001/api/exchange-rate', timeout=5)
            fx = fx_resp.json().get('rate', 216)
        except:
            fx = settings.get('exchange_rate_cny', 216)
        
        results = []
        import math
        
        for item in items:
            model = item.get('model', '')
            size = item.get('size', '')
            sale_price = float(item.get('sale_price', 0))
            cny = float(item.get('cny', 0))
            
            if not model or not cny or sale_price <= 0:
                results.append({
                    **item,
                    'status': 'INVALID',
                    'reason': '모델/CNY/판매가 누락'
                })
                continue
            
            # 입찰가 = 판매가 - 언더컷, 1000원 단위 올림
            bid_price = math.ceil((sale_price - undercut) / 1000) * 1000
            
            # 원가
            cost = cny * fx * 1.03 + overseas_ship
            
            # 정산
            settlement = bid_price * (1 - fee_rate * 1.1) - fixed_fee
            margin = settlement - cost
            
            status = 'GO' if margin >= min_margin else ('LOW' if margin >= 0 else 'DEFICIT')
            
            results.append({
                **item,
                'fx': round(fx, 2),
                'bid_price': bid_price,
                'cost': round(cost),
                'settlement': round(settlement),
                'margin': round(margin),
                'margin_pct': round((margin/bid_price*100) if bid_price else 0, 1),
                'status': status,
                'reason': '마진 OK' if status == 'GO' else f'{margin_status_msg(status, margin, min_margin)}'
            })
        
        # 통계
        go_count = sum(1 for r in results if r.get('status') == 'GO')
        low_count = sum(1 for r in results if r.get('status') == 'LOW')
        deficit_count = sum(1 for r in results if r.get('status') == 'DEFICIT')
        
        return jsonify({
            'ok': True,
            'total': len(results),
            'go': go_count,
            'low': low_count,
            'deficit': deficit_count,
            'invalid': sum(1 for r in results if r.get('status') == 'INVALID'),
            'items': results,
            'settings_used': {
                'fx': round(fx, 2),
                'fee_rate': fee_rate,
                'min_margin': min_margin,
                'overseas_ship': overseas_ship,
                'undercut': undercut,
            }
        })
    except Exception as e:
        import traceback
        return jsonify({'ok': False, 'error': str(e), 'trace': traceback.format_exc()}), 500


def margin_status_msg(status, margin, min_margin):
    if status == 'LOW':
        return f'마진 {round(margin):,}원 < {min_margin:,} (조정 또는 단가 협상 필요)'
    if status == 'DEFICIT':
        return f'적자 {round(margin):,}원 (입찰 불가)'
    return ''
'''
    
    # 끝에 추가
    text = text.rstrip() + NEW_ROUTE + '\n'
    ks.write_text(text, encoding='utf-8')
    print("  ✅ /api/new-bid/calc-batch 추가됨")
PYEOF

python3 -m py_compile kream_server.py && echo "  ✅ 문법 OK" || fail_and_restore "신규 라우트 문법"
echo ""

# ==========================================
# [STAGE 4] 서버 재시작 + sync 실행
# ==========================================
echo "════════════════════ [STAGE 4] 서버 재시작 + sync 검증 ════════════════════"

lsof -ti:5001 | xargs kill -9 2>/dev/null || true
sleep 2
nohup python3 kream_server.py > server.log 2>&1 & disown
sleep 8
verify_server || fail_and_restore "재시작 실패"
echo ""

echo "  🔄 sync 실행 (메뉴 클릭 방식, 시간 좀 걸림)..."
SYNC_RAW=$(curl -s -X POST http://localhost:5001/api/my-bids/sync)
SYNC_TASK=$(echo "$SYNC_RAW" | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('taskId',''))
except: print('')
" 2>/dev/null)

if [ -n "$SYNC_TASK" ]; then
    echo "    task: $SYNC_TASK"
    for i in {1..80}; do  # 4분
        sleep 3
        STATUS_RAW=$(curl -s "http://localhost:5001/api/task/$SYNC_TASK")
        STATUS=$(echo "$STATUS_RAW" | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('status',''))
except: print('')
" 2>/dev/null)
        echo "    [$i/80] $STATUS"
        if [ "$STATUS" == "done" ] || [ "$STATUS" == "completed" ] || [ "$STATUS" == "success" ]; then
            echo ""
            echo "    📋 task 결과:"
            echo "$STATUS_RAW" | python3 -m json.tool 2>/dev/null | head -30
            break
        fi
        [ "$STATUS" == "failed" ] || [ "$STATUS" == "error" ] && echo "    ❌ 실패" && break
    done
fi

sleep 3
NEW_BIDS=$(curl -s http://localhost:5001/api/my-bids/local | python3 -c "
import sys,json
try: print(len(json.load(sys.stdin).get('bids',[])))
except: print('ERROR')
" 2>/dev/null)
echo ""
echo "  📊 sync 후 입찰: ${NEW_BIDS}건"
echo ""

# [SYNC-V2] 로그
echo "  📜 [SYNC-V2] 로그 (마지막 30줄):"
tail -300 server.log 2>/dev/null | grep "\[SYNC-V2\]" | tail -30 || echo "    (로그 없음 — print가 stderr로 갔을 수 있음)"
echo ""

# 입찰 샘플 (정상이면)
if [ "${NEW_BIDS:-0}" -gt 0 ]; then
    echo "  📋 입찰 샘플 (3건):"
    curl -s http://localhost:5001/api/my-bids/local | python3 -c "
import sys,json
d = json.load(sys.stdin)
for b in d.get('bids', [])[:3]:
    print(f\"    {b.get('orderId'):<20} {b.get('model'):<15} {b.get('size'):<10} {b.get('price'):>8}원 rank={b.get('rank','-')}\")
" 2>/dev/null
fi
echo ""

# ==========================================
# [STAGE 5] 신규 입찰 도구 검증
# ==========================================
echo "════════════════════ [STAGE 5] 신규 입찰 도구 검증 ════════════════════"

# 샘플 호출
CALC_RESULT=$(curl -s -X POST http://localhost:5001/api/new-bid/calc-batch \
  -H 'Content-Type: application/json' \
  -d '{"items":[
    {"model":"TEST1","size":"260","sale_price":150000,"cny":350},
    {"model":"TEST2","size":"245","sale_price":80000,"cny":300},
    {"model":"TEST3","size":"230","sale_price":100000,"cny":600}
  ]}')

echo "  📊 신규 입찰 마진 계산 테스트:"
echo "$CALC_RESULT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(f\"    총 {d.get('total')}건 / GO {d.get('go')} / LOW {d.get('low')} / DEFICIT {d.get('deficit')}\")
    for it in d.get('items', []):
        print(f\"    {it.get('model'):<10} {it.get('size'):<6} 입찰가={it.get('bid_price','?'):>7} 마진={it.get('margin','?')} [{it.get('status')}]\")
except Exception as e: print(f'ERROR: {e}')
" 2>/dev/null
echo ""

# ==========================================
# [STAGE 6] 커밋
# ==========================================
echo "════════════════════ [STAGE 6] 커밋 ════════════════════"

git add kream_adjuster.py kream_server.py 2>/dev/null
git commit -m "feat(Step 30): sync 메뉴 클릭 방식 복구 + 신규 입찰 마진 계산기

- collect_my_bids_via_menu(): 메인 → '통합 입찰 관리' → '입찰 내역 관리' 메뉴 클릭
- 텍스트 기반 행 추출 (주문번호 패턴 + 주변 텍스트 파싱)
- 페이지네이션 자동 순회 (최대 10페이지)
- /api/new-bid/calc-batch: 일괄 마진 검산 (GO/LOW/DEFICIT)

배경: 사장 스크린샷으로 정확한 메뉴 경로 + 60+건 입찰 확인.
직접 URL 진입 안 됨 (SPA 라우트), 메뉴 클릭만 가능.

결과: ${NEW_BIDS:-?}건 sync" 2>/dev/null || echo "  (커밋 변경 없음)"
git push origin main 2>/dev/null || echo "  (push 스킵)"

FINAL_HASH=$(git log -1 --format=%h)
echo "  ✅ 커밋: $FINAL_HASH"
echo ""

# ==========================================
# 컨텍스트 v24
# ==========================================
PA_PENDING=$(sqlite3 price_history.db "SELECT COUNT(*) FROM price_adjustments WHERE status='pending'" 2>/dev/null || echo "?")

cat > "다음세션_시작_컨텍스트_v24.md" <<MDEOF
# 다음 세션 시작 컨텍스트 v24

> 작성일: $(date '+%Y-%m-%d %H:%M:%S')
> 직전 커밋: $(git log -1 --format='%h %s')

## Step 30 결과

- **sync 복구**: ${NEW_BIDS:-?}건 (스크린샷에서 본 60+건과 비교)
- **신규 입찰 도구**: /api/new-bid/calc-batch (일괄 마진 검산)

## 핵심 변경

1. \`collect_my_bids_via_menu()\` 신설 — 메인 → 통합 입찰 관리 → 입찰 내역 관리 메뉴 클릭
2. 텍스트 기반 데이터 추출 (HTML 셀렉터 의존 ↓)
3. /api/my-bids/sync가 v2 함수 호출하도록 변경

## 다음 작업

$([ "${NEW_BIDS:-0}" -gt 30 ] && echo "### sync 복구 성공 — 본격 비즈니스 작업
- 모든 누적 도구가 의미 있게 작동
- 자본 추적, 정리 도구, 포트폴리오 등 진짜 활용 가능
- 자동조정 dry_run 검토 가능" || echo "### sync 부분 성공 또는 0건
- ${NEW_BIDS:-?}건만 잡혔으면 페이지네이션 디버깅 필요
- 0건이면 메뉴 클릭이 실제로 안 일어났을 가능성")

## 다음 채팅 첫 메시지

\`\`\`
다음세션_시작_컨텍스트_v24.md 읽고 현재 상태.

직전 커밋 $FINAL_HASH (Step 30).
sync 결과: ${NEW_BIDS:-?}건

오늘 작업: [구체 지시]
\`\`\`

## 절대 규칙

7대 규칙 + 자동 토글 ON 금지.
MDEOF

git add 다음세션_시작_컨텍스트_v24.md pipeline_step30.log 2>/dev/null
git commit -m "docs: 다음세션 컨텍스트 v24 (Step 30)" 2>/dev/null || true
git push origin main 2>/dev/null || true

PIPELINE_END=$(date +%s)
ELAPSED=$((PIPELINE_END - PIPELINE_START))

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🎉 Step 30 완료 — ${ELAPSED}초"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "결과:"
echo "  📊 sync: ${NEW_BIDS:-?}건"
echo "  💰 신규 입찰 계산기: /api/new-bid/calc-batch"
echo ""
echo "📜 로그: pipeline_step30.log"
echo ""
