# Claude Code 작업지시서 — 운영 2종 Sub-Agents 생성 (간소화)

**작업 대상:** kream-operator + infra-manager
**예상 소요:** 5~10분 (자동 진행)
**작업자:** Claude Code
**승인자:** 주데이 (승주)

**🚦 사용자 승인 게이트:** 마지막 Git Push 1회만

**선행 작업:** 검증 3종 완료 (커밋 `aa8006a`)

---

## 진행 방식

자동 진행이 기본. **Git push 직전**에만 멈춤.

자동 안전장치:
- `.claude/hooks/syntax-check.sh`, `dangerous-command-check.sh`
- 자기복제 검증(Step F)
- **신규: 검증 3종 활용** — 작성된 파일을 qa-validator 명세에 맞춰 자체 검증

---

## 0. 사전 확인 (자동 진행)

```bash
cd ~/Desktop/kream_automation
git log -3 --oneline   # aa8006a 확인
ls -la .claude/agents/  # 검증 3종 파일 존재 확인
git status
```

다음 문서 읽기 (수정 금지):
1. `~/Desktop/kream_automation/AGENTS_INDEX.md` (kream-operator, infra-manager 명세 — 가장 중요)
2. `~/Desktop/kream_automation/NORTH_STAR.md` (7원칙)
3. `~/Desktop/kream_automation/ARCHITECTURE.md`
4. `~/Desktop/kream_automation/CLAUDE.md` (절대 규칙 6개)
5. **신규 추가:** `~/Desktop/kream_automation/.claude/agents/orchestrator.md`, `auditor.md`, `qa-validator.md` — 일관성 유지를 위해 검증 3종의 구조/톤 확인

읽기 완료 후 **요약 보고 없이 바로** 1번 작업 시작.

**중단 조건:**
- 검증 3종 파일이 없거나 손상됨
- 비전 문서 누락
- git status에 예상 외 변경

---

## 1. 작업 목표

`.claude/agents/` 폴더에 다음 2개 파일 추가.

| 파일 | 역할 |
|---|---|
| `kream-operator.md` | KREAM 도메인 전담 (입찰/가격조정/판매수집/원가관리) |
| `infra-manager.md` | 서버/스케줄러/DB/인증 인프라 관리 |

**왜 이 2개를 다음에?** 현재 운영 중인 KREAM 시스템을 안정화하는 핵심. 다른 도메인(SSRO, CS, 이미지 등)은 아직 미구축이지만 KREAM은 즉시 활용 가능.

---

## 2. 각 에이전트 파일 명세

### 2.1 공통 구조 (검증 3종과 동일)

```yaml
---
name: <agent-name>
description: <한 줄 설명>
model: <inherit | sonnet | opus>
tools: <도구 목록 또는 inherit>
---

# <Agent Display Name>

## 역할 (Mission)
## 호출 조건 (When to invoke)
## 절대 금지 (Never do)
## 작업 흐름 (Workflow)
## 출력 포맷 (Output format)
## 인용/참조 문서
```

**AGENTS_INDEX.md v1.1 명세와 충돌 시 AGENTS_INDEX.md 우선.**

### 2.2 kream-operator.md

**역할:** KREAM 판매자센터 운영 전담. 입찰/가격조정/판매수집/원가관리 도메인 책임자.

**관리 대상 (KREAM 인수인계서 v5 기준):**
- `kream_server.py` (Flask, 6,835줄)
- `kream_bot.py` (Playwright, 2,905줄)
- `kream_collector.py` (가격 수집, 1,275줄)
- `kream_adjuster.py` (가격 조정, 600줄)
- `competitor_analysis.py`
- `tab_*.html` (대시보드 탭들)
- `price_history.db` (17개 테이블)
- `auth_state.json`, `auth_state_kream.json`
- `settings.json`, `queue_data.json`, `my_bids_local.json`

**핵심 동작:**
1. KREAM 도메인 작업 요청 수신 (입찰, 가격 조정, 판매 수집, 원가 등)
2. 작업 전 현재 상태 진단:
   - `/api/health` 호출
   - 인증 상태 (auth_state.json 유효성)
   - 스케줄러 상태 (입찰 모니터링, 판매 수집)
   - DB 무결성 (`PRAGMA integrity_check`)
