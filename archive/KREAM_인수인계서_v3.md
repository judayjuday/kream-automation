# KREAM 판매자센터 자동화 프로젝트 — 인수인계서 v3 (2026-04-14)

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
- 환율: CNY 217.30원 (open.er-api.com에서 자동 업데이트)

---

## 2. 핵심 파일 (~/Desktop/kream_automation/)

```
kream_server.py          # Flask 서버 (대시보드 백엔드, 포트 5001) — 2,431줄
kream_dashboard.html     # 웹 대시보드 프론트엔드 — 4,518줄 (매우 큼)
kream_bot.py             # Playwright 자동화 (로그인/고시정보/입찰) — 1,481줄
kream_collector.py       # KREAM 가격 수집 (API 인터셉트 + DOM 스크래핑) — 1,023줄
kream_adjuster.py        # 가격 자동 조정 (내 입찰 수집 → 시장 분석 → 추천) — 592줄
china_price.py           # 识货 앱 자동화 (별도 개발자 이관, 현재 미사용)

auth_state.json          # 판매자센터 로그인 세션 (localStorage JWT 포함!)
auth_state_kream.json    # KREAM 일반사이트 로그인 세션
queue_data.json          # 상품 큐 데이터 (서버 재시작 시 복원)
batch_history.json       # 실행 이력
my_bids_local.json       # 내 입찰 현황
kream_prices.json        # 가격 수집 결과
settings.json            # 환율/수수료/headless 설정

.gitignore               # auth_state*.json 제외됨
```

---

## 3. kream_server.py — API 엔드포인트 전체 목록

### 페이지 서빙
| 메서드 | 경로 | 설명 |
|--------|------|------|
| GET | `/` | kream_dashboard.html 서빙 |

### 상품 검색 / 가격 수집
| 메서드 | 경로 | 설명 | 파라미터 |
|--------|------|------|----------|
| POST | `/api/search` | KREAM 가격 수집 (모델번호/상품번호) | `{productId?, model?}` |
| POST | `/api/keyword-search` | KREAM 키워드 검색 → 상품 목록 | `{keyword, maxScroll?}` |
| POST | `/api/keyword-search/download` | 키워드 검색 결과 엑셀 다운로드 | `{products:[...]}` |

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

### 가격 자동 조정
| 메서드 | 경로 | 설명 | 파라미터 |
|--------|------|------|----------|
| POST | `/api/adjust/scan` | 내 입찰 수집 → 시장 분석 → 추천 | (없음) |
| POST | `/api/adjust/execute` | 승인된 가격 수정 실행 | `{items:[{orderId, newPrice}]}` |

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

### 중국 가격
| 메서드 | 경로 | 설명 |
|--------|------|------|
| POST | `/api/china-price` | 识货/得物 앱에서 중국 가격 검색 |

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
    # /sign-in 페이지 열고 사용자가 직접 로그인
    # 로그인 후 /c2c 방문 → localStorage JWT 추출 → storage_state 병합

async def login_kream(playwright)
    # KREAM 일반사이트 수동 로그인 → auth_state_kream.json 저장

async def ensure_logged_in(page) → bool
    # /c2c 이동 → /sign-in 리다이렉트 확인
    # 빈 페이지 감지 (body 텍스트 < 20자 → 세션 만료)
    # 네비게이션 요소 존재 확인
    # 성공 시 dismiss_popups() 호출

async def dismiss_popups(page)
    # 팝업 자동 닫기: "다시 보지 않기", "확인", X 버튼, "오늘 하루 안 보기"
    # 최대 10개까지 처리
```

### 고시정보 입력

```python
async def fill_product_info(page, product, delay=2.0)
    # 1. /business/my/products/{product_id} 이동
    # 2. 고시 카테고리 드롭다운 선택 (반드시 먼저! attributeSet 필드 생성됨)
    # 3. ★ DOM에서 라벨→인덱스 동적 매핑 (LABEL_ALIASES로 유연 매칭)
    #    - 카테고리별 필드 순서가 다름 (가방/의류/신발)
    #    - 하드코딩된 인덱스 사용 안 함
    # 4. attributeSet.N.value에 값 입력
    # 5. 원산지 드롭다운 (countryOfOriginId)
    # 6. HS코드 드롭다운 (hsCodeId)
    # 7. 배송 정보 (무게/박스 사이즈)
    # 8. '저장하기' 버튼 클릭 → 네트워크 응답 모니터링
    # 9. 저장 검증: 새로고침 → 첫 필드 값 확인
