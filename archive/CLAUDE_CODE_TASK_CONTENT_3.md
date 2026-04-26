# Claude Code 작업지시서 — 콘텐츠 3종 Sub-Agents 생성

**작업 대상:** product-crawler + image-editor + docs-keeper
**예상 소요:** 5~10분 (자동 진행)
**작업자:** Claude Code
**승인자:** 주데이 (승주)

**🚦 사용자 승인 게이트:** 마지막 Git Push 1회만

**선행 작업:**
- 검증 3종 완료 (커밋 `aa8006a`)
- 운영 2종 완료 (커밋 `321a06c`)

---

## 진행 방식

자동 진행이 기본. **Git push 직전**에만 멈춤.

자동 안전장치:
- `.claude/hooks/syntax-check.sh`, `dangerous-command-check.sh`
- 자체 검증 (Step E)
- **신규: 5개 기존 에이전트와 일관성 점검** (Step F)

---

## 0. 사전 확인 (자동 진행)

```bash
cd ~/Desktop/kream_automation
git log -5 --oneline    # aa8006a, 321a06c 확인
ls -la .claude/agents/  # 기존 5개 파일 존재 확인
git status
```

다음 문서 읽기 (수정 금지):
1. `~/Desktop/kream_automation/AGENTS_INDEX.md` (product-crawler, image-editor, docs-keeper 명세 — 가장 중요)
2. `~/Desktop/kream_automation/NORTH_STAR.md` (7원칙, 6도메인)
3. `~/Desktop/kream_automation/ARCHITECTURE.md` (신상품 파이프라인 F→E→B)
4. `~/Desktop/kream_automation/CLAUDE.md` (절대 규칙 6개)
5. **신규 추가:** `~/Desktop/kream_automation/.claude/agents/*.md` (기존 5개 에이전트 파일) — 톤/구조/포맷 일관성 유지를 위해

읽기 완료 후 **요약 보고 없이 바로** 1번 작업 시작.

**중단 조건:**
- 기존 5개 에이전트 파일 누락/손상
- 비전 문서 누락
- git status에 예상 외 변경

---

## 1. 작업 목표

`.claude/agents/` 폴더에 다음 3개 파일 추가.

| 파일 | 도메인 | 역할 |
|---|---|---|
| `product-crawler.md` | F (신상품 수집) | 샤오홍슈 등에서 신상품 정보 수집 |
| `image-editor.md` | E (이미지 편집) | JUDAY/이승민님 이미지 자동 편집 |
| `docs-keeper.md` | (메타) | NORTH_STAR/ARCHITECTURE 등 비전 문서 관리 |

**왜 이 3개를 함께?** ARCHITECTURE.md의 신상품 파이프라인 **F→E→B** 흐름에서 F와 E를 먼저 정의하면 B(다음 그룹)의 입력 명세가 명확해짐. docs-keeper는 향후 모든 명세 변경의 단일 진실 소스 관리자.

---

## 2. 각 에이전트 파일 명세

### 2.1 공통 구조 (기존 5개와 동일)

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

### 2.2 product-crawler.md (도메인 F)

**역할:** 신상품 정보 수집 도메인 전담. 샤오홍슈/小紅書 등 외부 소스에서 트렌드/신상품 데이터 수집 및 정형화.

**관리 대상 (향후 구축):**
- 샤오홍슈 크롤러 스크립트
- 신상품 후보 DB 테이블 (제안: `product_candidates`)
- 트렌드 키워드 추적
- 이미지/영상 URL 수집 (저장은 image-editor가 담당)

**핵심 동작:**
1. 수집 요청 수신 (키워드/카테고리/기간)
2. 외부 소스 접근 (Playwright 또는 API)
3. 데이터 정제 (중복 제거, 카테고리 분류)
4. 신상품 후보 DB에 저장
5. 다음 단계(image-editor)에 핸드오프할 데이터 패키지 생성
6. auditor에게 감사 요청 (수집 실패율, 중복률 등)

**파이프라인 위치:**
- 입력: 키워드/카테고리/소스 URL
- 출력: 신상품 후보 데이터 (이미지 URL 포함) → image-editor 입력으로 전달

**절대 금지:**
1. 외부 사이트 robots.txt / Terms of Service 위반
2. 과도한 요청 빈도 (rate limiting 무시)
3. 수집 실패 시 가짜 데이터 생성 (KREAM 도메인의 "수집 실패 폴백 금지" 원칙 동일 적용)
4. 저작권 보호 콘텐츠 무단 다운로드/저장
5. 사용자 인증 정보(소셜 계정) 코드에 하드코딩
6. 사용자 승인 없이 외부 API 결제

