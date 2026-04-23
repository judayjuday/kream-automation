# Hooks 가이드

## 현재 설치된 hooks

### PostToolUse: syntax-check.sh
- **트리거**: Edit, Write 도구 사용 후
- **동작**: .py 파일 수정 시 `py_compile`로 문법 체크
- **실패 시**: exit 2 → 클로드 코드에 오류 전달, 수정 유도

### PreToolUse: dangerous-command-check.sh
- **트리거**: Bash 도구 사용 전
- **차단 대상**:
  - `DROP TABLE`, `DELETE FROM sales_history/bid_cost/price_adjustments`
  - `rm price_history.db`
  - `auth_state.json` 백업 없이 덮어쓰기
  - `git push -f`, `git reset --hard`
- **실패 시**: exit 2 → 명령 실행 차단

### Stop: 작업 완료 전 검증 (prompt hook)
- **트리거**: 클로드 코드가 작업 종료 시
- **동작**: CLAUDE.md 체크리스트 확인 요청

## hook 추가 방법
1. `.claude/hooks/` 에 스크립트 작성
2. `chmod +x` 실행 권한 부여
3. `.claude/settings.json`에 등록
4. stdin으로 JSON 입력 받음 (jq로 파싱)
