#!/bin/bash
# PreToolUse hook: 위험한 명령 차단
# Bash 도구 사용 전 자동 실행

CMD=$(jq -r '.tool_input.command // empty' <&0)

if [[ -z "$CMD" ]]; then
  exit 0
fi

# DB 파일 DROP/DELETE 차단
if echo "$CMD" | grep -qE "DROP TABLE|DELETE FROM sales_history|DELETE FROM bid_cost|DELETE FROM price_adjustments"; then
  echo "BLOCKED: 위험한 DB 명령 차단됨. CLAUDE.md 절대 규칙 참조." >&2
  exit 2
fi

# price_history.db 삭제 차단
if echo "$CMD" | grep -qE "rm.*price_history\.db"; then
  echo "BLOCKED: price_history.db 삭제 금지. CLAUDE.md 절대 규칙 참조." >&2
  exit 2
fi

# auth_state.json 덮어쓰기 차단 (백업 없이)
if echo "$CMD" | grep -qE ">.*auth_state.*\.json" && ! echo "$CMD" | grep -q "backup"; then
  echo "BLOCKED: auth_state 덮어쓰기 금지. 백업 먼저 하세요." >&2
  exit 2
fi

# git push -f, git reset --hard 차단
if echo "$CMD" | grep -qE "git push.*(-f|--force)|git reset.*--hard"; then
  echo "BLOCKED: 위험한 git 명령. 사용자 확인 필요." >&2
  exit 2
fi

exit 0