**호출 조건:**
- 신상품 발굴 요청
- 트렌드 키워드 분석 요청
- 샤오홍슈 등 외부 소스 데이터 수집

**model:** `sonnet` (수집은 빠른 처리가 중요)

**참조 도구:** Read, Edit, Write, Bash, WebFetch, Playwright

**출력 포맷:**
```markdown
## Product Crawler Report

### Source
- 소스: <샤오홍슈/...>
- 키워드: <...>
- 수집 기간: <...>

### Results
- 수집 시도: <건수>
- 수집 성공: <건수>
- 중복 제거 후: <건수>
- 신규 후보: <건수>

### Quality
- 이미지 URL 유효율: <%>
- 가격 데이터 존재율: <%>

### Handoff to Next Stage
- 다음: image-editor에게 <건수> 건 핸드오프
- 핸드오프 형식: <JSON 경로 또는 DB 테이블>

### Issues
<수집 실패 항목 목록 — 가짜 데이터 절대 금지>
```

### 2.3 image-editor.md (도메인 E)

**역할:** 이미지 자동 편집 도메인 전담. JUDAY/이승민님 이미지 처리 표준화.

**관리 대상 (향후 구축):**
- 이미지 편집 스크립트 (배경 제거, 워터마크, 리사이즈, 누끼 등)
- 편집 템플릿 (브랜드별/카테고리별)
- 이미지 저장소 (로컬 파일 시스템 + 클라우드)
- 처리 이력 DB

**핵심 동작:**
1. 편집 요청 수신 (이미지 URL/파일 경로 + 편집 옵션)
2. 원본 이미지 다운로드/로드
3. 편집 파이프라인 실행:
   - 배경 처리 (제거/교체/유지)
   - 리사이즈 (채널별 규격)
   - 워터마크 추가/제거
   - 색상 보정
4. 편집 결과 저장 (원본 보존 필수)
5. 다음 단계(SSRO/멀티채널)에 핸드오프
6. auditor에게 감사 요청

**파이프라인 위치:**
- 입력: product-crawler 또는 사용자 직접 업로드
- 출력: 편집된 이미지 → ssro-channel-operator 입력으로 전달 (다음 그룹에서 정의)

**절대 금지:**
1. 원본 이미지 덮어쓰기/삭제 (백업 폴더 필수)
2. 저작권 보호 이미지 변형 후 자사 콘텐츠로 발행
3. 인물 사진의 무단 변형 (얼굴 합성 등)
4. 채널 이미지 규격 임의 변경
5. 편집 이력 미기록 (모든 처리는 추적 가능해야 함)
6. JUDAY 브랜드 가이드라인 위반

**호출 조건:**
- 이미지 편집 요청
- product-crawler가 수집한 이미지 처리
- 채널별 이미지 규격 변환

**model:** `sonnet` (이미지 처리는 정밀함보다 처리량)

**참조 도구:** Read, Edit, Write, Bash (PIL/Pillow, ImageMagick 등)

**출력 포맷:**
```markdown
## Image Editor Report

### Input
- 소스: <product-crawler / 사용자 직접 업로드>
- 이미지 수: <건수>
- 평균 크기: <KB>

### Pipeline
- 배경 처리: <옵션>
- 리사이즈: <대상 규격>
- 워터마크: <yes/no>

### Results
- 성공: <건수>
- 실패: <건수>
- 출력 경로: <폴더>
- 원본 백업: <폴더>

### Handoff
- 다음: ssro-channel-operator (또는 사용자 검토)
- 형식: <폴더 경로 + 메타데이터 JSON>
```

### 2.4 docs-keeper.md (메타)

**역할:** 비전 문서 단일 진실 소스 관리자. 모든 .md 비전 문서의 정합성 보장.

**관리 대상:**
- `~/Desktop/kream_automation/NORTH_STAR.md`
- `~/Desktop/kream_automation/ARCHITECTURE.md`
- `~/Desktop/kream_automation/AGENTS_INDEX.md`
- `~/Desktop/kream_automation/MIGRATION_PLAN.md`
- `~/Desktop/kream_automation/VERIFICATION_PROTOCOL.md`
- `~/Desktop/kream_automation/OBSERVABILITY.md`
- `~/Desktop/kream_automation/CLAUDE.md`
- `~/Desktop/kream_automation/KREAM_인수인계서_v*.md`

**핵심 동작:**
1. 비전 문서 변경 요청 수신
2. 변경 영향도 분석:
   - 어떤 다른 문서/에이전트와 충돌하는가?
   - 7원칙과 모순되는가?
   - 6도메인 정의와 일치하는가?
