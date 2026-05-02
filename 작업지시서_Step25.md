# 작업지시서 — Step 25: sync URL 핀포인트 패치

> 의존: Step 24 (커밋 5e45fc4)
> 진단 결과: 실제 입찰 관리 URL = /business/ask-sales (재고별 입찰 관리)

## 진단 증거 (Step 24에서 확보)

탐색 결과 다음 링크 발견:
```
"text": "재고별 입찰 관리",
"href": "https://partner.kream.co.kr/business/ask-sales"
```

기존 BID_URLS_FALLBACK 5개에 이 URL 누락.

## 작업

### kream_adjuster.py + kream_bot.py 모두 점검

1. 두 파일 모두에서 BID_URLS_FALLBACK 변수 또는 sync 함수 내 page.goto URL을 찾는다
2. https://partner.kream.co.kr/business/ask-sales 가 **첫 번째**로 시도되도록 추가
3. 이미 추가되어 있으면 스킵

권장 순서:
```python
BID_URLS_FALLBACK = [
    'https://partner.kream.co.kr/business/ask-sales',  # NEW: 진단으로 확인된 정확한 URL
    'https://partner.kream.co.kr/c2c/sell/bid',
    'https://partner.kream.co.kr/c2c/sell',
    'https://partner.kream.co.kr/c2c/bid',
    'https://partner.kream.co.kr/business/bid',
    'https://partner.kream.co.kr/c2c',
]
```

### 셀렉터 보강

`/business/ask-sales` 페이지의 입찰 행 셀렉터도 확인 필요.
다음 셀렉터를 ROW_SELECTORS 리스트 앞쪽에 추가 (없으면 스킵):

```python
ROW_SELECTORS = [
    # NEW: ask-sales 페이지 추정 셀렉터들
    '[class*="ask-sales"] tbody tr',
    '[class*="AskSales"] tbody tr',
    'div[class*="askRow"]',
    'div[class*="ask-item"]',
    # 기존
    'table tbody tr',
    '.bid-list-item',
    # ...
]
```

## 검증

1. python3 -m py_compile kream_adjuster.py
2. python3 -m py_compile kream_bot.py  
3. 서버 재시작
4. /api/my-bids/sync POST → task 폴링 → 입찰 수 확인
5. server.log [SYNC] 로그에서 어느 URL이 통했는지 확인
6. 회귀: health, capital-status, daily-summary

## 절대 규칙
- 기존 파싱 로직 변경 금지
- DB 스키마 변경 금지
- 자동 토글 ON 변경 금지

## 커밋
```
fix(Step 25): sync URL 핀포인트 패치 (/business/ask-sales)

- 진단 결과 발견된 실제 입찰 관리 URL 추가
- BID_URLS_FALLBACK 맨 앞에 우선 시도

배경: Step 24 메뉴 탐색에서 "재고별 입찰 관리" → /business/ask-sales 발견
```
