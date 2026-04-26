# MIGRATION_PLAN.md
**프로젝트:** 주데이 이커머스 자동화 시스템
**작성일:** 2026-04-24
**버전:** v1.0
**관련 문서:** NORTH_STAR.md, ARCHITECTURE.md, AGENTS_INDEX.md

> 이 문서는 **현재 KREAM 단일 프로젝트 폴더 → 6개 도메인 + Sub-Agents 구조**로
> 이전하기 위한 단계별 실행 계획입니다.
> M1(2026-04-25 ~ 04-26)에 이 계획대로 실행합니다.

---

## 1. 이전 원칙

### 안전 우선
- **운영 중인 KREAM 시스템 절대 멈춤 없이** 이전
- 각 단계마다 **롤백 가능 지점** 확보
- 이전 중 발생하는 신규 판매/주문은 정상 처리되어야 함

### 점진적 이전
- 한 번에 다 옮기지 않음 → 단계별로
- 각 단계 완료 후 검증 → 다음 단계
- 새 폴더 구조에서 작동 확인 후 → 기존 위치 정리

### 무손실
- 모든 파일은 이동 (`mv`)이 아닌 복사 (`cp`) 후 검증
- 백업 필수 (이전 시작 전)
- Git 히스토리 유지

---

## 2. 현재 상태 vs 목표 상태

### 현재 (As-Is)
```
~/Desktop/kream_automation/
├── kream_server.py
├── kream_bot.py
├── kream_collector.py
├── kream_adjuster.py
├── kream_dashboard.html
├── tabs/
│   └── tab_*.html (12개)
├── price_history.db
├── auth_state.json
├── auth_state_kream.json
├── settings.json
├── my_bids_local.json
├── batch_history.json
├── queue_data.json
├── kream_prices.json
├── alert_history.json
├── tunnel.log
├── server.log
├── CLAUDE.md
├── KREAM_인수인계서_v6.md
├── NORTH_STAR.md (이번 채팅에서 추가)
├── ARCHITECTURE.md (이번 채팅에서 추가)
├── AGENTS_INDEX.md (이번 채팅에서 추가)
├── 작업지시서_Step4_v2.md
├── 작업지시서_Step5_v1.md
├── .claude/
│   ├── settings.json
│   ├── settings.local.json
│   ├── hooks/
│   │   ├── README.md
│   │   ├── dangerous-command-check.sh
│   │   └── syntax-check.sh
│   └── skills/
│       ├── api-addition/SKILL.md
│       └── db-migration/SKILL.md
├── backups/
└── .git/
```

### 목표 (To-Be)
```
~/Desktop/juday_automation/         ⭐ 폴더명 변경
├── NORTH_STAR.md
├── ARCHITECTURE.md
├── AGENTS_INDEX.md
├── MIGRATION_PLAN.md (이 문서)
├── README.md (전체 안내)
├── .gitignore
│
├── apps/
│   ├── kream/
│   │   ├── kream_server.py
│   │   ├── kream_bot.py
│   │   ├── kream_collector.py
│   │   ├── kream_adjuster.py
│   │   ├── competitor_analysis.py
│   │   ├── health_alert.py
│   │   ├── kream_dashboard.html
│   │   └── tabs/
│   ├── ssro/                       (M3에서 시작)
│   ├── cs/                         (M12에서 시작)
│   ├── image_editor/               (M5에서 시작)
│   ├── product_crawler/            (M6에서 시작)
│   ├── dashboard/                  (M4부터 점진)
│   └── common/                     (필요 시 신규)
│
├── docs/
│   ├── kream/
│   │   ├── HANDOFF.md              (인수인계서 v6 이전)
│   │   ├── CHANGELOG.md            (Git log 기반 작성)
│   │   ├── RULES.md                (CLAUDE.md의 KREAM 규칙)
│   │   └── TROUBLESHOOTING.md
│   ├── ssro/HANDOFF.md             (M3에서 시작)
│   ├── cs/HANDOFF.md               (M12에서 시작)
│   ├── image_editor/HANDOFF.md     (M5에서 시작)
│   ├── product_crawler/HANDOFF.md  (M6에서 시작)
│   └── dashboard/HANDOFF.md        (M4에서 시작)
│
├── work_orders/
│   ├── 2026-04/
│   │   ├── ✅작업지시서_Step4_v2.md
│   │   └── 🔄작업지시서_Step5_v1.md
│   └── 2026-05/                    (M1 이후 신규)
│
├── tests/                          (회귀 테스트, M1에서 골격만)
│   └── test_kream_smoke.py
│
├── .claude/
│   ├── settings.json
│   ├── settings.local.json
│   ├── hooks/                      (기존 그대로)
│   ├── skills/                     (기존 그대로)
│   └── agents/                     ⭐ 신규 - 10개 에이전트
│       ├── orchestrator.md
│       ├── kream-operator.md
│       ├── ssro-channel-operator.md
│       ├── cs-drafter.md
│       ├── dashboard-builder.md
│       ├── image-editor.md
│       ├── product-crawler.md
│       ├── qa-validator.md
│       ├── infra-manager.md
│       └── docs-keeper.md
│
├── archive/                        (폐기되지만 보관)
│   ├── KREAM_인수인계서_v5.md
│   └── CLAUDE.md (구버전)
│
├── data/                           (.gitignore)
│   ├── price_history.db
│   ├── auth_state.json
│   ├── auth_state_kream.json
│   ├── settings.json
│   ├── my_bids_local.json
│   ├── batch_history.json
│   ├── queue_data.json
│   ├── kream_prices.json
│   ├── alert_history.json
│   ├── tunnel.log
│   └── server.log
│
├── backups/                        (.gitignore, 기존 그대로)
│
└── .git/                           (Git 히스토리 유지)
```