```

### 입찰 등록

```python
async def place_bid(page, bid, delay=3.0) → bool
    # 8단계 자동 입찰 플로우 (상세 디버그 로깅 포함):
    # [1] 상품 검색: /business/products?keyword={product_id}
    # [2] "판매 입찰하기" 버튼 클릭
    #     → "상품 정보 입력 필요" 팝업 감지 (고시정보 미등록)
    # [3] 옵션/수량 선택 모달
    #   [3-1] 사이즈 선택 (버튼/드롭다운/class 매칭 3가지 방법)
    #   [3-2] 수량 설정 (+ 버튼, Counter_plus 셀렉터)
    #   [3-3] "판매 입찰 계속" 클릭
    # [4] 판매 희망가 입력 (placeholder*="판매 희망가" → "희망가" → 폴백)
    # [4-1] 입찰기한 설정 (30/60/90일, select 또는 버튼)
    # [5] 체크박스 선택 (React: 부모 div 클릭 → force 클릭 폴백)
    # [6] 하단 "판매 입찰하기" 최종 클릭 (disabled 확인)
    # [7] 확인 팝업 ("총 N건의 판매 입찰하기" → 확인)
    # [8] "입찰 신청 결과" 팝업 → "성공 N건" 텍스트 확인
    #     네트워크 POST/PUT 요청/응답 로깅
```

### 유틸리티

```python
async def react_clear_and_fill(page, selector, value)
    # React input 클리어 + 타이핑 (Meta+a → Backspace → type)

async def select_dropdown(page, button_selector, option_text)
    # 드롭다운 클릭 → 옵션 선택 (get_by_text → li/role="option" 폴백)

async def _save_debug_screenshot(page, name)
    # debug_screenshots/ 에 타임스탬프 스크린샷 저장

async def _debug_dump_page(page, label)
    # URL, 타이틀, 버튼 목록, 모달/팝업, 에러 메시지 덤프
```

---

## 5. kream_collector.py — 가격 수집 구조

```python
async def collect_prices(product_ids, headless, save_excel, include_partner) → list
    # 메인 수집 함수: KREAM + 판매자센터 동시 수집

async def collect_from_kream(page, product_id) → dict
    # 1) JSON-LD 스키마 (#Product) → offers.price = 즉시구매가 초기값
    # 2) DOM 스크래핑 → 표시가격, 상품명, 모델번호, 거래수
    # 3) 체결 거래 내역 (transaction_history_summary 클래스)
    # 4) 판매입찰 탭 → sell_bids (최저가 = 즉시구매가)
    # 5) 구매입찰 탭 → buy_bids (최고가 = 즉시판매가)
    # 6) API 인터셉트 (api.kream.co.kr/api/p/options/display)
    #    → 사이즈×배송타입별 가격 (buyPrice, sellPrice)
    #    → 국내 배송 최저가 우선 (해외 포함 overall_price 대신)
    # 7) 사이즈별 가격 계산

async def collect_size_prices_via_api(page, product_id, pre_captured) → list
    # 페이지 로드 시 API 사전캡처 → 없으면 reload fallback
    # picker_type=buy → buyPrice (판매입찰 최저가)
    # picker_type=sell → sellPrice (구매입찰 최고가)

async def collect_from_partner(page, product_id) → dict
    # 판매자센터 상품/입찰 목록 테이블 파싱
```

**가격 우선순위 (즉시구매가 결정):**
1. API `buyPrice` (국내 배송 최저가) — 가장 정확
2. 판매입찰 탭 DOM 최저가 — API 실패 시
3. JSON-LD `offers.price` — 최종 fallback

---

## 6. kream_adjuster.py — 가격 자동 조정

```python
async def collect_my_bids(headless) → list
    # /business/asks 에서 입찰 중 내역 수집
    # 주문번호(A-XX000000000), 모델번호, 사이즈, 가격, 순번, 판매유형

async def collect_market_data(product_ids, headless) → dict
    # collect_from_kream 호출하여 시장 데이터 수집

