# KREAM 판매자센터 자동화 프로젝트 — 인수인계서 v7 (2026-04-26)

## 1. 프로젝트 개요

**목적:** KREAM(크림) 판매자센터 반복 작업 자동화 + 해외(중국) 상품 대량 등록/입찰 시스템

**비전 (v7 NEW — NORTH_STAR.md 기반):** KREAM은 6개 도메인 중 하나(도메인 A)이며, 전체 시스템은 11개 Sub-Agent로 운영되는 자동화 생태계로 확장 중.

**사용자:** 주데이 (judayjuday)
- KREAM 계정: judaykream@gmail.com
- GitHub: judayjuday (Private: https://github.com/judayjuday/kream-automation.git)
- Claude Code: Team Account (JUDAY), juday@juday.co.kr
- Mac ARM (Python 3.9.6, Node.js, Claude Code 설치됨)
- AS 전화번호: 010-7544-6127
- 해외 거주 중 (한국 사무실 iMac으로 원격 작업)
- 识货 가격 수집은 별도 개발자에게 이관함 (API 키 Disabled)

**물류:** 중국 공장/셀러 → 허브넷(웨이하이 물류창고) → KREAM 검수센터 → 고객

**환경:**
- 맥북 (해외): 개발/테스트용. KREAM 일반사이트 차단됨. 판매자센터만 접속 가능.
- 사무실 iMac (한국): 실제 운영용. 크롬 원격 데스크톱으로 접속. KREAM 모든 사이트 접속 가능.
  - Cloudflare Tunnel로 외부에서 대시보드 접속 가능
- 환율: CNY 약 216원 (open.er-api.com에서 자동 업데이트)

**입찰 전략 (확정):**
- 사이즈당 2건 유지
- 마진 하한: 4,000원
- 언더컷: -1,000원 (설정에서 변경 가능)

---

## 2. 6개 도메인 구조 (v7 NEW)

전체 비즈니스 자동화는 6개 도메인으로 구성:

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

## 3. 11개 Sub-Agent 시스템 (v7 NEW — 완성)

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

**커밋 이력 (11개 에이전트 시스템 구축):**
- `aa8006a` 검증 3종 (orchestrator, auditor, qa-validator)
- `321a06c` 운영 2종 (kream-operator, infra-manager)
- `3fb16e7` 콘텐츠 3종 (product-crawler, image-editor, docs-keeper)
- `8786f21` 확장 운영 3종 (ssro-channel-operator, cs-drafter, dashboard-builder)

---

## 4. 7가지 핵심 원칙 (v7 NEW — NORTH_STAR.md 기반)

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
kream_server.py          # Flask 서버 (대시보드 백엔드, 포트 5001) — 6,835줄
kream_dashboard.html     # 웹 대시보드 프론트엔드 — 7,063줄
kream_bot.py             # Playwright 자동화 (로그인/고시정보/입찰/발송수집) — 2,905줄
kream_collector.py       # KREAM 가격 수집 (API 인터셉트 + DOM 스크래핑) — 1,275줄
kream_adjuster.py        # 가격 자동 조정 (내 입찰 수집 → 시장 분석 → 추천) — 600줄
competitor_analysis.py   # 경쟁사 분석 — 532줄
health_alert.py          # 헬스체크 경보 알림

tabs/                    # 탭별 HTML 파일 (대시보드에서 동적 로드)
  tab_register.html      # 상품 등록/입찰 (큐 시스템)
  tab_margin.html        # 마진 계산기
  tab_bulk.html          # 대량 등록
  tab_discover.html      # 상품 발굴 + 자동 스캔
  tab_adjust.html        # 가격 자동 조정 + 언더컷 자동 방어 [v5 강화]
  tab_prices.html        # 가격 수집
  tab_mybids.html        # 입찰 관리
  tab_history.html       # 실행 이력 + 판매 이력
  tab_sales.html         # [v5 NEW / v6 강화] 판매 관리 + 자동 재입찰 패널
  tab_logistics.html     # [v5 NEW] 물류 관리 (허브넷)
  tab_pattern.html       # 판매 패턴 분석
  tab_settings.html      # 환율/수수료/자동조정/자동재입찰 설정 [v6 강화]

auth_state.json          # 판매자센터 로그인 세션 (localStorage JWT 포함!)
auth_state_kream.json    # KREAM 일반사이트 로그인 세션
queue_data.json          # 상품 큐 데이터 (서버 재시작 시 복원)
batch_history.json       # 실행 이력
my_bids_local.json       # 내 입찰 현황
kream_prices.json        # 가격 수집 결과
settings.json            # 환율/수수료/headless/자동조정/자동재입찰 설정
price_history.db         # SQLite DB (WAL 모드) — 18개 테이블 (v7: auto_rebid_log 포함)

.claude/                 # Claude Code 검증 + 에이전트 시스템
  settings.json          # 프로젝트 전용 hooks 설정
  settings.local.json    # 로컬 전용 설정
  hooks/
    syntax-check.sh      # Python 파일 수정 후 문법 자동 체크
    dangerous-command-check.sh  # 위험 명령 차단 (DROP/DELETE/rm/force push)
    README.md
  skills/
    db-migration/SKILL.md    # DB 마이그레이션 규칙
    api-addition/SKILL.md    # API 추가 규칙
  agents/                # [v7 NEW] 11개 Sub-Agent 정의
    orchestrator.md
    qa-validator.md
    auditor.md
    kream-operator.md
    infra-manager.md
    product-crawler.md
    image-editor.md
    docs-keeper.md
    ssro-channel-operator.md
    cs-drafter.md
    dashboard-builder.md

# 비전 문서 (v7 NEW — Git 관리)
NORTH_STAR.md            # 7원칙, 6도메인, 6주 로드맵 (v1.4)
ARCHITECTURE.md          # 시스템 구조 + 신상품 파이프라인 F→E→B (v1.1)
AGENTS_INDEX.md          # 11개 Sub-Agents 명세 (v1.1)
MIGRATION_PLAN.md        # 5단계 이전 계획
VERIFICATION_PROTOCOL.md # Plan→Act→Verify→Report 프로토콜
OBSERVABILITY.md         # 로그 + 자가 진단 + 되돌리기

CLAUDE.md                # Claude Code 작업 규칙 + 절대 규칙 + 체크리스트
.gitignore               # auth_state*.json 제외됨
```

---

## 6. kream_server.py — API 엔드포인트 (총 108개)

### 페이지 서빙
| 메서드 | 경로 | 설명 |
|--------|------|------|
| GET | `/` | kream_dashboard.html 서빙 |
| GET | `/tabs/<filename>` | 탭 HTML 파일 서빙 |

### 상품 검색 / 가격 수집
| 메서드 | 경로 | 설명 |
|--------|------|------|
| POST | `/api/search` | KREAM 가격 수집 (모델번호/상품번호) |
| POST | `/api/keyword-search` | KREAM 키워드 검색 → 상품 목록 |
| POST | `/api/keyword-search/download` | 키워드 검색 결과 엑셀 다운로드 |
| POST | `/api/market-check` | 시장 분류 체크 (得物+KREAM or KREAM only) |

### 고시정보 / 입찰
| 메서드 | 경로 | 설명 |
|--------|------|------|
| POST | `/api/product-info` | 상품 고시정보 등록 (Playwright) |
| POST | `/api/bid` | 판매 입찰 단건 등록 |
| POST | `/api/register` | 고시정보 + 입찰 통합 실행 |

### 태스크 관리
| 메서드 | 경로 | 설명 |
|--------|------|------|
| GET | `/api/task/<task_id>` | 태스크 실행 상태/로그 폴링 |

### 가격 자동 조정 / 모니터링
| 메서드 | 경로 | 설명 |
|--------|------|------|
| POST | `/api/adjust/scan` | 내 입찰 수집 → 시장 분석 → 추천 |
| POST | `/api/adjust/execute` | 승인된 가격 수정 실행 |
| GET | `/api/adjust/pending` | 승인 대기 목록 |
| GET | `/api/adjust/history-log` | 가격 조정 히스토리 |
| POST | `/api/adjust/approve` | 가격 조정 승인 |
| POST | `/api/adjust/reject` | 가격 조정 거부 |
| GET | `/api/monitor/status` | 입찰 순위 모니터링 상태 |
| POST | `/api/monitor/start` | 모니터링 시작 |
| POST | `/api/monitor/stop` | 모니터링 중지 |
| POST | `/api/monitor/run-once` | 모니터링 1회 실행 |
| POST | `/api/email/test` | 이메일 알림 테스트 |

### 원가 관리 (v5 NEW)
| 메서드 | 경로 | 설명 |
|--------|------|------|
| POST | `/api/bid-cost/upsert` | 원가 등록/수정 (UPSERT) |
| GET | `/api/bid-cost/get/<order_id>` | 특정 주문의 원가 조회 |
| GET | `/api/bid-cost/missing` | 원가 없는 pending 건 모델별 그룹화 |
| POST | `/api/bid-cost/bulk-upsert` | 여러 건 원가 일괄 저장 |

### 언더컷 자동 방어 (v5 NEW)
| 메서드 | 경로 | 설명 |
|--------|------|------|
| GET | `/api/auto-adjust/status` | 자동 조정 상태 (통계/설정/성공률) |
| POST | `/api/auto-adjust/toggle` | 자동 조정 ON/OFF |
| POST | `/api/auto-adjust/run-once` | 수동 1회 실행 |
| GET | `/api/auto-adjust/history` | 자동 조정 이력 |

### 자동 재입찰 (v6 NEW)
| 메서드 | 경로 | 설명 |
|--------|------|------|
| GET | `/api/auto-rebid/status` | 자동 재입찰 상태 (통계/설정) |
| POST | `/api/auto-rebid/toggle` | 자동 재입찰 ON/OFF |
| POST | `/api/auto-rebid/run-once` | 수동 1회 실행 |
| GET | `/api/auto-rebid/history` | 재입찰 이력 |

### 대량 입찰
| 메서드 | 경로 | 설명 |
|--------|------|------|
| POST | `/api/bulk/generate` | KREAM 대량입찰 엑셀 생성 |
| GET | `/api/bulk/download` | 생성된 대량입찰 엑셀 다운로드 |
| POST | `/api/bulk/upload` | 대량입찰 엑셀 판매자센터 업로드 |

### 입찰 내역 관리
| 메서드 | 경로 | 설명 |
|--------|------|------|
| GET | `/api/my-bids` | 판매자센터에서 내 입찰 수집 |
| POST | `/api/my-bids/delete` | 입찰 삭제 |
| POST | `/api/my-bids/modify` | 입찰가 수정 |
| GET | `/api/my-bids/local` | 로컬 저장된 내 입찰 조회 |
| POST | `/api/my-bids/sync` | 판매자센터 → 로컬 동기화 |

### 상품 큐 시스템
| 메서드 | 경로 | 설명 |
|--------|------|------|
| POST | `/api/queue/add` | 큐에 상품 추가 |
| POST | `/api/queue/bulk-add` | 큐 일괄 추가 |
| POST | `/api/queue/upload-excel` | 엑셀 → 큐 추가 |
| GET | `/api/queue/list` | 큐 목록 조회 |
| PUT | `/api/queue/<item_id>` | 큐 항목 수정 |
| DELETE | `/api/queue/<item_id>` | 큐 항목 삭제 |
| DELETE | `/api/queue/clear` | 큐 전체 삭제 |
| POST | `/api/queue/execute` | 큐 일괄 실행 |
| GET | `/api/queue/download-excel` | 현재 큐 엑셀 다운로드 |
| GET | `/api/queue/template` | 업로드용 빈 엑셀 양식 다운로드 |

### 자동 입찰 (Playwright)
| 메서드 | 경로 | 설명 |
|--------|------|------|
| POST | `/api/queue/auto-register` | 선택 상품 자동 고시정보+입찰 |
| POST | `/api/auto-bid/pause` | 자동 입찰 일시정지 |
| POST | `/api/auto-bid/resume` | 자동 입찰 재개 |
| POST | `/api/auto-bid/stop` | 자동 입찰 중단 |
| GET | `/api/auto-bid/status` | 자동 입찰 상태 조회 |

### 입찰 정리 도구 (v6 — 커밋 1926071)
| 메서드 | 경로 | 설명 |
|--------|------|------|
| POST | `/api/cleanup/scan` | 4유형 정리 대상 스캔 |
| POST | `/api/cleanup/execute` | 정리 실행 (Soft Delete 1시간) |
| POST | `/api/cleanup/restore` | 1시간 이내 되돌리기 |

### 실행 이력
| 메서드 | 경로 | 설명 |
|--------|------|------|
| GET | `/api/history` | 개별 실행 이력 조회 |
| GET | `/api/batch-history` | 일괄 실행 이력 (최근 30건) |

### 설정 / 환율
| 메서드 | 경로 | 설명 |
|--------|------|------|
| GET | `/api/settings` | 설정 조회 |
| POST | `/api/settings` | 설정 저장 |
| GET | `/api/exchange-rate` | 현재 환율 조회 |
| POST | `/api/exchange-rate/refresh` | 환율 새로 가져오기 |

### 상품 발굴
| 메서드 | 경로 | 설명 |
|--------|------|------|
| GET | `/api/discovery` | 엑셀에서 상품 발굴 데이터 조회 |
| POST | `/api/discovery/upload` | 새 엑셀 파일 업로드 |
| POST | `/api/discovery/auto-scan` | 자동 상품 발굴 |

### 가격 이력
| 메서드 | 경로 | 설명 |
|--------|------|------|
| GET | `/api/price-history/<product_id>` | 상품별 가격 이력 조회 |

### 중국 가격
| 메서드 | 경로 | 설명 |
|--------|------|------|
| POST | `/api/china-price` | 识货/得物 앱에서 중국 가격 검색 |

### 판매 관리
| 메서드 | 경로 | 설명 |
|--------|------|------|
| GET | `/api/sales/recent` | 최근 판매 내역 |
| POST | `/api/sales/sync` | 수동 판매 동기화 (Playwright) |
| GET | `/api/sales/stats` | 판매 통계 |
| GET | `/api/sales/scheduler/status` | 판매 수집 스케줄러 상태 |
| POST | `/api/sales/scheduler/start` | 스케줄러 시작 |
| POST | `/api/sales/scheduler/stop` | 스케줄러 중지 |
| GET | `/api/sales/alerts` | 새 체결건 알림 조회 |
| POST | `/api/sales/alerts/dismiss` | 알림 확인 |
| GET | `/api/sales/rebid-recommendations` | 재입찰 추천 목록 |
| GET | `/api/sales/search` | 판매 검색 |
| GET | `/api/sales/by-model/<model>` | 모델별 판매 조회 |

### 물류 관리 (v5 NEW)
| 메서드 | 경로 | 설명 |
|--------|------|------|
| GET | `/api/logistics/pending` | 발송 대기 목록 |
| GET | `/api/logistics/requests` | 발송 요청 목록 |
| POST | `/api/logistics/request` | 발송 요청 생성 |
| PUT | `/api/logistics/request/<id>` | 발송 요청 수정 |
| GET | `/api/logistics/suppliers` | 협력사 목록 |
| POST | `/api/logistics/supplier` | 협력사 추가 |

### 헬스체크 / 알림
| 메서드 | 경로 | 설명 |
|--------|------|------|
| GET | `/api/health` | 서버 헬스 상태 |
| POST | `/api/health/test-alert` | 테스트 알림 발송 |
| GET | `/api/notifications/recent` | 최근 알림 |

---

## 7. 자동 재입찰 시스템 (v6 NEW — 커밋 1c67013)

### 개요
판매 수집 직후 새 체결건 감지 시 자동으로 재입찰 실행. 주데이님 매번 수동 재입찰 부담 제거.

### 작동 원리
1. 판매 수집 스케줄러가 새 판매 감지
2. `auto_rebid_after_sale()` 호출
3. 6중 안전장치 통과 시 같은 모델/사이즈에 자동 재입찰
4. 결과를 `auto_rebid_log`에 기록

### 6중 안전장치
| # | 조건 |
|---|---|
| 1 | 원가 존재 (bid_cost JOIN) |
| 2 | 마진 하한 4,000원 |
| 3 | 가격 급변 차단 (판매가 ±10% 벗어나면 중단) |
| 4 | 일일 한도 (auto_rebid_daily_max=20) |
| 5 | 모델 블랙리스트 |
| 6 | 루프 가드 (같은 order 중복 재입찰 차단) |

### 기본 설정 (settings.json)
```json
{
  "auto_rebid_enabled": false,    // 기본 OFF
  "auto_rebid_daily_max": 20,
  "auto_rebid_blacklist": []
}
```

### 액션 종류 (auto_rebid_log.action)
- `auto_rebid_success` — 재입찰 성공
- `skipped_no_cost` — 원가 없음
- `skipped_loop_guard` — 루프 방지
- `skipped_blacklist` — 블랙리스트
- `skipped_daily_max` — 일일 한도 초과
- `skipped_price_drift` — 가격 급변
- `skipped_low_margin` — 마진 부족
- `failed` — 입찰 실행 실패

---

## 8. kream_bot.py — 주요 함수 시그니처

### 브라우저 / 세션 관리
```python
async def create_browser(playwright, headless=False) → Browser
async def create_context(browser, storage=None) → BrowserContext
async def save_state_with_localstorage(page, context, path, origin_url)
    # ★ 핵심: storage_state + localStorage 병합 저장 (JWT 포함)
async def apply_stealth(page)
```

### 로그인
```python
async def login_manual(playwright)         # 판매자센터 수동
async def login_kream(playwright)          # KREAM 일반사이트 수동
async def login_auto_partner(playwright)   # 판매자센터 자동 (Gmail IMAP)
async def login_auto_kream(playwright)     # KREAM 자동 (네이버)
async def ensure_logged_in(page, context=None) → bool
async def dismiss_popups(page)
```

### 고시정보 입력 / 입찰
```python
async def fill_product_info(page, product, delay=2.0)
async def place_bid(page, bid, delay=3.0) → bool
async def place_bids_batch(page, product_id, bids, bid_days=30, delay=3.0) → dict
```

### 발송관리 수집
```python
async def collect_shipments(page, max_pages=10) → list
def _parse_shipment_row(cells) → dict or None
```

---

## 9. kream_collector.py — 가격 수집 구조

```python
async def collect_prices(product_ids, headless, save_excel, include_partner) → list
async def collect_from_kream(page, product_id) → dict
async def collect_size_prices_via_api(page, product_id, pre_captured) → list
```

**가격 우선순위 (즉시구매가):**
1. API `buyPrice` (국내 배송 최저가) — 가장 정확
2. 판매입찰 탭 DOM 최저가 — API 실패 시
3. JSON-LD `offers.price` — 최종 fallback

**사이즈별 즉시구매가:** 각 사이즈의 해외배송 buyPrice를 개별 매핑.

---

## 10. DB 테이블 구조 (price_history.db — 18개 테이블)

### price_adjustments
```sql
id, order_id, product_id, model, name_kr, size, old_price, competitor_price,
new_price, expected_profit, status, created_at, executed_at
```

### bid_cost (v5 NEW)
```sql
order_id(UNIQUE), model, size, cny_price, exchange_rate,
overseas_shipping, other_costs, created_at
```

### auto_adjust_log (v5 NEW)
```sql
id, order_id, model, size, old_price, new_price, expected_profit,
action, skip_reason, modify_result, executed_at
```

### auto_rebid_log (v6 NEW)
```sql
id, order_id, model, size, sold_price, new_bid_price, action,
skip_reason, executed_at
-- 인덱스: idx_rebid_executed, idx_rebid_model_size
```

### sales_history
```sql
id, order_id(UNIQUE), product_id, model, product_info, size,
sale_price, trade_date, ship_date, ship_status, collected_at
```

### suppliers (v5 NEW — 물류)
```sql
id, name, contact, phone, wechat, notes, created_at
```

### shipment_requests (v5 NEW — 물류)
```sql
id, order_id, product_id, model, size, supplier_id, hubnet_hbl,
request_date, tracking_number, status, proof_image, notes, created_at, updated_at
```

### shipment_costs (v5 NEW — 물류)
```sql
id, shipment_id, cost_type, amount, currency, notes, created_at
```

### 기타 테이블
- `dewu_prices`, `size_conversion`, `trade_volume`, `price_history`
- `my_bids_history`, `bid_competition_log`, `conditional_bids`
- `notifications`, `competitor_info`, `edit_log`

---

## 11. 스케줄러 시스템

| 스케줄러 | 간격 | 설명 |
|----------|------|------|
| 입찰 순위 모니터링 | 매일 8,10,12,14,16,18,20,22시 | 순위 체크 → 가격 조정 추천 |
| 판매 수집 | 30분 ±5분 지터 | 발송관리에서 판매 내역 수집 |
| 자동 재입찰 (v6) | 판매 수집 직후 | 새 판매 감지 시 자동 재입찰 |
| 환율 자동 조회 | 서버 시작 시 1회 | open.er-api.com에서 CNY/USD 환율 |
| 헬스체크 경보 | 5분 간격 | 서버 상태 모니터링 + 이메일 알림 |
| 언더컷 자동 방어 | 모니터링 직후 | pending 건 자동 수정 (6중 안전장치) |

---

## 12. 핵심 기술 결정사항 (반드시 숙지!)

### ⚠️ KREAM 인증 시스템 (가장 중요!)
- **partner.kream.co.kr** 와 **kream.co.kr** 는 **완전히 별도 인증**
- 판매자센터는 **localStorage에 JWT accessToken** 저장 (쿠키 아님!)
- **실패 시 auth_state.json을 빈 세션으로 덮어쓰면 절대 안 됨!**
- 모든 세션 저장은 반드시 `save_state_with_localstorage()` 사용

### 자동 로그인
- **판매자센터**: Gmail IMAP으로 인증코드 자동 수신
- **KREAM 일반사이트**: 네이버 로그인 연동
- **둘 다**: `python3 kream_bot.py --mode auto-login`

### 봇 감지 우회
- `channel="chrome"` (실제 Chrome 사용) — 필수! Chromium은 차단됨
- `playwright-stealth` 패키지 적용
- headless=False 권장

### 수수료 구조
- 판매수수료 = 판매가 × 6% (이벤트 시 3.5%/5.5%)
- 판매수수료 부가세 = 수수료 × 10%
- 고정수수료 = 2,500원 (부가세 포함)
- **정산액 = 판매가 × (1 - 수수료율 × 1.1) - 2,500**

### 원가 계산
- 환율: CNY × open.er-api.com 환율 × 1.03(마진)
- **관부가세: 고객 부담 → 원가에서 제외**
- 해외배송비: 기본 8,000원
- **입찰가는 항상 1,000원 단위 올림** (`math.ceil(price/1000)*1000`)
- **예상수익 = 정산액 - 원가** (원가 없으면 NULL, 가짜 값 금지)

### 즉시구매가 정의
- **즉시구매가 = 현재 살아있는 판매입찰 최저가** (과거 체결가 아님!)
- **사이즈별 개별 매칭**

### 언더컷 전략
- 기본 언더컷 금액: 1,000원 (settings 탭에서 변경 가능)
- 입찰 예정가 = 해당 사이즈 즉시구매가 - 언더컷 금액

---

## 13. 검증 시스템

### CLAUDE.md 절대 규칙 6개
1. 원가 없으면 가짜 값 사용 금지 → NULL
2. 판매 완료 건 수정/삭제 금지
3. price_history.db 직접 DROP/DELETE 금지
4. auth_state.json 백업 없이 덮어쓰기 금지
5. git push -f, git reset --hard 금지
6. 테스트 데이터로 실제 입찰 금지

### Claude Code Hooks (.claude/settings.json)
| Hook | 트리거 | 동작 |
|------|--------|------|
| PostToolUse (syntax-check.sh) | Edit/Write 후 | Python 문법 자동 체크 |
| PreToolUse (dangerous-command-check.sh) | Bash 실행 전 | 위험 명령 차단 |
| Stop (prompt) | 작업 종료 시 | 체크리스트 확인 요청 |

### Skills
- `db-migration`: ALTER TABLE 시 NULL 허용, DROP 금지
- `api-addition`: JSON 에러 응답, 응답 구조 표준, curl 테스트 필수

### 11개 Sub-Agent 시스템 (v7 NEW)
- 작업은 orchestrator를 거쳐 적절한 도메인 에이전트로 분배
- qa-validator가 결과 검증
- auditor가 사후 감사

---

## 14. v6→v7 변경사항 (2026-04-26)

### 11개 에이전트 시스템 구축 완료
- 4번의 커밋으로 11개 에이전트 정의 완료
- 검증 3종 → 운영 2종 → 콘텐츠 3종 → 확장 운영 3종 순서

### 비전 문서 6종 Git 관리 시작
- NORTH_STAR.md, ARCHITECTURE.md, AGENTS_INDEX.md
- MIGRATION_PLAN.md, OBSERVABILITY.md, VERIFICATION_PROTOCOL.md
- 단일 진실 소스 원칙(원칙 4) 강화

### 작업 방식 변화
- 기존: 작업지시서 기반 Claude Code 실행
- 추가: 에이전트 기반 자연어 요청 가능 ("kream-operator로 X 해줘")

### v6→v7 변경 없는 항목
- KREAM 운영 코드 (kream_server.py 등) — 변경 없음
- DB 스키마 — 변경 없음
- 자동 재입찰 시스템 — v6 그대로

---

## 15. 알려진 버그와 해결 히스토리

### 해결 완료

| # | 버그 | 원인 | 해결 | 날짜 |
|---|------|------|------|------|
| 1 | 즉시구매가 103,000원 (실제 129,000원+) | API 캡처 실패 시 체결가 fallback | JSON-LD 초기값 + API/DOM 덮어씀 | 04-13 |
| 2 | 최근거래가가 display_price로 잘못 수집 | 잘못된 할당 | 체결거래 내역 첫 항목에서 수집 | 04-13 |
| 3 | 판매자센터 세션 만료 | localStorage JWT 누락 | save_state_with_localstorage() | 04-14 |
| 4 | 자동 입찰 시 productId 0 | 큐 데이터에 productId 없음 | model로 KREAM 검색 | 04-14 |
| 5 | 고시정보 잘못된 필드에 입력 | 카테고리별 인덱스 하드코딩 | DOM 라벨 동적 매핑 | 04-14 |
| 6 | 빈 세션으로 auth_state 덮어쓰기 | 실패 시에도 세션 저장 | 성공 시에만 저장 | 04-14 |
| 7 | 즉시구매가 사이즈별 매칭 오류 | 전체 표시가격으로 덮어씀 | 사이즈별 buyPrice 개별 매핑 | 04-18 |
| 8 | 기본 전략 undercut3k 혼란 | 하드코딩 3000 | 설정값 참조 | 04-18 |
| 9 | 원가 등록해도 "원가 등록 필요" 표시 | JOIN 누락 | LEFT JOIN + 실시간 재계산 | 04-23 |
| 10 | 원가 없이 입찰 가능 | cny_price 검증 없음 | CNY 필수 강제 | 04-23 |

### 미해결 / 주의사항

| # | 문제 | 상태 | 비고 |
|---|------|------|------|
| 1 | 해외에서 kream.co.kr 접속 차단 | 환경 제약 | 사무실 iMac만 가능 |
| 2 | API 캡처 타이밍 문제 | 간헐적 | DOM/JSON-LD fallback |
| 3 | kream_dashboard.html 7,000줄+ | 관리 어려움 | 짧게 요청 권장 |
| 4 | place_bid()가 orderId 미반환 | 구조적 한계 | bid_cost에 임시키 사용 |
| 5 | last_sale 60시간 경과 (헬스체크 critical) | 점검 필요 | v7 완료 후 kream-operator로 점검 예정 |

---

## 16. 터미널 명령어

```bash
cd ~/Desktop/kream_automation

# 서버 실행
python3 kream_server.py                    # → http://localhost:5001

# 서버 재시작 (kill -9 직후 죽는 이슈 방지)
lsof -ti:5001 | xargs kill -9 2>/dev/null
sleep 2
nohup python3 kream_server.py > server.log 2>&1 &
disown

# 로그인
python3 kream_bot.py --mode login              # 판매자센터 수동
python3 kream_bot.py --mode login-kream        # KREAM 수동
python3 kream_bot.py --mode auto-login         # 둘 다 자동

# 가격 수집
python3 kream_collector.py --products 125755 --no-partner

# Claude Code (자연어 요청 가능)
claude --dangerously-skip-permissions

# Git 동기화
git add -A && git commit -m "메시지" && git push origin main
```

---

## 17. 현재 DB 상태 (2026-04-26 기준)

| 테이블 | 건수 | 비고 |
|--------|------|------|
| bid_cost | 6+ | 입찰 원가 데이터 |
| price_adjustments | 102+ | pending 일부 |
| auto_adjust_log | 44+ | 자동 가격조정 이력 |
| auto_rebid_log | 0 | v6 NEW (판매 없어서 0건) |
| sales_history | 0 | last_sale 60시간 경과 (점검 필요) |

---

## 18. 다음 작업 예정

### 즉시 점검 필요
- **last_sale 60시간 이슈** — 판매 수집 스케줄러 점검 (kream-operator 호출)

### 마이그레이션 (MIGRATION_PLAN.md)
- Step 1~5: 점진적 시스템 이전

### 도메인별 미구축 영역
- 도메인 B (SSRO): 자사몰 + 멀티채널 통합
- 도메인 C (CS): 일 50~100건 답변 자동화
- 도메인 D (대시보드): 6도메인 통합
- 도메인 E (이미지): 자동 편집 파이프라인
- 도메인 F (크롤링): 샤오홍슈 신상품 수집

### 페이스
1~2일/마일스톤, 다음 주 전 완료 원칙

---

## 19. 사무실 iMac 원격 접속

- Chrome 원격 데스크톱: remotedesktop.google.com
- 계정: juday@juday.co.kr
- Cloudflare Tunnel: 외부에서 대시보드 접속 가능
- 에너지 설정: 잠자기 방지 ON, 정전 후 자동 시작 ON
- 설치됨: Python 3.9, Playwright, Flask, openpyxl, playwright-stealth

---

## 20. 계정 정보

- Claude Code: Team Account (JUDAY), juday@juday.co.kr
- KREAM: judaykream@gmail.com
- GitHub: judayjuday/kream-automation (Private)
- Gmail App Password: settings.json의 gmail_app_password
- 네이버: settings.json의 naver_id, naver_pw

---

## 21. 새 채팅 시작 방법

이 인수인계서를 첫 메시지에 붙여넣고 작업 시작.

**v7부터는 두 가지 방식 가능:**

### 방식 A: 작업지시서 기반 (기존)
1. Claude (이 채팅)에게 작업지시서 작성 요청
2. `claude --dangerously-skip-permissions` 실행
3. 작업지시서 기반 Claude Code 작업

### 방식 B: 에이전트 기반 (v7 NEW)
1. `claude --dangerously-skip-permissions` 실행
2. 자연어로 직접 요청:
   - "kream-operator로 입찰 정리해줘"
   - "infra-manager로 헬스체크 돌려줘"
   - "auditor로 최근 7일 변경사항 감사해줘"
   - "qa-validator로 X 작업 검증해줘"

**파일은 `~/Desktop/kream_automation/` 에 모두 있음.**
**CLAUDE.md에 작업 규칙, 절대 규칙, 체크리스트 정의됨.**
**.claude/agents/ 에 11개 Sub-Agent 정의 있음.**

**첫 요청 예시 (방식 B):**
"이 인수인계서를 읽고, kream-operator를 호출해서 last_sale 60시간 경과 이슈 점검해줘."

---

## Changelog

- **v7 (2026-04-26)**: 11개 Sub-Agent 시스템 추가, 비전 문서 6종 Git 관리, 6개 도메인 정의
- **v6 (2026-04-24)**: 자동 재입찰 시스템 (auto_rebid_log, 6중 안전장치)
- **v5 (2026-04-24)**: 판매 관리 강화, 가격 자동 조정 원가 연동, 언더컷 자동 방어
- **v4 (2026-04-22)**: 운영 안정화 (WAL 모드, 백업, 헬스체크 신호등)
- **v3**: 다중 사이즈 배치 입찰
- **v2**: 자동 로그인 (Gmail IMAP, 네이버 OAuth)
- **v1**: 초기 자동화 시스템
