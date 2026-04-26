# KREAM 판매자센터 자동화 프로젝트 — 인수인계서 v5 (2026-04-24)

## 1. 프로젝트 개요

**목적:** KREAM(크림) 판매자센터 반복 작업 자동화 + 해외(중국) 상품 대량 등록/입찰 시스템
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

## 2. 핵심 파일 (~/Desktop/kream_automation/)

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
  tab_sales.html         # [v5 NEW] 판매 관리 대시보드
  tab_logistics.html     # [v5 NEW] 물류 관리 (허브넷)
  tab_pattern.html       # 판매 패턴 분석
  tab_settings.html      # 환율/수수료/자동조정 설정

auth_state.json          # 판매자센터 로그인 세션 (localStorage JWT 포함!)
auth_state_kream.json    # KREAM 일반사이트 로그인 세션
queue_data.json          # 상품 큐 데이터 (서버 재시작 시 복원)
batch_history.json       # 실행 이력
my_bids_local.json       # 내 입찰 현황
kream_prices.json        # 가격 수집 결과
settings.json            # 환율/수수료/headless/자동조정 설정
price_history.db         # SQLite DB (WAL 모드) — 17개 테이블

.claude/                 # [v5 NEW] Claude Code 검증 시스템
  settings.json          # 프로젝트 전용 hooks 설정
  settings.local.json    # 로컬 전용 설정
  hooks/
    syntax-check.sh      # Python 파일 수정 후 문법 자동 체크
    dangerous-command-check.sh  # 위험 명령 차단 (DROP/DELETE/rm/force push)
    README.md
  skills/
    db-migration/SKILL.md    # DB 마이그레이션 규칙
    api-addition/SKILL.md    # API 추가 규칙

