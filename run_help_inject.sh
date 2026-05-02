#!/bin/bash
# 대시보드 In-App 도움말 자동 주입 파이프라인
# 사용법: bash run_help_inject.sh
# 작성: 2026-05-02
#
# 동작:
#   1. help_content.json (12개 탭 도움말 콘텐츠) 프로젝트에 복사
#   2. Claude Code 자동 호출 — 각 탭 HTML에 ❓ 버튼 + 모달 주입
#   3. 검증 → 실패 시 백업 자동 복원
#   4. PASS 시 커밋 + push
#
# 사용자 개입: 시작 시 0번. 끝나면 대시보드에서 ❓ 클릭 확인.

set -e
exec > >(tee -a pipeline_help.log) 2>&1

cd ~/Desktop/kream_automation

PIPELINE_START=$(date +%s)
TS=$(date '+%Y%m%d_%H%M%S')

echo "================================================================"
echo "🚀 도움말 주입 Pipeline — $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================"
echo ""

# ==========================================
# 공통 함수
# ==========================================
fail_and_restore() {
    local stage=$1
    echo ""
    echo "❌ [$stage] FAIL — 백업 복원"
    [ -f "kream_dashboard.html.help_pre.bak" ] && cp "kream_dashboard.html.help_pre.bak" kream_dashboard.html
    for f in tabs/*.help_pre.bak; do
        [ -f "$f" ] && cp "$f" "${f%.help_pre.bak}"
    done
    
    echo "🔄 서버 재시작..."
    lsof -ti:5001 | xargs kill -9 2>/dev/null || true
    sleep 2
    nohup python3 kream_server.py > server.log 2>&1 & disown
    sleep 5
    
    echo "❌ Pipeline 중단"
    exit 1
}

verify_server() {
    sleep 3
    local code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:5001/api/health)
    [ "$code" == "200" ] && echo "✅ 서버 정상" && return 0
    echo "❌ 서버 응답 없음 (HTTP $code)" && return 1
}

# ==========================================
# [STAGE 0] 사전 점검
# ==========================================
echo "════════════════════ [STAGE 0] 사전 점검 ════════════════════"
verify_server || fail_and_restore "사전 점검"
echo "  현재 커밋: $(git log --oneline -1)"

# tabs 폴더 확인
if [ ! -d "tabs" ]; then
    echo "❌ tabs/ 디렉토리 없음"
    exit 1
fi
echo "  tabs/ 파일: $(ls tabs/*.html 2>/dev/null | wc -l)개"
echo ""

# ==========================================
# [STAGE 1] 백업
# ==========================================
echo "════════════════════ [STAGE 1] 백업 ════════════════════"
cp kream_dashboard.html "kream_dashboard.html.help_pre.bak"
for f in tabs/*.html; do
    cp "$f" "${f}.help_pre.bak"
done
echo "  ✅ 대시보드 + 12개 탭 백업"
echo ""

# ==========================================
# [STAGE 2] help_content.json 작성
# ==========================================
echo "════════════════════ [STAGE 2] 도움말 콘텐츠 작성 ════════════════════"

cat > help_content.json <<'JSONEOF'
{
  "register": {
    "icon": "📦",
    "title": "상품 등록/입찰",
    "what": "중국에서 소싱한 상품을 KREAM에 등록하고 판매 입찰하는 큐(대기열) 시스템",
    "why": "한 건씩 등록하면 시간이 너무 걸려서, 여러 상품을 큐에 쌓아놓고 한번에 KREAM 검색 + 마진 계산 + 자동 입찰까지 처리하기 위해 만들었음",
    "how": [
      "1. 모델번호 + CNY 가격 입력해서 큐에 추가 (또는 엑셀로 일괄 추가)",
      "2. '큐 실행' 누르면 KREAM에서 사이즈별 즉시구매가 자동 수집 + 마진 계산",
      "3. 마진 4,000원 이상 사이즈만 자동 선택됨",
      "4. '자동 입찰' 누르면 Playwright가 판매자센터 열고 고시정보 + 입찰 자동 등록",
      "5. 진행 상황은 실시간 로그로 확인"
    ],
    "warn": "CNY 원가 없이는 입찰 안 됨 (require_cny_on_bid=true). 큐에 쌓은 상품은 서버 재시작해도 유지됨 (queue_data.json)."
  },
  "margin": {
    "icon": "💰",
    "title": "마진 계산기",
    "what": "단일 상품의 예상 수익을 빠르게 시뮬레이션하는 도구",
    "why": "큐에 넣기 전에 '이 가격에 입찰하면 얼마 남지?'를 즉시 확인하기 위해. 환율 변동, 수수료 변동에 따른 시나리오 비교용",
    "how": [
      "1. CNY 원가 + 예상 판매가 입력",
      "2. 자동으로 정산액(수수료 차감) + 원가(환율 적용) + 순수익 계산",
      "3. 마진 < 10,000원이면 빨간색 경고 표시"
    ],
    "warn": "관부가세는 고객 부담이라 원가 계산에서 제외됨. 해외배송비 8,000원은 기본값."
  },
  "bulk": {
    "icon": "📋",
    "title": "대량 등록",
    "what": "엑셀 파일로 한 번에 수십~수백 건 입찰을 KREAM에 업로드하는 기능",
    "why": "큐 시스템보다 더 빠르게 대규모 입찰을 일괄 처리하기 위해. 신상 출시 시점에 빠르게 시장 점유 목적",
    "how": [
      "1. 엑셀 양식 다운로드 (모델번호/사이즈/가격/수량 컬럼)",
      "2. 엑셀 채워서 업로드",
      "3. KREAM 대량입찰 양식으로 자동 변환",
      "4. 판매자센터에 자동 업로드"
    ],
    "warn": "대량 입찰은 bid_cost 자동 저장이 안 됨 → 입찰 후 '원가 일괄 입력' 모달로 CNY 따로 등록해야 자동 조정 동작함."
  },
  "discover": {
    "icon": "🔍",
    "title": "상품 발굴",
    "what": "수익성 좋은 신상품을 KREAM 인기 키워드 기반으로 자동 스캔",
    "why": "어떤 상품을 소싱할지 일일이 찾는 게 비효율적이라, 인기도 + 거래량 + 마진 가능성을 점수화해서 후보 추천하기 위해",
    "how": [
      "1. '자동 스캔' 누르면 인기 키워드별 상품 수집",
      "2. 점수 계산 (거래량 + 가격대 + 카테고리 가중치)",
      "3. 상위 후보를 엑셀로 다운로드 → 검토 후 큐에 추가",
      "4. 또는 직접 엑셀 업로드해서 발굴 데이터 갱신"
    ],
    "warn": "kream.co.kr 접속 가능한 환경에서만 동작 (해외 맥북에서는 차단됨)."
  },
  "adjust": {
    "icon": "🎯",
    "title": "가격 자동 조정",
    "what": "내 입찰이 경쟁자한테 밀렸을 때 자동으로 언더컷해서 1순위 회복",
    "why": "수동으로 매시간 순위 체크하는 게 불가능해서, 6중 안전장치(원가/마진/쿨다운/한도/실패율/스테일체크) 두고 자동 방어 시스템 만들었음",
    "how": [
      "1. '스캔' 누르면 내 입찰 + 시장 분석 → 조정 후보 리스트 생성",
      "2. 마진 4,000원 이상 + 원가 등록된 건만 후보에 올라옴",
      "3. 수동: 후보 골라서 '승인' → 자동 실행",
      "4. 자동: '자동 조정 ON' 토글 → 모니터링 직후 자동 실행 (기본 OFF)",
      "5. 이력 탭에서 모든 실행 결과 확인 (성공/스킵/실패 사유 포함)"
    ],
    "warn": "자동 조정은 위험해서 기본 OFF. 켜기 전에 반드시 수동으로 며칠 돌려서 결과 검증할 것. 하루 한도 10건, 24시간 쿨다운, 실패율 20% 초과 시 자동 OFF."
  },
  "prices": {
    "icon": "📊",
    "title": "가격 수집",
    "what": "KREAM에서 모델번호/상품ID로 즉시구매가 + 사이즈별 가격 수집",
    "why": "마진 계산이나 시장 분석 전에 정확한 KREAM 가격을 알아야 해서. API 인터셉트 + DOM 스크래핑 + JSON-LD 3중 fallback 구조",
    "how": [
      "1. 모델번호 또는 상품ID 입력",
      "2. '수집' 누르면 Playwright가 KREAM 열고 가격 자동 추출",
      "3. 사이즈별 즉시구매가 + 최근 체결가 + 거래량 표시",
      "4. 결과는 kream_prices.json + DB에 저장"
    ],
    "warn": "kream.co.kr 차단 환경(해외)에서는 수집 실패. 즉시구매가 = 살아있는 판매입찰 최저가 (과거 체결가 아님)."
  },
  "mybids": {
    "icon": "📂",
    "title": "입찰 관리",
    "what": "현재 판매자센터에 등록된 모든 내 입찰 조회/수정/삭제",
    "why": "판매자센터 UI에서 일일이 찾기 힘드니까, 모델/사이즈/가격/순위 한눈에 보고 일괄 관리하기 위해",
    "how": [
      "1. '동기화' 누르면 판매자센터에서 최신 입찰 끌어옴",
      "2. 모델/사이즈/순위로 필터링",
      "3. 가격 수정 또는 삭제 (단건/일괄)",
      "4. 로컬 캐시(my_bids_local.json) 활용으로 빠른 조회"
    ],
    "warn": "삭제는 복구 불가. 판매 완료된 건은 절대 수정/삭제 금지 (CLAUDE.md 절대 규칙 #2)."
  },
  "sales": {
    "icon": "💵",
    "title": "판매 관리",
    "what": "체결된 판매 내역 + 통계 대시보드",
    "why": "어떤 모델이 잘 팔리는지, 주간/월간 매출 추이, 사이즈별 판매 빈도를 추적해서 다음 소싱 의사결정에 활용하기 위해",
    "how": [
      "1. '동기화' 누르면 판매자센터 발송관리에서 체결건 자동 수집",
      "2. 30분마다 자동 수집 (스케줄러 ON 상태)",
      "3. 모델별/일별 통계 + 검색",
      "4. '재입찰 추천'에서 최근 판매된 사이즈 자동 입찰 후보 확인"
    ],
    "warn": "최근 trade_date가 오래됐으면 수집 실패 가능성. 헬스체크 탭에서 스케줄러 상태 확인."
  },
  "history": {
    "icon": "📝",
    "title": "실행 이력",
    "what": "모든 자동 입찰/가격 조정/모니터링 실행 결과 로그",
    "why": "뭐가 언제 어떻게 실행됐는지 추적해야 문제 발생 시 원인 파악 가능. 자동화 시스템의 신뢰성 확보용",
    "how": [
      "1. 최근 30건 실행 이력 자동 표시",
      "2. 성공/실패 + 상세 로그 + 소요 시간",
      "3. 실패 건은 사유 클릭하면 상세 에러"
    ],
    "warn": "이력은 DB에 영구 저장됨. 너무 많아지면 batch_history.json 백업 후 정리 권장."
  },
  "pattern": {
    "icon": "📈",
    "title": "판매 패턴",
    "what": "판매 데이터를 시간대/요일/모델/사이즈별로 분석한 인사이트",
    "why": "언제 가장 많이 팔리는지, 어떤 사이즈가 회전 빠른지 알아야 입찰 전략(어느 시간에 가격 조정할지)에 반영 가능",
    "how": [
      "1. 자동으로 sales_history 분석 결과 차트 표시",
      "2. 시간대별 판매 분포",
      "3. 모델별 회전율",
      "4. 사이즈별 판매 빈도"
    ],
    "warn": "데이터 부족할 때(판매 < 50건)는 패턴이 부정확함. 충분히 쌓인 후 활용."
  },
  "logistics": {
    "icon": "🚚",
    "title": "물류 관리",
    "what": "허브넷(웨이하이 물류창고) 기반 발송 요청 + 협력사 관리",
    "why": "중국 셀러 → 허브넷 → KREAM 검수센터 흐름에서 어떤 상품이 어디에 있는지 추적하고, 협력사별 발송 비용 관리하기 위해",
    "how": [
      "1. '발송 요청' 생성 (주문번호 + 모델 + 협력사 선택)",
      "2. 허브넷 HBL 입력 → 추적번호 자동 연동",
      "3. 협력사 정보 등록 (위챗/연락처)",
      "4. 발송 비용 기록"
    ],
    "warn": "허브넷 인증 만료 시 자동 사전 갱신(12h 주기) 동작하지만 실패 시 상단 배너로 알림."
  },
  "settings": {
    "icon": "⚙️",
    "title": "환율/수수료 설정",
    "what": "환율, 수수료율, 자동화 토글, 마진 하한 등 시스템 핵심 파라미터 관리",
    "why": "환율은 매일 변하고, 수수료 프로모션도 자주 바뀌고, 자동화 위험도에 따라 토글 조정 필요해서 한곳에 모아둠",
    "how": [
      "1. 환율: 자동 조회 (open.er-api.com) 또는 수동 입력",
      "2. 수수료: 기본 6% (이벤트 시 3.5/5.5%)",
      "3. 언더컷: 기본 1,000원",
      "4. 마진 하한: 기본 4,000원",
      "5. 자동 토글: 입찰/조정/재입찰/정리/PDF/사전갱신 (대부분 OFF 권장)"
    ],
    "warn": "자동 토글 ON 변경은 위험. 반드시 수동 모드에서 며칠 검증 후 단계적 ON. require_cny_on_bid는 항상 ON 유지 권장 (가짜 원가 입력 방지)."
  }
}
JSONEOF

echo "  ✅ help_content.json 생성 (12개 탭)"
echo ""

# ==========================================
# [STAGE 3] 작업지시서 생성
# ==========================================
echo "════════════════════ [STAGE 3] 작업지시서 ════════════════════"

cat > "작업지시서_HELP_INJECT.md" <<'MDEOF'
# 작업지시서 — 대시보드 In-App 도움말 주입

> 작성: 자동 생성
> 목적: 각 탭에 ❓ 버튼 + 모달 도움말 추가. 사용자가 직접 검증 안 해도 시스템 이해 가능하게.

## 환경 제약
- 맥북(해외)에서 실행 중
- 절대 규칙 (CLAUDE.md) 모두 준수
- 자동 토글 ON 변경 금지 (현재 OFF 유지)

## 작업 #1: kream_server.py — 도움말 API 추가

기존 import 영역 아래(또는 적절한 위치)에 라우트 1개 추가:

```python
@app.route('/api/help/<tab_id>', methods=['GET'])
def api_help(tab_id):
    """탭별 In-App 도움말 콘텐츠 반환."""
    try:
        from pathlib import Path
        help_path = Path(__file__).parent / 'help_content.json'
        if not help_path.exists():
            return jsonify({'ok': False, 'error': 'help_content.json 없음'}), 404
        data = json.loads(help_path.read_text(encoding='utf-8'))
        if tab_id not in data:
            return jsonify({'ok': False, 'error': f'tab_id={tab_id} 없음'}), 404
        return jsonify({'ok': True, 'help': data[tab_id]})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500
```

기존 라우트 변경 금지. 추가만.

## 작업 #2: kream_dashboard.html — 공용 모달 + 헬퍼 함수 주입

`</body>` 직전에 모달 + JS 주입:

```html
<!-- ========== In-App Help Modal (auto-injected) ========== -->
<div id="help-modal" style="display:none; position:fixed; top:0; left:0; right:0; bottom:0; background:rgba(0,0,0,0.5); z-index:9999; align-items:center; justify-content:center;" onclick="if(event.target===this) closeHelpModal()">
  <div style="background:#fff; max-width:560px; width:90%; max-height:80vh; overflow-y:auto; border-radius:12px; padding:24px; box-shadow:0 20px 60px rgba(0,0,0,0.3);">
    <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:16px;">
      <h2 id="help-title" style="margin:0; font-size:20px; color:#111;"></h2>
      <button onclick="closeHelpModal()" style="background:none; border:none; font-size:24px; cursor:pointer; color:#666;">×</button>
    </div>
    <div style="color:#333; line-height:1.6; font-size:14px;">
      <div style="background:#f3f4f6; padding:12px; border-radius:8px; margin-bottom:12px;">
        <strong style="color:#0369a1;">📌 이 화면은</strong>
        <div id="help-what" style="margin-top:4px;"></div>
      </div>
      <div style="margin-bottom:12px;">
        <strong style="color:#7c3aed;">🎯 왜 만들었나</strong>
        <div id="help-why" style="margin-top:4px;"></div>
      </div>
      <div style="margin-bottom:12px;">
        <strong style="color:#059669;">⚙️ 사용법</strong>
        <ol id="help-how" style="margin-top:4px; padding-left:20px;"></ol>
      </div>
      <div id="help-warn-box" style="background:#fef3c7; border-left:3px solid #f59e0b; padding:10px 12px; border-radius:4px; display:none;">
        <strong style="color:#92400e;">⚠️ 주의</strong>
        <div id="help-warn" style="margin-top:4px; color:#78350f;"></div>
      </div>
    </div>
  </div>
</div>

<script>
async function showHelp(tabId) {
  try {
    const r = await fetch('/api/help/' + tabId);
    const d = await r.json();
    if (!d.ok) { alert('도움말 없음: ' + d.error); return; }
    const h = d.help;
    document.getElementById('help-title').textContent = (h.icon || '') + ' ' + h.title;
    document.getElementById('help-what').textContent = h.what || '';
    document.getElementById('help-why').textContent = h.why || '';
    const ol = document.getElementById('help-how');
    ol.innerHTML = (h.how || []).map(s => '<li style="margin-bottom:4px;">' + s.replace(/^\d+\.\s*/, '') + '</li>').join('');
    if (h.warn) {
      document.getElementById('help-warn').textContent = h.warn;
      document.getElementById('help-warn-box').style.display = 'block';
    } else {
      document.getElementById('help-warn-box').style.display = 'none';
    }
    const modal = document.getElementById('help-modal');
    modal.style.display = 'flex';
  } catch(e) {
    alert('도움말 로드 실패: ' + e.message);
  }
}
function closeHelpModal() {
  document.getElementById('help-modal').style.display = 'none';
}
// ESC로 닫기
document.addEventListener('keydown', e => {
  if (e.key === 'Escape') closeHelpModal();
});
</script>
```

## 작업 #3: 각 탭 HTML에 ❓ 버튼 주입

tabs/ 디렉토리의 각 파일 상단(첫 번째 div나 h1/h2 안)에 ❓ 버튼 추가.

매핑:
- tab_register.html → showHelp('register')
- tab_margin.html → showHelp('margin')
- tab_bulk.html → showHelp('bulk')
- tab_discover.html → showHelp('discover')
- tab_adjust.html → showHelp('adjust')
- tab_prices.html → showHelp('prices')
- tab_mybids.html → showHelp('mybids')
- tab_sales.html → showHelp('sales')
- tab_history.html → showHelp('history')
- tab_pattern.html → showHelp('pattern')
- tab_logistics.html → showHelp('logistics')
- tab_settings.html → showHelp('settings')

각 탭 파일 맨 앞(첫 번째 콘텐츠 div의 시작 부분)에 다음 헤더 삽입:

```html
<div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:12px; padding:8px 0; border-bottom:1px solid #e5e7eb;">
  <span style="font-size:14px; color:#6b7280;">현재 메뉴</span>
  <button onclick="showHelp('TAB_ID_HERE')" 
          style="background:#f3f4f6; border:1px solid #d1d5db; border-radius:20px; padding:4px 12px; font-size:13px; cursor:pointer; color:#374151;"
          title="이 화면 사용법 보기">
    ❓ 도움말
  </button>