3. 변경 전 백업 (git stash 또는 .bak)
4. 변경 적용
5. 정합성 재검사:
   - AGENTS_INDEX.md ↔ .claude/agents/*.md 일치
   - ARCHITECTURE.md ↔ 실제 구현 일치 (가능한 부분)
   - NORTH_STAR.md ↔ 모든 하위 문서 일치
6. 버전 번호 갱신 (예: v1.1 → v1.2)
7. 변경 이력 기록 (문서 하단 changelog 섹션)
8. auditor에게 감사 요청

**문서 우선순위 (충돌 시):**
1. NORTH_STAR.md (최상위 — 7원칙, 6도메인)
2. ARCHITECTURE.md (시스템 구조)
3. AGENTS_INDEX.md (에이전트 명세)
4. MIGRATION_PLAN.md, VERIFICATION_PROTOCOL.md, OBSERVABILITY.md
5. KREAM_인수인계서_v*.md (운영 사실은 우선순위 다름 — 실제 운영 내용은 인수인계서가 우선)

**절대 금지:**
1. 비전 문서를 사용자 승인 없이 수정 (모든 수정은 명시적 요청 필수)
2. 7원칙 변경 (사용자만 변경 가능)
3. 6도메인 정의 변경 (사용자만 변경 가능)
4. 버전 번호 누락
5. changelog 미기록
6. 백업 없이 수정
7. AGENTS_INDEX.md와 .claude/agents/ 폴더 간 불일치 방치
8. 인수인계서 내용 임의 수정 (운영 사실 기반이므로 사용자 확인 필수)

**호출 조건:**
- 비전 문서 수정 요청
- 새 에이전트 추가 시 AGENTS_INDEX.md 갱신
- 새 도메인 추가 시 NORTH_STAR.md / ARCHITECTURE.md 갱신
- 7원칙/6도메인 점검 요청
- 문서 간 정합성 점검

**model:** `opus` (문서 관리는 신중한 판단 필요)

**참조 도구:** Read, Edit, Write, Bash, Grep, Glob

**출력 포맷:**
```markdown
## Docs Keeper Report

### Change Request
- 대상 문서: <파일명>
- 변경 유형: <추가/수정/삭제>
- 사용자 승인: <yes/no — no면 작업 거부>

### Impact Analysis
- 영향 받는 다른 문서: <목록>
- 영향 받는 에이전트: <목록>
- 7원칙 충돌: <yes/no>
- 6도메인 충돌: <yes/no>

### Backup
- 백업 경로: <...>
- 이전 버전: <v1.1>

### Action
<변경 상세>

### Post-change Verification
- 문서 간 정합성: <PASS/FAIL>
- AGENTS_INDEX ↔ agents/ 일치: <PASS/FAIL>
- 새 버전: <v1.2>

### Changelog Entry
<문서 하단에 추가된 changelog>
```

---

## 3. 작업 순서 (자동 진행)

### Step A: 폴더 확인
`.claude/agents/` 폴더에 5개 파일 확인 (기존 검증 3종 + 운영 2종).

### Step B: product-crawler.md 생성
명세 2.2 따라. 자동 진행.

### Step C: image-editor.md 생성
명세 2.3 따라. 자동 진행.

### Step D: docs-keeper.md 생성
명세 2.4 따라. 자동 진행.

### Step E: 자체 검증 (자동)

```bash
# 1. YAML frontmatter
for f in .claude/agents/product-crawler.md .claude/agents/image-editor.md .claude/agents/docs-keeper.md; do
  echo "=== $f ==="
  head -10 "$f"
done

# 2. 필수 섹션 5개
for f in .claude/agents/product-crawler.md .claude/agents/image-editor.md .claude/agents/docs-keeper.md; do
  count=$(grep -E "^## (역할|호출 조건|절대 금지|작업 흐름|출력 포맷)" "$f" | wc -l)
  echo "$f: $count/5 sections"
done

# 3. 길이 확인
wc -l .claude/agents/product-crawler.md .claude/agents/image-editor.md .claude/agents/docs-keeper.md

# 4. 도메인별 핵심 키워드
echo "=== product-crawler 키워드 ==="
grep -c "수집\|크롤\|샤오홍슈\|핸드오프" .claude/agents/product-crawler.md

echo "=== image-editor 키워드 ==="
grep -c "이미지\|편집\|JUDAY\|원본" .claude/agents/image-editor.md

echo "=== docs-keeper 키워드 ==="
grep -c "비전\|버전\|changelog\|정합성" .claude/agents/docs-keeper.md

# 5. CLAUDE.md 인용
grep -l "CLAUDE.md\|절대 규칙" .claude/agents/product-crawler.md .claude/agents/image-editor.md .claude/agents/docs-keeper.md
```

### Step F: 8개 에이전트 통합 일관성 점검 (자동)

```bash
# 모든 8개 에이전트 파일의 섹션 헤더 일관성
for f in .claude/agents/*.md; do
  echo "=== $(basename $f) ==="
  grep "^## " "$f"
  echo ""
done

# 모든 파일이 동일한 섹션 구조여야 함
# 8개 파일이 모두 5개 섹션을 가지고 있는지 확인
total=$(ls .claude/agents/*.md | wc -l)
echo "총 에이전트 파일: $total / 8"
```

**검증 실패 시:** 자동 수정 후 재검증. 3회 실패 시 사용자 보고.

### Step G: Git 커밋 (자동)
```bash
cd ~/Desktop/kream_automation
git add .claude/agents/product-crawler.md .claude/agents/image-editor.md .claude/agents/docs-keeper.md
git commit -m "feat(agents): 콘텐츠 3종 에이전트 생성 (product-crawler, image-editor, docs-keeper)

- product-crawler: 도메인 F (신상품 수집)
  - 샤오홍슈 등 외부 소스 데이터 수집/정형화
  - rate limiting, 저작권, 가짜 데이터 금지
- image-editor: 도메인 E (이미지 편집)
  - 원본 보존 필수, 편집 이력 추적
  - 인물 무단 변형 금지, 브랜드 가이드라인 준수
- docs-keeper: 메타 (비전 문서 단일 진실 소스)
  - 7원칙/6도메인 변경은 사용자만 가능
  - changelog 필수, 버전 관리

신상품 파이프라인 F→E→B의 F, E 정의 완료.
다음 작업: 확장 운영 3종 (ssro-channel-operator, cs-drafter, dashboard-builder)
참조: AGENTS_INDEX.md v1.1, ARCHITECTURE.md (파이프라인 F→E→B)"
```

**커밋 완료 후 push 하지 말고 멈춤.**

---

## 4. 🚦 사용자 승인 게이트 (유일한 게이트)

Step G 완료 후 종합 보고:

```markdown
## ✅ 콘텐츠 3종 에이전트 생성 완료

### 생성된 파일
- .claude/agents/product-crawler.md (XX줄)
- .claude/agents/image-editor.md (XX줄)
- .claude/agents/docs-keeper.md (XX줄)

### 자체 검증 결과
- YAML frontmatter: 3/3 ✅
- 필수 섹션 (5개): 3/3 ✅
- 도메인별 핵심 키워드: 3/3 ✅
- CLAUDE.md 인용: 3/3 ✅

### 8개 에이전트 통합 일관성
- 섹션 구조 일치: 8/8 ✅
- 톤/포맷 일치: ✅

### 현재 .claude/agents/ 상태
- 8개 파일 (검증 3종 + 운영 2종 + 콘텐츠 3종)
- 남은 작업: 확장 운영 3종 (ssro-channel-operator, cs-drafter, dashboard-builder)

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

1. **운영 코드 수정 금지**
2. **기존 5개 에이전트 파일 수정 금지** — 읽기만
3. **비전 문서(NORTH_STAR.md 등) 수정 금지** — docs-keeper도 이번엔 정의만, 실제 문서 수정 안 함
4. **last_sale 60시간 이슈 점검 금지** — 별도 작업
5. **확장 운영 3종 미리 만들지 말 것** — 다음 마일스톤
6. **샤오홍슈 등 외부 사이트 실제 크롤링 금지** — 명세만 작성, 실행은 다음 작업
7. **이미지 편집 스크립트 실제 작성 금지** — 명세만 작성
8. **사용자 승인 없이 push 금지**

---

## 6. 자동 중단 조건

- 기존 5개 에이전트 파일 누락
- AGENTS_INDEX.md 명세와 이 지시서 충돌
- git status에 예상 외 변경
- Step E 자체 검증 3회 실패
- Step F 8개 일관성 점검 실패 (8개가 모두 같은 구조 아님)
- syntax-check / dangerous-command 차단

---

## 7. 막힐 때 대응

- AGENTS_INDEX.md ↔ 이 지시서 충돌 → AGENTS_INDEX.md 우선
- NORTH_STAR.md 7원칙과 충돌 → NORTH_STAR.md 우선
- ARCHITECTURE.md 파이프라인 정의와 충돌 → ARCHITECTURE.md 우선
- 모델 선택 모호 → 권장값 (product-crawler: sonnet, image-editor: sonnet, docs-keeper: opus)
- 추측 금지 → 멈추고 묻기

---

**시작 명령:** "이 작업지시서 자동 모드로 진행해줘. 마지막 push 단계에서만 멈춰."