CLAUDE.md                # Claude Code 작업 규칙 + 절대 규칙 + 체크리스트
.gitignore               # auth_state*.json 제외됨
```

---

## 3. kream_server.py — API 엔드포인트 전체 목록 (104개)

### 페이지 서빙
| 메서드 | 경로 | 설명 |
|--------|------|------|
| GET | `/` | kream_dashboard.html 서빙 |
| GET | `/tabs/<filename>` | 탭 HTML 파일 서빙 |

### 상품 검색 / 가격 수집
| 메서드 | 경로 | 설명 | 파라미터 |
|--------|------|------|----------|
| POST | `/api/search` | KREAM 가격 수집 (모델번호/상품번호) | `{productId?, model?}` |
| POST | `/api/keyword-search` | KREAM 키워드 검색 → 상품 목록 | `{keyword, maxScroll?}` |
| POST | `/api/keyword-search/download` | 키워드 검색 결과 엑셀 다운로드 | `{products:[...]}` |
| POST | `/api/market-check` | 시장 분류 체크 (得物+KREAM or KREAM only) | `{model}` |

### 고시정보 / 입찰
| 메서드 | 경로 | 설명 | 파라미터 |
|--------|------|------|----------|
| POST | `/api/product-info` | 상품 고시정보 등록 (Playwright) | `{productId, gosi:{...}}` |
| POST | `/api/bid` | 판매 입찰 단건 등록 | `{productId, price, size?, quantity?}` |
| POST | `/api/register` | 고시정보 + 입찰 통합 실행 | `{productId, price, size, qty, gosiAlready, gosi, cny_price?, model?}` |

### 태스크 관리
| 메서드 | 경로 | 설명 |
|--------|------|------|
| GET | `/api/task/<task_id>` | 태스크 실행 상태/로그 폴링 |

### 가격 자동 조정 / 모니터링
| 메서드 | 경로 | 설명 | 파라미터 |
|--------|------|------|----------|
| POST | `/api/adjust/scan` | 내 입찰 수집 → 시장 분석 → 추천 | (없음) |
| POST | `/api/adjust/execute` | 승인된 가격 수정 실행 | `{items:[{orderId, newPrice}]}` |
| GET | `/api/adjust/pending` | 승인 대기 목록 (bid_cost JOIN, 실시간 수익 재계산) [v5 강화] | |
| GET | `/api/adjust/history-log` | 가격 조정 히스토리 | |
| POST | `/api/adjust/approve` | 가격 조정 승인 (자동 실행) | `{ids:[...]}` |
| POST | `/api/adjust/reject` | 가격 조정 거부 | `{ids:[...]}` |
| GET | `/api/monitor/status` | 입찰 순위 모니터링 상태 | |
| POST | `/api/monitor/start` | 모니터링 시작 | |
| POST | `/api/monitor/stop` | 모니터링 중지 | |
| POST | `/api/monitor/run-once` | 모니터링 1회 실행 | |
| POST | `/api/email/test` | 이메일 알림 테스트 | |

### 원가 관리 (v5 NEW)
| 메서드 | 경로 | 설명 | 파라미터 |
|--------|------|------|----------|
| POST | `/api/bid-cost/upsert` | 원가 등록/수정 (UPSERT) + pending 건 재계산 | `{order_id, model, size, cny_price, exchange_rate?, overseas_shipping?, other_costs?}` |
| GET | `/api/bid-cost/get/<order_id>` | 특정 주문의 원가 조회 | |
| GET | `/api/bid-cost/missing` | 원가 없는 pending 건 모델별 그룹화 | |
| POST | `/api/bid-cost/bulk-upsert` | 여러 건 원가 일괄 저장 + 재계산 | `{entries:[{order_id, cny_price, ...}]}` |

### 언더컷 자동 방어 (v5 NEW)
| 메서드 | 경로 | 설명 | 파라미터 |
|--------|------|------|----------|
| GET | `/api/auto-adjust/status` | 자동 조정 상태 (통계/설정/성공률) | |
| POST | `/api/auto-adjust/toggle` | 자동 조정 ON/OFF | `{enabled: bool}` |
| POST | `/api/auto-adjust/run-once` | 수동 1회 실행 (enabled 무관) | |
| GET | `/api/auto-adjust/history` | 자동 조정 이력 | `?limit=50&filter=all&from_date=&to_date=` |

### 대량 입찰
| 메서드 | 경로 | 설명 | 파라미터 |
|--------|------|------|----------|
| POST | `/api/bulk/generate` | KREAM 대량입찰 엑셀 생성 | `{items:[...]}` |
| GET | `/api/bulk/download` | 생성된 대량입찰 엑셀 다운로드 | |
| POST | `/api/bulk/upload` | 대량입찰 엑셀 판매자센터 업로드 | |

### 입찰 내역 관리
| 메서드 | 경로 | 설명 | 파라미터 |
|--------|------|------|----------|
| GET | `/api/my-bids` | 판매자센터에서 내 입찰 수집 | |
| POST | `/api/my-bids/delete` | 입찰 삭제 | `{orderIds:[...]}` |
| POST | `/api/my-bids/modify` | 입찰가 수정 | `{orderId, newPrice}` |
| GET | `/api/my-bids/local` | 로컬 저장된 내 입찰 조회 | |
| POST | `/api/my-bids/sync` | 판매자센터 → 로컬 동기화 | |

### 상품 큐 시스템
| 메서드 | 경로 | 설명 | 파라미터 |
|--------|------|------|----------|
| POST | `/api/queue/add` | 큐에 상품 추가 | `{model, cny?, sizes?[], shipping?, bid_strategy?, bid_days?}` |
| POST | `/api/queue/bulk-add` | 큐 일괄 추가 | `{items:[...]}` |
| POST | `/api/queue/upload-excel` | 엑셀 → 큐 추가 | (multipart file) |
| GET | `/api/queue/list` | 큐 목록 조회 | |
| PUT | `/api/queue/<item_id>` | 큐 항목 수정 | `{model?, cny?, category?, ...}` |
| DELETE | `/api/queue/<item_id>` | 큐 항목 삭제 | |
| DELETE | `/api/queue/clear` | 큐 전체 삭제 | |
| POST | `/api/queue/execute` | 큐 일괄 실행 (KREAM 검색 + 마진 계산) | |
| GET | `/api/queue/download-excel` | 현재 큐 엑셀 다운로드 | |
| GET | `/api/queue/template` | 업로드용 빈 엑셀 양식 다운로드 | |

### 자동 입찰 (Playwright)
| 메서드 | 경로 | 설명 | 파라미터 |
|--------|------|------|----------|
| POST | `/api/queue/auto-register` | 선택 상품 자동 고시정보+입찰 (CNY 필수 검증 포함) [v5 강화] | `{items:[{productId, model, price, cny_price, ...}]}` |
| POST | `/api/auto-bid/pause` | 자동 입찰 일시정지 | |
| POST | `/api/auto-bid/resume` | 자동 입찰 재개 | |
| POST | `/api/auto-bid/stop` | 자동 입찰 중단 | |
| GET | `/api/auto-bid/status` | 자동 입찰 상태 조회 | |

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
| POST | `/api/discovery/auto-scan` | 자동 상품 발굴 (인기 키워드 → 점수 계산) |

### 가격 이력
| 메서드 | 경로 | 설명 |
|--------|------|------|
| GET | `/api/price-history/<product_id>` | 상품별 가격 이력 조회 |

### 중국 가격
| 메서드 | 경로 | 설명 |
|--------|------|------|
| POST | `/api/china-price` | 识货/得物 앱에서 중국 가격 검색 |

### 판매 관리 (v4+v5)
| 메서드 | 경로 | 설명 | 파라미터 |
|--------|------|------|----------|
| GET | `/api/sales/recent` | 최근 판매 내역 | `?limit=50&offset=0` |
| POST | `/api/sales/sync` | 수동 판매 동기화 (Playwright) | |
| GET | `/api/sales/stats` | 판매 통계 (총/주간/모델별/일별) | |
| GET | `/api/sales/scheduler/status` | 판매 수집 스케줄러 상태 | |
| POST | `/api/sales/scheduler/start` | 스케줄러 시작 | |
| POST | `/api/sales/scheduler/stop` | 스케줄러 중지 | |
| GET | `/api/sales/alerts` | 새 체결건 알림 조회 | |
| POST | `/api/sales/alerts/dismiss` | 알림 확인 (클리어) | |
| GET | `/api/sales/rebid-recommendations` | 재입찰 추천 목록 | |
| GET | `/api/sales/search` | 판매 검색 | |
| GET | `/api/sales/by-model/<model>` | 모델별 판매 조회 | |

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

## 4. kream_bot.py — 주요 함수 시그니처와 동작

### 브라우저 / 세션 관리

```python
async def create_browser(playwright, headless=False) → Browser
    # channel="chrome" (Chromium 차단 우회), stealth args 포함

