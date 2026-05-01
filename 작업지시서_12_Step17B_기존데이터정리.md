# 작업지시서 12 — Step 17-B 기존 ONE SIZE 잘못 등록 데이터 정리

## 목적

Step 17-A로 앞으로의 입찰은 차단되지만, 기존에 잘못 등록된 데이터 정리.

## 대상 데이터

진단 결과:
- JQ4110 (신발) ONE SIZE 3건 — 정리 필수
- JE3208, JE3209 (사용자 확인: 가방) — 정리 불필요. 식货 재임포트로 자동 분류됨
- IX7694, KA9266, KA9271, IC8349 (가방 추정) — 식货 재임포트 후 model_category 캐시로 확인

## 절대 규칙

1. KREAM에서 사용자 동의 없이 입찰 삭제 금지
2. 식货 사이즈 정보는 추천만, 실제 가격 결정은 사용자
3. price_adjustments 기록은 보존 (감사 자료)
4. 정리 작업 전 반드시 사용자 확인

## 진행

### Step B-1: 정리 대상 식별

```bash
sqlite3 -header price_history.db "
SELECT bc.model, bc.order_id, bc.size, bc.cny_price, mc.category, mc.needs_size
FROM bid_cost bc
LEFT JOIN model_category mc ON mc.model = bc.model
WHERE bc.size = 'ONE SIZE' AND mc.needs_size = 1
ORDER BY bc.model
"
```

이 결과에 나오는 모델은 모두 정리 대상 (신발인데 ONE SIZE 등록).

### Step B-2: 사용자에게 정리 옵션 제시

각 모델별로 사용자가 결정:

**옵션 1**: KREAM에서 ONE SIZE 입찰 삭제 → 사이즈별 신규 입찰
- 장점: 깨끗함
- 단점: 사이즈별 가격 결정 필요

**옵션 2**: 기존 입찰 그대로 두고 만료 시 자연 소멸 (입찰 기간 보통 30일)
- 장점: 가장 안전
- 단점: 만료까지 시장 노이즈

**옵션 3**: 기존 ONE SIZE는 유지, 추가로 사이즈별 신규 입찰 같이 등록
- 장점: 둘 다 시장에 노출
- 단점: 사이즈 ONE SIZE 입찰은 어차피 매칭 안 될 가능성

권장: 옵션 2 (자연 소멸) — 가장 안전. Step 17-A로 앞으로의 잘못된 등록은 차단됨.

### Step B-3: 옵션 2 선택 시 추가 작업
- 만료 후 재입찰 시 사이즈별 등록 강제 (Step 17-A로 자동 차단됨)
- 모니터링: bid_cost에서 ONE SIZE + needs_size=1 건수가 시간에 따라 줄어드는지

### Step B-4: model_category 캐시 검증

식货 재임포트 후:
```bash
sqlite3 -header price_history.db "
SELECT model, category, needs_size, source FROM model_category 
WHERE model IN ('JQ4110','IX7694','KA9266','KA9271','IC8349','JE3208','JE3209')
ORDER BY model
"
```

기대:
- JQ4110: shoes, needs_size=1
- IX7694, KA9266, KA9271, IC8349, JE3208, JE3209: bags, needs_size=0

## 보고

[Step 17-B 완료]
- 정리 대상 모델: N개
- 사용자 결정: 옵션 X
- model_category 캐시 검증: ✓/✗
- 잘못된 ONE SIZE 입찰 추적 모니터링 시작
