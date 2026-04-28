# KREAM × 허브넷 × SSRO 통합 아키텍처 v1

작성일: 2026-04-28
대상: 승주님 + Claude Code
목적: KREAM 자동화 시스템과 SSRO 주문관리를 연결해서, 허브넷 PDF/협력사 발주/위챗 트래킹 역전달까지 손이 안 가게 만들기

---

## 0. 한 줄 요약

> **KREAM 판매를 SSRO의 5번째 플랫폼으로 편입한다.** 그러면 허브넷 PDF만 별도로 다운로드해서 SSRO에 붙이면, 나머지(협력사 매칭, 발주, 트래킹 매칭, 위챗 메시지 생성)는 SSRO의 기존 워크플로우가 다 처리한다.

---

## 1. 두 시스템 비교

| 항목 | KREAM 자동화 (iMac) | SSRO (juday.pages.dev) |
|------|--------------------|-----------------------|
| 역할 | KREAM 입찰/판매/가격조정 자동화 | 4개 플랫폼(에이블리/지그재그/크로켓/네이버) 주문관리 + 발주 + 재고 + 배송추적 |
| 일 주문량 | (별도) | 150~300건 |
| 협력사 처리 | 없음 (수동) | huli/Lee/정소남/Perri/Chen/주데이 자동 매칭 |
| 스택 | Flask + SQLite + Playwright | Supabase(Postgres) + React + Cloudflare Pages |
| 위치 | 사무실 iMac (로컬) | 클라우드 (어디서나) |
| 워크플로우 | 입찰 → 판매 → 발송 (수동) | 통합시트 → 발주검토중 → 발주완료 → … → 발송완료 (자동) |

**기존 문제:** KREAM 판매가 SSRO 워크플로우 바깥에 있어서, 승주님이 매번 손으로:
1. 허브넷에서 PDF 다운로드 → 박스에 붙임
2. 협력사한테 따로 발주 알림
3. 협력사 트래킹 받음 → 허브넷 위챗에 전달

---

## 2. 통합 후 흐름

```
┌─────────────────────────────────────────────────────┐
│ KREAM 자동화 (iMac)                                  │
│                                                     │
│  [판매 수집 스케줄러] ──→ sales_history (SQLite)     │
│         │                                           │
│         ↓                                           │
│  [허브넷 봇] ──→ HBL 매칭 → PDF 다운로드             │
│         │      └→ Supabase Storage 업로드            │
│         ↓                                           │
│  [SSRO Sync] ──→ Supabase REST API                  │
│                  POST orders (platform="kream")     │
└─────────────────────────────────────────────────────┘
                          │
                          ↓ HTTPS
┌─────────────────────────────────────────────────────┐
│ SSRO (Supabase + React)                             │
│                                                     │
│  orders.platform = "kream" 인 건은:                  │
│  ├─ supplier_map으로 협력사 자동 매칭 (이미 구현됨)   │
│  ├─ 통합시트 → 발주검토중 → 발주완료 (기존 워크플로우)│
│  ├─ jp_inventory 재고 자동 할당 (이미 구현됨)         │
│  └─ hubnet_pdf_url 컬럼 (신규)                       │
│                                                     │
│  BulkShippingPage:                                  │
│  ├─ 협력사별 발주 엑셀 (기존)                         │
│  └─ KREAM 건은 PDF zip 같이 다운로드 (신규)          │
│                                                     │
│  InboundPage:                                       │
│  ├─ 협력사가 트래킹 입력 (기존)                       │
│  └─ KREAM 건만 위챗 메시지/엑셀 자동 생성 (신규)      │
└─────────────────────────────────────────────────────┘
```

---

## 3. 핵심 설계 결정

### 3.1 KREAM 판매 = SSRO `orders` 테이블의 새 platform

`orders.platform = "kream"` 으로 INSERT. 기존 4개 플랫폼(에이블리/지그재그/크로켓/네이버)과 동일한 워크플로우를 탄다.

**필드 매핑 (KREAM sales_history → SSRO orders):**

