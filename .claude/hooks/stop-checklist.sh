#!/bin/bash
# Stop hook (type=command): 변경 파일 기반 검증 체크리스트
# - 작업 파일(.py/.html/.sql/.sh/.js/.css) 변경 0건 → exit 0 (진단/문서 turn 통과)
# - 변경 있으면 종류별 체크리스트 메시지 + exit 2 (Claude에 검증 강제)
# - 런타임 산출물(*.bak.*, alert_history.json, my_bids_local.json, tunnel.log, server.log)은 무시

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-/Users/iseungju/Desktop/kream_automation}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0

# git 사용 불가 시 안전하게 통과
if ! command -v git >/dev/null 2>&1 || [[ ! -d .git ]]; then
  exit 0
fi

# 변경 파일 목록 (modified + untracked)
# 1) 런타임/백업 파일 제외
# 2) 의미 있는 작업 파일 확장자만
CHANGED=$(git status --porcelain 2>/dev/null \
  | sed 's/^...//' \
  | grep -vE '\.bak\.[0-9]+$' \
  | grep -vE '(^|/)(alert_history|my_bids_local|tunnel|server|backup|nohup)\.(json|log|out)$' \
  | grep -vE '(^|/).claude/' \
  | grep -E '\.(py|html|sql|sh|js|css)$' \
  || true)

if [[ -z "$CHANGED" ]]; then
  # 진단/조회/문서 전용 turn — 검증 강제 불필요
  exit 0
fi

PY_CHANGED=$(echo "$CHANGED" | grep -E '\.py$' || true)
HTML_CHANGED=$(echo "$CHANGED" | grep -E '\.html$' || true)
JS_CHANGED=$(echo "$CHANGED" | grep -E '\.js$' || true)
SQL_CHANGED=$(echo "$CHANGED" | grep -E '\.sql$' || true)
SH_CHANGED=$(echo "$CHANGED" | grep -E '\.sh$' || true)

{
  echo "작업 완료 전 검증 — 변경된 작업 파일:"
  echo "$CHANGED" | sed 's|^|  - |'
  echo ""
  echo "필요한 검증 항목 (CLAUDE.md 체크리스트):"
  if [[ -n "$PY_CHANGED" ]]; then
    echo "  [Python] py_compile 문법 체크"
    echo "  [Python] /api/health 200 응답 확인"
    echo "  [Python] 새 API 추가 시 라우트 충돌 + JSON 에러 응답 확인"
  fi
  if [[ -n "$HTML_CHANGED" || -n "$JS_CHANGED" ]]; then
    echo "  [Frontend] 브라우저 콘솔 에러 확인"
  fi
  if [[ -n "$SQL_CHANGED" ]]; then
    echo "  [DB] 마이그레이션: NULL 허용 + IF NOT EXISTS + 백업 확인"
  fi
  if [[ -n "$SH_CHANGED" ]]; then
    echo "  [Shell] chmod +x 적용 + 단발 실행 검증"
  fi
  echo ""
  echo "확인 후 완료 선언. 변경이 의도된 결과면 PASS 명시."
} >&2
exit 2
