# Claude Code 작업지시서 — 검증 3종 Sub-Agents 생성 (간소화 v2)

**작업 대상:** orchestrator + auditor + qa-validator
**예상 소요:** 5~10분 (자동 진행)
**작업자:** Claude Code
**승인자:** 주데이 (승주)

**🚦 사용자 승인 게이트:** 마지막 Git Push 1회만

---

## 진행 방식

이 작업지시서는 **자동 진행**이 기본입니다.
- 사전 확인, 파일 생성, 검증, 커밋까지 **연속으로 진행**
- **Git push 직전**에만 멈추고 사용자에게 결과 보고 + 승인 요청
- 문제 발견 시 자동으로 멈추고 사용자에게 보고

자동 안전장치:
- `.claude/hooks/syntax-check.sh` — 파일 변경마다 자동 체크
- `.claude/hooks/dangerous-command-check.sh` — 위험 명령 차단
- 자기복제 검증(Step D) — 3개 파일 자기 검증

---

## 0. 사전 확인 (자동 진행)

```bash
cd ~/Desktop/kream_automation
pwd
ls -la .claude/
ls -la .claude/agents/ 2>/dev/null || echo "agents 폴더 없음 (이번에 생성)"
git status
git log -1 --oneline
```

다음 문서들을 읽기만 한다 (수정 금지). 다 읽고 핵심 명세를 내부적으로 파악하고 다음 단계로 진행:
1. `~/Desktop/kream_automation/NORTH_STAR.md` (7원칙)
2. `~/Desktop/kream_automation/ARCHITECTURE.md`
3. `~/Desktop/kream_automation/AGENTS_INDEX.md` (11개 에이전트 명세 — 가장 중요)
4. `~/Desktop/kream_automation/VERIFICATION_PROTOCOL.md`
5. `~/Desktop/kream_automation/MIGRATION_PLAN.md`
6. `~/Desktop/kream_automation/OBSERVABILITY.md`
7. `~/Desktop/kream_automation/CLAUDE.md` (절대 규칙 6개)

읽기 완료 후 **요약 보고 없이 바로** 1번 작업 시작.

**중단 조건:** 문서 중 하나라도 없거나 git status에 예상치 못한 변경이 있으면 멈추고 사용자에게 보고.

---

## 1. 작업 목표

`.claude/agents/` 폴더에 다음 3개 파일을 생성한다.

| 파일 | 역할 |
|---|---|
| `orchestrator.md` | 작업 분배 + 다른 에이전트 호출 조율 |
| `auditor.md` | 모든 변경 사항 사후 감사 (DB/파일/Git) |
| `qa-validator.md` | Plan→Act→Verify→Report 루프의 Verify 단계 |

**왜 이 3개를 먼저?** 나머지 8개 에이전트를 만들 때 즉시 검증에 활용 가능.

---

## 2. 각 에이전트 파일 명세

### 2.1 공통 구조 (모든 .md 파일 필수)

```yaml
---
name: <agent-name>
description: <한 줄 설명 — 언제 호출해야 하는지>
model: <inherit | sonnet | opus>
tools: <필요한 도구 명시, 또는 inherit>
---

# <Agent Display Name>

## 역할 (Mission)
## 호출 조건 (When to invoke)
## 절대 금지 (Never do)
## 작업 흐름 (Workflow)
## 출력 포맷 (Output format)
## 인용/참조 문서
```

**AGENTS_INDEX.md v1.1의 명세와 충돌하면 AGENTS_INDEX.md 우선.**

### 2.2 orchestrator.md

**역할:** 사용자 요청을 받아 적절한 Sub-Agent에게 분배. 직접 실행 금지.

**핵심 동작:**
1. 사용자 요청 수신
2. AGENTS_INDEX.md 참조하여 어떤 에이전트가 적합한지 판단
3. 해당 에이전트에게 작업 위임
4. 결과 받아서 qa-validator에게 검증 요청
5. 통과 시 사용자에게 보고, 실패 시 재시도 또는 반려