| KREAM 컬럼 | SSRO 컬럼 | 비고 |
|-----------|-----------|------|
| `order_id` | `product_order_no` (UNIQUE) | 중복 방지 |
| `model` | `product_code` | 협력사 매칭 키 |
| `size` | `size` | EU 사이즈 |
| `product_info` | `product_name` | |
| `sale_price` | `selling_price` | |
| `sale_price` | `payment_amount` | KREAM은 결제액=판매가 |
| (계산) | `settlement_amount` | `sale_price × (1 - 0.06 × 1.1) - 2500` |
| `trade_date` | `payment_date` | TEXT 형식 (SSRO 표준) |
| (고정) | `current_sheet` = "통합시트" | 진입점 |
| (고정) | `shipping_country` = "중국" | 디폴트 |
| (계산/매칭) | `supplier` | products.supplier_map 조회 |
| (신규 컬럼) | `hubnet_pdf_url` | Supabase Storage URL |
| (신규 컬럼) | `hubnet_hbl` | 허브넷 HBL 번호 |

KREAM 측에는 `sales_history`에 `ssro_synced_at`, `ssro_sync_status` 컬럼만 추가하면 됨.

### 3.2 자동 푸시 vs 승인제

**자동 푸시.** 이유:
- KREAM 판매 자체가 자동화의 결과물 (이미 입찰 → 매칭 자동)
- SSRO에 들어가도 "통합시트"부터 시작이라, 잘못 들어와도 사람이 시트에서 확인 가능
- 승인제로 하면 결국 사람이 개입해야 해서 자동화 의미가 반감
- 단, 푸시 실패 시 알림 + 재시도 로직 필수

### 3.3 연결 방식: Supabase REST API 직접 호출

파일 동기화 X, REST API O. 이유:
- SSRO는 클라우드, KREAM은 로컬 → 파일 공유 어려움
- Supabase가 이미 PostgREST 자동 생성 → 별도 API 서버 불필요
- Python에서 `supabase-py` 또는 `requests`로 바로 호출 가능

**인증:**
- KREAM 자동화는 서버사이드 → **Service Role Key** 사용 (anon key 아님)
- Service Role Key는 settings.json 또는 별도 `secrets.json`에 저장 (.gitignore에 추가)
- ⚠️ 현재 SSRO는 RLS 전체 비활성화 + anon key 노출 상태 → 별도 보안 작업 필요 (§7 참고)

### 3.4 허브넷 PDF 저장 위치

**Supabase Storage** (private 버킷).
- 이유: SSRO 화면에서 바로 다운로드 링크 클릭 가능
- 백업: KREAM 자동화 측에도 `~/Desktop/kream_automation/labels/{YYYYMM}/` 에 로컬 사본 유지
- 버킷 이름: `hubnet-labels`
- 파일명 규칙: `{HBL번호}_{model}_{size}_{date}.pdf`

### 3.5 협력사 매칭 — 어디서 할 것인가

**SSRO에서 한다.** 이유:
- SSRO에 이미 `products.supplier_map` 매칭 로직 존재 (excelParser.js v5.3)
- 매칭 룰 변경 시 SSRO 한 곳에서만 관리
- KREAM 자동화는 매칭 모름 → 그냥 INSERT만

**구체적 동작:**
- KREAM Sync가 INSERT 시 `supplier`를 빈 값으로 둠
- SSRO 측에 DB trigger 또는 백그라운드 작업이 supplier_map 룩업 실행
  - **선택지 A:** Supabase Edge Function (Deno) — `on_kream_order_inserted`
  - **선택지 B:** AppLayout.jsx의 백그라운드 작업에 KREAM 건 supplier 채우기 추가
- 매칭 실패 (예: products에 없는 모델) → `supplier = NULL` + 알림 표시

승주님이 알려주신 룰:
> "아디다스와 LEE 제외한 모든 상품 = huli. 중판창고 직출고는 재고관리에서 확인."

이건 SSRO `products` 테이블에 미리 들어있어야 동작. 지금 KREAM에서 파는 모델들이 SSRO products에 다 등록되어 있는지가 관건. (§5.4에서 다룸)

### 3.6 위챗 메시지 자동 생성 — SSRO 안에서

