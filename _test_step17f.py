"""Step 17-F 회귀 테스트.

카테고리 기반 디폴트 gosi 동작 확인.
실행: python3 _test_step17f.py
"""

from kream_bot import auto_fill_gosi


def test_jq4110_category_default():
    result = auto_fill_gosi("JQ4110", "신발")
    assert result is not None, "JQ4110은 카테고리 신발이라 디폴트 반환되어야 함"
    assert result.get("type") == "운동화", f"type=운동화 기대, got {result.get('type')!r}"
    print("PASS: test_jq4110_category_default")


def test_unknown_category_returns_none():
    result = auto_fill_gosi("UNKNOWN_MODEL_XYZ", None)
    assert result is None, f"카테고리 None이면 디폴트도 없어야 함 (got {result!r})"
    print("PASS: test_unknown_category_returns_none")


def test_keyword_match_priority():
    # 키워드 매칭이 비어 있으면 카테고리 디폴트로 폴백.
    # 어느 쪽이든 None이 아니어야 함 (입찰 가능 상태).
    result = auto_fill_gosi("Onitsuka Tiger Mexico 66", "신발")
    assert result is not None, "키워드/카테고리 어느 쪽으로도 None이 아니어야 함"
    print("PASS: test_keyword_match_priority")


if __name__ == "__main__":
    test_jq4110_category_default()
    test_unknown_category_returns_none()
    test_keyword_match_priority()
    print("\nAll 3 tests PASSED.")
