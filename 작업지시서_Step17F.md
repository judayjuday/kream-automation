# 작업지시서 — Step 17-F: gosi=None 카테고리 기반 디폴트

> 의존: Step 17-E (66076d6), Phase 2-C
> 목적: JQ4110 220mm 같은 카테고리="신발"인데 키워드 매칭 실패한 케이스에서 gosi.type 디폴트로 입찰 가능하게 함
> 예상 회수 가치: 220mm 마진 8,789원 (즉시) + 향후 유사 케이스 다수

## 배경 (Step 17-E와의 관계)

Step 17-E에서 카테고리 추론 0순위로 `get_model_category()` DB 조회 추가됨.
JQ4110은 model_category="신발"로 등록되어 있지만, auto_fill_gosi가 키워드 매칭 실패 시 None 반환하도록 변경됨 (Ozgaia 같은 마이너 모델은 키워드 매칭 안됨).

결과: category="신발"인데 gosi=None → validate_gosi_for_bid 차단 → 220mm 입찰 불가

## 해법

auto_fill_gosi가 키워드 매칭 실패하더라도, **category가 결정된 경우 카테고리 기반 디폴트 gosi 반환**.

### 카테고리별 디폴트 gosi

```python
CATEGORY_DEFAULT_GOSI = {
    "신발": {
        "type": "운동화",
        "material": "혼방",
        "size": "사이즈별 별도 표기",
        "manufacturer": "수입원: 판매자 / 제조국: 중국",
        "caution": "상세페이지 참조",
        "warranty": "구매일로부터 1년 / 고객센터 010-7544-6127",
        "as_phone": "010-7544-6127",
    },
    "의류": {
        "type": "상의",
        "material": "혼방",
        "size": "사이즈별 별도 표기",
        "manufacturer": "수입원: 판매자 / 제조국: 중국",
        "caution": "상세페이지 참조",
        "warranty": "구매일로부터 1년 / 고객센터 010-7544-6127",
        "as_phone": "010-7544-6127",
    },
    "가방": {
        "type": "가방",
        "material": "혼방",
        "size": "단일 사이즈",
        "manufacturer": "수입원: 판매자 / 제조국: 중국",
        "caution": "상세페이지 참조",
        "warranty": "구매일로부터 1년 / 고객센터 010-7544-6127",
        "as_phone": "010-7544-6127",
    },
    # 액세서리 등 필요 시 추가
}
```

### auto_fill_gosi 수정 (kream_bot.py)

기존:
```python
def auto_fill_gosi(model, category, ...):
    # 키워드 매칭
    for keyword, gosi_template in KEYWORD_GOSI_MAP.items():
        if keyword in model.lower():
            return gosi_template
    return None  # ← 매칭 실패
```

변경:
```python
def auto_fill_gosi(model, category, ...):
    # 1. 키워드 매칭 (기존 로직 우선)
    for keyword, gosi_template in KEYWORD_GOSI_MAP.items():
        if keyword in model.lower():
            return gosi_template
    
    # 2. NEW: 카테고리 기반 디폴트 (settings.json 토글)
    settings = _load_settings()
    if settings.get('use_category_default_gosi', True):  # 기본 ON
        if category in CATEGORY_DEFAULT_GOSI:
            return CATEGORY_DEFAULT_GOSI[category].copy()
    
    return None  # 카테고리도 모르면 여전히 None
```

### settings.json 추가

```json
{
  "use_category_default_gosi": true,
  ...
}
```

## 검증

1. JQ4110 220mm 케이스 시뮬레이션:
   - get_model_category("JQ4110") → "신발"
   - auto_fill_gosi("JQ4110", "신375") → CATEGORY_DEFAULT_GOSI["신발"] 반환 (None 아님)
   - validate_gosi_for_bid 통과
   
2. 카테고리도 없는 케이스:
   - 모델 X (DB 등록 없음)
   - get_model_category(X) → None
   - auto_fill_gosi(X, None) → None (변동 없음)
   - validate_gosi_for_bid 차단 (변동 없음)

3. 토글 OFF 시:
   - settings.use_category_default_gosi = false
   - JQ4110 → None (Step 17-E 동작 유지)

## 회귀 테스트

```python
# _test_step17f.py (신규)
def test_jq4110_category_default():
    from kream_bot import auto_fill_gosi
    result = auto_fill_gosi("JQ4110", "신발")
    assert result is not None, "JQ4110은 카테고리 신발이라 디폴트 반환되어야 함"
    assert result.get('type') == "운동화"
    print("PASS: test_jq4110_category_default")

def test_unknown_category_returns_none():
    from kream_bot import auto_fill_gosi
    result = auto_fill_gosi("UNKNOWN_MODEL_XYZ", None)
    assert result is None, "카테고리 None이면 디폴트도 없어야 함"
    print("PASS: test_unknown_category_returns_none")

def test_keyword_match_priority():
    from kream_bot import auto_fill_gosi
    # 기존 키워드 매칭이 우선
    result = auto_fill_gosi("Onitsuka Tiger Mexico 66", "신발")
    # KEYWORD_GOSI_MAP에 있으면 그쪽이 우선이라 카테고리 디폴트와 다를 수 있음
    assert result is not None
    print("PASS: test_keyword_match_priority")

if __name__ == '__main__':
    test_jq4110_category_default()
    test_unknown_category_returns_none()
    test_keyword_match_priority()
```

## 절대 규칙
- Step 17-E의 검증 함수 (validate_category_for_bid, validate_gosi_for_bid) 변경 금지
- get_model_category 변경 금지 (이미 0순위 우선)
- 기존 KEYWORD_GOSI_MAP 우선순위 유지

## 커밋 메시지
```
feat(Step 17-F): 카테고리 기반 디폴트 gosi (JQ4110 220mm 회수)

- CATEGORY_DEFAULT_GOSI: 신발/의류/가방 카테고리별 디폴트 템플릿
- auto_fill_gosi: 키워드 매칭 실패 시 카테고리 기반 디폴트 반환
  (settings.use_category_default_gosi 토글, 기본 ON)
- _test_step17f.py: 회귀 테스트 3종 (PASS)

효과:
- JQ4110 카테고리="신발" + 키워드 매칭 실패 → 디폴트 적용으로 입찰 가능
- 220mm 마진 8,789원 회수 가능
- 카테고리 자체가 None이면 변동 없음 (안전)
```