**InboundPage에 KREAM 전용 액션 추가.**
- 협력사가 트래킹 입력 → SSRO 화면 하단에 "허브넷 위챗 메시지 생성" 버튼
- 형식 1: 클립보드용 텍스트 (HBL번호 ↔ 트래킹번호 줄바꿈 구분)
- 형식 2: 엑셀 파일 (HBL, 트래킹, 협력사명)
- 승주님은 결과물을 위챗에 복붙/첨부만

**위챗 자체 자동 발송은 안 함.** 이유:
- 위챗 봇은 차단 강함, 계정 정지 위험
- 위챗 비즈니스 API는 중국 법인 필요
- 복붙은 5초면 끝나는 작업

---

## 4. 구체적 워크플로우 (시간순)

### 4.1 정상 케이스 (KREAM 신발 1건 판매)

```
T+0      KREAM에서 결제 완료
T+30분   판매 수집 스케줄러 → sales_history INSERT
T+30분   허브넷 봇 트리거 → HBL 검색 → PDF 다운로드
         (PDF: hubnet-labels/{HBL}_{model}_{size}_{date}.pdf)
T+31분   SSRO Sync 트리거 → orders INSERT
         (platform="kream", current_sheet="통합시트", supplier=NULL)
T+32분   SSRO 백그라운드 → supplier_map 매칭
         → "아식스 1203A243" → supplier="huli"
T+다음 발주 사이클
         BulkShippingPage에서 huli 협력사 발주 엑셀 다운로드
         (KREAM 건은 PDF zip도 같이 다운로드)
T+협력사 발송 후
         InboundPage에서 협력사 트래킹 입력
         → KREAM 건이면 "위챗 메시지 생성" 버튼 노출
T+승주님 위챗에 복붙
T+허브넷 측에서 트래킹 등록 → 발송 완료
```

### 4.2 예외 케이스

| 상황 | 동작 |
|------|------|
| 허브넷 HBL 매칭 실패 | KREAM 측에 "PDF 다운로드 대기" 상태로 큐에 보관, 4회 재시도 후 알림 |
| Supabase API 호출 실패 | KREAM 측 큐에 보관, 5분 후 재시도 (최대 12회) |
| products에 모델 없음 | SSRO orders.supplier=NULL → 대시보드에 "협력사 미매칭" 알림 |
| PDF 손상 / 빈 파일 | 다운로드 검증 실패 → 재시도 → 실패 시 알림 |
| 동일 order_id 중복 | product_order_no UNIQUE 제약으로 INSERT 실패 → KREAM 측 sync_status="duplicate" |
| 트래킹 매칭 안 됨 | InboundPage 기존 미매칭 처리 흐름 사용 |

---

## 5. 작업 분할 (3개 작업지시서로 분리)

### 📄 작업지시서 1: 허브넷 봇 + PDF 자동 다운로드
**범위:** KREAM 자동화 시스템 안에서 완결
**산출물:** KREAM 판매 발생 시 자동으로 PDF가 로컬에 저장됨

**핵심 작업:**
- `kream_hubnet_bot.py` 신규 (Playwright)
- 허브넷 자동 로그인 + 세션 보관
- HBL 조회 → PDF 다운로드 함수
- KREAM `sales_history` ↔ 허브넷 HBL 매칭
- DB: `hubnet_orders` 테이블 + `sales_history`에 `hbl_number`, `pdf_path` 컬럼 추가
- 대시보드 `tab_logistics.html`에 "허브넷 PDF 현황" 패널

**선행 조건:**
- 승주님이 허브넷 페이지 스크린샷 + HTML 캡처 제공
- 송장 PDF 샘플 1~2개 (이름 패턴 확인용)

### 📄 작업지시서 2: KREAM → SSRO 동기화
**범위:** 두 시스템 사이 다리 + SSRO 측 수정
**산출물:** KREAM 판매가 SSRO 통합시트에 자동 등장

**핵심 작업:**

KREAM 자동화 측:
- `ssro_sync.py` 신규 (Supabase REST API 호출)
- `sales_history`에 `ssro_synced_at`, `ssro_sync_status` 컬럼 추가
- 큐 + 재시도 로직 + 실패 알림
- Service Role Key를 `secrets.json`에 안전 보관

