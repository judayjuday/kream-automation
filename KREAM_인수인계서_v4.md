# KREAM 판매자센터 자동화 프로젝트 — 인수인계서 v4 (2026-04-18)

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
- 환율: CNY 약 216원 (open.er-api.com에서 자동 업데이트)

---

## 2. 핵심 파일 (~/Desktop/kream_automation/)

```
kream_server.py          # Flask 서버 (대시보드 백엔드, 포트 5001) — 4,212줄
kream_dashboard.html     # 웹 대시보드 프론트엔드 — 5,124줄
kream_bot.py             # Playwright 자동화 (로그인/고시정보/입찰/발송수집) — 2,905줄
kream_collector.py       # KREAM 가격 수집 (API 인터셉트 + DOM 스크래핑) — 1,150줄
kream_adjuster.py        # 가격 자동 조정 (내 입찰 수집 → 시장 분석 → 추천) — 592줄
competitor_analysis.py   # 경쟁사 분석 — 532줄

tabs/                    # 탭별 HTML 파일 (대시보드에서 인클루드)
  tab_register.html      # 상품 등록/입찰 (큐 시스템)
  tab_margin.html        # 마진 계산기
  tab_bulk.html          # 대량 등록
  tab_discover.html      # 상품 발굴 + 자동 스캔
  tab_adjust.html        # 가격 자동 조정
  tab_prices.html        # 가격 수집
  tab_mybids.html        # 입찰 관리
  tab_history.html       # 실행 이력 + 판매 이력
  tab_settings.html      # 환율/수수료 설정

auth_state.json          # 판매자센터 로그인 세션 (localStorage JWT 포함!)
auth_state_kream.json    # KREAM 일반사이트 로그인 세션
queue_data.json          # 상품 큐 데이터 (서버 재시작 시 복원)
batch_history.json       # 실행 이력
my_bids_local.json       # 내 입찰 현황
kream_prices.json        # 가격 수집 결과
settings.json            # 환율/수수료/headless 설정
price_history.db         # SQLite DB (가격이력/입찰이력/판매이력/得物가격)

.gitignore               # auth_state*.json 제외됨
```

---

## 3. kream_server.py — API 엔드포인트 전체 목록

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
| POST | `/api/register` | 고시정보 + 입찰 통합 실행 | `{productId, price, size, qty, gosiAlready, gosi}` |

### 태스크 관리
| 메서드 | 경로 | 설명 |
|--------|------|------|
| GET | `/api/task/<task_id>` | 태스크 실행 상태/로그 폴링 |

### 가격 자동 조정 / 모니터링
| 메서드 | 경로 | 설명 | 파라미터 |
|--------|------|------|----------|
| POST | `/api/adjust/scan` | 내 입찰 수집 → 시장 분석 → 추천 | (없음) |
| POST | `/api/adjust/execute` | 승인된 가격 수정 실행 | `{items:[{orderId, newPrice}]}` |
| GET | `/api/adjust/pending` | 승인 대기 가격 조정 목록 | |
| GET | `/api/adjust/history-log` | 가격 조정 히스토리 | |
| POST | `/api/adjust/approve` | 가격 조정 승인 (자동 실행) | `{ids:[...]}` |
| POST | `/api/adjust/reject` | 가격 조정 거부 | `{ids:[...]}` |
| GET | `/api/monitor/status` | 입찰 순위 모니터링 상태 | |
| POST | `/api/monitor/start` | 모니터링 시작 | |
| POST | `/api/monitor/stop` | 모니터링 중지 | |
| POST | `/api/monitor/run-once` | 모니터링 1회 실행 | |
| POST | `/api/email/test` | 이메일 알림 테스트 | |

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
| POST | `/api/queue/auto-register` | 선택 상품 자동 고시정보+입찰 | `{items:[{productId, model, price, ...}]}` |
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
| POST | `/api/discovery/auto-scan` | **[NEW]** 자동 상품 발굴 (인기 키워드 → 점수 계산) |

### 가격 이력
| 메서드 | 경로 | 설명 |
|--------|------|------|
| GET | `/api/price-history/<product_id>` | 상품별 가격 이력 조회 |

### 중국 가격
| 메서드 | 경로 | 설명 |
|--------|------|------|
| POST | `/api/china-price` | 识货/得物 앱에서 중국 가격 검색 |

