# VERIFICATION_PROTOCOL.md
**프로젝트:** 주데이 이커머스 자동화 시스템
**작성일:** 2026-04-24
**버전:** v1.0
**관련 문서:** NORTH_STAR.md (원칙 6), AGENTS_INDEX.md

> 이 문서는 **모든 코드 변경 작업의 표준 검증 프로토콜**입니다.
> 원칙 6 "자체 검증 필수"의 구체적 실행 방법입니다.

---

## 1. 기본 원칙

**"검증 없이 완료 선언 금지."**

모든 에이전트는 작업 완료 전 반드시 4단계 프로토콜을 거쳐야 함.

---

## 2. 4단계 프로토콜

### Step 1: Plan (계획 선언)

작업 시작 전 다음 4가지 명시:

```
## 작업 계획
- 변경할 파일: [파일명]
- 영향 받는 기능: [기능 A, B]
- 검증 방법: [아래 Verify 단계 중 어떤 것 적용할지]
- 롤백 방법: [실패 시 되돌리는 방법]
```

### Step 2: Act (구현)

- 실제 코드 작성
- 한 번에 한 가지 변경 (여러 건이면 쪼개기)
- 커밋은 아직 안 함

### Step 3: Verify (자동 검증 4종)

**모든 작업 공통:**

```bash
# 3.1 문법 체크
python3 -c "import py_compile; py_compile.compile('kream_server.py', doraise=True)"

# 3.2 서버 재시작 + 헬스체크
lsof -ti:5001 | xargs kill -9 2>/dev/null
sleep 2
nohup python3 kream_server.py > server.log 2>&1 &
disown
sleep 5
curl -s http://localhost:5001/api/health | python3 -m json.tool

# 3.3 관련 API 응답 확인 (작업한 API 3개 내외)
curl -s http://localhost:5001/api/<변경한-엔드포인트> | python3 -m json.tool

# 3.4 회귀 테스트 (해당 도메인만)
pytest tests/test_<domain>_*.py -v  # 있다면
```

**4개 중 1개라도 실패 = Step 4 Report에서 실패 보고 (완료 선언 금지)**

### Step 4: Report (결과 보고)

작업 완료 후 다음 형식으로 보고:

```markdown
## 작업 결과

### 구현 기능 요약
| 기능 | 파일 | 라인 | 상태 |
|------|------|------|------|
| ... | ... | ... | ✅/❌ |

### 검증 결과
| 단계 | 결과 |
|------|------|
| 3.1 문법 체크 | ✅ PASS |
| 3.2 헬스체크 | ✅ PASS (status: healthy) |
| 3.3 API 응답 | ✅ PASS (3/3) |
| 3.4 회귀 테스트 | ✅ PASS (12/12) 또는 SKIP (테스트 없음) |

### 변경 파일 목록
- `git diff --stat` 결과

### 알려진 제약
- (있다면)
```

---

## 3. 검증 실패 시 프로토콜

```
검증 실패 발생
   ↓
Step 4에서 실패 보고 (완료 선언 X)
   ↓
주데이에게 다음 선택지 제시:
   1. 수정 후 재시도 (자동 X, 주데이 승인 필요)
   2. 롤백 (git reset 또는 복구)
   3. 주데이와 함께 원인 분석
   ↓
자동 재시도는 최대 1회만 허용
   ↓
2회 이상 실패 → 강제 중단 + 주데이에게 전권 이양
```

**"Claude가 스스로 3번 돌리는 건 위험."**
- 2번째 실패도 원인이 같으면 3번째도 실패할 가능성 큼
- 무한 루프 방지
- 주데이의 판단이 더 중요

---

## 4. 에이전트별 검증 템플릿

### KREAM 도메인 (kream-operator)

```bash
# 추가 검증:
curl -s http://localhost:5001/api/auto-rebid/status | python3 -m json.tool
curl -s http://localhost:5001/api/auto-adjust/status | python3 -m json.tool
curl -s http://localhost:5001/api/my-bids/local | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('입찰 수:', len(d.get('bids', [])))
"
```

### SSRO 도메인 (ssro-channel-operator)

