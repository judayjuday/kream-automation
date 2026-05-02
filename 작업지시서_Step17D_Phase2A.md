# 작업지시서 — Step 17-D Phase 2-A: 즉시 수동 진입점 + atomic 저장

> 작성일: 2026-05-02
> 의존: Step17D_Phase1_사전분석_20260502.md
> 예상 시간: 30분
> 예상 라인: +85 라인, 4개 파일

---

## 0. 사전 점검 (Claude Code가 시작 전 필수 실행)

```bash
cd ~/Desktop/kream_automation

# 0-1. 현재 브랜치 + 클린 상태 확인
git status
git log --oneline -1

# 0-2. 백업 (CLAUDE.md 절대 규칙 #4 준수)
cp kream_bot.py kream_bot.py.step17d_2a_pre.bak
cp kream_server.py kream_server.py.step17d_2a_pre.bak
cp kream_hubnet_bot.py kream_hubnet_bot.py.step17d_2a_pre.bak 2>/dev/null || echo "kream_hubnet_bot.py 없음"
sqlite3 price_history.db ".backup '/Users/iseungju/Desktop/kream_automation/price_history_backup_step17d_2a_pre.db'"

# 0-3. 현재 hubnet 세션 상태 확인 (만료 확인됨, 빈 세션 317 byte)
ls -la auth_state_hubnet.json
```

---

## 1. 작업 범위 (4가지)

### 작업 #1 — kream_bot.py에 `--mode login-hubnet` 추가

**문제**: 사용자가 허브넷 세션 만료 시 수동으로 재로그인할 CLI 진입점 없음.

**구현**:
- `kream_bot.py` argparse `choices`에 `'login-hubnet'` 추가
- `main()` 함수에서 `args.mode == 'login-hubnet'` 분기 처리
- `kream_hubnet_bot.py`의 `hubnet_login()` 함수를 import해서 호출
- 결과: `python3 kream_bot.py --mode login-hubnet` 명령 동작

**예상 코드 위치**: `kream_bot.py` 마지막 부분의 argparse 정의 + main 분기

**검증**:
```bash
python3 kream_bot.py --help  # login-hubnet 보이는지
python3 kream_bot.py --mode login-hubnet  # 실제 동작 (Playwright headless=False 권장)
ls -la auth_state_hubnet.json  # mtime 갱신 + 크기 5KB 이상
```

---

### 작업 #2 — save_state_with_localstorage 백업+atomic 저장

**문제**: 분석서 6.3 — 새 로그인 실패 시 기존 세션 덮어쓰기 위험. atomic write 미구현.

**구현 (kream_bot.py:254 부근)**:

```python
async def save_state_with_localstorage(page, context, path, origin_url):
    """storage_state + localStorage 통합 저장 (atomic + backup)"""
    import os
    import shutil
    import json
    import tempfile
    
    # 1. context.storage_state() → 메모리 dict
    state = await context.storage_state()
    
    # 2. localStorage 추가
    try:
        local_storage = await page.evaluate("() => Object.entries(window.localStorage)")
        if local_storage:
            origin_entry = next(
                (o for o in state.get('origins', []) if o.get('origin') == origin_url),
                None
            )
            if origin_entry is None:
                origin_entry = {'origin': origin_url, 'localStorage': []}
                state.setdefault('origins', []).append(origin_entry)
            origin_entry['localStorage'] = [
                {'name': k, 'value': v} for k, v in local_storage
            ]
    except Exception as e:
        print(f"[WARN] localStorage 추출 실패: {e}")
    
    # 3. 토큰 키 검증 (빈 세션 저장 방지)
    has_meaningful_data = (
        len(state.get('cookies', [])) > 0 or
        any(len(o.get('localStorage', [])) > 0 for o in state.get('origins', []))
    )
    if not has_meaningful_data:
        print(f"[ERROR] 세션 데이터 없음, 저장 거부: {path}")
        return False
    
    # 4. 기존 파일 백업 (성공 시에만)
    if os.path.exists(path):
        backup_path = f"{path}.pre_relogin.bak"
        shutil.copy2(path, backup_path)
    
    # 5. 임시 파일에 쓰기
    tmp_path = f"{path}.tmp"
    with open(tmp_path, 'w', encoding='utf-8') as f:
        json.dump(state, f, indent=2, ensure_ascii=False)
    
    # 6. 임시 파일 검증
    with open(tmp_path, 'r', encoding='utf-8') as f:
        verify = json.load(f)
    if not verify.get('cookies') and not verify.get('origins'):
        os.remove(tmp_path)
        print(f"[ERROR] 임시 파일 검증 실패: {tmp_path}")
        return False
    
    # 7. atomic replace
    os.replace(tmp_path, path)
    
    # 8. 7일 이상 된 .pre_relogin.bak 자동 삭제
    backup_path = f"{path}.pre_relogin.bak"
    if os.path.exists(backup_path):
        age_days = (time.time() - os.path.getmtime(backup_path)) / 86400
        if age_days > 7:
            os.remove(backup_path)
    
    print(f"[INFO] 세션 저장 성공: {path}")
    return True
```

