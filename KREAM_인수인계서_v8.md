# KREAM 판매자센터 자동화 프로젝트 — 인수인계서 v8 (2026-05-04)

## 1. 프로젝트 개요

**목적:** KREAM(크림) 판매자센터 반복 작업 자동화 + 해외(중국) 상품 대량 등록/입찰 시스템

**비전 (v7~v8 — NORTH_STAR.md 기반):** KREAM은 6개 도메인 중 하나(도메인 A)이며, 전체 시스템은 11개 Sub-Agent로 운영되는 자동화 생태계.

**비즈니스 모델:** 구매대행
- 입찰 걸어둔 상태 = 자본 미지출 (체결 시점에 매입)
- "tied_total"은 묶인 자본 아니라 _노출 입찰액_
- 핵심 KPI: 체결률 + 확정 마진 (bid_cost 매칭된 판매만)

**비즈니스 데이터 (2026-05-04 기준):**
- 매출 누적: 689,000원 (7건)
- 확정 마진: 56,746원 (평균 8,107원/건)
- 매출 대비 마진율: **8.2%** (실제 데이터, fuzzy 매칭 활용)
- 활성 입찰: 51건 (오니츠카 토쿠텐 1183B938-100 단일 모델)

**사용자:** 승주 (judayjuday)
- KREAM 계정: judaykream@gmail.com
- GitHub: judayjuday (Private: https://github.com/judayjuday/kream-automation.git)
- Claude Code: Team Account (JUDAY), juday@juday.co.kr
- Mac ARM (Python 3.9.6, Node.js, Claude Code 설치됨)
- 사용자명: iseungju, 호스트: iseungjuui-MacBookAir

**물류:** 중국 공장/셀러 → 허브넷(웨이하이 물류창고) → KREAM 검수센터 → 고객

**환경 (v8 갱신):**
- **현재 한국에서 작업 중** (kream.co.kr + partner.kream.co.kr 모두 접속 가능)
- 맥북 단독 운영 (사무실 iMac 원격 안 함)
- 환경 자동 감지: env=korea (Step 33-D에서 수정 완료)
- 환율: CNY 약 217원 (open.er-api.com에서 자동 업데이트)
- Cloudflare Tunnel로 외부에서 대시보드 접속 가능

**입찰 전략 (확정):**
- 사이즈당 2건 유지
- 마진 하한: 4,000원
- 언더컷: -1,000원 (설정에서 변경 가능)

---

## 2. 6개 도메인 구조 (v7~v8)

| 도메인 | 명칭 | 상태 | 담당 에이전트 |
|---|---|---|---|
| A | KREAM (스니커즈/패션 리셀) | ✅ 운영 중 | kream-operator |
| B | SSRO + 멀티채널 (의류/가방/잡화) | 📋 계획 단계 | ssro-channel-operator |
| C | CS 자동화 (일 50~100건) | 📋 계획 단계 | cs-drafter |
| D | 통합 대시보드 | 📋 계획 단계 | dashboard-builder |
| E | 이미지 자동 편집 (JUDAY) | 📋 계획 단계 | image-editor |
| F | 신상품 정보 수집 (샤오홍슈) | 📋 계획 단계 | product-crawler |

**신상품 파이프라인 F → E → B:** 크롤링(F) → 이미지편집(E) → 채널등록(B)

---

## 3. 11개 Sub-Agent 시스템

`.claude/agents/` 폴더에 정의된 에이전트 시스템:

| # | 에이전트 | 모델 | 역할 |
|---|---|---|---|
| 1 | orchestrator | inherit | 작업 분배 + 다른 에이전트 호출 조율 |
| 2 | qa-validator | inherit | Plan→Act→Verify→Report 검증 |
| 3 | auditor | sonnet | 사후 감사 (DB/파일/Git) |
| 4 | kream-operator | opus | 도메인 A — KREAM 도메인 전담 |
| 5 | infra-manager | sonnet | 서버/스케줄러/DB/인증 인프라 |
| 6 | product-crawler | sonnet | 도메인 F — 신상품 수집 |
| 7 | image-editor | sonnet | 도메인 E — 이미지 자동 편집 |
| 8 | docs-keeper | opus | 비전 문서 단일 진실 소스 관리 |
| 9 | ssro-channel-operator | opus | 도메인 B — 멀티채널 운영 |
| 10 | cs-drafter | sonnet | 도메인 C — CS 답변 초안 (자동 발송 금지) |
| 11 | dashboard-builder | sonnet | 도메인 D — 통합 대시보드 |

---

## 4. 7가지 핵심 원칙 (NORTH_STAR.md)

1. **안전이 속도보다 우선**
2. **직접 작업 시간을 0으로**
3. **기능별 격리** (Sub-Agents)
4. **단일 진실 소스**
5. **수익 직결 우선**
6. **자체 검증 필수** (Plan → Act → Verify → Report)
7. **모든 것을 기록하고 학습** (Logging + Auto-Diagnosis + Time-Travel)

---

## 5. 핵심 파일 (~/Desktop/kream_automation/)

```
kream_server.py          # Flask 서버 (포트 5001) — 6,800+줄
kream_dashboard.html     # 웹 대시보드 — 7,000+줄
kream_bot.py             # Playwright 자동화 — 2,900+줄
kream_collector.py       # KREAM 가격 수집 — 1,275줄
kream_adjuster.py        # 가격 자동 조정 + sync v2 (Step 33-B 수정) — 700+줄
competitor_analysis.py   # 경쟁사 분석 — 532줄
health_alert.py          # 헬스체크 경보 알림

tabs/                    # 탭별 HTML 파일
  tab_register.html      # 상품 등록/입찰 (큐 시스템)
  tab_margin.html        # 마진 계산기 (v8: 사이즈별 일괄 + 회전 시간 강화)
  tab_bulk.html          # 대량 등록
  tab_discover.html      # 상품 발굴 + 자동 스캔
  tab_adjust.html        # 가격 자동 조정 + 언더컷 자동 방어
  tab_prices.html        # 가격 수집
  tab_mybids.html        # 입찰 관리
  tab_history.html       # 실행 이력 + 판매 이력
  tab_sales.html         # 판매 관리 + 자동 재입찰
  tab_logistics.html     # 물류 관리 (허브넷)
  tab_pattern.html       # 판매 패턴 분석
  tab_settings.html      # 환율/수수료/자동조정/자동재입찰 설정
  tab_new_bid.html       # [v8 NEW Step 31] 신규 입찰 일괄 도구
  tab_realized.html      # [v8 NEW Step 31] 판매 마진 확정 (월별 + ROI)
  tab_market.html        # [v8 NEW Step 31] 시장 모니터링 (가격 추이 + 급변 알림)

auth_state.json          # 판매자센터 세션 (localStorage JWT 포함!)
auth_state_kream.json    # KREAM 일반사이트 세션
.relogin_state.json      # [v8 NEW Step 33-A] 자동 재로그인 상태
queue_data.json          # 상품 큐
batch_history.json       # 실행 이력
my_bids_local.json       # 내 입찰 현황 (51건)
kream_prices.json        # 가격 수집 결과
settings.json            # 환율/수수료/자동조정/자동재입찰
price_history.db         # SQLite WAL — 19개 테이블 (v8: market_price_history 추가)

신규입찰_사용가이드.md    # [v8 NEW Step 33-C] 사장용 워크플로우 가이드

.claude/                 # Claude Code 검증 + 에이전트
  settings.json
  hooks/
    syntax-check.sh
    dangerous-command-check.sh
  skills/
    db-migration/SKILL.md
    api-addition/SKILL.md
  agents/                # 11개 Sub-Agent (v7)
    orchestrator.md, qa-validator.md, auditor.md, kream-operator.md,
    infra-manager.md, product-crawler.md, image-editor.md, docs-keeper.md,
    ssro-channel-operator.md, cs-drafter.md, dashboard-builder.md

# 비전 문서
NORTH_STAR.md            # 7원칙, 6도메인, 6주 로드맵
ARCHITECTURE.md          # 시스템 구조 + 신상품 파이프라인 F→E→B
AGENTS_INDEX.md          # 11개 Sub-Agents 명세
MIGRATION_PLAN.md
VERIFICATION_PROTOCOL.md # Plan→Act→Verify→Report
OBSERVABILITY.md

CLAUDE.md                # Claude Code 절대 규칙 + 체크리스트
.gitignore               # auth_state*.json 제외됨
```

---

## 6. kream_server.py — API 엔드포인트 (총 130+개)

v7의 108개 + Step 18~33에서 추가된 22+개.

### 신규 추가 (Step 18-33)

**일일 자동화 / 자본 추적 (Step 18-D, 20):**
- GET /api/daily-summary
- GET /api/capital-status, /capital-history, /capital-efficiency

**정리 자동화 (Step 19, 22):**
- POST /api/cleanup/diagnose, bulk-withdraw, bulk-adjust, auto-execute
- GET /api/cleanup/effect-report

**판매 마진 (Step 22-23):**
- GET /api/real-margin (fuzzy 매칭)
- GET /api/conversion-rate
- GET /api/realized-margin/cumulative (Step 31)

**모델 분석 (Step 20):**
- GET /api/portfolio/overview
- GET /api/model/<model>/deep-analysis

**진단 (Step 25-30):**
- GET /api/env/recheck
- GET /api/diagnostics/sync-page-dump, list-dumps, explore-menu
- GET /api/my-bids/verify-deleted, rank-changes

**시장 모니터링 (Step 31):**
- GET /api/market/history/<model>, alerts
- POST /api/market/collect-now
- GET /api/market-prices/from-bids

**도움말 (Step 31):**
- GET /api/help/<tab_id>

**신규 입찰 (Step 31):**
- POST /api/new-bid/calc-batch, auto-fetch-prices

**자동 재로그인 (Step 33-A):**
- GET /api/auth/relogin-status
- POST /api/auth/relogin-now

**알림 관리 (Step 33-A):**
- GET /api/notifications/stats
- POST /api/notifications/cleanup-old

**일지/리포트 (Step 18-D, 21):**
- GET /api/daily-log/<date>
- GET /api/weekly-report

---

## 7. 자동 재입찰 시스템 (v6, 변경 없음)

판매 수집 직후 새 체결건 감지 시 자동 재입찰. 6중 안전장치.

### 6중 안전장치
1. 원가 존재 (bid_cost JOIN)
2. 마진 하한 4,000원
3. 가격 급변 차단 (판매가 ±10%)
4. 일일 한도 (auto_rebid_daily_max=20)
5. 모델 블랙리스트
6. 루프 가드

### 기본 설정
```json
{
  "auto_rebid_enabled": false,    // 기본 OFF
  "auto_rebid_daily_max": 20,
  "auto_rebid_blacklist": []
}
```

---

## 8. 알림 디바운싱 (v8 NEW — Step 32 v3, 커밋 b0a9eba)

**문제 배경:** 161건 알림 폭주 (12시간마다 health_critical / sales_no_data 발송).

**해결:**
- `_should_send_alert_dedupe(subject, body, window_sec=60)` 헬퍼
- safe_send_alert 함수 첫 줄에 디바운싱 가드
- 60초 내 동일 (subject, body) 조합 차단
- 캐시 500개 초과 시 1시간 이전 항목 자동 정리

**효과:** 같은 알림 60초 내 1번만 → 폭주 멈춤.

---

## 9. 자동 재로그인 인프라 (v8 NEW — Step 33-A, 커밋 d902a39)

**기능:** sync 1h+ 멈추면 백그라운드에서 자동 재로그인 (사장 개입 0).

**작동:**
1. 30분 스케줄러로 sync 시각 체크
2. last_sync 1시간 이상 경과 + 6h 쿨다운 통과 시
3. `subprocess`로 `kream_bot.py --mode auto-login-partner` 호출
4. 결과 `.relogin_state.json`에 기록
5. 성공/실패 알림 (디바운싱 적용)

**6h 쿨다운:** 무한 루프 방지.

**수동 즉시 트리거:** 빨간 배너 "즉시 재로그인" 버튼 → POST /api/auth/relogin-now

---

## 10. kream_bot.py — 주요 함수 (변경 없음)

### 브라우저 / 세션
```python
async def create_browser(playwright, headless=False)
async def create_context(browser, storage=None)
async def save_state_with_localstorage(page, context, path, origin_url)
    # ★ 핵심: localStorage JWT 병합 저장
async def apply_stealth(page)  # ← Step 33-B에서 사용 (playwright_stealth 사라짐 대체)
```

### 로그인
```python
async def login_manual(playwright)
async def login_kream(playwright)
async def login_auto_partner(playwright)
async def login_auto_kream(playwright)
async def ensure_logged_in(page, context=None)
```

### 고시정보 / 입찰
```python
async def fill_product_info(page, product, delay=2.0)
async def place_bid(page, bid, delay=3.0)
async def place_bids_batch(page, product_id, bids, bid_days=30, delay=3.0)
```

---

## 11. kream_adjuster.py — sync 함수 (v8 핵심 — Step 33-B)

### collect_my_bids_via_menu (v8 핵심, 커밋 1c9ce33)

**작동:** 메인 → "통합 입찰 관리" → "입찰 내역 관리" 메뉴 클릭 → 데이터 추출.

**Step 33-B 핵심 발견:**
- KREAM 파트너 사이트의 페이지 버튼이 `Base_base__ot5b7` 클래스 + 숫자 텍스트 패턴
- 기존 코드는 `class*="pagination"` 영역 안에서만 숫자 버튼을 찾아 매칭 실패
- 페이지네이션 영역 자체가 `pagination` 클래스를 갖지 않음

**수정:**
- 페이지 next 클릭 우선순위: `Base_` 클래스 + 숫자 텍스트 → aria-label → ›/Next 텍스트 → 일반 숫자
- 페이지 사이즈 select는 `개씩 보기` 옵션 있는 select만 인정 (이전 0건 사고 원인)
- `playwright_stealth.stealth_async` 사라짐 → `kream_bot.apply_stealth`로 교체
- `[SYNC-V2-DBG]` 1회성 dump (다음 셀렉터 변경 시 재진단용)

**검증:** 6페이지 순회 → 51건 (10×5 + 1, 중복 제거)

**잔여 이슈:** size 필드 빈 값 (정규식이 모델번호 100/가격 168 매치 가능성).

---

## 12. kream_collector.py — 가격 수집 (변경 없음)

```python
async def collect_prices(product_ids, headless, save_excel, include_partner)
async def collect_from_kream(page, product_id)
async def collect_size_prices_via_api(page, product_id, pre_captured)
```

**가격 우선순위:**
1. API `buyPrice` (국내 배송 최저가)
2. 판매입찰 탭 DOM 최저가
3. JSON-LD `offers.price`

---

## 13. DB 테이블 구조 (price_history.db — 19개 테이블)

### v6/v7 기준 18개 + v8 추가 1개

**v8 신규:**
- **market_price_history** (Step 31) — model, size, buy_price, recent_price, collected_at

**v6 기준 핵심 테이블:**
- bid_cost (입찰 원가)
- price_adjustments (pending 102+)
- auto_adjust_log (Step 32 자동 조정 이력)
- auto_rebid_log (v6 자동 재입찰)
- sales_history (판매 7건)
- capital_history (Step 18-D)
- suppliers, shipment_requests, shipment_costs (물류)
- dewu_prices, size_conversion, trade_volume
- price_history, my_bids_history, bid_competition_log
- conditional_bids, notifications, edit_log

---

## 14. 환경 감지 (v8 — Step 33-D, 커밋 bd178f0)

**기존 문제:** HTTP-check timeout 시 무조건 `macbook_overseas` 단정 → 한국에서도 잘못 잡힘.

**v8 해결:**
1. KREAM timeout 10s → 15s
2. KREAM 실패 시 `naver.com` 5s 백업 체크
3. 결과 분류:
   - 네이버 OK + KREAM 실패 → `overseas_blocked` (IP 차단)
   - 둘 다 실패 → `offline`
   - KREAM OK → `korea`
4. `FORCE_ENV` 환경변수 우선 (수동 우회)
5. **보너스:** 짤린 User-Agent로 KREAM이 500 반환하던 부수 버그도 수정

---

## 15. 스케줄러 시스템 (v8)

| 스케줄러 | 간격 | 도입 |
|---|---|---|
| 입찰 순위 모니터링 | 매일 8,10,12,14,16,18,20,22시 | v5 |
| 판매 수집 | 30분 ±5분 지터 | v5 |
| 환율 자동 조회 | 서버 시작 시 1회 | v5 |
| 헬스체크 경보 | 5분 간격 | v5 |
| 언더컷 자동 방어 | 모니터링 직후 | v5 |
| **자동 재입찰** | 판매 감지 직후 | v6 |
| 자본 스냅샷 | 1시간 | Step 18-D |
| 일지 자동 저장 | 매일 23:55 | Step 18-D |
| 입찰 sync + rank | 30분 | Step 18-D |
| sync health check | 35분 | Step 18-D |
| 사전 갱신 (세션) | 12h | Step 18-D |
| 주간 리포트 | 매주 월 0:05 | Step 21 |
| **시장가 수집** | **2h** | **Step 31** |
| **자동 재로그인 체크** | **30분** | **Step 33-A** |

---

## 16. 신규 도구 4종 (Step 31, 커밋 c1e9980)

### 1. 🆕 신규 입찰 일괄 도구 (tab_new_bid.html)
- 모델/CNY 텍스트 입력 (TAB 구분)
- KREAM 시장가 자동 수집 (한국 환경 활용)
- 마진 계산 → GO/LOW/DEFICIT 자동 분류
- GO 항목 자동 체크 → 큐 등록
- 큐 등록 시 bid_cost 자동 저장

### 2. 💰 마진 계산기 강화 (tab_margin.html 추가 섹션)
- margin-batch: 사이즈별 일괄 입력
- margin-rotation: 모델별 회전 시간 추정 (sales_history 기반)

### 3. 💰 판매 마진 확정 (tab_realized.html)
- /api/real-margin (fuzzy 매칭) 활용
- 월별 매출/수익 막대 차트
- 모델별 ROI 순위
- 누적 표시: 매출 689k / 마진 56k / 8.2%

### 4. 📈 시장 모니터링 (tab_market.html)
- 활성 모델 가격 자동 수집 (2h)
- 가격 ±10% 이상 급변 알림
- 모델별 가격 추이 조회

---

## 17. 핵심 기술 결정사항 (반드시 숙지!)

### ⚠️ KREAM 인증 시스템
- **partner.kream.co.kr** 와 **kream.co.kr** 는 **완전히 별도 인증**
- 판매자센터는 **localStorage에 JWT accessToken** 저장 (쿠키 아님!)
- 모든 세션 저장은 반드시 `save_state_with_localstorage()` 함수 사용
- 실패 시 빈 세션으로 덮어쓰기 절대 금지

### 자동 로그인
- 판매자센터: Gmail IMAP으로 인증코드 자동 수신
- KREAM 일반사이트: 네이버 로그인 연동
- 둘 다: `python3 kream_bot.py --mode auto-login`

### 봇 감지 우회
- `channel="chrome"` (실제 Chrome) — 필수, Chromium은 차단
- `kream_bot.apply_stealth` 적용 (playwright_stealth 패키지 의존성 제거됨, Step 33-B)

### 수수료 / 원가 / 마진
- 판매수수료 = 판매가 × 6% (이벤트 시 3.5%/5.5%)
- 정산액 = 판매가 × (1 - 수수료율 × 1.1) - 2,500원
- 원가 = CNY × 환율 × 1.03 + 8,000원 배송비
- **관부가세: 고객 부담 → 원가에 미포함**
- **입찰가: 1,000원 단위 올림** (math.ceil)
- **예상수익 = 정산액 - 원가** (원가 없으면 NULL, 가짜 값 금지)

### 즉시구매가
- 즉시구매가 = 현재 살아있는 판매입찰 최저가 (과거 체결가 아님!)
- **사이즈별 개별 매칭** (전체 표시가격과 혼동 금지)

### 언더컷
- 기본 언더컷 1,000원 (settings 변경 가능)
- 입찰가 = 사이즈별 즉시구매가 - 언더컷

### macOS 환경 특이사항 (v8 NEW)
- `timeout` 명령어 없음 → `--max-time` 또는 자체 구현
- 좀비 PID 발생 시 `sudo lsof | kill -9` 필요
- nohup + & 백그라운드 시작 실패 케이스 있음 (좀비 잔존)
- 포그라운드 `python3 kream_server.py` 권장

---

## 18. 검증 시스템 (v5~v8)

### CLAUDE.md 절대 규칙 7대
1. 원가 없으면 가짜 값 사용 금지 → NULL
2. 판매 완료 건 수정/삭제 금지
3. price_history.db 직접 DROP/DELETE 금지
4. auth_state.json 백업 없이 덮어쓰기 금지
5. git push -f, git reset --hard 금지
6. 테스트 데이터로 실제 입찰 금지
7. **자동 토글 ON 변경 금지** (사용자 명시적 트리거만)

### Claude Code Hooks
- PostToolUse syntax-check (Python 문법)
- PreToolUse dangerous-command-check (DROP/DELETE/rm/force push 차단)
- Stop 체크리스트

### Skills
- db-migration: ALTER TABLE NULL 허용, DROP 금지
- api-addition: JSON 에러 응답, curl 테스트 필수

---

## 19. v7→v8 변경사항 (Step 18~33)

### Step 18-D: 일일 자동화 + APScheduler
- 일지 자동 저장 (23:55)
- 자본 스냅샷 (1h)
- 입찰 sync + rank (30분)
- sync health check (35분)
- 커밋: 0695df0

### Step 19: 정리 자동화 + cleanup 도구

### Step 20: 자본 가시성 + 모델 분석 + 의사결정 패널
- /api/capital-status, /capital-history, /capital-efficiency
- /api/portfolio/overview, /model/<model>/deep-analysis
- 커밋: bbc4b83

### Step 21: 효과 측정 인프라
- /api/weekly-report (매주 월 0:05)
- 커밋: 771a6d2

### Step 22: 구매대행 모델 인사이트 + 체결률 KPI
- /api/conversion-rate
- 커밋: 5d36225

### Step 23: 데이터 정합성 복구
- /api/real-margin (bid_cost fuzzy 매칭)
- 매출 689k / 마진 56k / 8.2% 확인됨
- 커밋: 0ca8662

### Step 25-30: sync 0건 시도 (모두 실패)
- /business/asks URL 추적
- 메뉴 클릭 방식 시도
- 결과: 모두 0건, 진짜 원인 못 잡음

### Step 31: 4개 도구 일괄 + Step 30 버그 수정
- 🆕 신규 입찰 / 💰 마진 강화 / 💰 판매 확정 / 📈 시장 모니터링
- market_price_history 테이블 신설
- /api/new-bid/calc-batch margin_status_msg NameError 수정
- collect_my_bids_via_menu print → stderr (로그 가시성)
- 커밋: c1e9980

### Step 32 v3: 알림 디바운싱
- _should_send_alert_dedupe 헬퍼
- safe_send_alert 60초 디바운싱
- 161건 → 일 2건 수준 예상
- 커밋: b0a9eba

### Step 33: D + B + A + C
- **Part D (커밋 bd178f0):** 환경 감지 버그 수정 (env=korea 인식)
- **Part B (커밋 1c9ce33):** sync 0건 → 51건 ⭐ 최대 성과
  - 진짜 원인: pagination 영역 클래스명 (Base_base__ot5b7)
  - playwright_stealth → apply_stealth 교체
- **Part A (커밋 d902a39):** 자동 재로그인 인프라
- **Part C (커밋 b2520cc):** 신규입찰_사용가이드.md

---

## 20. 알려진 버그와 해결 히스토리

### 해결 완료 (v5~v8)

| # | 버그 | 원인 | 해결 | 날짜 |
|---|---|---|---|---|
| 1 | 즉시구매가 103,000원 (실제 129,000원+) | API 캡처 실패 시 체결가 fallback | JSON-LD 초기값 + API/DOM 덮어씀 | 04-13 |
| 2 | 최근거래가가 display_price로 잘못 수집 | 잘못된 할당 | 체결거래 내역 첫 항목 | 04-13 |
| 3 | 판매자센터 세션 만료 | localStorage JWT 누락 | save_state_with_localstorage() | 04-14 |
| 4 | 자동 입찰 시 productId 0 | 큐 데이터에 productId 없음 | model로 KREAM 검색 | 04-14 |
| 5 | 고시정보 잘못된 필드에 입력 | 카테고리별 인덱스 하드코딩 | DOM 라벨 동적 매핑 | 04-14 |
| 6 | 빈 세션으로 auth_state 덮어쓰기 | 실패 시에도 세션 저장 | 성공 시에만 저장 | 04-14 |
| 7 | 즉시구매가 사이즈별 매칭 오류 | 전체 표시가격으로 덮어씀 | 사이즈별 buyPrice 개별 매핑 | 04-18 |
| 8 | 원가 등록해도 "원가 등록 필요" 표시 | JOIN 누락 | LEFT JOIN + 실시간 재계산 | 04-23 |
| 9 | 원가 없이 입찰 가능 | cny_price 검증 없음 | CNY 필수 강제 | 04-23 |
| 10 | calc-batch margin_status_msg NameError | 라우트 위치 if __name__ 안 | 라우트 위로 이동 + 헬퍼 위로 | 04-30 (Step 31) |
| 11 | 알림 161건 폭주 | 같은 alert 12h마다 발송 | 60초 디바운싱 | 05-03 (Step 32) |
| 12 | sync 0건 (Step 25~30 시도) | pagination 영역 클래스명 다름 | Base_base 클래스 + 숫자 매칭 | 05-03 (Step 33-B) |
| 13 | env=macbook_overseas 잘못 단정 | timeout만 났다고 단정 | 네이버 백업 체크 + 분기 | 05-03 (Step 33-D) |
| 14 | KREAM HTTP 500 | 짤린 User-Agent | Chrome 풀 UA | 05-03 (Step 33-D 부산물) |

### 미해결 / 주의사항

| # | 문제 | 상태 | 비고 |
|---|---|---|---|
| 1 | size 필드 빈 값 (sync 데이터) | 다음 작업 | 정규식이 모델번호 100/가격 168 매치 가능성 |
| 2 | API 캡처 타이밍 문제 | 간헐적 | DOM/JSON-LD fallback |
| 3 | kream_dashboard.html 7,000줄+ | 관리 어려움 | 짧게 요청 권장 |
| 4 | place_bid()가 orderId 미반환 | 구조적 한계 | bid_cost에 임시키 사용 |
| 5 | pending 102건 미처리 | sync 살아났으니 진행 가능 | 자동 조정 또는 수동 승인 |
| 6 | 자동 재로그인 24h 동작 미검증 | 시간 필요 | /api/auth/relogin-status로 확인 |
| 7 | macOS 좀비 PID | 환경 이슈 | sudo lsof | kill -9 필요 시 |

---

## 21. 터미널 명령어

```bash
cd ~/Desktop/kream_automation

# 서버 실행 (포그라운드 권장 — 좀비 PID 안 만듦)
python3 kream_server.py

# 백그라운드 (실패 시 좀비 가능)
nohup python3 kream_server.py > server.log 2>&1 & disown

# 좀비 PID 풀기 (백그라운드 시작 안 될 때)
sudo lsof -nP -iTCP:5001 | grep LISTEN | awk '{print $2}' | xargs sudo kill -9

# 로그인
python3 kream_bot.py --mode login              # 판매자센터 수동
python3 kream_bot.py --mode login-kream        # KREAM 수동
python3 kream_bot.py --mode auto-login         # 둘 다 자동
python3 kream_bot.py --mode auto-login-partner # 판매자센터만

# 가격 수집
python3 kream_collector.py --products 125755 --no-partner

# Claude Code
claude --dangerously-skip-permissions

# Git 동기화
git add -A && git commit -m "메시지" && git push origin main
```

---

## 22. 현재 DB 상태 (2026-05-04 기준)

| 테이블 | 건수 | 비고 |
|---|---|---|
| my_bids_local (JSON) | 51 | sync 정상화 후 |
| bid_cost | 6+ | 입찰 원가 |
| price_adjustments | 102+ | pending 처리 대기 |
| auto_adjust_log | 44+ | 자동 가격조정 이력 |
| auto_rebid_log | 0 | v6 자동 재입찰 (판매 없어 0건) |
| sales_history | 7 | 매출 689k / 마진 56k |
| notifications | ~35건 | 디바운싱 후 |
| market_price_history | 0 | 곧 누적 시작 |

---

## 23. 다음 작업 후보

### A. size 필드 정규식 수정 (10분)
- collect_my_bids_via_menu의 size 필드 빈 값 문제
- rawText 분석해서 사이즈만 정확히 추출

### B. pending 102건 가격 자동 조정 처리
- sync 살아났으니 진짜 의미 있음
- 마진 4,000원+ 조건 통과 건 자동 실행 또는 수동 승인

### C. 신규 입찰 도구 실전 사용
- 신규입찰_사용가이드.md 따라 모델 1개 등록
- 워크플로우 검증

### D. 자동 재로그인 24h 후 동작 검증
- /api/auth/relogin-status로 시도 이력 확인

### E. 판매 마진 확정 검증
- 51건 sync 데이터로 bid_cost 매칭 정확도 재검증

---

## 24. 계정 정보

- Claude Code: Team Account (JUDAY), juday@juday.co.kr
- KREAM: judaykream@gmail.com
- GitHub: judayjuday/kream-automation (Private)
- Gmail App Password: settings.json의 gmail_app_password
- 네이버: settings.json의 naver_id, naver_pw
- AS 전화번호: 010-7544-6127

---

## 25. 새 채팅 시작 방법

이 인수인계서(v8) + 다음세션_시작_컨텍스트_v27.md 첨부 후 시작.

**첫 메시지 템플릿:**
```
KREAM_인수인계서_v8.md + 다음세션_시작_컨텍스트_v27.md 읽었음.
직전 커밋 d902a39 (Step 33 D+B+A 완료).

오늘 작업: [구체 지시]
```

---

## Changelog

### v8 (2026-05-04)
- Step 18~33 모든 변경사항 반영
- 환경: 한국 (메모리 갱신, env=korea 인식)
- sync 51건 정상화 (Step 33-B 핵심 — Base_base__ot5b7 발견)
- 자동 재로그인 인프라 (Step 33-A)
- 알림 디바운싱 60초 (Step 32 v3)
- 신규 도구 4종 (Step 31)
- 비즈니스 데이터: 매출 689k / 마진 56k / 8.2%
- macOS 환경 특이사항 추가 (좀비 PID, timeout 없음)
- 새 미해결 7건 정리

### v7 (2026-04-26)
- 11개 Sub-Agent 시스템 구축
- 비전 문서 6종 Git 관리
- API 104→108개

### v6
- 자동 재입찰 시스템

### v5 (2026-04-24)
- 운영 안정화 1~3차
- 검증 시스템 (.claude/ hooks + skills)