```bash
# 추가 검증 (M3 이후):
curl -s http://localhost:5001/api/ssro/orders/recent | python3 -m json.tool
sqlite3 data/automation.db "SELECT COUNT(*) FROM ssro_orders;"
```

### CS 도메인 (cs-drafter)

```bash
# 추가 검증 (M12 이후):
curl -s http://localhost:5001/api/cs/drafts/pending | python3 -m json.tool
sqlite3 data/automation.db "SELECT COUNT(*) FROM cs_drafts WHERE status='draft_ready';"
```

### 이미지 편집 도메인 (image-editor)

```bash
# 추가 검증 (M5 이후):
python3 -c "from PIL import Image; print('Pillow OK')"
# R2 업로드 테스트 (작은 테스트 이미지 1개)
curl -I https://pub-a6171463d5644d5397d0127a58028498.r2.dev/test.png
```

### 크롤러 도메인 (product-crawler)

```bash
# 추가 검증 (M6 이후):
curl -s http://localhost:5001/api/crawler/sources | python3 -m json.tool
# rate limit 준수 확인 (시간당 요청 수)
```

---

## 5. 자동 검증 스크립트 (공통 템플릿)

매번 반복 안 하려고 스크립트 하나 만들기:

```bash
# scripts/verify.sh
#!/bin/bash
# 사용: ./scripts/verify.sh [domain]

DOMAIN=${1:-all}
PORT=5001

echo "=== 1. 문법 체크 ==="
python3 -c "import py_compile; py_compile.compile('apps/kream/kream_server.py', doraise=True)" && echo "✅ PASS" || echo "❌ FAIL"

echo ""
echo "=== 2. 서버 재시작 + 헬스체크 ==="
lsof -ti:$PORT | xargs kill -9 2>/dev/null
sleep 2
cd apps/kream && nohup python3 kream_server.py > ../../data/server.log 2>&1 &
disown
sleep 5

HEALTH=$(curl -s http://localhost:$PORT/api/health)
echo "$HEALTH" | python3 -m json.tool
if echo "$HEALTH" | grep -q '"ok": true\|"valid": true'; then
    echo "✅ 헬스체크 PASS"
else
    echo "❌ 헬스체크 FAIL"
    exit 1
fi

echo ""
echo "=== 3. 도메인별 API 체크 ==="
case $DOMAIN in
    kream|all)
        curl -s http://localhost:$PORT/api/auto-rebid/status | python3 -m json.tool
        curl -s http://localhost:$PORT/api/auto-adjust/status | python3 -m json.tool
        ;;
    ssro)
        curl -s http://localhost:$PORT/api/ssro/orders/recent | python3 -m json.tool
        ;;
    # ... 다른 도메인들
esac

echo ""
echo "=== 4. 회귀 테스트 ==="
if [ -d "tests" ]; then
    pytest tests/test_${DOMAIN}_*.py -v 2>/dev/null || echo "⏭️  테스트 파일 없음"
fi

echo ""
echo "=== 완료 ==="
```

---

## 6. Claude Code 훅 연동

`.claude/hooks/` 에 기존 syntax-check.sh 외 추가:

### post-edit-verify.sh (신규)

```bash
#!/bin/bash
# 파일 편집 후 자동 실행

# kream 관련 파일만 트리거
if [[ "$FILE_PATH" == *"apps/kream"* ]]; then
    ./scripts/verify.sh kream
fi
```

### pre-commit-verify.sh (신규)

```bash
#!/bin/bash
# 커밋 직전 실행 — 실패 시 커밋 금지

./scripts/verify.sh all

if [ $? -ne 0 ]; then
    echo "❌ 검증 실패 → 커밋 중단"
    echo "문제 해결 후 다시 커밋"
    exit 1
fi
```

---

## 7. 변경 이력

| 버전 | 날짜 | 변경 사유 |
|------|------|----------|
| v1.0 | 2026-04-24 | 최초 작성 (원칙 6 구체화) |

---

**🎯 이 문서를 읽고 답할 수 있어야 함:**
- 검증 4종은? → 문법 / 헬스체크 / API / 회귀테스트
- 검증 실패하면? → 완료 선언 금지, 주데이에게 보고
- 자동 재시도는? → 최대 1회 (그 이후 강제 중단)