**절대 금지:**
- 코드 직접 수정 (Edit/Write 금지)
- DB 직접 조작
- Git 직접 commit/push

**호출 조건:** 사용자가 작업을 요청하는 모든 진입점

**model:** `inherit`

### 2.3 auditor.md

**역할:** 모든 변경 사항의 사후 감사. DB 무결성, 파일 정합성, Git 상태 확인.

**핵심 동작:**
1. 변경된 파일 리스트 받음
2. 다음 항목 체크:
   - Python 문법 (hooks 1차 + 종합 보고)
   - DB 테이블 무결성 (`PRAGMA integrity_check`)
   - bid_cost / price_adjustments JOIN 정합성
   - auth_state*.json 파일 크기 (빈 세션 검출)
   - .gitignore 위반 (auth_state 커밋 시도)
3. 위반 발견 시 즉시 작업 중단 + 사용자 보고
4. CLAUDE.md 절대 규칙 6개 위반 검사

**절대 금지:**
- 감사 결과 임의 수정 (보고만)
- 발견한 문제를 "괜찮음"으로 둔갑

**호출 조건:**
- 모든 코드/DB 변경 후
- Git commit 직전
- 마이그레이션 단계마다

**model:** `sonnet`

**참조 도구:** Read, Bash (sqlite3, git, python -c "compile()"), Glob

### 2.4 qa-validator.md

**역할:** Plan→Act→Verify→Report 루프의 Verify 단계.

**핵심 동작:**
1. 작업지시서/사용자 원 요청 + 작업 결과 받음
2. 검증 항목 추출 (요구사항 → 검증 가능한 형태)
3. 각 항목 검증 실행:
   - 코드: 단위 테스트 또는 curl API 테스트
   - DB: SELECT로 결과 확인
   - 문서: 필수 섹션 존재 확인
4. 통과/실패 매트릭스 작성
5. 실패 시 재작업 지시 또는 사용자 에스컬레이션

**절대 금지:**
- 검증 항목 임의 축소
- "동작할 것 같음" 같은 추측 보고
- 실제 실행 없이 통과 처리

**호출 조건:**
- orchestrator가 작업 완료 보고 후
- 사용자가 "검증해줘" 요청 시

**model:** `inherit`

**출력 포맷 (반드시 이 구조):**
```markdown
## QA Validation Report

### Requirements (from request)
1. ...
2. ...

### Validation Matrix
| # | Requirement | Method | Result | Evidence |
|---|---|---|---|---|
| 1 | ... | curl /api/... | ✅ PASS | 200 OK, body: {...} |
| 2 | ... | sqlite SELECT | ❌ FAIL | expected 5, got 3 |

### Verdict
- PASS / FAIL / PARTIAL
- Failed items require: <재작업 지시>
```

---

## 3. 작업 순서 (자동 진행)

각 단계 완료 후 **자동으로 다음 단계 진행**. 사용자 승인 대기 없음.

### Step A: 폴더 생성
```bash
cd ~/Desktop/kream_automation
mkdir -p .claude/agents
```

### Step B: orchestrator.md 생성
명세 2.2 따라 작성. 작성 후 자동으로 Step C 진행.

### Step C: auditor.md 생성
명세 2.3 따라 작성. 작성 후 자동으로 Step D 진행.

### Step D: qa-validator.md 생성
명세 2.4 따라 작성. 작성 후 자동으로 Step E 진행.

### Step E: 자기복제 검증 (자동)
3개 파일 자기 검증:

```bash
# 1. YAML frontmatter 검증
for f in .claude/agents/*.md; do
  echo "=== $f ==="
  head -10 "$f"
done

# 2. 필수 섹션 존재 확인 (5개 섹션 모두 있어야 함)
for f in .claude/agents/*.md; do
  count=$(grep -E "^## (역할|호출 조건|절대 금지|작업 흐름|출력 포맷)" "$f" | wc -l)
  echo "$f: $count/5 sections"
done

# 3. 길이 확인
wc -l .claude/agents/*.md

# 4. CLAUDE.md 인용 여부
grep -l "CLAUDE.md\|절대 규칙" .claude/agents/*.md
```