### 판매 이력 (NEW - v4)
| 메서드 | 경로 | 설명 | 파라미터 |
|--------|------|------|----------|
| GET | `/api/sales/recent` | 최근 판매 내역 | `?limit=50&offset=0` |
| POST | `/api/sales/sync` | 수동 판매 동기화 (Playwright) | |
| GET | `/api/sales/stats` | 판매 통계 (총/주간/모델별/일별) | |
| GET | `/api/sales/scheduler/status` | 판매 수집 스케줄러 상태 | |
| POST | `/api/sales/scheduler/start` | 스케줄러 시작 (1시간 간격) | |
| POST | `/api/sales/scheduler/stop` | 스케줄러 중지 | |
| GET | `/api/sales/alerts` | 새 체결건 알림 조회 | |
| POST | `/api/sales/alerts/dismiss` | 알림 확인 (클리어) | |
| GET | `/api/sales/rebid-recommendations` | 재입찰 추천 목록 | |

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
    # [NEW] 판매자센터 자동 로그인 (Gmail IMAP 인증코드 자동 입력)

async def login_auto_kream(playwright)
    # [NEW] KREAM 자동 로그인 (네이버 계정 연동)

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

async def place_bids_batch(page, bids, delay=3.0) → list
    # [NEW] 여러 사이즈 한 번에 입찰
```

### 발송관리 수집 (NEW - v4)

```python
async def collect_shipments(page, max_pages=10) → list
    # /business/shipments 페이지에서 발송완료 내역 수집
    # 발송완료 탭 클릭 → 100개씩 보기 → 테이블 파싱
    # 반환: [{order_id, product_id, model, product_info, size, sale_price, trade_date, ship_date, ship_status}]

def _parse_shipment_row(cells) → dict or None
    # 발송관리 테이블 행 파싱 (정규식 기반)
```

---

## 5. kream_collector.py — 가격 수집 구조

```python
async def collect_prices(product_ids, headless, save_excel, include_partner) → list
    # 메인 수집 함수

async def collect_from_kream(page, product_id) → dict
    # JSON-LD + DOM + API 인터셉트로 사이즈×배송타입별 가격 수집

async def collect_size_prices_via_api(page, product_id, pre_captured) → list
    # API 인터셉트로 사이즈별 buyPrice/sellPrice 수집
    # 해외배송(overseas) 가격과 국내배송(normal) 가격 구분
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
    # 해외배송 경쟁력 분석 (해외 vs 국내 가격차, 경쟁자 수)

def classify_market(size_margins) → dict
    # 시장 분류: 정상 시장(green) / 혼합 시장(yellow) / 비정상 시장(red) / 데이터 부족(gray)
    # 사이즈별 마진율 계산 → 평균 마진율 기반 판정