def calc_recommendation(bid, market) → dict
    # 추천가 계산 규칙:
    # - 기존 입찰가보다 절대 낮추지 않음 (올리거나 유지만)
    # - Case 1: 이미 최저가 이하 → 유지
    # - Case 2: 최근 거래가 > 내 가격 → 거래가 근처 상향
    # - Case 3: 순번 5위 초과 → 최저가 매칭 상향
    # - Case 4: 적정가 → 유지

async def modify_bid_price(order_id, new_price, headless) → bool
    # 판매자센터에서 기존 입찰 가격 수정

async def full_adjust_flow(headless) → dict
    # 1→2→3단계 통합: 내 입찰 수집 → 시장 분석 → 추천 생성
```

---

## 7. kream_server.py — 주요 서버 로직

### 환율 시스템
- 서버 시작 시 백그라운드 스레드로 환율 자동 조회
- primary: `open.er-api.com/v6/latest/CNY`
- fallback: `cdn.jsdelivr.net/@fawazahmed0/currency-api`
- settings.json에 cnyRate, usdRate 저장

### 태스크 시스템
- `new_task() → task_id` (자동 증가)
- 모든 비동기 작업은 `threading.Thread(daemon=True)` 실행
- 프론트엔드에서 `/api/task/<id>` 폴링으로 상태/로그 확인

### 자동 입찰 제어
- `auto_bid_control["state"]`: idle → running → paused/stopping → idle
- `auto_bid_event` (threading.Event): paused 시 clear → wait 블로킹

### 큐 일괄 실행 (`/api/queue/execute`)
1. 같은 품번은 `search_cache`로 KREAM 검색 1번만 (중복 방지)
2. 카테고리 자동 판별: KREAM 카테고리 → 영문명 → 한글명 순
3. 고시정보 자동 채움 (`auto_fill_gosi`): 영문명에서 종류/소재/색상 추출
4. 마진 계산 (`calculate_margin_for_queue`): 환율×마진 + 관세 + 부가세 + 배송비

### 자동 입찰 (`/api/queue/auto-register`)
- **productId가 0이면 model로 KREAM 검색하여 상품번호 획득** (2026-04-14 수정)
- `run_full_register()` 호출 → 고시정보 + 입찰 순차 실행
- 실패 시에도 빈 세션으로 auth_state.json 덮어쓰지 않음

---

## 8. 대시보드 기능 (http://localhost:5001)

### 상품 등록/입찰 탭
- 상품 추가 폼 (모델번호 + CNY + 배송비 + 수량 + 만료일 + 입찰전략)
- 입찰 전략: 마진 10%/15%/20% / 언더컷(-3,000원) / 직접 입력
- 사이즈별 가격 입력 (신발용, 항상 표시)
- 큐 테이블: 복사/삭제, 만료일 선택(30/60/90일), 큐 데이터 JSON 자동 저장/복원
- 일괄 실행 (KREAM 검색 + 마진 계산) — 같은 품번은 한 번만 검색
- 잘못된 품번 5초 내 실패 처리
- 결과 테이블: 입찰 예정가(인라인 편집), 예상 마진, 내 입찰가, 고시정보 상태
- 품번 클릭 → 상세 패널 (기본정보/고시정보 수정/원가분해/시장현황/마진시뮬레이션)
- 모델번호 클릭 정렬
- "자동 입찰 (Playwright)" 버튼 — 고시정보 등록 + 입찰 자동 처리
- 일시정지/이어서/중단 버튼
- 엑셀 백업 다운로드/업로드, 큐 다운로드/업로드, 양식 다운로드
- "내 입찰 현황 동기화" 버튼

### 마진 계산기 탭
- 모델번호 검색 → KREAM 실시간 가격 + CNY 역계산

### 대량 등록 탭
- 엑셀 생성 + KREAM 업로드 자동화

### 데이터 탭들
- 상품 발굴, 가격 자동 조정, 가격 수집, 입찰 관리

### 실행 이력 탭
- 일괄 실행/자동 입찰 결과 자동 저장 (batch_history.json)
- 날짜별 조회, 클릭하면 상세 펼침, "큐에 다시 추가" 버튼

### 환율/수수료 탭
- 서버 시작 시 자동 환율 가져오기 (open.er-api.com)
- 좌측 하단에 현재 환율 + 업데이트 시간 표시

---

## 9. 핵심 기술 결정사항 (반드시 숙지!)

### ⚠️ KREAM 인증 시스템 (가장 중요!)
- **partner.kream.co.kr (판매자센터)** 와 **kream.co.kr (일반사이트)** 는 **완전히 별도 인증**
- 판매자센터는 **쿠키가 아니라 localStorage에 JWT accessToken** 저장
- auth_state.json에는 쿠키 2개(GA)만 있고, 실제 인증은 `origins[].localStorage`의 accessToken
- Playwright `storage_state`의 origins 필드에 localStorage 포함시켜야 함
- **실패 시 auth_state.json을 빈 세션으로 덮어쓰면 절대 안 됨!** (성공 시에만 저장)
- 모든 세션 저장은 반드시 `save_state_with_localstorage()` 함수 사용

### 봇 감지 우회
- `channel="chrome"` (실제 Chrome 사용) — 필수! Chromium은 차단됨
- `playwright-stealth` 패키지 적용
- headless=False 권장 (settings.json에서 설정)

### 수수료 구조
- 판매수수료 = 판매가 × 6%
- 판매수수료 부가세 = 수수료 × 10%
- 고정수수료 = 2,500원 (부가세 포함)

### 원가 계산
- 환율: CNY × open.er-api.com 환율 × 1.03(마진)
- 관세: 가방 8%, 의류/신발 13% (USD 150 초과 시)
- 해외배송비: 기본 8,000원
- **입찰가는 항상 1,000원 단위 올림** (math.ceil(price/1000)*1000)

### 즉시구매가 정의
- **즉시구매가 = 현재 살아있는 판매입찰 최저가** (과거 체결가 아님!)
- KREAM API buyPrice가 None이면 판매입찰 탭에서 직접 수집
- 체결 거래 가격을 즉시구매가로 사용하면 안 됨

### 고시정보 필드 매핑
- 카테고리별로 필드 순서가 다름 (가방 vs 의류 vs 신발)
- DOM에서 실제 라벨→인덱스 매핑을 동적으로 읽음 (LABEL_ALIASES 사용)
- 고시정보 기본값: 제조국 "상품별 상이", 원산지 "China (중국) (CN)", AS전화번호 "010-7544-6127"
- 가방 HS: "4202.92", 신발 HS: "6404.11"
- 고시카테고리 기본값: "가방" (이전 "의류"에서 변경됨)

---

## 10. 2026-04-14 변경사항 전체 정리

### A. localStorage JWT 세션 저장 전면 교체 (kream_bot.py, kream_server.py)

**문제:** 기존 `context.storage_state(path=STATE_FILE)` 호출은 쿠키만 저장하고 localStorage를 누락. 판매자센터는 localStorage JWT로 인증하므로 세션이 깨짐.

**수정:**
- `kream_bot.py`에 `save_state_with_localstorage()` 함수 추가 — localStorage를 별도 추출하여 `origins[].localStorage`에 병합
- `kream_server.py`의 모든 세션 저장 지점 교체 (8곳):
  - `search_by_model()`, `run_bid()`, `run_product_info()`, `run_full_register()`
  - `upload_bulk_excel()`, `delete_bids()`, `kream_keyword_search()`
- **성공 시에만 세션 저장** — 실패 시 빈 세션으로 덮어쓰기 방지

**관련 파일:** `kream_bot.py:179-204`, `kream_server.py:31` (import 추가)

### B. productId 0 문제 해결 (kream_server.py)

**문제:** 대시보드에서 자동 입찰 실행 시 `bi["productId"]`가 `0` 또는 빈 값으로 전달되어 모든 입찰이 실패.

**수정:**
- `bi["productId"]` → `bi.get("productId") or 0` (KeyError 방지)
- productId가 0이면 **model로 KREAM 검색하여 실제 상품번호 획득** (`search_by_model()` 호출)
- 검색 실패 시 해당 건만 스킵하고 다음 건 계속 진행

**관련 파일:** `kream_server.py:2143-2173`

### C. 고시정보 동적 필드 매핑 (kream_bot.py)

**문제:** 기존 하드코딩된 `attributeSet.0~8` 인덱스가 카테고리별로 다름. 가방 카테고리에서 의류 인덱스로 입력하면 잘못된 필드에 값이 들어감.

**수정:**
- DOM에서 각 `attributeSet.N.value` input의 부모 라벨을 읽어 `{라벨: 인덱스}` 매핑 생성
- `LABEL_ALIASES` 딕셔너리로 데이터 키→DOM 라벨 유연 매칭:
  ```python
  "취급시_주의사항": ["세탁방법 및 취급시 주의사항", "취급시 주의사항", "취급시_주의사항"]
  "AS_전화번호":     ["AS 책임자와 전화번호", "AS_전화번호", "AS 전화번호"]
  ```
- 현재 카테고리에 해당 필드가 없으면 건너뜀 (에러 방지)

**관련 파일:** `kream_bot.py:491-549`

### D. 기타 수정사항

| 항목 | 변경 전 | 변경 후 | 파일 |
|------|---------|---------|------|
| AS 전화번호 | "01075446127" | "010-7544-6127" | kream_server.py:527 |
| 고시카테고리 기본값 | "의류" | "가방" | kream_server.py:537 |
| bid_strategy 큐 저장 | 미포함 | 큐 추가/수정 시 저장 | kream_server.py:1607,1858 |
| ensure_logged_in | URL 확인만 | + 빈 페이지 감지, 네비게이션 확인, HTML 소스 덤프 | kream_bot.py:304-365 |
| select_dropdown | 단순 클릭 | + 스크롤 JS 폴백, li/role="option" 재시도 | kream_bot.py:113-151 |
| fill_product_info | "상품 고시정보" 텍스트 대기 | + categoryName 드롭다운 근처 JS 스크롤 | kream_bot.py:449-463 |
| place_bid | 기본 로깅 | 8단계 전체 상세 디버그 (스크린샷, 네트워크 모니터링) | kream_bot.py:812-1405 |
| kream_collector.py | save_state → 기본 | save_state_with_localstorage 사용 | kream_collector.py:60-86 |
| kream_adjuster.py | save_state → 기본 | save_state_with_localstorage 사용 | kream_adjuster.py:52-78 |

---

## 11. 알려진 버그와 해결 히스토리

### 해결 완료

| # | 버그 | 원인 | 해결 | 날짜 |
|---|------|------|------|------|
| 1 | **즉시구매가 103,000원** (실제 129,000원+) | 판매입찰 없을 때 JSON-LD에 체결가 노출, API 캡처 실패 시 fallback 없음 | JSON-LD offers.price를 초기값으로 설정, API/DOM 성공 시 덮어씀 | 04-13 |
| 2 | **최근거래가가 display_price로 잘못 수집** | `recent_trade_price = display_price` 할당 | 체결거래 내역 첫 번째 항목에서 수집하도록 수정 | 04-13 |
| 3 | **판매자센터 세션 만료** | `context.storage_state()`가 쿠키만 저장, localStorage JWT 누락 | `save_state_with_localstorage()` 함수로 전면 교체 | 04-14 |
| 4 | **자동 입찰 시 productId 0** | 큐 데이터에서 productId가 없거나 0인 채로 전달 | productId 0이면 model로 KREAM 검색하여 상품번호 획득 | 04-14 |
| 5 | **고시정보 잘못된 필드에 입력** | 가방/의류/신발별 attributeSet 인덱스가 다른데 하드코딩 | DOM 라벨 동적 매핑 + LABEL_ALIASES 유연 매칭 | 04-14 |
| 6 | **빈 세션으로 auth_state 덮어쓰기** | 입찰 실패 시에도 세션 저장 → 빈 세션으로 덮어씀 | 성공 시에만 세션 저장하도록 조건 추가 | 04-14 |
| 7 | **AS 전화번호 하이픈 누락** | "01075446127"로 하드코딩 | "010-7544-6127"로 수정 | 04-14 |
| 8 | **고시카테고리 기본값 "의류"** | 대부분 가방인데 기본값이 의류 | 기본값 "가방"으로 변경 | 04-14 |

### 미해결 / 주의사항

| # | 문제 | 상태 | 비고 |
|---|------|------|------|
| 1 | **해외에서 kream.co.kr 접속 차단** | 환경 제약 | 사무실 iMac에서만 가격 수집 가능 |
| 2 | **사무실 iMac 전체 플로우 미테스트** | PENDING | 개발은 맥북, 운영은 iMac — 환경 차이 검증 필요 |
| 3 | **자동 로그인 미구현** | PENDING | 세션 만료 시 수동 재로그인 필요 (--mode login) |
| 4 | **큐 데이터 재실행 필요** | 주의 | 기존 큐에 productId 0인 항목이 있을 수 있음 — 새로 일괄 실행하면 자동 검색됨 |
| 5 | **API 캡처 타이밍 문제** | 간헐적 | api.kream.co.kr API가 가끔 캡처 안 됨 → DOM/JSON-LD fallback으로 커버 |
| 6 | **kream_dashboard.html 4,500줄+** | 관리 어려움 | Claude Code 사용 시 `/clear` 후 짧게 요청, 429 에러 주의 |

---

## 12. 현재 동작하는 것 / 안 되는 것

### 동작 확인됨 (2026-04-14)
- 판매자센터 localStorage JWT 인증 + 세션 유지
- 고시정보 자동 등록 (PUT API 200 OK 확인, 동적 필드 매핑)
- 판매 입찰 자동 등록 (POST API 200 OK 확인)
- IC8349 상품으로 전체 플로우 성공 (고시정보 + 119,000원 입찰)
- productId 0일 때 model로 자동 검색하여 상품번호 획득
- 대시보드 큐 시스템, 마진 시뮬레이션, 결과 테이블
- 환율 자동 업데이트, 큐 데이터 영구 저장
- 일괄 실행/자동 입찰 배치 히스토리 저장

### PENDING 기능
- 수량 인라인 편집 (큐/결과 테이블에서)
- 내 입찰 현황 만료 임박 경고
- CLAUDE.md 파일 생성 (Claude Code 규칙)
- 识货 가격 수집 → API 인터셉트 방식 전환 (AI 비전 비용 과다)
- 프롬프트 캐싱 적용

---

## 13. 터미널 명령어

```bash
cd ~/Desktop/kream_automation