</div>
```

TAB_ID_HERE 부분을 매핑에 따라 교체.

이미 ❓ 도움말 버튼이 있으면 추가 금지 (멱등성).

## 작업 #4: 검증

1. `python3 -m py_compile kream_server.py` → 0 종료
2. 서버 재시작: `lsof -ti:5001 | xargs kill -9; nohup python3 kream_server.py > server.log 2>&1 & disown; sleep 5`
3. `curl -s http://localhost:5001/api/health` → 200
4. `curl -s http://localhost:5001/api/help/register` → ok=true, help.title 존재
5. `curl -s http://localhost:5001/api/help/settings` → ok=true
6. `curl -s http://localhost:5001/api/help/nonexistent` → 404
7. 각 tab_*.html에 showHelp(') 문자열 존재 확인:
   ```bash
   for f in tabs/tab_*.html; do
     grep -q "showHelp(" "$f" && echo "✅ $f" || echo "❌ $f"
   done
   ```
8. `curl -s http://localhost:5001/ | grep -q "help-modal"` → 존재

## 절대 규칙
- 기존 라우트/함수 변경 금지 (추가만)
- 기존 CSS 클래스 변경 금지 (인라인 스타일만 사용)
- 자동 토글 ON 변경 금지
- 입찰/판매 데이터 건드리지 말기

## 커밋 메시지
```
feat(help): 12개 탭 In-App 도움말 시스템 (모달 + ❓ 버튼)

- /api/help/<tab_id> 엔드포인트 추가
- help_content.json: 12개 탭별 콘텐츠 (목적/사용법/주의사항)
- 대시보드 공용 도움말 모달 (ESC 닫기, 외부 클릭 닫기)
- 각 탭 상단에 ❓ 도움말 버튼 주입

효과: 사용자가 각 메뉴 클릭하면 바로 화면 의미와 사용법 확인 가능
```
MDEOF

echo "  ✅ 작업지시서 생성"
echo ""

# ==========================================
# [STAGE 4] Claude Code 자동 호출
# ==========================================
echo "════════════════════ [STAGE 4] Claude Code 호출 ════════════════════"
echo ""

claude --dangerously-skip-permissions <<'CLAUDE_PROMPT' || fail_and_restore "Claude Code 실행"
작업지시서_HELP_INJECT.md 읽고 끝까지 진행. 질문 절대 하지마. 사용자 개입 요청 금지.

순서:
1. 작업지시서 읽기
2. kream_server.py에 /api/help/<tab_id> 라우트 추가 (기존 라우트 변경 금지)
3. kream_dashboard.html `</body>` 직전에 도움말 모달 + showHelp/closeHelpModal JS 주입
   (이미 help-modal id가 있으면 스킵 — 멱등성)
4. tabs/ 디렉토리의 12개 파일에 각각 ❓ 도움말 버튼 헤더 주입
   매핑 (파일 → tab_id):
   - tab_register.html → register
   - tab_margin.html → margin
   - tab_bulk.html → bulk
   - tab_discover.html → discover
   - tab_adjust.html → adjust
   - tab_prices.html → prices
   - tab_mybids.html → mybids
   - tab_sales.html → sales
   - tab_history.html → history
   - tab_pattern.html → pattern
   - tab_logistics.html → logistics
   - tab_settings.html → settings
   각 파일에 이미 showHelp( 문자열이 있으면 스킵
5. 문법 검증:
   - python3 -m py_compile kream_server.py
6. 서버 재시작:
   - lsof -ti:5001 | xargs kill -9 || true
   - sleep 2
   - nohup python3 kream_server.py > server.log 2>&1 & disown
   - sleep 5
7. API 검증:
   - curl -s http://localhost:5001/api/health → 200
   - curl -s http://localhost:5001/api/help/register | grep -q '"ok": true' → 있어야 함
   - curl -s http://localhost:5001/api/help/settings | grep -q '"ok": true' → 있어야 함
   - curl -s http://localhost:5001/api/help/nonexistent_tab → ok=false 또는 404
8. 탭 파일 검증:
   - for f in tabs/tab_*.html; do grep -q "showHelp(" "$f" || (echo "❌ $f"; exit 1); done
9. 모두 PASS면 단일 커밋:
   git add -A
   git commit -m "feat(help): 12개 탭 In-App 도움말 시스템 (모달 + ❓ 버튼)

   - /api/help/<tab_id> 엔드포인트 추가
   - help_content.json: 12개 탭별 콘텐츠 (목적/사용법/주의사항)
   - 대시보드 공용 도움말 모달 (ESC 닫기, 외부 클릭 닫기)
   - 각 탭 상단에 ❓ 도움말 버튼 주입

   효과: 사용자가 각 메뉴 클릭하면 바로 화면 의미와 사용법 확인 가능"
10. git push origin main
11. 끝.

검증 FAIL 시 즉시 종료. 백업 복원은 외부 스크립트가 처리.
질문/확인 요청 절대 금지.
CLAUDE_PROMPT

echo ""
echo "🔍 최종 검증..."
verify_server || fail_and_restore "최종 검증"

# 도움말 API 직접 호출 검증
HELP_OK=$(curl -s http://localhost:5001/api/help/register | python3 -c "import json,sys; d=json.load(sys.stdin); print('YES' if d.get('ok') else 'NO')" 2>/dev/null || echo "NO")
if [ "$HELP_OK" != "YES" ]; then
    echo "⚠️  /api/help/register 응답 비정상"
    fail_and_restore "도움말 API 검증"
fi
echo "  ✅ /api/help/register 정상"

# 탭 파일 주입 검증
INJECTED=0
MISSING=0
for f in tabs/tab_*.html; do
    if grep -q "showHelp(" "$f" 2>/dev/null; then
        INJECTED=$((INJECTED+1))
    else
        MISSING=$((MISSING+1))
        echo "  ⚠️  $f 에 ❓ 버튼 없음"
    fi
done
echo "  ✅ ❓ 버튼 주입: ${INJECTED}개 (누락 ${MISSING}개)"

if [ "$INJECTED" -lt 8 ]; then
    fail_and_restore "탭 주입 부족"
fi

FINAL_HASH=$(git log -1 --format=%h)
echo "  ✅ 커밋: $FINAL_HASH"
echo ""

# ==========================================
# 최종 요약
# ==========================================
PIPELINE_END=$(date +%s)
ELAPSED=$((PIPELINE_END - PIPELINE_START))
ELAPSED_MIN=$((ELAPSED / 60))

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🎉 도움말 주입 완료 — ${ELAPSED_MIN}분 ${ELAPSED}초"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "✅ 결과:"
echo "  - API: GET /api/help/<tab_id> 추가"
echo "  - 도움말 콘텐츠: 12개 탭 (help_content.json)"
echo "  - 대시보드 모달 + ❓ 버튼 주입"
echo "  - 커밋: $FINAL_HASH"
echo ""
echo "📋 사용 방법:"
echo "  1. 대시보드 열기 (http://localhost:5001 또는 Cloudflare Tunnel URL)"
echo "  2. 사이드바에서 메뉴 클릭"
echo "  3. 우상단 ❓ 도움말 버튼 클릭"
echo "  4. 모달에서 [이 화면이 뭔지 / 왜 만들었나 / 사용법 / 주의사항] 확인"
echo ""
echo "📜 진행 로그: pipeline_help.log"
echo ""
echo "💡 콘텐츠 수정 방법:"
echo "  ~/Desktop/kream_automation/help_content.json 편집 후"
echo "  서버 재시작 없이 즉시 반영됨 (브라우저 새로고침만)"
echo ""