```

### 시장 체크 (/api/market-check)
- 得物 데이터가 있으면: 得物+KREAM 기준 분석
- 得物 데이터가 없으면: KREAM 큐 결과 기반으로 분석 (v4 개선 — 이전에는 404 에러)
- 데이터 소스 표시: "[KREAM 기준]" 또는 "[得物+KREAM 기준]"

---

## 7. DB 테이블 구조 (price_history.db)

### price_adjustments
```sql
id, order_id, product_id, model, name_kr, size, old_price, competitor_price,
new_price, expected_profit, status(pending/done/rejected), created_at, executed_at
```

### sales_history (NEW - v4)
```sql
id, order_id(UNIQUE), product_id, model, product_info, size,
sale_price, trade_date, ship_date, ship_status, collected_at
```

### dewu_prices
```sql
id, model, brand, eu_size, kr_size, cny_price, updated_at
```

### size_conversion
```sql
id, brand, eu_size, kr_size
```

### trade_volume
```sql
id, ... (거래량 추적)
```

---

## 8. 스케줄러 시스템

| 스케줄러 | 간격 | 설명 |
|----------|------|------|
| 입찰 순위 모니터링 | 매일 8,10,12,14,16,18,20,22시 | 내 입찰 순위 확인 → 이메일 알림 |
| 판매 수집 | 1시간 | 발송관리 페이지에서 판매 내역 수집 |
| 환율 자동 조회 | 서버 시작 시 1회 | open.er-api.com에서 CNY/USD 환율 |

---

## 9. 대시보드 기능 (http://localhost:5001)

### 상품 등록/입찰 탭 (tab_register.html)
- 상품 추가 폼 (모델번호 + CNY + 배송비 + 수량 + 만료일 + 입찰전략)
- 입찰 전략: 마진 10%/15%/20% / 언더컷(-N원, 설정에서 금액 변경) / 직접 입력
- **언더컷 금액 통일: 기본 1,000원 (설정 탭에서 변경 가능, undercut3k 옵션 제거됨)**
- 사이즈별 가격 입력 (신발용)
- 시장 체크 버튼 — 得物 없이도 KREAM 데이터만으로 분석 가능
- 큐 테이블, 일괄 실행, 결과 테이블, 자동 입찰

### 실행 이력 탭 (tab_history.html)
- **[NEW] 최근 판매 섹션** — 판매 통계 요약, 테이블 + 페이지네이션
- **[NEW] 재입찰 추천** — 판매 완료 건 기반 재입찰 큐 추가
- **[NEW] 판매 수집 스케줄러** — 시작/중지, 상태 표시
- **[NEW] 새 판매 알림 배지** — 30초 폴링
- 일괄 실행/자동 입찰 결과 자동 저장

### 상품 발굴 탭 (tab_discover.html)
- KREAM 키워드 검색
- 엑셀 데이터 (해외직구 TOP 100, 검색량 급등, BRAND TOP 100)
- **[NEW] 자동 상품 발굴** — 카테고리별 인기 키워드 검색 → 점수 계산 → 상위 50건
  - 점수 = 거래량(40) + 가격대(30) + 관심수(20) + 모델번호 보너스(10)
  - 키워드: 오니츠카 타이거, 뉴발란스 1906, 미즈노, 아식스, 나이키 덩크 등

### 기타 탭
- 마진 계산기, 대량 등록, 가격 자동 조정, 가격 수집, 입찰 관리, 설정

---

## 10. 핵심 기술 결정사항 (반드시 숙지!)

### ⚠️ KREAM 인증 시스템 (가장 중요!)
- **partner.kream.co.kr (판매자센터)** 와 **kream.co.kr (일반사이트)** 는 **완전히 별도 인증**
- 판매자센터는 **localStorage에 JWT accessToken** 저장 (쿠키 아님!)
- **실패 시 auth_state.json을 빈 세션으로 덮어쓰면 절대 안 됨!** (성공 시에만 저장)
- 모든 세션 저장은 반드시 `save_state_with_localstorage()` 함수 사용

### 자동 로그인 (v3 이후 추가)
- **판매자센터**: Gmail IMAP으로 인증코드 자동 수신 → 자동 입력
  - 설정: settings.json의 kream_email, kream_password, gmail_app_password
  - `python3 kream_bot.py --mode auto-login-partner`
- **KREAM 일반사이트**: 네이버 로그인 연동
  - 설정: settings.json의 naver_id, naver_pw
  - `python3 kream_bot.py --mode auto-login-kream`
- **둘 다**: `python3 kream_bot.py --mode auto-login`

### 봇 감지 우회
- `channel="chrome"` (실제 Chrome 사용) — 필수! Chromium은 차단됨
- `playwright-stealth` 패키지 적용
- headless=False 권장

### 수수료 구조
- 판매수수료 = 판매가 × 6%
- 판매수수료 부가세 = 수수료 × 10%
- 고정수수료 = 2,500원 (부가세 포함)

### 원가 계산
- 환율: CNY × open.er-api.com 환율 × 1.03(마진)
- **관부가세: 고객 부담 → 원가에서 제외** (v3 이후 변경)
- 해외배송비: 기본 8,000원
- **입찰가는 항상 1,000원 단위 올림** (math.ceil(price/1000)*1000)

### 즉시구매가 정의
- **즉시구매가 = 현재 살아있는 판매입찰 최저가** (과거 체결가 아님!)
- **사이즈별 개별 매칭** — 전체 상품 표시가격과 혼동하지 않음 (v4 버그 수정)

### 언더컷 전략
- 기본 언더컷 금액: 1,000원 (settings 탭에서 변경 가능)
- 입찰 예정가 = 해당 사이즈 즉시구매가 - 언더컷 금액
- undercut3k 옵션 제거됨 (v4)

---

## 11. v3→v4 변경사항 (2026-04-14 ~ 2026-04-18)

### A. 즉시구매가 사이즈별 매칭 버그 수정
- **문제:** 특정 사이즈의 즉시구매가가 전체 상품 표시가격으로 덮어써짐
- **수정:** kream_collector.py에서 사이즈별 buyPrice 개별 매핑

### B. 언더컷 전략 통일 (-1,000원)
- undercut3k 옵션 전체 제거 (tab_register.html, kream_dashboard.html)
- 모든 언더컷 금액이 SETTINGS.undercutAmount (기본 1000) 참조

### C. 발송관리 데이터 수집 + 판매 이력 추적
- kream_bot.py: `collect_shipments()` 함수 추가
- sales_history DB 테이블 신설
- 판매 수집 스케줄러 (1시간 간격, 24시간 운영)
- API 6개: /api/sales/recent, sync, stats, scheduler/*

### D. 판매 완료 → 자동 재입찰 추천
- 새 체결건 감지 시 알림 리스트 저장
- 대시보드 판매 배지 알림 (30초 폴링)
- 재입찰 추천 테이블 + 큐 자동 추가
- API: /api/sales/alerts, alerts/dismiss, rebid-recommendations

### E. 득물 가격 데이터 연동 개선
- 시장 체크: 得物 없어도 KREAM 데이터만으로 분석 진행
- "得物 가격 데이터가 없습니다" 404 → 분석 결과 반환
- 데이터 소스 표시 추가

### F. 상품 발굴 자동화 기초
- /api/discovery/auto-scan: 카테고리별 인기 키워드 자동 검색
- 점수 계산: 거래량 + 가격대 + 관심수 + 모델번호 보너스
- 대시보드 상품 발굴 탭에 자동 스캔 UI

### G. 이전 변경사항 (v3에서 추가됨, 참고)
- 자동 로그인 (Gmail IMAP + 네이버)
- 여러 사이즈 한 번에 입찰 (place_bids_batch)
- 사이즈별 가격 수집 (배송타입별 최저가)
- SQLite 가격 이력 DB
- 입찰 순위 모니터링 + 이메일 알림
- 경쟁사 분석 스크립트
- 시장 분류 시스템
- 해외배송 경쟁력 분석
- 원가 계산 변경 (관부가세 제외)
- 대시보드 파일 분리 구조 (tabs/)

---

## 12. 알려진 버그와 해결 히스토리

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

### 미해결 / 주의사항

| # | 문제 | 상태 | 비고 |
|---|------|------|------|
| 1 | 해외에서 kream.co.kr 접속 차단 | 환경 제약 | 사무실 iMac에서만 가격 수집 가능 |
| 2 | API 캡처 타이밍 문제 | 간헐적 | DOM/JSON-LD fallback으로 커버 |
| 3 | kream_dashboard.html 5,100줄+ | 관리 어려움 | Claude Code 사용 시 짧게 요청 |

---

## 13. 터미널 명령어

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
git add -A && git commit -m "업데이트" && git push -f origin main

# 서버 재시작
lsof -ti:5001 | xargs kill -9 2>/dev/null; python3 kream_server.py > server.log 2>&1 &
```