---

## 3. 이전 단계 (5단계, 1~2일 소요)

### 🟢 STEP 0: 사전 준비 (10분, 5분 다운타임)

```bash
cd ~/Desktop/kream_automation

# 0.1 현재 상태 백업
mkdir -p ~/Desktop/_kream_backup_pre_migration
cp -r . ~/Desktop/_kream_backup_pre_migration/
echo "백업 완료: ~/Desktop/_kream_backup_pre_migration/"

# 0.2 Git 상태 정리 (커밋되지 않은 변경 있으면 STOP)
git status
# Changes to be committed가 있으면 → 먼저 커밋
# Untracked files는 OK

# 0.3 서버 잠시 중단
lsof -ti:5001 | xargs kill -9 2>/dev/null
echo "서버 중단됨 - 5분 안에 재시작 예정"

# 0.4 현재 위치 확인
pwd
ls -la
```

**검증 체크리스트:**
- [ ] `~/Desktop/_kream_backup_pre_migration/` 에 모든 파일 복사됨
- [ ] `git status` clean 또는 모든 변경 커밋됨
- [ ] 서버 잠시 중단된 상태

**롤백:** 이 단계는 백업만 했으므로 롤백 불필요

---

### 🟢 STEP 1: 새 폴더 구조 생성 (10분, 다운타임 없음)

기존 `kream_automation/` 옆에 새 구조를 만듭니다 (이전 X, 신규 생성).

```bash
cd ~/Desktop

# 1.1 새 최상위 폴더 생성
mkdir -p juday_automation
cd juday_automation

# 1.2 폴더 구조 생성
mkdir -p apps/{kream,ssro,cs,image_editor,product_crawler,dashboard,common}
mkdir -p docs/{kream,ssro,cs,image_editor,product_crawler,dashboard}
mkdir -p work_orders/2026-04
mkdir -p work_orders/2026-05
mkdir -p tests
mkdir -p archive
mkdir -p data
mkdir -p backups
mkdir -p .claude/{hooks,skills,agents}

# 1.3 구조 확인
tree -L 2 -d
# 또는 ls -la

# 1.4 .gitignore 작성
cat > .gitignore << 'EOF'
# 런타임 데이터
data/
backups/
__pycache__/
*.pyc
.DS_Store

# 인증 (절대 커밋 금지)
auth_state*.json

# 로그
*.log
alert_history.json

# IDE
.vscode/
.idea/

# 노트북에서 임시 작업
*.tmp
*.swp
EOF

echo "폴더 구조 생성 완료"
```