3. 작업 실행 (코드 수정/스크립트 실행/DB 조회)
4. 작업 후 auditor에게 감사 요청
5. qa-validator에게 검증 요청
6. 결과 보고

**입찰 전략 (확정 운영 규칙 — 절대 임의 변경 금지):**
- 사이즈당 2건 유지
- 마진 하한 4,000원 (예상 수익 미달 시 수정 없이 알림만)
- 언더컷 1,000원 (settings.json 참조)
- 입찰가는 항상 1,000원 단위 올림 (`math.ceil(price/1000)*1000`)

**원가 계산식 (절대 변경 금지):**
- `CNY × 환율 × 1.03(송금 수수료) + 8,000원(배송비)`
- 관부가세는 고객 부담, 원가에서 제외
- 판매수수료 6% (보수적 추정)
- 정산액 = 판매가 × (1 - 수수료율 × 1.1) - 2,500
- 예상수익 = 정산액 - 원가 (원가 없으면 NULL, 가짜 값 금지)

**절대 금지 (CLAUDE.md 절대 규칙 + KREAM 특화):**
1. 원가 없이 가짜 값 사용 금지 → NULL
2. 판매 완료 건 수정/삭제 금지
3. `price_history.db` 직접 DROP/DELETE 금지
4. `auth_state.json` 백업 없이 덮어쓰기 금지 (실패 시 절대 빈 세션 저장 금지)
5. 테스트 데이터로 실제 입찰 금지
6. KREAM 사이트 봇 감지 우회 설정 변경 금지 (`channel="chrome"`, playwright-stealth 필수)
7. 입찰 전략(2건/4000원/1000원) 사용자 승인 없이 변경 금지

**호출 조건:**
- 입찰/가격조정/판매수집/원가 관련 작업
- KREAM 대시보드 UI 수정
- `kream_*.py` 파일 수정
- `price_history.db` 데이터 작업
- KREAM 인증/세션 관련 이슈

**model:** `opus` (KREAM은 운영 중이라 신중한 판단 필요)

**참조 도구:** Read, Edit, Write, Bash, Grep, Glob

**출력 포맷:**
```markdown
## KREAM Operator Report

### Pre-flight Diagnosis
- /api/health: <status>
- auth (partner): <valid/expired>
- auth (kream): <valid/expired>
- 스케줄러 (모니터링): <running/stopped>
- 스케줄러 (판매수집): <running/stopped>
- DB integrity: <ok/issue>

### Action Taken
<작업 상세>

### Post-flight Verification
- auditor 감사: <PASS/FAIL>
- qa-validator 검증: <PASS/FAIL>

### Impact
- 영향 받는 입찰/판매: <건수>
- 새 데이터: <건수>
```

### 2.3 infra-manager.md

**역할:** 서버/스케줄러/DB/인증/외부연동 인프라 관리. 도메인 로직은 다루지 않음.

**관리 대상:**
- Flask 서버 프로세스 (포트 5001)
- 스케줄러 (입찰 모니터링, 판매 수집, 헬스체크 경보, 자동 가격조정, 일일 백업, 환율 갱신)
- `price_history.db` 인프라 (WAL 모드, 백업, 무결성)
- 인증 (`auth_state*.json`, Gmail IMAP, 네이버 OAuth, KREAM 판매자센터 OTP)
- Cloudflare Tunnel
- 환율 API (open.er-api.com)
- `.gitignore`, `settings.json` 인프라 항목
- `.claude/hooks/`, `.claude/skills/`

**핵심 동작:**
1. 인프라 작업 요청 수신
2. 영향도 사전 평가 (얼마나 많은 도메인에 영향?)
3. 백업 (DB, auth_state, settings.json 변경 전 필수)
4. 작업 실행
5. 헬스체크 + 스케줄러 상태 확인
6. 롤백 가능성 점검
7. auditor + qa-validator 호출

**스케줄러 일정 (변경 시 사용자 승인):**
| 스케줄러 | 간격 |
|---|---|
| 입찰 순위 모니터링 | 8,10,12,14,16,18,20,22시 |
| 판매 수집 | 30분 ±5분 지터 |
| 환율 자동 조회 | 서버 시작 시 1회 |
| 헬스체크 경보 | 5분 간격 |
| 언더컷 자동 방어 | 모니터링 직후 |