async def create_context(browser, storage=None) → BrowserContext
    # storage_state 로드, viewport 1440x900, locale ko-KR

async def save_state_with_localstorage(page, context, path, origin_url)
    # ★ 핵심 함수: storage_state + localStorage 병합 저장
    # origins[].localStorage에 JWT accessToken 포함
    # 모든 세션 저장 시 이 함수 사용 필수!

async def apply_stealth(page)
    # playwright_stealth 패키지 적용
```

### 로그인

```python
async def login_manual(playwright)
    # 판매자센터 수동 로그인 → auth_state.json 저장

async def login_kream(playwright)
    # KREAM 일반사이트 수동 로그인 → auth_state_kream.json 저장

async def login_auto_partner(playwright)
    # 판매자센터 자동 로그인 (Gmail IMAP 인증코드 자동 입력)

async def login_auto_kream(playwright)
    # KREAM 자동 로그인 (네이버 계정 연동)

async def ensure_logged_in(page, context=None) → bool
    # /c2c 이동 → /sign-in 리다이렉트 확인
    # 빈 페이지 감지 + 자동 재로그인 시도
    # 성공 시 dismiss_popups() 호출

async def dismiss_popups(page)
    # 팝업 자동 닫기 (최대 10개)
```

### 고시정보 입력 / 입찰

```python
async def fill_product_info(page, product, delay=2.0)
    # DOM 라벨→인덱스 동적 매핑 (LABEL_ALIASES)

