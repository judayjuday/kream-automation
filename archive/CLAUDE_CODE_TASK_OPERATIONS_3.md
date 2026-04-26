# Claude Code 작업지시서 — 확장 운영 3종 Sub-Agents 생성 (마지막 그룹)

**작업 대상:** ssro-channel-operator + cs-drafter + dashboard-builder
**예상 소요:** 5~10분 (자동 진행)
**작업자:** Claude Code
**승인자:** 주데이 (승주)

**🚦 사용자 승인 게이트:** 마지막 Git Push 1회만

**선행 작업:**
- 검증 3종 완료 (커밋 `aa8006a`)
- 운영 2종 완료 (커밋 `321a06c`)
- 콘텐츠 3종 완료 (커밋 `3fb16e7`)

**🎉 이번 작업으로 11개 에이전트 시스템 완성**

---

## 진행 방식

자동 진행이 기본. **Git push 직전**에만 멈춤.

이번 작업의 특별한 점:
- **마지막 그룹** — 11개 에이전트 시스템 완성
- **신상품 파이프라인 F→E→B 완전체** — B(SSRO 멀티채널) 정의로 흐름 마무리
- **운영 시스템 완성** — KREAM(A) + SSRO(B) + CS(C) + 대시보드(D) + 이미지(E) + 크롤링(F) 6개 도메인 모두 에이전트 보유
- **Step F에서 11개 에이전트 전체 일관성 최종 점검**

---

## 0. 사전 확인 (자동 진행)

```bash
cd ~/Desktop/kream_automation
git log -7 --oneline    # aa8006a, 321a06c, 3fb16e7 확인
ls -la .claude/agents/  # 기존 8개 파일 존재 확인
git status
```

다음 문서 읽기 (수정 금지):
1. `~/Desktop/kream_automation/AGENTS_INDEX.md` (ssro-channel-operator, cs-drafter, dashboard-builder 명세)
2. `~/Desktop/kream_automation/NORTH_STAR.md` (7원칙, 6도메인)
3. `~/Desktop/kream_automation/ARCHITECTURE.md` (신상품 파이프라인, 통합 대시보드 구조)
4. `~/Desktop/kream_automation/CLAUDE.md` (절대 규칙 6개)
5. `~/Desktop/kream_automation/.claude/agents/*.md` (기존 8개 에이전트 — 일관성 유지)

읽기 완료 후 **요약 보고 없이 바로** 1번 작업 시작.

**중단 조건:**
- 기존 8개 에이전트 파일 누락
- 비전 문서 누락
- git status에 예상 외 변경

---

## 1. 작업 목표

`.claude/agents/` 폴더에 다음 3개 파일 추가.

| 파일 | 도메인 | 역할 |
|---|---|---|
| `ssro-channel-operator.md` | B (멀티채널 판매) | 자사몰+에이블리+지그재그+크로켓+네이버 운영 |
| `cs-drafter.md` | C (CS 자동화) | 일 50~100건 CS 답변 초안 작성 |
| `dashboard-builder.md` | D (통합 대시보드) | 도메인별 데이터 통합 대시보드 |

**왜 마지막에?** 외부 채널 의존성이 가장 많아 안정화 필요. 다른 8개 에이전트가 먼저 정의되어야 입력/출력이 명확해짐.

---

## 2. 각 에이전트 파일 명세

### 2.1 공통 구조 (기존 8개와 동일)

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

### 2.2 ssro-channel-operator.md (도메인 B)

**역할:** 자사몰 SSRO + 외부 채널(에이블리/지그재그/크로켓/네이버) 멀티채널 운영. 의류/가방/잡화 카테고리 담당.

**관리 대상 (향후 구축):**
- 자사몰 SSRO 관리 시스템
- 채널별 상품 등록 자동화
- 채널별 가격/재고 동기화
- 주문 통합 수집
- 정산 데이터 통합
- 채널별 인증/세션 관리

**파이프라인 위치:**
- 입력: image-editor 출력 (편집된 이미지) + product-crawler 출력 (상품 정보)
- 출력: 채널별 등록 결과 → dashboard-builder로 통합 보고