**서버 재시작 표준 패턴 (kill -9 직후 죽는 이슈 방지):**
```bash
lsof -ti:5001 | xargs kill -9 2>/dev/null
sleep 2
cd ~/Desktop/kream_automation
nohup python3 kream_server.py > server.log 2>&1 &
disown
sleep 3
curl -s http://localhost:5001/api/health | head -20
```

**절대 금지:**
1. `price_history.db` 백업 없이 ALTER TABLE
2. `auth_state*.json` 빈 세션으로 덮어쓰기 (KREAM 인수인계서 v5의 절대 규칙)
3. SQLite WAL 모드 해제
4. `.gitignore`에서 `auth_state*.json` 제거
5. `git push -f`, `git reset --hard` (CLAUDE.md 절대 규칙 5)
6. 스케줄러 일정 사용자 승인 없이 변경
7. 외부 의존 서비스(Cloudflare Tunnel, 환율 API)에 직접 결제 정보 입력
8. 사무실 iMac과 맥북 동시 편집 (iCloud 충돌)

**호출 조건:**
- 서버 재시작/포트 이슈
- DB 마이그레이션/백업/복구
- 스케줄러 추가/수정/일정 변경
- 인증 만료/갱신
- Cloudflare Tunnel 이슈
- 환율 갱신 이슈
- `.claude/` 폴더 hooks/skills 추가

**model:** `sonnet` (인프라는 빠른 진단이 중요)

**참조 도구:** Read, Edit, Write, Bash, Grep

**출력 포맷:**
```markdown
## Infra Manager Report

### Affected Components
- 서버: <on/off>
- DB: <table.column 변경 여부>
- 스케줄러: <변경 항목>
- 인증: <변경 항목>

### Backup Created
- DB: <경로/시각>
- auth_state: <경로/시각>
- settings.json: <경로/시각>

### Action Taken
<작업 상세>

### Post-action Health
- /api/health: <status>
- 스케줄러 2개 running 확인: <yes/no>
- 인증 2개 valid 확인: <yes/no>

### Rollback Plan
<롤백 방법>
```

---

## 3. 작업 순서 (자동 진행)

### Step A: 폴더 확인
`.claude/agents/` 폴더는 이미 있음. 확인만.

### Step B: kream-operator.md 생성
명세 2.2 따라 작성. 자동으로 Step C 진행.

### Step C: infra-manager.md 생성
명세 2.3 따라 작성. 자동으로 Step D 진행.

### Step D: 검증 3종 활용 자체 검증 (자동)
이번엔 검증 3종이 이미 있으므로 그 명세를 활용해 자체 검증.

```bash
# 1. YAML frontmatter 검증
for f in .claude/agents/kream-operator.md .claude/agents/infra-manager.md; do
  echo "=== $f ==="
  head -10 "$f"
done

# 2. 필수 섹션 5개 존재 확인
for f in .claude/agents/kream-operator.md .claude/agents/infra-manager.md; do
  count=$(grep -E "^## (역할|호출 조건|절대 금지|작업 흐름|출력 포맷)" "$f" | wc -l)
  echo "$f: $count/5 sections"
done

# 3. 길이 확인
wc -l .claude/agents/kream-operator.md .claude/agents/infra-manager.md

# 4. 핵심 도메인 키워드 존재 확인
echo "=== kream-operator 핵심 키워드 ==="
grep -c "입찰\|원가\|bid_cost\|판매" .claude/agents/kream-operator.md

echo "=== infra-manager 핵심 키워드 ==="
grep -c "스케줄러\|auth_state\|백업\|WAL" .claude/agents/infra-manager.md

# 5. CLAUDE.md 인용 여부
grep -l "CLAUDE.md\|절대 규칙" .claude/agents/kream-operator.md .claude/agents/infra-manager.md
```

**검증 실패 시:** 자동 수정 후 재검증. 3회 실패 시 사용자 보고.

### Step E: 검증 3종 통합 점검 (자동)
운영 2종이 검증 3종과 일관된 톤/구조인지 확인:

```bash
# 모든 에이전트 파일의 섹션 헤더 일관성
for f in .claude/agents/*.md; do
  echo "=== $(basename $f) ==="
  grep "^## " "$f"
  echo ""
done
```

5개 파일 모두 동일한 섹션 구조여야 함.

### Step F: Git 커밋 (자동)
```bash
cd ~/Desktop/kream_automation
git add .claude/agents/kream-operator.md .claude/agents/infra-manager.md
git commit -m "feat(agents): 운영 2종 에이전트 생성 (kream-operator, infra-manager)

- kream-operator: KREAM 도메인 전담 (입찰/가격조정/판매수집/원가)
  - 입찰 전략 확정 규칙 명시 (2건/4000원/1000원)
  - 원가 계산식 고정 (CNY×환율×1.03+8000)
  - 7가지 절대 금지 규칙
- infra-manager: 서버/스케줄러/DB/인증 인프라
  - 서버 재시작 표준 패턴 (nohup+disown)
  - 백업 필수화
  - 8가지 절대 금지 규칙

다음 작업: 확장 6종 (cs-drafter, ssro-channel-operator, dashboard-builder,
  image-editor, product-crawler, docs-keeper)
참조: AGENTS_INDEX.md v1.1, KREAM 인수인계서 v5"
```

**커밋 완료 후 push 하지 말고 멈춤.**

---

## 4. 🚦 사용자 승인 게이트 (유일한 게이트)

Step F 완료 후 종합 보고:

```markdown
## ✅ 운영 2종 에이전트 생성 완료

### 생성된 파일
- .claude/agents/kream-operator.md (XX줄)
- .claude/agents/infra-manager.md (XX줄)

### 자체 검증 결과
- YAML frontmatter: 2/2 ✅
- 필수 섹션 (5개): 2/2 ✅
- 핵심 키워드 존재: 2/2 ✅
- CLAUDE.md 인용: 2/2 ✅

### 검증 3종과의 일관성
- 섹션 구조 일치: ✅
- 톤/포맷 일치: ✅

### 현재 .claude/agents/ 상태
- 5개 파일 (검증 3종 + 운영 2종)
- 남은 작업: 확장 6종

### Git 상태
- 커밋 해시: <hash>
- Push: ⏸️ 대기 중

### 발견한 이슈
(없으면 "없음")

---

**push 진행** / **보류**?
```

사용자 응답 대기.

---

## 5. 절대 금지

1. **운영 코드 수정 금지** — `kream_server.py`, `kream_bot.py`, `kream_dashboard.html`, DB 등 일체 손대지 말 것. 이번엔 .md 파일 2개만 추가.
2. **검증 3종 파일 수정 금지** — 이미 커밋된 검증 3종은 읽기만.
3. **AGENTS_INDEX.md, NORTH_STAR.md 등 비전 문서 수정 금지**
4. **last_sale 60시간 이슈 점검 금지** — 별도 작업으로 분리됨
5. **확장 6종 미리 만들지 말 것** — 다음 마일스톤
6. **테스트 입찰/실제 데이터 변경 금지**
7. **사용자 승인 없이 push 금지**

---

## 6. 자동 중단 조건

- 검증 3종 파일이 없거나 손상
- AGENTS_INDEX.md 명세와 이 지시서 충돌
- git status에 예상 외 변경
- Step D 자체 검증 3회 실패
- syntax-check / dangerous-command 차단
- 섹션 구조가 검증 3종과 다름 (Step E 실패)

---

## 7. 막힐 때 대응

- AGENTS_INDEX.md ↔ 이 지시서 충돌 → AGENTS_INDEX.md 우선
- KREAM 인수인계서 v5 ↔ AGENTS_INDEX.md 충돌 → KREAM 인수인계서 우선 (운영 사실)
- NORTH_STAR.md 7원칙과 충돌 → NORTH_STAR.md 우선
- 모델 선택 모호 → 권장값 사용 (kream-operator: opus, infra-manager: sonnet)
- 추측 금지 → 멈추고 묻기

---

**시작 명령:** "이 작업지시서 자동 모드로 진행해줘. 마지막 push 단계에서만 멈춰."
