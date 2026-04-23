#!/bin/bash
# PostToolUse hook: Python 파일 수정 후 문법 체크
# Edit/Write 도구 사용 후 자동 실행

FILE_PATH=$(jq -r '.tool_input.file_path // empty' <&0)

if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

if [[ "$FILE_PATH" == *.py ]]; then
  # 파일 존재 확인
  if [[ ! -f "$FILE_PATH" ]]; then
    exit 0
  fi

  OUTPUT=$(python3 -c "import py_compile; py_compile.compile('$FILE_PATH', doraise=True)" 2>&1)
  if [ $? -ne 0 ]; then
    echo "SYNTAX ERROR in $FILE_PATH" >&2
    echo "$OUTPUT" >&2
    exit 2
  fi
fi

# HTML/JS 파일은 기본 체크 스킵
exit 0