---

## 14. 사무실 iMac 원격 접속

- Chrome 원격 데스크톱: remotedesktop.google.com
- 계정: juday@juday.co.kr
- 에너지 설정: 잠자기 방지 ON, 정전 후 자동 시작 ON
- 설치됨: Python 3.9, Playwright, Flask, openpyxl, playwright-stealth

---

## 15. 계정 정보

- Claude Code: Team Account (JUDAY), juday@juday.co.kr
- KREAM: judaykream@gmail.com
- GitHub: judayjuday/kream-automation (Private)
- Gmail App Password: settings.json의 gmail_app_password
- 네이버: settings.json의 naver_id, naver_pw

---

## 16. 새 채팅 시작 방법

이 인수인계서를 첫 메시지에 붙여넣고 작업 시작.
Claude Code 사용 시 `claude --dangerously-skip-permissions` 로 실행.
파일은 `~/Desktop/kream_automation/` 에 모두 있음.
CLAUDE.md에 작업 규칙과 순차 작업 큐가 정의되어 있음.

**첫 요청 예시:**
"이 인수인계서를 읽고, ~/Desktop/kream_automation/ 폴더의 kream_server.py, kream_bot.py, kream_dashboard.html을 읽어서 현재 상태를 파악해줘. 그다음 [작업 내용] 해줘."
