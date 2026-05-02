#!/bin/bash
# Step 27 — 진짜 sync URL = /business/asks 패치
#
# Step 26 진단으로 확정:
#   - kream_server.py:4904 → kream_adjuster.collect_my_bids() 호출
#   - kream_adjuster.py docstring: "partner.kream.co.kr/business/asks"
#   - debug_asks.py도 동일 URL 사용
#
# 즉 정확한 URL은 /business/asks (Step 25의 ask-sales는 메뉴 라벨일뿐)

set -e
exec > >(tee -a pipeline_step27.log) 2>&1
cd ~/Desktop/kream_automation

PIPELINE_START=$(date +%s)
TS=$(date '+%Y%m%d_%H%M%S')

echo "================================================================"
echo "🚀 Step 27 Pipeline — $(date '+%Y-%m-%d %H:%M:%S')"
echo "   /business/asks 정확한 URL 패치 + 진단 재실행"
echo "================================================================"
echo ""

fail_and_restore() {
    echo ""
    echo "❌ [$1] FAIL — 백업 복원"
    [ -f "kream_adjuster.py.step27_pre.bak" ] && cp "kream_adjuster.py.step27_pre.bak" kream_adjuster.py
    
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

# 현재 BID_URLS_FALLBACK 보기
echo "  🔍 현재 BID_URLS_FALLBACK 내용:"
sed -n '90,115p' kream_adjuster.py | head -30
echo ""

# ==========================================
# [STAGE 1] 백업
# ==========================================
echo "════════════════════ [STAGE 1] 백업 ════════════════════"
cp kream_adjuster.py "kream_adjuster.py.step27_pre.bak"
echo "  ✅ 백업 완료"
echo ""

# ==========================================
# [STAGE 2] /business/asks를 BID_URLS_FALLBACK 맨 앞에 추가 (직접 패치)
# ==========================================
echo "════════════════════ [STAGE 2] URL 패치 (Claude Code 안 씀, 직접) ════════════════════"

python3 <<'PYEOF'
"""kream_adjuster.py의 BID_URLS_FALLBACK 맨 앞에 /business/asks 추가."""
import re
from pathlib import Path

p = Path('kream_adjuster.py')
text = p.read_text(encoding='utf-8')

# 이미 /business/asks 가 있으면 스킵
if "/business/asks\"" in text or "'/business/asks'" in text:
    # ask-sales가 아닌 asks (s 끝남)만 체크
    # ask-sales는 있어도 됨, 다만 asks가 첫 번째여야 함
    if "f\"{PARTNER_URL}/business/asks\"" in text and \
       text.find("f\"{PARTNER_URL}/business/asks\"") < text.find("f\"{PARTNER_URL}/business/ask-sales\""):
        print("  ✅ /business/asks 이미 첫 번째에 있음 — 스킵")
    else:
        # ask-sales 앞에 asks 삽입
        old = '''        BID_URLS_FALLBACK = [
            f"{PARTNER_URL}/business/ask-sales"'''
        new = '''        BID_URLS_FALLBACK = [
            f"{PARTNER_URL}/business/asks",                                          # PRIMARY: 실제 데이터 URL (kream_adjuster docstring 명시)
            f"{PARTNER_URL}/business/ask-sales"'''
        if old in text:
            text = text.replace(old, new, 1)
            p.write_text(text, encoding='utf-8')
            print("  ✅ /business/asks 추가됨 (ask-sales 앞에)")
        else:
            print("  ⚠️ ask-sales 라인 못 찾음 — 수동 점검 필요")
else:
    # asks 자체가 없음 → 맨 앞에 추가 시도
    old = "BID_URLS_FALLBACK = ["
    new = """BID_URLS_FALLBACK = [
            f"{PARTNER_URL}/business/asks","""
    # 첫 매치만 변경
    idx = text.find(old)
    if idx > 0:
        text = text[:idx] + new + text[idx + len(old):]
        p.write_text(text, encoding='utf-8')
        print("  ✅ /business/asks 추가됨 (맨 앞)")
    else:
        print("  ⚠️ BID_URLS_FALLBACK 정의 못 찾음")
PYEOF

echo ""
echo "  📋 패치 후 BID_URLS_FALLBACK:"
sed -n '90,115p' kream_adjuster.py | head -30
echo ""

# 문법 검증
echo "  🔍 문법 검증..."
python3 -m py_compile kream_adjuster.py && echo "  ✅ kream_adjuster.py 문법 OK" || fail_and_restore "문법 오류"
echo ""

# ==========================================
# [STAGE 3] 서버 재시작 + sync 실행
# ==========================================
echo "════════════════════ [STAGE 3] 서버 재시작 + sync 실행 ════════════════════"

lsof -ti:5001 | xargs kill -9 2>/dev/null || true
sleep 2
nohup python3 kream_server.py > server.log 2>&1 & disown
sleep 8
verify_server || fail_and_restore "재시작 실패"

echo ""
echo "  🔄 sync 실행..."
SYNC_RAW=$(curl -s -X POST http://localhost:5001/api/my-bids/sync)
SYNC_TASK=$(echo "$SYNC_RAW" | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('taskId',''))
except: print('')
" 2>/dev/null)

if [ -n "$SYNC_TASK" ]; then
    echo "    task: $SYNC_TASK"
    for i in {1..50}; do
        sleep 3
        STATUS_RAW=$(curl -s "http://localhost:5001/api/task/$SYNC_TASK")
        STATUS=$(echo "$STATUS_RAW" | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('status',''))
except: print('')
" 2>/dev/null)
        echo "    [$i/50] $STATUS"
        if [ "$STATUS" == "done" ] || [ "$STATUS" == "completed" ] || [ "$STATUS" == "success" ]; then
            echo ""
            echo "    📋 task 결과:"
            echo "$STATUS_RAW" | python3 -m json.tool 2>/dev/null | head -25
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

# [SYNC] 로그
echo "  📜 [SYNC] 로그:"
tail -300 server.log 2>/dev/null | grep -E "\[SYNC\]" | tail -10 || echo "    (로그 없음 — collect_my_bids 함수 안의 print만 있을 수 있음)"
echo ""

# ==========================================
# [STAGE 4] ask-sales 페이지 진단 (Step 26 버그 수정 — 작업 디렉토리에서 실행)
# ==========================================
echo "════════════════════ [STAGE 4] /business/asks 페이지 진단 ════════════════════"

# /tmp가 아닌 작업 폴더에 임시 스크립트 (sys.path 문제 회피)
cat > _step27_diagnose.py <<'PYEOF'
"""/business/asks 페이지 직접 접속 진단."""
import asyncio
import json
import sys
from pathlib import Path
from datetime import datetime

# 현재 작업 디렉토리 sys.path에 추가
sys.path.insert(0, str(Path(__file__).resolve().parent))

async def main():
    from playwright.async_api import async_playwright
    from kream_bot import create_browser, create_context, ensure_logged_in, dismiss_popups
    
    async with async_playwright() as p:
        browser = await create_browser(p, headless=True)
        context = await create_context(browser, storage='auth_state.json')
        page = await context.new_page()
        
        urls_to_test = [
            'https://partner.kream.co.kr/business/asks',
            'https://partner.kream.co.kr/business/asks?page=1&perPage=50',
        ]
        
        results = []
        for url in urls_to_test:
            print(f"\n>>> goto {url}")
            try:
                await page.goto(url, wait_until='domcontentloaded', timeout=30000)
                await page.wait_for_timeout(5000)
                
                # 동적 로딩 대기 — 추가
                try:
                    await page.wait_for_selector('table, [class*="row"], [class*="item"]', timeout=10000)
                except: 
                    pass
                
                logged_in = await ensure_logged_in(page, context)
                try: await dismiss_popups(page)
                except: pass
                await page.wait_for_timeout(2000)
                
                final_url = page.url
                title = await page.title()
                
                # 셀렉터 매칭
                selectors = {}
                for sel in ['table tbody tr', 'div[class*="row"]', 'div[class*="ask"]', 
                           '[role="row"]', 'div[class*="item"]', 'li']:
                    try:
                        els = await page.query_selector_all(sel)
                        selectors[sel] = len(els)
                    except: selectors[sel] = -1
                
                # 가장 많이 잡히는 셀렉터
                best = sorted([(k,v) for k,v in selectors.items() if v >= 3], key=lambda x: -x[1])[:3]
                
                print(f"  logged_in: {logged_in}")
                print(f"  final_url: {final_url}")
                print(f"  title: {title}")
                print(f"  셀렉터 결과: {selectors}")
                if best:
                    print(f"  유망 셀렉터: {best}")
                
                # body 텍스트 일부
                body_preview = await page.evaluate("() => document.body.innerText.substring(0, 500)")
                print(f"  body preview: {repr(body_preview[:300])}")
                
                # 스크린샷
                ts = datetime.now().strftime('%Y%m%d_%H%M%S')
                slug = url.split('/')[-1].split('?')[0] or 'asks'
                dump_dir = Path('diagnostics')
                dump_dir.mkdir(exist_ok=True)
                png = dump_dir / f'asks_{slug}_{ts}.png'
                await page.screenshot(path=str(png), full_page=True)
                print(f"  스크린샷: {png}")
                
                results.append({
                    'url': url,
                    'final_url': final_url,
                    'logged_in': logged_in,
                    'title': title,
                    'selectors': selectors,
                    'best': best,
                    'screenshot': str(png),
                    'body_preview': body_preview[:300],
                })
            except Exception as e:
                print(f"  ERROR: {e}")
                results.append({'url': url, 'error': str(e)})
        
        await browser.close()
        
        # JSON 저장
        with open('asks_diagnosis_result.json', 'w', encoding='utf-8') as f:
            json.dump(results, f, ensure_ascii=False, indent=2, default=str)
        print(f"\n>>> 진단 결과 저장: asks_diagnosis_result.json")

asyncio.run(main())
PYEOF

echo "  🚀 /business/asks 페이지 직접 검증..."
python3 _step27_diagnose.py 2>&1 | tail -60 || echo "  진단 실패"

echo ""
echo "  📂 저장된 스크린샷:"
ls -lt diagnostics/asks_*.png 2>/dev/null | head -3 | awk '{print "    " $NF}'
echo ""

# 진단 JSON 정보 추출
if [ -f asks_diagnosis_result.json ]; then
    DIAG_SUMMARY=$(python3 -c "
import json
try:
    with open('asks_diagnosis_result.json') as f:
        results = json.load(f)
    for r in results:
        if 'error' in r:
            print(f\"  {r['url']}: ERROR\")
        else:
            best = r.get('best', [])
            best_str = best[0] if best else 'none'
            print(f\"  {r['url'].split('/')[-1]}: logged={r.get('logged_in')} best={best_str}\")
except: print('  진단 파일 읽기 실패')
" 2>/dev/null)
    echo "  📊 진단 요약:"
    echo "$DIAG_SUMMARY"
fi

# 정리
rm -f _step27_diagnose.py 2>/dev/null

# ==========================================
# [STAGE 5] 커밋 + 컨텍스트
# ==========================================
echo ""
echo "════════════════════ [STAGE 5] 커밋 ════════════════════"

if [ "${NEW_BIDS:-0}" -gt 0 ]; then
    SUMMARY="✅ 복구 성공 — ${NEW_BIDS}건 sync"
    git add kream_adjuster.py 2>/dev/null
    git commit -m "fix(Step 27): sync URL 정확한 패치 (/business/asks)

Step 26 진단으로 확정:
- kream_adjuster docstring: 'partner.kream.co.kr/business/asks'
- Step 25에서 추가한 ask-sales는 메뉴 라벨, 실제 데이터 URL 아님
- /business/asks를 BID_URLS_FALLBACK 맨 앞에 추가

결과: sync ${NEW_BIDS}건 복원됨" 2>/dev/null || echo "  (커밋 변경 없음)"
    git push origin main 2>/dev/null || echo "  (push 스킵)"
else
    SUMMARY="⚠️ 여전히 0건 — 진단 결과 확인 필요"
    git add kream_adjuster.py asks_diagnosis_result.json 2>/dev/null
    git commit -m "diag(Step 27): /business/asks 진단 + URL 추가 (여전히 0건)" 2>/dev/null || echo "  (변경 없음)"
    git push origin main 2>/dev/null || echo "  (push 스킵)"
fi

FINAL_HASH=$(git log -1 --format=%h)
echo "  ✅ 커밋: $FINAL_HASH"
echo ""

PA_PENDING=$(sqlite3 price_history.db "SELECT COUNT(*) FROM price_adjustments WHERE status='pending'" 2>/dev/null || echo "?")

cat > "다음세션_시작_컨텍스트_v21.md" <<MDEOF
# 다음 세션 시작 컨텍스트 v21

> 작성일: $(date '+%Y-%m-%d %H:%M:%S') (자동 생성)
> 직전 커밋: $(git log -1 --format='%h %s')

## 1. Step 27 결과

- $SUMMARY
- 정확한 URL 발견: \`/business/asks\` (Step 26 진단으로 확정)
- 추가된 진단 파일: asks_diagnosis_result.json + diagnostics/asks_*.png

## 2. sync 결과

- 입찰 수: ${NEW_BIDS:-?}건
- 진단 요약:
$DIAG_SUMMARY

## 3. 누적 (Step 18~27)

| Step | 커밋 |
|---|---|
| 26 (진단) | (no commit) |
| **27 (URL 패치)** | **$FINAL_HASH** |

## 4. 다음 작업

$([ "${NEW_BIDS:-0}" -gt 0 ] && echo "### 정상 복구 — 본격 비즈니스 가치 작업
- 모든 누적 도구가 의미 있게 동작
- 회수/조정/포트폴리오 등 실제 활용
- 자동조정 dry_run 검토" || echo "### 진단 결과 직접 확인 필요
1. open ~/Desktop/kream_automation/diagnostics/asks_*.png
2. 페이지에 입찰 보이는지/빈 페이지인지/리다이렉트인지 확인
3. asks_diagnosis_result.json 셀렉터 결과로 진짜 셀렉터 패치 가능")

## 5. 다음 채팅 첫 메시지

\`\`\`
다음세션_시작_컨텍스트_v21.md 읽고 현재 상태 파악.

스크린샷 결과: [입찰 N건 보임 / 빈 페이지 / 다른 결과]

오늘 작업: [기획 / 구체 지시]
\`\`\`

## 6. 절대 규칙

7대 규칙 + 자동 토글 ON 금지.
MDEOF

git add 다음세션_시작_컨텍스트_v21.md pipeline_step27.log 2>/dev/null
git commit -m "docs: 다음세션 컨텍스트 v21 (Step 27)" 2>/dev/null || echo "  (변경 없음)"
git push origin main 2>/dev/null || echo "  (push 스킵)"

PIPELINE_END=$(date +%s)
ELAPSED=$((PIPELINE_END - PIPELINE_START))

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🎉 Step 27 완료 — ${ELAPSED}초"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "결과: $SUMMARY"
echo ""
echo "📋 진단 파일:"
echo "  open ~/Desktop/kream_automation/diagnostics/"
echo "  cat asks_diagnosis_result.json"
echo ""
echo "📜 로그: pipeline_step27.log"
echo ""