**채널별 특성 (각각 별도 처리 필요):**
- **자사몰 SSRO**: 마스터 데이터, 가격 결정 권한
- **에이블리**: 의류/잡화 강세, 빠른 등록
- **지그재그**: 의류 중심, 트렌드 민감
- **크로켓**: 잡화/소품
- **네이버 스마트스토어**: 검색 노출, 광고 연동

**핵심 동작:**
1. 멀티채널 작업 요청 수신
2. 채널별 사전 진단:
   - 인증 상태 확인
   - 재고/가격 동기화 상태
   - 미처리 주문 건수
3. 작업 실행 (등록/수정/주문수집/재고동기화)
4. 채널 간 데이터 충돌 검사 (가격/재고)
5. auditor에게 감사 요청
6. dashboard-builder에게 통합 보고

**절대 금지:**
1. 채널 간 가격 임의 차등 (사용자 정책 없이) — 가격 정책은 사용자 결정
2. 자사몰 마스터 데이터를 외부 채널 데이터로 덮어쓰기
3. 주문 데이터 임의 수정/삭제
4. 채널 인증 정보 평문 저장
5. 채널 API rate limit 무시
6. 카테고리 임의 변경 (의류 → 잡화 등)
7. 정산 데이터 임의 수정
8. 사용자 승인 없이 자동 발송

**호출 조건:**
- 신상품 채널 등록 (image-editor 핸드오프 후)
- 멀티채널 가격/재고 동기화
- 주문 수집
- 채널별 정산 점검
- 채널 인증 갱신

**model:** `opus` (멀티채널은 사고 시 영향 범위 큼)

**참조 도구:** Read, Edit, Write, Bash, Playwright, WebFetch

**출력 포맷:**
```markdown
## SSRO Channel Operator Report

### Channel Status
- 자사몰 SSRO: <상태>
- 에이블리: <상태>
- 지그재그: <상태>
- 크로켓: <상태>
- 네이버: <상태>

### Action Taken
- 채널: <채널명>
- 작업: <등록/수정/주문수집/...>
- 영향 상품: <건수>

### Cross-channel Consistency
- 가격 동기화: <PASS/FAIL>
- 재고 동기화: <PASS/FAIL>
- 충돌 항목: <목록>

### Handoff to Dashboard
- dashboard-builder에게 통합 보고 전달
```

### 2.3 cs-drafter.md (도메인 C)

**역할:** CS 답변 초안 작성. 일 50~100건 처리. **자동 발송 절대 금지 — 항상 사용자 승인 필요**.

**관리 대상 (향후 구축):**
- 채널별 CS 인박스 (KREAM/자사몰/에이블리/지그재그/크로켓/네이버)
- FAQ 데이터베이스
- 답변 템플릿
- 고객 응대 이력
- 에스컬레이션 룰 (이런 경우 사람이 직접 처리)

**핵심 동작:**
1. CS 인박스 수신
2. 분류:
   - 단순 문의 (배송/교환/반품 절차)
   - 복잡 문의 (불량/하자/환불)
   - 클레임 (감정적 표현/법적 위협)
   - 칭찬/리뷰
3. 카테고리별 초안 작성:
   - 단순: 템플릿 + 주문 정보 자동 채우기
   - 복잡: 가이드라인 기반 + 사용자 검토 강조
   - 클레임: **에스컬레이션 — 사람 직접 처리 권장**
   - 칭찬: 감사 답변 초안
4. 각 초안에 신뢰도 점수 부여 (자동 발송 절대 안 함, 사용자 검토용)
5. 사용자 검토 인터페이스로 전달
6. 사용자 승인된 답변만 발송

**절대 금지:**
1. **자동 발송 절대 금지** — 모든 답변은 사용자 승인 필수
2. 환불/교환 약속 (사용자 정책 권한)
3. 가격 할인/쿠폰 발행 (사용자 권한)
4. 불량 인정 (사용자 판단 권한)
5. 법적 표현 사용 ("법적 책임", "소송" 등)
6. 고객 정보 외부 공유
7. 클레임 답변을 자동으로 작성 (반드시 에스컬레이션)
8. 욕설/감정적 표현 응대 (반드시 사람 처리)

**호출 조건:**
- 새 CS 문의 수신
- 사용자가 "CS 답변 초안 만들어줘" 요청
- FAQ 갱신
- CS 통계/분석 요청

