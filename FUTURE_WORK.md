# 미래 작업 백로그

이 문서는 사장님이 결정했지만 아직 구현 안 된 시스템 개선 사항을 기록합니다.
새 채팅 시작 시 이 파일도 함께 확인할 것.

---

## 🔥 우선순위 높음

### 1. 송금 환율 시스템 (Step 41+에서 약속) — ✅ 완료 (인프라, Step 42)

**배경 (사장님 비즈니스 모델):**
- 한 달에 2~3번 해외 송금 (CNY 환전)
- 후불 결제: 협력사가 사장님 대신 상품 구매 → 사장님이 나중에 송금으로 정산
- 따라서 "입찰 시점 환율"보다 "송금 시점 환율"이 진짜 원가에 가까움

**Step 42 완료 사항:**
- ✅ remittance_history 테이블 신설 (날짜/CNY/KRW/환율/협력사/위챗/수수료/메모/상태)
- ✅ remittance_bid_match 테이블 (N:M 매칭, UNIQUE 제약)
- ✅ services/remittance.py: CRUD + FIFO 자동 매칭 + 가중평균 환율 조회
- ✅ API 4개: POST add, GET list, POST match, GET unmatched-bids
- ✅ calc_expected_profit 환율 폴백 체인 확장 (remittance 매칭 → bid_cost → settings → 217)
- ✅ 대시보드 탭 (`tabs/tab_remittance.html`) + 사이드바 메뉴 등록

**다음 단계 (미완):**
1. 사장님 실제 송금 데이터 입력 → FIFO 매칭 → 마진 재계산 검증
2. 환율 손익 그래프 (송금 환율 vs 입찰 시점 환율 시계열)
3. 부분 정산 / 협력사별 미정산 잔액 대시보드 카드

**언제 진행:** 사장님이 송금 데이터 1~2건 입력 후.

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
