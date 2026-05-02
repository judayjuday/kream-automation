# 패치 지시서 — Step 16-A UI 수정

목적: 사용자 피드백 반영
1. "식货" 표기를 한글로 변경 ("식화" 또는 적절한 한글 표기)
2. "활성 batch: 로딩 중..." 멈춤 버그 진단 + 수정

작업 모드: tabs/tab_adjust.html UI 부분만 수정. 백엔드 API 코드 변경 금지.

## 사전 백업
```bash
cp tabs/tab_adjust.html tabs/tab_adjust.html.ui_fix_pre.bak
```

## Step 1: 표기 변경

### 1-1. 사용자 결정 사항 검토 (보고 후 진행)
"식货"를 어떻게 한글화할지 옵션:
- A: "식화" (음역)
- B: "스휴오" (중국어 발음 음역)
- C: "ShihHuo" (영문 표기)
- D: "중국 시장가" (의역)
- E: 그냥 "시장가" (가장 자연스러움)

권장: E ("시장가") — 한국 사용자 입장에서 가장 명확. "식货"는 데이터 출처일 뿐 사용자가 의식할 필요 없음.

이번 패치에서는 권장안 E로 진행하되, 사용자가 다르게 원하면 보고 후 재수정.

### 1-2. tab_adjust.html에서 "식货" 검색 + 치환
```bash
grep -n "식货\|식貨" tabs/tab_adjust.html
```
모든 위치 변경:
- `"식货 ↔ 등록 원가 차이"` → `"시장가 ↔ 등록 원가 차이"`
- `"식货 활성 배치 vs bid_cost 가격 차이"` → `"시장 시장가 vs 등록 원가 차이"`
- 기타 식货 표기 모두 한글화

### 1-3. JS 코드 안의 한자도 정리
- 변수명/주석은 영문 유지 가능 (shihuo, shihuoDiff)
- 사용자 노출 텍스트만 한글화

## Step 2: "활성 batch: 로딩 중..." 멈춤 버그 진단

### 2-1. 현재 JS 로직 확인
```bash
grep -n "로딩 중\|loadShihuoDiff\|shihuoDiffMeta\|active_batch_id" tabs/tab_adjust.html
```

### 2-2. 의심 원인 분석
- 카드가 표시될 때 자동으로 활성 batch_id를 fetch하는 로직이 있는가?
- 아니면 "차이 보기" 버튼 클릭 시에만 fetch?
- "로딩 중..." 텍스트가 페이지 로드 시 박혀있는데 fetch 자체가 안 일어나는 게 문제일 가능성 높음

### 2-3. 수정 방향
1. **카드 렌더링 시 자동으로 활성 batch_id를 fetch해서 표시**
   - 페이지 로드 → /api/shihuo/latest 호출 → 응답으로 batch_id + 차이 건수 표시
   - "차이 보기" 버튼은 모달 열기 전용
2. **활성 batch가 없으면 "활성 batch 없음"으로 표시** (로딩 중이 아닌 명확한 상태)
3. **에러 발생 시 "조회 실패"로 표시 + 콘솔 에러 로깅**

### 2-4. 수정된 카드 코드 예시
```html
<!-- 카드 영역 -->
<div class="card">
  <div style="display:flex; justify-content:space-between; align-items:center;">
    <div>
      <h3>🔍 시장가 ↔ 등록 원가 차이</h3>
      <p id="shihuoDiffSummary" style="margin:0; color:#666; font-size:0.9em;">조회 중...</p>
    </div>
    <button onclick="openShihuoDiffModal()">차이 보기</button>
  </div>
</div>
```

```javascript
// 카드 자동 로드
async function loadShihuoDiffSummary(){
  const summary = document.getElementById('shihuoDiffSummary');
  try {
    const r = await fetch('/api/bid-cost/shihuo-diff').then(x=>x.json());
    if (!r.ok) {
      summary.textContent = '조회 실패';
      return;
    }
    const batch = r.active_batch_id || '활성 batch 없음';
    summary.textContent = `활성 batch: ${batch} · 차이 ${r.count}건`;
  } catch(e) {
    summary.textContent = '조회 실패';
    console.error('shihuo-diff summary load error:', e);
  }
}

// 페이지 로드 시 자동 호출
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', loadShihuoDiffSummary);
} else {
  loadShihuoDiffSummary();
}

// 모달 열기 (기존 loadShihuoDiff 함수를 모달 열기 전용으로 단순화)
async function openShihuoDiffModal(){
  // 기존 loadShihuoDiff 로직 + 모달 열기
}
```

### 2-5. 탭 전환 시 재로드 처리
- 탭 시스템이 탭별 HTML을 동적 로드하는 구조면, 페이지 첫 로드 시점에 JS가 실행 안 될 수 있음
- 해결: window.loadShihuoDiffSummary 전역 등록 + 탭 활성화 이벤트 후크 또는 setTimeout으로 100ms 후 호출

## Step 3: 검증

### 3-1. HTML 문법 체크
```bash
python3 -c "from html.parser import HTMLParser; HTMLParser().feed(open('tabs/tab_adjust.html').read()); print('OK')"
```

### 3-2. grep 재검색
```bash
grep -n "식货\|식貨" tabs/tab_adjust.html
```
0건이어야 함 (사용자 노출 텍스트). 변수명/주석에 남아있는 건 OK.

### 3-3. 사용자 브라우저 검증
사용자에게 다음을 부탁:
1. 강력 새로고침 (Cmd+Shift+R)
2. 가격 자동 조정 탭 진입
3. "🔍 시장가 ↔ 등록 원가 차이" 카드 확인
4. 카드 하단 텍스트가 "활성 batch: shihuo_xxxxx · 차이 0건" 형태로 표시되는지 확인 (로딩 중... 사라져야 함)
5. "차이 보기" 버튼 클릭 → 모달 표시
6. 콘솔(F12) 에러 0건

## 보고

[Step 16-A UI 패치 결과]
- 식货 → 한글 치환: N건
- 활성 batch 로딩 버그 원인: ...
- 수정 방식: ...
- HTML 문법 OK
- 사용자 브라우저 검증 대기

---

다음 후속 작업으로 분리:
- KREAM 세션 만료 시 자동 재로그인 (별도 작업지시서로 진행 예정)