**검증 체크리스트:**
- [ ] `~/Desktop/juday_automation/` 생성됨
- [ ] 모든 하위 폴더 생성됨
- [ ] `.gitignore` 작성됨

**롤백:** `rm -rf ~/Desktop/juday_automation` (단순 삭제)

---

### 🟡 STEP 2: 핵심 코드 이전 (15분, 다운타임 약 5분)

KREAM 코드를 새 위치로 복사합니다.

```bash
cd ~/Desktop/kream_automation

# 2.1 KREAM 앱 코드 복사 (mv 아닌 cp - 안전)
cp kream_server.py ~/Desktop/juday_automation/apps/kream/
cp kream_bot.py ~/Desktop/juday_automation/apps/kream/
cp kream_collector.py ~/Desktop/juday_automation/apps/kream/
cp kream_adjuster.py ~/Desktop/juday_automation/apps/kream/
cp competitor_analysis.py ~/Desktop/juday_automation/apps/kream/ 2>/dev/null
cp health_alert.py ~/Desktop/juday_automation/apps/kream/
cp kream_dashboard.html ~/Desktop/juday_automation/apps/kream/
cp -r tabs ~/Desktop/juday_automation/apps/kream/

# 2.2 데이터 파일 복사 (data/로)
cp price_history.db ~/Desktop/juday_automation/data/
cp auth_state.json ~/Desktop/juday_automation/data/
cp auth_state_kream.json ~/Desktop/juday_automation/data/
cp settings.json ~/Desktop/juday_automation/data/
cp my_bids_local.json ~/Desktop/juday_automation/data/
cp batch_history.json ~/Desktop/juday_automation/data/ 2>/dev/null
cp queue_data.json ~/Desktop/juday_automation/data/ 2>/dev/null
cp kream_prices.json ~/Desktop/juday_automation/data/ 2>/dev/null

# 2.3 Claude Code 설정 복사
cp -r .claude/* ~/Desktop/juday_automation/.claude/

# 2.4 백업 폴더 복사
cp -r backups ~/Desktop/juday_automation/ 2>/dev/null

# 2.5 검증
echo "=== 새 폴더 파일 수 ==="
find ~/Desktop/juday_automation/apps/kream -type f | wc -l
echo "=== 새 폴더 데이터 파일 수 ==="
find ~/Desktop/juday_automation/data -type f | wc -l
```

**검증 체크리스트:**
- [ ] `apps/kream/` 안에 핵심 파일 7~8개 복사됨
- [ ] `apps/kream/tabs/` 안에 12개 HTML 복사됨
- [ ] `data/` 안에 DB + JSON 8개 복사됨
- [ ] `.claude/` 안에 hooks, skills 복사됨

**롤백:** STEP 1 + STEP 2 결과물 삭제 후 기존 폴더 그대로 사용

---

### 🟡 STEP 3: 경로 수정 + 첫 실행 테스트 (30분, 다운타임 10분)

새 폴더에서 KREAM 서버 실행 테스트. 코드 안의 경로를 새 위치에 맞게 수정합니다.

#### 3.1 경로 의존성 확인

```bash
cd ~/Desktop/juday_automation/apps/kream

# 코드에서 절대 경로 참조 확인
grep -rn "/Users/iseungju/Desktop/kream_automation" .
grep -rn "price_history.db" . | head -10
grep -rn "auth_state" . | head -10
grep -rn "settings.json" . | head -10
grep -rn "my_bids_local.json" . | head -10
```

#### 3.2 경로 변경 전략 (2가지 중 선택)

**옵션 A: 코드는 안 바꾸고, 심볼릭 링크 활용 (추천)**

```bash
cd ~/Desktop/juday_automation/apps/kream

# data/ 안의 파일들을 현재 디렉토리에 symlink
ln -s ../../data/price_history.db price_history.db
ln -s ../../data/auth_state.json auth_state.json
ln -s ../../data/auth_state_kream.json auth_state_kream.json
ln -s ../../data/settings.json settings.json
ln -s ../../data/my_bids_local.json my_bids_local.json
ln -s ../../data/batch_history.json batch_history.json 2>/dev/null
ln -s ../../data/queue_data.json queue_data.json 2>/dev/null
ln -s ../../data/kream_prices.json kream_prices.json 2>/dev/null

ls -la
# l로 시작하는 항목들이 symlink (예: lrwxr-xr-x ... -> ../../data/price_history.db)
```