# 서버 실행
python3 kream_server.py                    # → http://localhost:5001

# 로그인
python3 kream_bot.py --mode login          # 판매자센터 (localStorage JWT 저장)
python3 kream_bot.py --mode login-kream    # KREAM 일반사이트

# 가격 수집
python3 kream_collector.py --products 125755 --no-partner

# Claude Code
claude --dangerously-skip-permissions

# Git 동기화 (맥북 → 사무실 iMac)
git add -A && git commit -m "업데이트" && git push -f origin main
# 사무실에서: git pull origin main

# 서버 재시작
lsof -ti:5001 | xargs kill -9; python3 kream_server.py

# 접속 테스트
python3 -c "
import urllib.request
try:
    r = urllib.request.urlopen('https://kream.co.kr', timeout=10)
    print(f'KREAM 일반: {r.status}')
except Exception as e:
    print(f'KREAM 일반: 실패')
try:
    r = urllib.request.urlopen('https://partner.kream.co.kr', timeout=10)
    print(f'판매자센터: {r.status}')
except Exception as e:
    print(f'판매자센터: 실패')
"
```

---

## 14. Claude Code 사용 시 주의사항

- **kream_dashboard.html이 4,500줄+ 매우 큼** → `/clear` 후 짧게 요청해야 429 에러 안 걸림
- **분당 30,000 토큰 제한** → 한 번에 긴 요청 보내지 말고 나눠서
- **파일 수정 후 서버 재시작 필수** — 서버가 구버전으로 돌면 수정이 반영 안 됨
- **.zshrc에 ANTHROPIC_API_KEY 넣지 말 것** — Claude Code가 API 크레딧을 소모함

---

## 15. 사무실 iMac 원격 접속

- Chrome 원격 데스크톱: remotedesktop.google.com
- 계정: juday@juday.co.kr
- 에너지 설정: 잠자기 방지 ON, 정전 후 자동 시작 ON
- 설치됨: Python 3.9, Playwright, Flask, openpyxl, playwright-stealth

---

## 16. 계정 정보

- Claude Code: Team Account (JUDAY), juday@juday.co.kr
- API 키: kream-shihuo (Disabled), juday cs (Active, 상담용)
- KREAM: judaykream@gmail.com
- GitHub: judayjuday/kream-automation (Private)

---

## 17. 새 채팅 시작 방법

이 인수인계서를 첫 메시지에 붙여넣고 작업 시작.
Claude Code 사용 시 `claude --dangerously-skip-permissions` 로 실행.
파일은 `~/Desktop/kream_automation/` 에 모두 있음.

**첫 요청 예시:**
"이 인수인계서를 읽고, ~/Desktop/kream_automation/ 폴더의 kream_server.py, kream_bot.py, kream_dashboard.html을 읽어서 현재 상태를 파악해줘. 그다음 [작업 내용] 해줘."