async def place_bid(page, bid, delay=3.0) → bool
    # 8단계 자동 입찰 플로우

async def place_bids_batch(page, product_id, bids, bid_days=30, delay=3.0) → dict
    # 여러 사이즈 한 번에 입찰
```

### 발송관리 수집

```python
async def collect_shipments(page, max_pages=10) → list
    # /business/shipments 페이지에서 발송완료 내역 수집

def _parse_shipment_row(cells) → dict or None
    # 발송관리 테이블 행 파싱 (정규식 기반)
```

---

## 5. kream_collector.py — 가격 수집 구조

```python
async def collect_prices(product_ids, headless, save_excel, include_partner) → list
async def collect_from_kream(page, product_id) → dict
async def collect_size_prices_via_api(page, product_id, pre_captured) → list
```

**가격 우선순위 (즉시구매가 결정):**
1. API `buyPrice` (국내 배송 최저가) — 가장 정확
2. 판매입찰 탭 DOM 최저가 — API 실패 시
3. JSON-LD `offers.price` — 최종 fallback

**사이즈별 즉시구매가 (v4 수정):**
- 각 사이즈의 해외배송 buyPrice를 개별 매핑
- 전체 상품 표시가격으로 덮어쓰지 않음

---

## 6. 경쟁사 분석 / 시장 분류 시스템

### competitor_analysis.py
```python
def analyze_competitiveness(kream_price, category, size_delivery_prices) → dict
def classify_market(size_margins) → dict
    # 정상 시장(green) / 혼합 시장(yellow) / 비정상 시장(red) / 데이터 부족(gray)
```

---

## 7. DB 테이블 구조 (price_history.db — 17개 테이블)

### price_adjustments
```sql
id, order_id, product_id, model, name_kr, size, old_price, competitor_price,
new_price, expected_profit, status(pending/profit_low/deficit/executed/rejected/failed/expired),
created_at, executed_at
```

### bid_cost (v5 NEW)
```sql
order_id(UNIQUE), model, size, cny_price, exchange_rate,
overseas_shipping, other_costs, created_at
-- 입찰 시점의 원가 정보. order_id 기준 UPSERT.
-- /api/adjust/pending에서 LEFT JOIN하여 실시간 수익 재계산.
```

### auto_adjust_log (v5 NEW)
```sql
id, order_id, model, size, old_price, new_price, expected_profit,
action(auto_modified/skipped_*/modify_failed), skip_reason, modify_result,
executed_at
-- 자동 가격 조정 이력. 모든 실행 결과 기록.
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
- `dewu_prices` — 得物 가격 데이터
- `size_conversion` — 사이즈 변환 (EU→KR)
- `trade_volume` — 거래량 추적
- `price_history` — 가격 이력
- `my_bids_history` — 내 입찰 이력
- `bid_competition_log` — 경쟁 입찰 로그
- `conditional_bids` — 조건부 입찰
- `notifications` — 알림
- `competitor_info` — 경쟁사 정보
- `edit_log` — 수정 로그

---

## 8. 스케줄러 시스템

| 스케줄러 | 간격 | 설명 |
|----------|------|------|
| 입찰 순위 모니터링 | 매일 8,10,12,14,16,18,20,22시 | 순위 체크 → 가격 조정 → 자동 실행 (설정 ON 시) |
| 판매 수집 | 30분 ±5분 지터 [v5 개선] | 발송관리에서 판매 내역 수집 |
| 환율 자동 조회 | 서버 시작 시 1회 | open.er-api.com에서 CNY/USD 환율 |
| 헬스체크 경보 | 5분 간격 | 서버 상태 모니터링 + 이메일 알림 |
| **언더컷 자동 방어** [v5 NEW] | 모니터링 직후 | pending 건 자동 수정 (6중 안전장치) |

---