**장점:** 코드 수정 0줄, 즉시 실행 가능
**단점:** symlink 깨지면 문제 발생 가능

**옵션 B: 코드의 파일 경로 모두 수정 (안전하지만 작업 큼)**

```bash
# 예시 (수동으로 하나씩)
# kream_server.py에서:
# 변경 전: DB_PATH = 'price_history.db'
# 변경 후: DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'data', 'price_history.db')
```

**장점:** 명시적이고 안전
**단점:** 30분~1시간 작업, 회귀 위험

**🎯 추천: 옵션 A로 시작 → M1 끝나면 옵션 B로 점진적 마이그레이션**

#### 3.3 첫 실행 테스트

```bash
cd ~/Desktop/juday_automation/apps/kream

# 서버 실행
nohup python3 kream_server.py > ~/Desktop/juday_automation/data/server.log 2>&1 &
disown
sleep 5

# 헬스체크
curl -s http://localhost:5001/api/health | python3 -m json.tool

# 자동화 기능 정상 작동 확인
curl -s http://localhost:5001/api/auto-rebid/status | python3 -m json.tool
curl -s http://localhost:5001/api/auto-adjust/status | python3 -m json.tool
```

**검증 체크리스트:**
- [ ] 서버 정상 실행 (포트 5001)
- [ ] `/api/health` 응답 정상 (status: healthy 또는 critical만 last_sale 때문)
- [ ] auth_partner valid: true
- [ ] 스케줄러 2개 running

**문제 발생 시:**
1. 서버 로그 확인: `tail -50 ~/Desktop/juday_automation/data/server.log`
2. symlink 깨짐 확인: `ls -la ~/Desktop/juday_automation/apps/kream/`
3. 롤백: 새 폴더 서버 죽이고 기존 폴더에서 다시 실행

**롤백:**
```bash
lsof -ti:5001 | xargs kill -9
cd ~/Desktop/kream_automation
nohup python3 kream_server.py > server.log 2>&1 &
disown
```

---

### 🟢 STEP 4: 문서 이전 + 정리 (20분, 다운타임 없음)

코드는 두고 문서만 정리합니다.

```bash
cd ~/Desktop/kream_automation

# 4.1 문서 복사
cp NORTH_STAR.md ~/Desktop/juday_automation/
cp ARCHITECTURE.md ~/Desktop/juday_automation/
cp AGENTS_INDEX.md ~/Desktop/juday_automation/

# 4.2 인수인계서 → KREAM 도메인 HANDOFF로 전환
cp KREAM_인수인계서_v6.md ~/Desktop/juday_automation/docs/kream/HANDOFF.md
echo "" >> ~/Desktop/juday_automation/docs/kream/HANDOFF.md
echo "---" >> ~/Desktop/juday_automation/docs/kream/HANDOFF.md
echo "**참고:** 이 문서는 기존 KREAM_인수인계서_v6.md를 도메인 HANDOFF 형식으로 이전한 것입니다." >> ~/Desktop/juday_automation/docs/kream/HANDOFF.md

# 4.3 CLAUDE.md → 분리
# CLAUDE.md의 KREAM 절대 규칙 부분 → docs/kream/RULES.md
# CLAUDE.md의 일반 부분 → 삭제 (NORTH_STAR.md로 흡수됨)
cp CLAUDE.md ~/Desktop/juday_automation/archive/CLAUDE_legacy.md
echo "수동 작업 필요: CLAUDE.md를 docs/kream/RULES.md로 분리"

# 4.4 작업지시서 이전
cp 작업지시서_Step4_v2.md ~/Desktop/juday_automation/work_orders/2026-04/
cp 작업지시서_Step5_v1.md ~/Desktop/juday_automation/work_orders/2026-04/

# 4.5 인수인계서 v5는 archive로
cp KREAM_인수인계서_v5.md ~/Desktop/juday_automation/archive/ 2>/dev/null

# 4.6 README.md 작성 (간단)
cat > ~/Desktop/juday_automation/README.md << 'EOF'
# 주데이 이커머스 자동화 시스템

## 빠른 시작
1. NORTH_STAR.md 읽기 (전체 비전)
2. ARCHITECTURE.md 읽기 (시스템 구조)
3. AGENTS_INDEX.md 읽기 (Sub-Agents 명단)

## 새 채팅 시작 시
NORTH_STAR.md 7장 "채팅 시작 템플릿" 사용

## 도메인
- A: KREAM (운영 중) - apps/kream/, docs/kream/
- B: SSRO + 멀티채널 (개발 예정)
- C: CS 자동화 (개발 예정)
- D: 통합 대시보드 (개발 예정)
- E: 이미지 자동 편집 JUDAY (개발 예정)
- F: 신상품 정보 수집 (개발 예정)

## 서버 실행
```bash
cd apps/kream
nohup python3 kream_server.py > ../../data/server.log 2>&1 &
disown
```

## 헬스체크
http://localhost:5001/api/health
EOF

echo "문서 이전 완료"
```

