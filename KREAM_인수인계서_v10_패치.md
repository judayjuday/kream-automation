# v10 패치 (2026-05-07)

## Step 42: 송금 환율 시스템 인프라

### 신규 파일
- `services/remittance.py` (385줄) — 송금 CRUD + FIFO 자동 매칭 + 환율 조회
- `tabs/tab_remittance.html` (175줄) — 송금 등록/이력/매칭 UI

### 신규 테이블 (price_history.db)
- `remittance_history` — 송금 이력 (날짜/CNY/KRW/환율/협력사/위챗/수수료/메모/상태)
- `remittance_bid_match` — 송금↔입찰 N:M 매칭 (UNIQUE: remittance_id+bid_cost_id)

### 신규 인덱스
- `idx_remittance_date`, `idx_remittance_status`
- `idx_rbm_remittance`, `idx_rbm_bid_cost`, `idx_rbm_order`

### 신규 API (총 4개)
- `POST /api/remittance/add` — 송금 등록 (환율 자동 계산)
- `GET  /api/remittance/list?limit&status` — 목록 + summary
- `POST /api/remittance/match` — 매칭 (수동 / `auto_fifo:true`)
- `GET  /api/remittance/unmatched-bids` — 미매칭 입찰 목록

### 환율 폴백 체인 확장 (`calc_expected_profit`, services/auto_rebid.py:145)

| 순위 | 출처 | 비고 |
|---|---|---|
| 1 | remittance 매칭 환율 (가중평균) | **신규 최우선** — order_id 기반 |
| 2 | bid_cost.exchange_rate | 입찰 시점 환율 |
| 3 | settings.exchange_rate | 현재 환율 (자동 갱신) |
| 4 | 217 | 안전 폴백 |

### FIFO 자동 매칭 알고리즘
- active 송금을 오래된 순으로 정렬
- 미매칭 입찰을 created_at 오름차순으로 순회
- 송금 잔액 부족 시 다음 송금으로 (부분 매칭 지원)
- 송금 amount_cny 모두 소진되면 status='depleted'

### 절대 규칙 준수 검증
- ✅ 가짜 값 금지: amount_cny ≤ 0 거부
- ✅ DROP TABLE 금지: 마이그레이션은 CREATE TABLE만
- ✅ DB 백업: `backups/price_history.db.before_step42.20260507_180227`
- ✅ settings 백업: `backups/settings.json.before_step42.20260507_180233`
- ✅ kream_server.py 백업: `backups/kream_server.py.before_step42.20260507_*`
- ✅ 테스트 데이터 정리: `notes='Step 42 검증'` 모두 삭제

### 자동 재입찰 회귀 검증
- 송금 데이터 없을 시 기존 폴백 유지 (order_id 매칭 없음 → bid_cost.exchange_rate 사용)
- `calc_expected_profit` 직접 검증: order_id 없음/매칭 없음 동일 결과 (-3527원, 동일)
- dry-run candidates_total=0 (데이터 부족, 회귀 아님)

### 검증 결과
- 송금 등록 1건 → FIFO 자동 매칭 4건 → 송금 status='depleted' 확인
- summary: unmatched_bid_count=48, unmatched_bid_cny=21,297

### FUTURE_WORK 진행도
- 우선순위 #1 (송금 환율 시스템) → ✅ 인프라 완료
- 다음 단계:
  1. 사장님 실제 송금 데이터 입력
  2. FIFO 매칭 후 마진 재계산 검증
  3. 환율 손익 그래프 (별도 Step)

### 사용 가이드
1. 사이드바 → "원가" 그룹 → "💸 송금 환율" 클릭
2. "📥 새 송금 등록" 폼: 날짜/CNY/KRW 필수, 협력사/위챗/수수료/메모 선택
3. "🔗 매칭" → "FIFO 자동 매칭 실행" 버튼: 오래된 송금↔오래된 입찰 자동 연결
4. 매칭 후 marginrkl 재계산은 자동 (calc_expected_profit가 매칭 환율 우선)