## 9. 언더컷 자동 방어 시스템 (v5 NEW)

### 개요
모니터링 완료 후 pending 건 중 조건 통과 건만 자동으로 가격 수정.

### 6중 안전장치
| # | 조건 | 설명 |
|---|------|------|
| 1 | 원가 체크 | bid_cost에 원가 데이터 있어야 함 |
| 2 | 마진 하한 | expected_profit >= 4,000원 (설정 변경 가능) |
| 3 | 쿨다운 | 같은 order_id 24시간 이내 재수정 금지 |
| 4 | 하루 한도 | 기본 10건/일 (설정 변경 가능) |
| 5 | 실패율 차단 | 최근 1시간 실패율 > 20% → 자동 OFF + 알림 |
| 6 | 스테일 체크 | 수정 직전 상태 재확인 (pending 유지 확인) |

### 실행 플로우
1. `_run_monitor_check()` 완료
2. `auto_adjust_enabled=true` 확인
3. `auto_execute_approvals()` 호출
4. pending 건 순회 → 6개 조건 체크 → 통과 건만 `modify_bid_price()` 실행
5. 모든 결과 `auto_adjust_log`에 기록

### 기본 설정 (settings.json)
```json
{
  "auto_adjust_enabled": false,    // 기본 OFF
  "auto_adjust_daily_max": 10,
  "auto_adjust_min_profit": 4000
}
```

---

## 10. 원가 관리 시스템 (v5 NEW)

### bid_cost 테이블
- 입찰 성공 시 자동 저장 (큐 일괄 입찰 경로)
- `/api/register` 단일 입찰에서도 저장
- 대량 엑셀 업로드는 자동 저장 불가 → 경고 로그 + 수동 입력

### 원가 연동 플로우
1. 입찰 시 `cny_price` → `bid_cost` 테이블 저장
2. `/api/adjust/pending` → `bid_cost` LEFT JOIN → `expected_profit` 실시간 재계산
3. 원가 수정 → `price_adjustments.expected_profit` 자동 갱신
4. 자동 방어 엔진 → `bid_cost`에서 원가 조회 → 마진 체크

### CNY 필수 강제
- `settings.json`의 `require_cny_on_bid: true` (기본 ON)
- `/api/register`, `/api/queue/auto-register` 모두 검증
- 프론트엔드에서도 사전 체크
- 설정 OFF 가능 (경고만 표시)

### 일괄 원가 입력
- `/api/bid-cost/missing` → 원가 없는 건 모델별 그룹화
- `/api/bid-cost/bulk-upsert` → 여러 건 한번에 저장 + 재계산
- 대시보드 모달: "원가 없는 입찰 N건 일괄 입력"

---

## 11. 핵심 기술 결정사항 (반드시 숙지!)

### ⚠️ KREAM 인증 시스템 (가장 중요!)
- **partner.kream.co.kr (판매자센터)** 와 **kream.co.kr (일반사이트)** 는 **완전히 별도 인증**
- 판매자센터는 **localStorage에 JWT accessToken** 저장 (쿠키 아님!)
- **실패 시 auth_state.json을 빈 세션으로 덮어쓰면 절대 안 됨!** (성공 시에만 저장)
- 모든 세션 저장은 반드시 `save_state_with_localstorage()` 함수 사용

### 자동 로그인
- **판매자센터**: Gmail IMAP으로 인증코드 자동 수신 → 자동 입력
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
- **입찰가는 항상 1,000원 단위 올림** (math.ceil(price/1000)*1000)
- **예상수익 = 정산액 - 원가** (원가 없으면 NULL, 가짜 값 금지)

### 즉시구매가 정의
- **즉시구매가 = 현재 살아있는 판매입찰 최저가** (과거 체결가 아님!)
- **사이즈별 개별 매칭** — 전체 상품 표시가격과 혼동하지 않음

### 언더컷 전략
- 기본 언더컷 금액: 1,000원 (settings 탭에서 변경 가능)
- 입찰 예정가 = 해당 사이즈 즉시구매가 - 언더컷 금액