**검증 체크리스트:**
- [ ] NORTH_STAR.md, ARCHITECTURE.md, AGENTS_INDEX.md 새 위치에 존재
- [ ] docs/kream/HANDOFF.md 생성됨
- [ ] work_orders/2026-04/ 안에 지시서 2개 있음
- [ ] archive/ 안에 옛날 문서 보관됨
- [ ] README.md 생성됨

---

### 🟡 STEP 5: Sub-Agents 파일 생성 + Git 정리 (30분, 다운타임 없음)

#### 5.1 .claude/agents/ 안에 10개 에이전트 파일 생성

```bash
cd ~/Desktop/juday_automation/.claude/agents

# AGENTS_INDEX.md의 각 에이전트 정의를 개별 파일로 분리
# (수동 작업이지만 AGENTS_INDEX.md의 "3. 에이전트별 상세 정의" 섹션을 그대로 사용)

touch orchestrator.md
touch kream-operator.md
touch ssro-channel-operator.md
touch cs-drafter.md
touch dashboard-builder.md
touch image-editor.md
touch product-crawler.md
touch qa-validator.md
touch infra-manager.md
touch docs-keeper.md

echo "10개 에이전트 파일 생성 완료 - 내용은 AGENTS_INDEX.md 3장에서 복사 필요"
```

**⚠️ 각 파일의 실제 내용은 다음 채팅에서 자동 생성** (이번 작업 토큰 절약 위해)

#### 5.2 Git 초기화 (새 폴더에)

```bash
cd ~/Desktop/juday_automation

# 옵션 A: 새 Git 저장소 (이력 끊김, 깔끔)
git init
git add -A
git commit -m "feat: 주데이 이커머스 자동화 시스템 신규 구조 (M1)

- NORTH_STAR.md, ARCHITECTURE.md, AGENTS_INDEX.md 추가
- 6개 도메인 (A: KREAM, B: SSRO, C: CS, D: 대시보드, E: 이미지편집 JUDAY, F: 신상품 크롤링)
- 10개 Sub-Agents 정의
- KREAM 코드 apps/kream/으로 이전
- 데이터 파일 data/로 분리
- symlink로 기존 코드 호환성 유지"

# 옵션 B: 기존 Git 히스토리 유지하면서 폴더 구조만 변경 (복잡)
# git filter-branch 등 사용 - 추천 안 함 (복잡하고 위험)
```

**🎯 추천: 옵션 A** — 새 Git 저장소로 시작
- 기존 kream_automation은 archive로 보관
- 6주 후 시점에서 회고할 때 비교 가능

#### 5.3 GitHub에 새 저장소 만들기

```bash
# GitHub에서 새 Private 저장소 생성: judayjuday/juday-automation
git remote add origin https://github.com/judayjuday/juday-automation.git
git branch -M main
git push -u origin main
```

**검증 체크리스트:**
- [ ] `.claude/agents/` 안에 10개 .md 파일 생성됨 (빈 파일이라도 OK)
- [ ] 새 Git 저장소 초기화됨
- [ ] GitHub에 push 성공

---

## 4. 이전 후 검증 (Total 검증)