**model:** `sonnet` (CS는 양 처리, 신뢰도 점수로 보완)

**참조 도구:** Read, Edit, Write, Bash, WebFetch

**출력 포맷 (각 답변마다):**
```markdown
## CS Drafter Output

### Inquiry
- 채널: <KREAM/자사몰/...>
- 분류: <단순/복잡/클레임/칭찬>
- 고객 메시지 요약: <...>
- 주문 정보: <...>

### Draft Response
<초안 텍스트>

### Confidence
- 점수: <0~100>
- 사유: <왜 이 점수인지>

### Recommendation
- ✅ 승인 추천 / ⚠️ 검토 필요 / 🚨 에스컬레이션

### Used Template
- <템플릿 ID 또는 "신규 작성">

### ⚠️ 자동 발송 금지 — 사용자 승인 필수
```

### 2.4 dashboard-builder.md (도메인 D)

**역할:** 통합 대시보드 구축/유지. 6개 도메인의 데이터를 하나의 뷰로 통합.

**관리 대상 (향후 구축):**
- 통합 대시보드 (가능: KREAM 대시보드를 확장 또는 별도)
- 각 도메인별 KPI 정의
- 실시간 데이터 동기화
- 알림/경보 통합

**통합 대상 데이터:**
- 도메인 A (KREAM): 입찰 건수, 판매, 마진, 재고
- 도메인 B (SSRO 멀티채널): 채널별 매출, 재고, 주문
- 도메인 C (CS): 미처리 건수, 평균 응답 시간, 카테고리별 분포
- 도메인 E (이미지): 처리량, 채널 발행 현황
- 도메인 F (크롤링): 신상품 후보, 트렌드 키워드

**핵심 동작:**
1. 대시보드 작업 요청 수신 (확장/수정/조회)
2. 영향 받는 도메인 식별
3. 각 도메인 에이전트로부터 데이터 수집:
   - kream-operator → KREAM 데이터
   - ssro-channel-operator → 멀티채널 데이터
   - cs-drafter → CS 데이터
   - image-editor → 이미지 처리 데이터
   - product-crawler → 신상품 후보 데이터
4. 데이터 정합성 검증 (도메인 간 충돌 검사)
5. 대시보드 UI 업데이트
6. auditor에게 감사 요청

**KPI 표준 (사용자 승인 후 변경 가능):**
- 수익 직결: 일 매출, 마진, ROI
- 운영 효율: 자동화율, 직접 작업 시간
- 시스템 건강: 에이전트 가동률, 에러율, 응답 시간

**절대 금지:**
1. 데이터 임의 수정 (대시보드는 읽기 전용 뷰)
2. KPI 임의 변경 (사용자 승인 필요)
3. 기존 KREAM 대시보드 파괴 (확장은 호환성 유지)
4. 도메인 간 데이터를 임의 합산 (예: KREAM 마진 + SSRO 마진 — 회계 분리 필요)
5. 실시간 갱신 빈도 임의 변경 (서버 부하)
6. 인증 우회 (대시보드 외부 접속도 인증 필수)
7. 민감 데이터(개인정보, 계정 정보) 노출

**호출 조건:**
- 통합 대시보드 신규 구축
- 새 KPI 추가
- 도메인 추가에 따른 대시보드 확장
- 알림/경보 통합

**model:** `opus` (대시보드는 다른 모든 도메인과 연결)

**참조 도구:** Read, Edit, Write, Bash, Grep, Glob

**출력 포맷:**
```markdown
## Dashboard Builder Report

### Scope
- 영향 받는 도메인: <목록>
- 변경 유형: <신규/수정/확장>

### Data Sources Verified
- kream-operator: <데이터 가져오기 PASS/FAIL>
- ssro-channel-operator: <PASS/FAIL>
- cs-drafter: <PASS/FAIL>
- image-editor: <PASS/FAIL>
- product-crawler: <PASS/FAIL>

### KPIs
- 신규 추가: <목록>
- 수정: <목록>

### Action
<상세>

### Cross-domain Consistency
- 데이터 정합성: <PASS/FAIL>
- 충돌 항목: <목록>

### User-facing Changes
- UI: <스크린샷 또는 설명>
- 알림 변경: <목록>
```

---

