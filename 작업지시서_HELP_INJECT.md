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