---

## 12. 검증 시스템 (v5 NEW)

### CLAUDE.md 절대 규칙
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
| PreToolUse (dangerous-command-check.sh) | Bash 실행 전 | DROP/DELETE/rm/force push 차단 |
| Stop (prompt) | 작업 종료 시 | 체크리스트 확인 요청 |

### Skills
- `db-migration`: ALTER TABLE 시 NULL 허용, DROP 금지, 인덱스 명명 규칙
- `api-addition`: JSON 에러 응답, 응답 구조 표준, curl 테스트 필수

---

## 13. v4→v5 변경사항 (2026-04-18 ~ 2026-04-24)

### Step 1: 판매 관리 대시보드 강화
- tab_sales.html 신설 (판매 현황 대시보드)
- 판매 수집 스케줄러 30분 ±5분 지터로 변경 (1시간에서)

### Step 2~2.6: 가격 자동 조정 원가 연동
- bid_cost 테이블 신설 (입찰 시점 원가 보관)
- /api/adjust/pending: bid_cost LEFT JOIN으로 실시간 수익 재계산
- 원가 수정 기능 (모달 등록/수정 분기)
- CNY 필수 강제 (settings.require_cny_on_bid, 기본 ON)
- 일괄 원가 입력 도구 (/api/bid-cost/missing, bulk-upsert)
- 3개 입찰 경로에서 bid_cost 자동 저장 + 경고 로그

### Step 3: 언더컷 자동 방어 시스템
- auto_adjust_log 테이블 신설
- auto_execute_approvals() 엔진 (6중 안전장치)
- API 4개: /api/auto-adjust/status, toggle, run-once, history
- 대시보드 UI: 자동 실행 패널 + 이력 테이블 + 설정 블록
- 모니터링 스케줄러 연동 (모니터링 완료 후 자동 실행)
- 기본값 OFF

### 검증 시스템 구축
- .claude/ 폴더 생성 (hooks, skills)
- CLAUDE.md 강화 (절대 규칙 6개, 체크리스트, 커밋 규칙, 테스트 데이터)
- 3개 Hook (syntax-check, dangerous-command-check, Stop)
- 2개 Skill (db-migration, api-addition)

### 운영 안정화 (v4.x)
- WAL 모드 적용 (동시 읽기/쓰기)
- 일일 백업 시스템
- 헬스체크 신호등 + 이메일 알림
- Cloudflare Tunnel 외부 접속

### 물류 관리 기초
- suppliers, shipment_requests, shipment_costs 테이블 신설
- tab_logistics.html 신설
- 물류 API 6개

---

## 14. 알려진 버그와 해결 히스토리

### 해결 완료

| # | 버그 | 원인 | 해결 | 날짜 |
|---|------|------|------|------|
| 1 | 즉시구매가 103,000원 (실제 129,000원+) | API 캡처 실패 시 체결가 fallback | JSON-LD 초기값 + API/DOM 덮어씀 | 04-13 |
| 2 | 최근거래가가 display_price로 잘못 수집 | 잘못된 할당 | 체결거래 내역 첫 항목에서 수집 | 04-13 |
| 3 | 판매자센터 세션 만료 | localStorage JWT 누락 | save_state_with_localstorage() 전면 교체 | 04-14 |
| 4 | 자동 입찰 시 productId 0 | 큐 데이터에 productId 없음 | model로 KREAM 검색하여 획득 | 04-14 |
| 5 | 고시정보 잘못된 필드에 입력 | 카테고리별 인덱스 하드코딩 | DOM 라벨 동적 매핑 | 04-14 |
| 6 | 빈 세션으로 auth_state 덮어쓰기 | 실패 시에도 세션 저장 | 성공 시에만 저장 | 04-14 |
| 7 | 즉시구매가 사이즈별 매칭 오류 | 전체 표시가격으로 덮어씀 | 사이즈별 buyPrice 개별 매핑 | 04-18 |
| 8 | 기본 전략 undercut3k 혼란 | 하드코딩 3000 | undercut3k 제거, 설정값 참조 | 04-18 |
| 9 | 원가 등록해도 "원가 등록 필요" 표시 | /api/adjust/pending에 bid_cost JOIN 없음 | LEFT JOIN + 실시간 재계산 | 04-23 |
| 10 | 원가 없이 입찰 가능 | cny_price 검증 없음 | CNY 필수 강제 (서버+프론트) | 04-23 |