## 3. 작업 순서 (자동 진행)

### Step A: 폴더 확인
`.claude/agents/` 폴더에 8개 파일 확인 (검증 3종 + 운영 2종 + 콘텐츠 3종).

### Step B: ssro-channel-operator.md 생성
명세 2.2 따라. 자동 진행.

### Step C: cs-drafter.md 생성
명세 2.3 따라. 자동 진행.

### Step D: dashboard-builder.md 생성
명세 2.4 따라. 자동 진행.

### Step E: 자체 검증 (자동)

```bash
# 1. YAML frontmatter
for f in .claude/agents/ssro-channel-operator.md .claude/agents/cs-drafter.md .claude/agents/dashboard-builder.md; do
  echo "=== $f ==="
  head -10 "$f"
done

# 2. 필수 섹션 5개
for f in .claude/agents/ssro-channel-operator.md .claude/agents/cs-drafter.md .claude/agents/dashboard-builder.md; do
  count=$(grep -E "^## (역할|호출 조건|절대 금지|작업 흐름|출력 포맷)" "$f" | wc -l)
  echo "$f: $count/5 sections"
done

# 3. 길이 확인
wc -l .claude/agents/ssro-channel-operator.md .claude/agents/cs-drafter.md .claude/agents/dashboard-builder.md

# 4. 도메인별 핵심 키워드
echo "=== ssro-channel-operator 키워드 ==="
grep -c "에이블리\|지그재그\|크로켓\|네이버\|자사몰" .claude/agents/ssro-channel-operator.md

echo "=== cs-drafter 키워드 ==="
grep -c "초안\|승인\|에스컬레이션\|자동 발송" .claude/agents/cs-drafter.md

echo "=== dashboard-builder 키워드 ==="
grep -c "통합\|KPI\|도메인\|정합성" .claude/agents/dashboard-builder.md

# 5. CLAUDE.md 인용
grep -l "CLAUDE.md\|절대 규칙" .claude/agents/ssro-channel-operator.md .claude/agents/cs-drafter.md .claude/agents/dashboard-builder.md

# 6. cs-drafter "자동 발송 금지" 강조 확인
grep -c "자동 발송 금지\|자동 발송 절대 금지\|승인 필수" .claude/agents/cs-drafter.md
# 최소 3회 등장해야 함 (강조 차원)
```

### Step F: 11개 에이전트 통합 일관성 최종 점검 (자동) 🎉

```bash
# 모든 11개 에이전트 파일 일관성
echo "=== 11개 에이전트 최종 점검 ==="
total=$(ls .claude/agents/*.md | wc -l)
echo "총 에이전트: $total / 11"

# 모든 파일의 섹션 헤더 일관성
for f in .claude/agents/*.md; do
  echo "--- $(basename $f) ---"
  grep "^## " "$f"
  echo ""
done

# YAML frontmatter 검증 (모두 name/description/model 가지고 있는지)
echo "=== YAML 검증 ==="
for f in .claude/agents/*.md; do
  has_name=$(grep -c "^name:" "$f")
  has_desc=$(grep -c "^description:" "$f")
  has_model=$(grep -c "^model:" "$f")
  echo "$(basename $f): name=$has_name, description=$has_desc, model=$has_model"
done

# AGENTS_INDEX.md 명시 11개와 일치하는지
echo "=== AGENTS_INDEX.md 일치 점검 ==="
expected="orchestrator kream-operator ssro-channel-operator cs-drafter dashboard-builder image-editor product-crawler qa-validator infra-manager docs-keeper auditor"
for name in $expected; do
  if [ -f ".claude/agents/${name}.md" ]; then
    echo "✅ $name"
  else
    echo "❌ $name (없음)"
  fi
done
```

**검증 실패 시:** 자동 수정 후 재검증. 3회 실패 시 사용자 보고.