```bash
cd ~/Desktop/juday_automation

# 4.1 폴더 구조 검증
tree -L 3 -d

# 4.2 서버 실행 확인
ls -la apps/kream/  # symlink가 있는지
curl -s http://localhost:5001/api/health | python3 -m json.tool

# 4.3 자동화 기능 살아있는지
curl -s http://localhost:5001/api/auto-rebid/status | python3 -m json.tool
curl -s http://localhost:5001/api/auto-adjust/status | python3 -m json.tool

# 4.4 DB 정상 접근 가능한지
sqlite3 data/price_history.db "SELECT COUNT(*) FROM bid_cost;"
sqlite3 data/price_history.db "SELECT COUNT(*) FROM sales_history;"
sqlite3 data/price_history.db ".tables" | wc -w

# 4.5 인증 살아있는지
curl -s http://localhost:5001/api/health | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('auth_partner valid:', d['auth_partner']['valid'])
print('auth_kream valid:', d['auth_kream']['valid'])
"
```

---

## 5. 기존 폴더 처리

### 옵션 A: 즉시 archive로 이동 (추천 X)
```bash
mv ~/Desktop/kream_automation ~/Desktop/_kream_automation_old
```

### 옵션 B: 1주일 보관 후 삭제 (추천)
```bash
# 1주일 후
mv ~/Desktop/kream_automation ~/Desktop/_kream_automation_old_2026-05-02
# 그 후 1주일 더 보관 후 완전 삭제
```

**주의:** 새 시스템이 1주일간 안정적으로 작동하면 그때 정리

---

## 6. 자주 발생할 문제 + 해결

### 문제 1: symlink가 안 만들어진다
```bash
# 확인
ls -la apps/kream/price_history.db
# 없으면:
cd apps/kream
ln -s ../../data/price_history.db price_history.db
```

### 문제 2: 서버는 실행되는데 DB 접근 에러
```bash
# DB 파일 존재 확인
ls -la data/price_history.db
# symlink 깨짐 확인
file apps/kream/price_history.db
# broken이면 다시 만들기
```

### 문제 3: Cloudflare Tunnel이 끊김
```bash
# 새 폴더에서 다시 실행 필요
cd ~/Desktop/juday_automation
cloudflared tunnel --url http://localhost:5001
```

### 문제 4: Claude Code가 새 구조를 못 알아챔
```bash
cd ~/Desktop/juday_automation
claude --dangerously-skip-permissions
# 첫 메시지로 NORTH_STAR.md, AGENTS_INDEX.md 읽으라고 안내
```

---

## 7. M1 완료 후 다음 단계

이 마이그레이션이 끝나면 즉시:

1. **M2: KREAM Step 5 입찰 정리**
   - 새 구조에서 첫 작업
   - kream-operator 에이전트가 담당
   - 작업지시서: work_orders/2026-04/작업지시서_Step5_v1.md

2. **M3: SSRO 주문 수집**
   - 새 도메인 첫 작업
   - ssro-channel-operator 에이전트가 담당
   - apps/ssro/ 첫 코드 작성

---

## 8. 변경 이력

| 버전 | 날짜 | 변경 사유 |
|------|------|----------|
| v1.0 | 2026-04-24 | 최초 작성 (M1 실행 계획) |

---

## 9. 안전 체크리스트 (실행 전 필독)

이전 시작 전 마지막 확인:

- [ ] 백업 완료 (`~/Desktop/_kream_backup_pre_migration/`)
- [ ] Git 모든 변경사항 커밋됨
- [ ] 현재 시간이 KREAM 운영 한가한 시간 (오후/밤)
- [ ] 1~2시간 작업 시간 확보됨
- [ ] 문제 발생 시 롤백할 수 있다는 자신감 (있음)

**모두 ✅이면 → STEP 0 시작!**

---

**🎯 이 문서를 읽고 답할 수 있어야 함:**
- 이전이 몇 단계인가? → 5단계 (STEP 0~5)
- 가장 위험한 단계는? → STEP 3 (서버 첫 실행 테스트)
- 롤백 가능한가? → 모든 단계에서 가능 (백업 + symlink)
- 다운타임은? → 총 15~20분 (STEP 0, 2, 3에서 분산)