### 미해결 / 주의사항

| # | 문제 | 상태 | 비고 |
|---|------|------|------|
| 1 | 해외에서 kream.co.kr 접속 차단 | 환경 제약 | 사무실 iMac에서만 가격 수집 가능 |
| 2 | API 캡처 타이밍 문제 | 간헐적 | DOM/JSON-LD fallback으로 커버 |
| 3 | kream_dashboard.html 7,000줄+ | 관리 어려움 | Claude Code 사용 시 짧게 요청 |
| 4 | place_bid()가 orderId 미반환 | 구조적 한계 | bid_cost에 임시키 사용 (productId_size) |

---

## 15. 터미널 명령어

```bash
cd ~/Desktop/kream_automation

# 서버 실행
python3 kream_server.py                    # → http://localhost:5001

# 로그인
python3 kream_bot.py --mode login              # 판매자센터 수동
python3 kream_bot.py --mode login-kream        # KREAM 수동
python3 kream_bot.py --mode auto-login         # 둘 다 자동
python3 kream_bot.py --mode auto-login-partner # 판매자센터만 자동
python3 kream_bot.py --mode auto-login-kream   # KREAM만 자동 (네이버)

# 가격 수집
python3 kream_collector.py --products 125755 --no-partner

# Claude Code
claude --dangerously-skip-permissions

# Git 동기화
git add -A && git commit -m "업데이트" && git push origin main

# 서버 재시작
lsof -ti:5001 | xargs kill -9 2>/dev/null; python3 kream_server.py > server.log 2>&1 &
```

---

## 16. 현재 DB 상태 (2026-04-24 기준)

| 테이블 | 건수 | 비고 |
|--------|------|------|
| bid_cost | 6 | 입찰 원가 데이터 |
| price_adjustments | 102 | 44건 pending |
| auto_adjust_log | 44 | 자동 실행 이력 |
| sales_history | 0 | 판매 내역 |

---

## 17. 다음 작업 예정

- **Step 4:** 자동 재입찰 시스템
- **Step 5:** 입찰 정리 도구
- **Step 6:** 인기 정의 시스템

---

## 18. 사무실 iMac 원격 접속

- Chrome 원격 데스크톱: remotedesktop.google.com
- 계정: juday@juday.co.kr
- Cloudflare Tunnel: 외부에서 대시보드 접속 가능
- 에너지 설정: 잠자기 방지 ON, 정전 후 자동 시작 ON
- 설치됨: Python 3.9, Playwright, Flask, openpyxl, playwright-stealth

---

## 19. 계정 정보

- Claude Code: Team Account (JUDAY), juday@juday.co.kr
- KREAM: judaykream@gmail.com
- GitHub: judayjuday/kream-automation (Private)
- Gmail App Password: settings.json의 gmail_app_password
- 네이버: settings.json의 naver_id, naver_pw

---

## 20. 새 채팅 시작 방법

이 인수인계서를 첫 메시지에 붙여넣고 작업 시작.
Claude Code 사용 시 `claude --dangerously-skip-permissions` 로 실행.
파일은 `~/Desktop/kream_automation/` 에 모두 있음.
CLAUDE.md에 작업 규칙, 절대 규칙, 체크리스트가 정의되어 있음.
.claude/ 폴더에 자동 검증 hooks가 설치되어 있음.

**첫 요청 예시:**
"이 인수인계서를 읽고, ~/Desktop/kream_automation/ 폴더의 kream_server.py, kream_bot.py, kream_dashboard.html을 읽어서 현재 상태를 파악해줘. 그다음 [작업 내용] 해줘."