**검증 실패 시:** 자동으로 수정 후 재검증. 3회 시도 후에도 실패하면 사용자에게 보고하고 멈춤.

### Step F: Git 커밋 (자동)
```bash
cd ~/Desktop/kream_automation
git status
git add .claude/agents/
git commit -m "feat(agents): 검증 3종 에이전트 생성 (orchestrator, auditor, qa-validator)

- orchestrator: 작업 분배 및 조율, 직접 실행 금지
- auditor: 사후 감사 (DB/파일/Git 무결성)
- qa-validator: Plan→Act→Verify→Report 루프의 Verify 담당

다음 작업: kream-operator + infra-manager (운영 안정화 2종)
참조: AGENTS_INDEX.md v1.1, NORTH_STAR.md v1.4 원칙 6"
```

**커밋 완료 후 push 하지 말고 멈춤.** 여기서 사용자에게 종합 보고.

---

## 4. 🚦 사용자 승인 게이트 (유일한 게이트)

Step F 완료 후 다음 형식으로 사용자에게 보고:

```markdown
## ✅ 검증 3종 에이전트 생성 완료

### 생성된 파일
- .claude/agents/orchestrator.md (XX줄)
- .claude/agents/auditor.md (XX줄)
- .claude/agents/qa-validator.md (XX줄)

### 자기복제 검증 결과
- YAML frontmatter: 3/3 ✅
- 필수 섹션 (5개): 3/3 ✅
- CLAUDE.md 인용: 3/3 ✅

### Git 상태
- 커밋 해시: <hash>
- 변경 파일: 3개 신규 추가
- Push: ⏸️ 대기 중

### 발견한 이슈
(없으면 "없음")

---

**다음 작업:** GitHub로 push 하시려면 "push 진행" 이라고 답해주세요.
push 보류하시려면 "보류"라고 하시면 로컬에만 커밋된 상태로 유지됩니다.
```

사용자 응답 대기.
- `"push 진행"` → `git push origin main` 실행 후 완료 보고
- `"보류"` → 로컬 커밋만 유지 후 완료 보고
- 그 외 답변 → 다시 명확히 묻기

---

## 5. 절대 금지

1. **다른 .md 파일 수정 금지** — NORTH_STAR.md, ARCHITECTURE.md, AGENTS_INDEX.md 등 읽기만.
2. **kream_server.py / kream_bot.py / kream_dashboard.html 수정 금지**
3. **DB 조작 금지**
4. **테스트 입찰 금지**
5. **`git push -f`, `git reset --hard` 금지** (CLAUDE.md 절대 규칙 5)
6. **나머지 8개 에이전트 미리 만들지 말 것**
7. **사용자 승인 없이 GitHub push 금지** — 4번 게이트에서만

---

## 6. 자동 중단 조건 (이런 일이 생기면 멈추고 보고)

- 비전 문서 6종 중 하나라도 없음
- git status에 예상 외 변경 있음 (다른 파일이 수정 중)
- Step E 자기검증 3회 시도 실패
- syntax-check hooks 실패
- dangerous-command-check hooks 차단
- AGENTS_INDEX.md 명세와 이 지시서 내용이 충돌 (사용자 판단 필요)

---

## 7. 막힐 때 대응

- AGENTS_INDEX.md ↔ 이 지시서 충돌 → AGENTS_INDEX.md 우선, 사용자에게 보고
- NORTH_STAR.md 7원칙과 충돌 → NORTH_STAR.md 우선
- 모델 선택(sonnet/opus) 모호 → `inherit`으로 두기
- 추측 금지 → 멈추고 묻기

---

**시작 명령:** "이 작업지시서 자동 모드로 진행해줘. 마지막 push 단계에서만 멈춰."