### Step G: Git 커밋 (자동)
```bash
cd ~/Desktop/kream_automation
git add .claude/agents/ssro-channel-operator.md .claude/agents/cs-drafter.md .claude/agents/dashboard-builder.md
git commit -m "feat(agents): 확장 운영 3종 에이전트 생성 — 11개 시스템 완성 🎉

- ssro-channel-operator: 도메인 B (멀티채널 판매)
  - 자사몰+에이블리+지그재그+크로켓+네이버 운영
  - 채널별 인증/가격/재고 분리 관리
  - 자사몰 마스터 데이터 보호
- cs-drafter: 도메인 C (CS 자동화)
  - 일 50~100건 답변 초안 작성
  - 자동 발송 절대 금지 (모든 답변 사용자 승인 필수)
  - 클레임은 에스컬레이션
- dashboard-builder: 도메인 D (통합 대시보드)
  - 6개 도메인 데이터 통합
  - KPI 표준 정의
  - 도메인 간 데이터 충돌 검증

신상품 파이프라인 F→E→B 완성.
6개 도메인 (A KREAM + B SSRO + C CS + D 대시보드 + E 이미지 + F 크롤링) 모두
에이전트 보유.
11개 에이전트 시스템 가동 준비 완료.

다음 작업: 통합 테스트 (실제 KREAM 작업으로 검증) + last_sale 60시간 이슈 점검
참조: AGENTS_INDEX.md v1.1, NORTH_STAR.md v1.4 (6도메인)"
```

**커밋 완료 후 push 하지 말고 멈춤.**

---

## 4. 🚦 사용자 승인 게이트 (유일한 게이트)

Step G 완료 후 종합 보고:

```markdown
## 🎉 11개 에이전트 시스템 완성

### 이번 작업 (확장 운영 3종)
- .claude/agents/ssro-channel-operator.md (XX줄)
- .claude/agents/cs-drafter.md (XX줄)
- .claude/agents/dashboard-builder.md (XX줄)

### 자체 검증 결과
- YAML frontmatter: 3/3 ✅
- 필수 섹션 (5개): 3/3 ✅
- 도메인별 핵심 키워드: 3/3 ✅
- CLAUDE.md 인용: 3/3 ✅
- cs-drafter 자동 발송 금지 강조: ✅

### 11개 에이전트 통합 점검 결과
- ✅ orchestrator (조율)
- ✅ qa-validator (검증)
- ✅ auditor (감사)
- ✅ kream-operator (도메인 A)
- ✅ infra-manager (인프라)
- ✅ product-crawler (도메인 F)
- ✅ image-editor (도메인 E)
- ✅ docs-keeper (메타)
- ✅ ssro-channel-operator (도메인 B)
- ✅ cs-drafter (도메인 C)
- ✅ dashboard-builder (도메인 D)

### 시스템 완성도
- 6개 도메인 모두 에이전트 보유: ✅
- 신상품 파이프라인 F→E→B 정의: ✅
- 검증/감사/조율 메타 시스템: ✅

### Git 상태
- 커밋 해시: <hash>
- Push: ⏸️ 대기 중

### 발견한 이슈
(없으면 "없음")

### 다음 추천
1. 통합 테스트 — 실제 KREAM 작업으로 에이전트 시스템 검증
2. last_sale 60시간 이슈 점검 — kream-operator 활용
3. MIGRATION_PLAN.md Step 1 시작

---

**push 진행** / **보류**?
```

---

## 5. 절대 금지

1. **운영 코드 수정 금지**
2. **기존 8개 에이전트 파일 수정 금지** — 읽기만
3. **비전 문서 수정 금지**
4. **last_sale 60시간 이슈 점검 금지** — 별도 작업
5. **실제 채널/CS/대시보드 코드 작성 금지** — 명세만
6. **사용자 승인 없이 push 금지**

---

## 6. 자동 중단 조건

- 기존 8개 에이전트 파일 누락
- AGENTS_INDEX.md 명세와 이 지시서 충돌
- git status에 예상 외 변경
- Step E 자체 검증 3회 실패
- Step F 11개 일관성 점검 실패

---

## 7. 막힐 때 대응

- AGENTS_INDEX.md ↔ 이 지시서 충돌 → AGENTS_INDEX.md 우선
- NORTH_STAR.md 6도메인과 충돌 → NORTH_STAR.md 우선
- 모델 선택 모호 → 권장값 (ssro-channel-operator: opus, cs-drafter: sonnet, dashboard-builder: opus)
- 추측 금지 → 멈추고 묻기

---

**시작 명령:** "이 작업지시서 자동 모드로 진행해줘. 마지막 push 단계에서만 멈춰."