**검증**:
- 정상 흐름: 로그인 성공 → 백업 생성 + 새 파일 + atomic
- 실패 흐름: 빈 세션 저장 거부, 기존 파일 보존
- 7일 이상 된 .pre_relogin.bak 자동 삭제

---

### 작업 #3 — /api/health에 auth_hubnet 추가

**문제**: 분석서 4-4 — 헬스체크에 허브넷 세션 누락.

**구현 (kream_server.py의 /api/health 핸들러)**:

기존 `auth_partner`, `auth_kream` 옆에 `auth_hubnet` 추가:

```python
# 기존 코드 패턴 그대로 따라하기
hubnet_state_path = "/Users/iseungju/Desktop/kream_automation/auth_state_hubnet.json"
auth_hubnet = {
    "exists": os.path.exists(hubnet_state_path),
    "age_hours": None,
    "last_modified": None,
    "valid": False,
}
if auth_hubnet["exists"]:
    mtime = os.path.getmtime(hubnet_state_path)
    auth_hubnet["age_hours"] = round((time.time() - mtime) / 3600, 1)
    auth_hubnet["last_modified"] = datetime.fromtimestamp(mtime).isoformat()
    # 파일 크기 + JSON 파싱 가능 여부로 valid 판정
    try:
        size = os.path.getsize(hubnet_state_path)
        if size > 1000:  # 빈 세션은 ~317 byte
            with open(hubnet_state_path, 'r') as f:
                json.load(f)  # 파싱 실패 시 except
            auth_hubnet["valid"] = True
    except Exception:
        auth_hubnet["valid"] = False

# 응답 dict에 추가
response_data["auth_hubnet"] = auth_hubnet

# status 결정 로직에 hubnet도 포함 (선택)
# 현재 기준에 맞춰서: hubnet 24h 초과 OR invalid 시 warning
```

**검증**:
```bash
curl -s http://localhost:5001/api/health | python3 -m json.tool
# auth_hubnet 필드 추가 확인
# exists, age_hours, last_modified, valid 모두 출력
```

---

### 작업 #4 — settings.json.bak 파일 정리

**문제**: 분석서 3 — 백업 .bak 파일 5개에 평문 자격증명 누적.

**구현 (스크립트, 코드 변경 X)**:

```bash
cd ~/Desktop/kream_automation

# 4-1. 현재 bak 파일 목록 + 크기
ls -la settings.json.*.bak 2>/dev/null

# 4-2. 7일 이상 된 것만 삭제 (CLAUDE.md 절대 규칙: 백업 없이 덮어쓰기 금지)
# 단, 모든 .bak가 자격증명 평문 포함이므로 즉시 삭제
echo "삭제할 파일:"
ls -t settings.json.*.bak 2>/dev/null

# 사용자 승인 받은 후 삭제
read -p "settings.json.*.bak 파일 5개를 삭제하시겠습니까? (y/n) " confirm
if [ "$confirm" = "y" ]; then
    rm -f settings.json.*.bak
    echo "✅ 삭제 완료"
else
    echo "❌ 취소됨"
fi
```