SSRO 측:
- `orders` 테이블에 `hubnet_pdf_url`, `hubnet_hbl` 컬럼 추가
- KREAM 정산 계산 함수 추가 (excelParser.js의 정산 공식 영역에 KREAM 분기)
- AppLayout.jsx 백그라운드 작업에 "KREAM 건 supplier 자동 매칭" 추가
  - 또는 Supabase Edge Function `kream-order-postprocess` 신규
- 사이드바 메뉴에 KREAM 건 필터 추가

Supabase 측:
- Storage 버킷 `hubnet-labels` 생성 (private)
- Service Role Key 발급 + KREAM 측 전달
- (선택) Edge Function 배포

### 📄 작업지시서 3: 협력사 트래킹 → 위챗 메시지 자동 생성
**범위:** SSRO 안에서 완결 (KREAM 측 손 안 댐)
**산출물:** 트래킹 입력 후 위챗 메시지/엑셀 자동 생성

**핵심 작업:**
- InboundPage에 KREAM 건 필터 + "위챗 메시지 생성" 버튼
- 메시지 형식 정의 (텍스트 / 엑셀)
- 클립보드 복사 + 엑셀 다운로드
- 누가 어떤 트래킹을 언제 위챗에 보냈는지 로깅 (`order_logs` 활용)

**선행 조건:**
- 승주님이 현재 위챗에 보내는 메시지/엑셀 실물 예시 제공

---

## 6. 작업 순서 권장

작업지시서 1 → 2 → 3 순서가 자연스럽지만, **2번이 가장 가치가 큼** (협력사 발주 자동화). 1번 없이 2번을 먼저 해도 SSRO 워크플로우는 돌아감 (PDF만 수동으로 첨부).

**현실적 권장:** 1번부터.
- 가장 독립적 (다른 시스템 안 건드림)
- 결과물이 즉시 가시적 (PDF 자동 다운로드)
- 1번 진행하면서 2번 설계가 명확해짐

---

## 7. ⚠️ 보안 이슈 (별도 처리 필요)

현재 SSRO 보안 상태가 위험합니다. 이건 KREAM 연동과 별개로 처리해야 함:

1. **Anon Key가 GitHub에 그대로 들어가 있을 가능성** — `supabase.js` 4번 줄에 하드코딩
2. **모든 테이블 RLS 비활성화** — anon key 가진 사람은 누구나 read/write 가능
3. **이번 zip을 외부에 공유하면 SSRO 전체 노출**

**최소한의 조치 (작업지시서 2 시작 전):**
- Service Role Key는 절대 클라이언트(React)에 두지 않음 (이미 안 되어 있음 — 다행)
- KREAM 측 `secrets.json`은 `.gitignore` 필수
- 가능하면 RLS 부분 활성화 (최소한 anon key로는 INSERT 못 하게)

이건 작업지시서 2에서 같이 다룰 건데, 미리 알고 계셔야 해서 적어둠.

---

## 8. 다음 단계

승주님이 결정해야 할 것:

1. **작업지시서 1번부터 만들까?** (권장) → "그래" 하시면 다음 답에서 정식 문서 만듦
2. **허브넷 페이지 스크린샷 + HTML 캡처 준비** — 1번 작업지시서 완성에 필요
3. **위챗 메시지 실물 예시** — 3번 작업지시서 시작 전 필요 (지금 안 줘도 됨)

---

## 부록: 참고 파일 위치

KREAM 자동화 측:
- 인수인계서: `~/Desktop/kream_automation/KREAM_인수인계서_v7.md`
- DB: `~/Desktop/kream_automation/price_history.db`
- 판매 수집: `kream_bot.py` `collect_shipments()`

SSRO 측:
- supabase 클라이언트: `src/utils/supabase.js`
- 정산 계산: `src/utils/excelParser.js` (line 196~)
- supplier_map 매칭: `src/utils/excelParser.js` (line 375~)
- 발주 엑셀 생성: `src/pages/BulkShippingPage.jsx`
- 트래킹 입력: `src/pages/InboundPage.jsx`
- DB 스키마: `db_schema.sql` + Supabase 대시보드

Supabase:
- Project: `fbkqsznoxjwevhgjnujt`
- 리전: Seoul
- URL: `https://fbkqsznoxjwevhgjnujt.supabase.co`
