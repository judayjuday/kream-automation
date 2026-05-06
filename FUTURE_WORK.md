# 미래 작업 백로그

이 문서는 사장님이 결정했지만 아직 구현 안 된 시스템 개선 사항을 기록합니다.
새 채팅 시작 시 이 파일도 함께 확인할 것.

---

## 🔥 우선순위 높음

### 1. 송금 환율 시스템 (Step 41+에서 약속)

**배경 (사장님 비즈니스 모델):**
- 한 달에 2~3번 해외 송금 (CNY 환전)
- 후불 결제: 협력사가 사장님 대신 상품 구매 → 사장님이 나중에 송금으로 정산
- 따라서 "입찰 시점 환율"보다 "송금 시점 환율"이 진짜 원가에 가까움

**현재 시스템:**
- bid_cost.exchange_rate: 입찰 시점 환율
- settings.exchange_rate: 현재 환율 (open.er-api.com 자동 갱신)
- 마진 계산: bid_cost.exchange_rate 우선, settings 폴백 (Step 41에서 구현)

**개선 방향 (미래):**
1. remittance_history 테이블 신설
   - 컬럼: id, remittance_date, amount_cny, amount_krw, exchange_rate, supplier, notes
   - 사장님이 송금할 때마다 기록
2. bid_cost ↔ remittance 매칭
   - 어떤 입찰이 어떤 송금으로 결제됐는지 매핑
   - FIFO 또는 사장님 지정 방식
3. 마진 재계산 로직
   - 매칭된 송금 환율로 정확한 마진 산출
   - 미매칭 입찰은 settings 환율 폴백 (현 정책 유지)
4. 대시보드: 송금 이력 + 미정산 입찰 합계 + 환율 손익 표시

**언제 진행:** 사장님이 송금 데이터 입력 준비되면.
**작업 추정:** Step 단위 1~2개.

---

## 📋 중간 우선순위

### 2. 브랜드별 사이즈표 시드 (Step 41+에서 결정)

**배경:** EU↔KR 사이즈 변환 + 브랜드별 사이즈 차이 (Onitsuka Tiger, New Balance, Mizuno 등).

**현재 상태:** size_conversion 테이블 존재. v8 인수인계서에 일부 매핑 기록됨.

**개선 방향:** 사장님이 브랜드별 데이터 제공 시 model_price_book의 brand 필드 + size_conversion 통합.

**언제 진행:** 사장님이 사이즈표 데이터 주실 때.

---

## 📋 낮은 우선순위

### 3. 모듈 분리 (kream_server.py → server/)
v8 인수인계서 23번 항목. Cursor 백그라운드 에이전트로 진행 가능.

### 4. KREAM 백엔드 Railway 이전
v8 인수인계서 23번 항목. 모듈 분리 후 진행.

---

## 진행 완료 (참고)

- Step 35~37: 자동 재입찰 dry-run + 단가표 시스템
- Step 38~40: 단가표 UI + 시드 보강
- Step 41: min_profit 3000 + 환율 동적 반영 + 운영 개선

---

## 새 채팅 시작 시 체크리스트

- [ ] KREAM_인수인계서_v8.md (또는 v9+) 읽기
- [ ] FUTURE_WORK.md (이 파일) 읽기
- [ ] git log --oneline -5
- [ ] curl /api/health
- [ ] 사장님이 "송금 환율" 또는 "사이즈표" 언급 시 이 파일 우선 참조
