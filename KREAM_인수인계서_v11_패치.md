# v11 패치 (2026-05-07 후속)

## Step 43 통합 (8개 서브스텝 완료)

작업 범위: 환율 손익 분석, 매칭 정밀화, 인보이스 추적, 운영 안전망, 통계 대시보드, 단가표 일괄 입력 / 검증.

---

### 43-1 절대 규칙 #7
- 인보이스 단가는 시스템 데이터로 사용 금지 명문화
- 의사결정 우선순위: bid_cost → model_price_book → bid_cost fuzzy → ❌ 인보이스
- 인보이스는 영수증 첨부 + 메모 기록 + 거래 추적 용도만 허용
- 커밋: `cc65a5a`

### 43-2 환율 손익 대시보드 (FX P&L)
- 신규 모듈: `services/fx_pnl.py`
- 매칭된 입찰: `(bid_cost.exchange_rate − 송금가중평균환율) × cny_price` 손익
- 미매칭 입찰: CNY/KRW 환율 위험 노출액 표시
- 협력사별 평균/최저/최고/실효 환율 + 수수료율 비교
- 신규 API: `GET /api/fx-pnl/portfolio` / `/api/fx-pnl/bid/<order_id>` / `/api/fx-pnl/supplier-comparison`
- UI: 송금 탭 상단 손익 요약 카드 4개 + 협력사별 환율 테이블
- 커밋: `b05a067`

### 43-3 협력사 인지 매칭
- 신규 함수: `auto_match_supplier_aware(supplier_id?)`
- 송금에 협력사 있는 것을 우선 매칭, 없는 것은 후순위
- supplier_id 지정 시 해당 협력사 송금만 매칭
- API 확장: `POST /api/remittance/match` body 옵션 `auto_supplier`, `supplier_id`
- UI: 매칭 옵션 3개 (FIFO / 협력사 인지 / 협력사 필터)
- 커밋: `5388e60`

### 43-4 인보이스번호 추적
- DB 마이그레이션:
  - `remittance_history.invoice_no_primary` 컬럼
  - 신규 테이블 `remittance_invoice` (1:N, UNIQUE(remittance_id, invoice_no))
  - 인덱스 3개
- 신규 함수: `link_invoice / list_invoices / find_by_invoice`
- 신규 API: `POST /api/remittance/<rid>/invoice`, `GET /api/remittance/<rid>/invoices`, `GET /api/invoice/search?q=`
- 절대 규칙 #7 명시: 추적/메모 용도만, 인보이스 단가는 시스템 데이터로 사용 금지
- 커밋: `64d0576`

### 43-5 매칭 해제 / 송금 취소 API
- 신규 함수: `unmatch / cancel_remittance / list_matches`
- `unmatch`: 매칭 1건 해제 + 송금 `allocated_cny` 자동 재계산 + status 자동 보정
- `cancel_remittance`: 송금 status='cancelled', 매칭 row만 제거 (입찰/판매 데이터 미접촉)
- 신규 API: `DELETE /api/remittance/match/<id>`, `POST /api/remittance/<id>/cancel`, `GET /api/remittance/<id>/matches`
- 절대 규칙 #2/#3 준수: bid_cost/sales_history 미접촉, status 변경
- 커밋: `53db6a8`

### 43-6 송금 통계 대시보드
- 신규 함수: `monthly_remittance_stats / remittance_trends`
- 월별: count/총 CNY/총 KRW/평균·최저·최고 환율/수수료
- 추세: 최근 N일 일별 송금 추세
- 신규 API: `GET /api/fx-pnl/monthly`, `GET /api/fx-pnl/trends?days=`
- UI: 송금 탭에 월별 통계 테이블 추가
- 커밋: `a650d2d`

### 43-7 단가표 CSV 일괄 입력
- 신규 함수: `bulk_upsert_from_csv` (NULL-safe UPSERT, model+size 키)
- 필수 컬럼: model, cny_price / 선택: size, category, brand, is_bulk_item, notes, source
- 신규 API: `POST /api/price-book/bulk-upload` (text 또는 multipart)
- UI: 단가표 탭에 CSV 업로드 영역 + 절대 규칙 #7 안내
- 커밋: `5e757e0`

### 43-8 단가 불일치 감지
- 신규 함수: `detect_bid_cost_anomalies(threshold_pct)`
- bid_cost와 model_price_book 단가 차이 ±N% 이상 케이스 탐지
- 신규 API: `GET /api/price-book/anomalies?threshold=20`
- UI: 단가표 탭에 임계값 조정 + 결과 테이블
- 운영 효과: 인보이스 잘못 시드 / 협력사 단가 변동 패턴 즉시 감지
- 커밋: `329811c`

---

## 신규 산출물 합계

- 신규 API: 13개
  - fx-pnl: portfolio, bid, supplier-comparison, monthly, trends
  - remittance: invoice link/list, matches, cancel, match DELETE
  - invoice: search
  - price-book: bulk-upload, anomalies
- 신규 테이블: 1개 (`remittance_invoice`)
- 신규 컬럼: 1개 (`remittance_history.invoice_no_primary`)
- 신규 인덱스: 3개 (`idx_remittance_invoice`, `idx_ri_remittance`, `idx_ri_invoice_no`)
- 신규 services 함수: 12개
  - fx_pnl: calculate_fx_pnl_for_bid, calculate_portfolio_fx_pnl, supplier_fx_comparison, monthly_remittance_stats, remittance_trends
  - remittance: auto_match_supplier_aware, link_invoice, list_invoices, find_by_invoice, unmatch, cancel_remittance, list_matches
  - price_book: bulk_upsert_from_csv, detect_bid_cost_anomalies

---

## 회귀 검증

- baseline executable_count = 8 (auto-rebid dry-run)
- 모든 Step 종료 시점 = 8 ✅ (8/8 통과)
- auto_rebid 코드 미접촉 — 회귀 0

---

## 절대 규칙 준수

- #1 가짜 값 금지: 환율 데이터 없으면 None 반환, fx_pnl_per_cny 계산 불가 시 None
- #2 sales_history 미접촉: cancel_remittance에서도 매칭 row만 정리
- #3 DROP/DELETE 금지: 송금 취소는 status 변경, 매칭 해제만 DELETE
- #4 auth_state.json 미접촉
- #5 git push -f 금지 — 일반 push 사용
- #6 TEST 데이터 금지
- #7 (신규) 인보이스 단가 시스템 데이터 사용 금지 — 모든 API/UI에 명시

---

## 사장님 다음 액션

1. 송금 데이터 입력 (Phase 2.6 폼)
2. 영수증 다중 첨부 (송금증 / 입금명세서 / 인보이스)
3. 인보이스번호 연결 (Step 43-4)
4. FIFO 매칭 또는 협력사 인지 매칭 (Step 43-3)
5. 환율 손익 대시보드 확인 (Step 43-2/6)
6. 단가표 CSV 일괄 입력 (Step 43-7) → 단가 불일치 감지 (Step 43-8)
7. (다음) Step 44 자동 재입찰 ENABLE 검토