**참고**: kream_server.py.*.bak, tabs/*.html.*.bak 등 다른 백업은 자격증명 없으므로 유지.

---

## 2. 회귀 테스트 (작업 후 필수)

```bash
cd ~/Desktop/kream_automation

# 2-1. 서버 재시작 (CLAUDE.md 패턴)
lsof -ti:5001 | xargs kill -9 2>/dev/null
sleep 2
nohup python3 kream_server.py > server.log 2>&1 & disown
sleep 3

# 2-2. /api/health 확인
echo "=== /api/health (auth_hubnet 추가 확인) ==="
curl -s http://localhost:5001/api/health | python3 -m json.tool | grep -A 5 "auth_hubnet"

# 2-3. CLI 진입점 확인
echo ""
echo "=== --help (login-hubnet 추가 확인) ==="
python3 kream_bot.py --help | grep "login-hubnet"

# 2-4. 실제 hubnet 로그인 (대화형, 사용자 작업)
echo ""
echo "=== hubnet 수동 로그인 시도 ==="
echo "다음 명령을 실행하세요:"
echo "  python3 kream_bot.py --mode login-hubnet"

# 2-5. 로그인 후 세션 확인
echo ""
echo "=== 세션 검증 ==="
ls -la auth_state_hubnet.json
# 크기 5KB 이상 + mtime 0h 가까이여야 정상

# 2-6. atomic 저장 검증 (로그인 직후)
echo ""
echo "=== 백업 파일 확인 ==="
ls -la auth_state_hubnet.json.pre_relogin.bak 2>/dev/null
# 첫 로그인 시에는 백업 없을 수 있음 (기존 세션이 빈 세션이라)
```

---

## 3. 커밋 메시지 (회귀 테스트 PASS 후)

```
feat(Step 17-D Phase 2-A): hubnet CLI 진입점 + atomic 세션 저장 + health 가시성

- kream_bot.py: --mode login-hubnet CLI 진입점 추가
- kream_bot.py: save_state_with_localstorage 백업+atomic 저장 (성공 시에만 덮어쓰기, 7일 자동 정리)
- kream_server.py: /api/health에 auth_hubnet 필드 추가 (exists/age_hours/last_modified/valid)
- settings.json.*.bak 파일 5개 정리 (평문 자격증명 노출 위험 제거)

회귀 테스트:
- /api/health에서 auth_hubnet 필드 정상 출력
- python3 kream_bot.py --help에서 login-hubnet 노출
- 빈 세션 저장 거부 동작 (atomic 검증)
- 기존 KREAM 판매자센터/일반 자동 로그인 회귀 없음
```

---

## 4. CLAUDE.md 절대 규칙 체크리스트

- [x] 1. 원가 없으면 가짜 값 금지 → N/A (이번 작업과 무관)
- [x] 2. 판매 완료 건 수정/삭제 금지 → N/A
- [x] 3. price_history.db 직접 DROP/DELETE 금지 → 백업만 함
- [x] 4. auth_state.json 백업 없이 덮어쓰기 금지 → 작업 #2가 이를 강화
- [x] 5. git push -f 금지 → 일반 push만 사용
- [x] 6. 테스트 데이터로 실제 입찰 금지 → N/A
- [x] 7. 데이터 수집 실패 시 다른 데이터로 대체 금지 → N/A

---

## 5. 작업 후 다음 단계

Phase 2-A 완료 후:
- **Phase 2-B**: 사전 갱신 스케줄러 (12h 주기, threading.Lock)
- **Phase 2-C**: 알림 채널 점검 + 대시보드 배너

각 Phase는 별도 작업지시서로 분리하여 순차 진행.
