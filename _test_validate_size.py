"""Step 17-A 회귀 테스트 — kream_server import 부작용 회피.

validate_size_for_bid 로직을 sqlite3 직접 조회로 재현한 후
4개 시나리오 검증. (kream_server 전체 import 금지: Flask app 부작용)
"""
import sqlite3
import sys
from pathlib import Path

PRICE_DB = Path(__file__).parent / "price_history.db"
ONE_SIZE_TOKENS = ("ONE SIZE", "ONESIZE", "ONE_SIZE", "FREE", "OS")


def get_model_category_local(model):
    if not model:
        return {"category": "unknown", "needs_size": True, "source": "default"}
    conn = sqlite3.connect(str(PRICE_DB))
    try:
        row = conn.execute(
            "SELECT category, needs_size, source FROM model_category WHERE model=?",
            (model,)
        ).fetchone()
        if row:
            return {"category": row[0], "needs_size": bool(row[1]), "source": row[2]}
        row = conn.execute(
            "SELECT category FROM shihuo_prices WHERE active=1 AND model=? LIMIT 1",
            (model,)
        ).fetchone()
        if row:
            cat = row[0] or "unknown"
            return {"category": cat, "needs_size": (cat != "bags"), "source": "shihuo"}
    finally:
        conn.close()
    return {"category": "unknown", "needs_size": True, "source": "default"}


def validate_size_for_bid_local(model, size):
    cat_info = get_model_category_local(model)
    size_clean = (size or "").strip().upper()
    if cat_info["needs_size"]:
        if not size_clean or size_clean in ONE_SIZE_TOKENS:
            return (False,
                    f"카테고리 '{cat_info['category']}'은(는) 사이즈 필수 (model={model}, size='{size}')",
                    cat_info)
    return (True, None, cat_info)


def run_tests():
    cases = [
        # (label, model, size, expected_valid)
        ("신발(JQ4110) ONE SIZE → 차단", "JQ4110", "ONE SIZE", False),
        ("신발(JQ4110) 빈값 → 차단", "JQ4110", "", False),
        ("신발(JQ4110) FREE → 차단", "JQ4110", "FREE", False),
        ("신발(JQ4110) 230 → 통과", "JQ4110", "230", True),
        ("신발(JQ1501) 250 → 통과", "JQ1501", "250", True),
        ("신발(KK3774) ONE SIZE → 차단", "KK3774", "ONE SIZE", False),
        ("가방(IX7694, 캐시 미스+shihuo 미스) ONE SIZE → 보수적 차단", "IX7694", "ONE SIZE", False),
        ("가방(JE3208, 재임포트로 캐시 등록) ONE SIZE → 통과", "JE3208", "ONE SIZE", True),
        ("가방(JE3209) ONE SIZE → 통과", "JE3209", "ONE SIZE", True),
        ("가방(KA9266) ONE SIZE → 통과", "KA9266", "ONE SIZE", True),
        ("가방(IC8349) 빈값 → 통과", "IC8349", "", True),
        ("미상 모델 ONE SIZE → 보수적 차단", "ZZZ_UNKNOWN", "ONE SIZE", False),
        ("미상 모델 230 → 통과", "ZZZ_UNKNOWN", "230", True),
        ("model 없음 ONE SIZE → 차단", "", "ONE SIZE", False),
    ]
    failed = 0
    for label, model, size, expected in cases:
        ok, err, cat = validate_size_for_bid_local(model, size)
        result = "✓" if ok == expected else "✗"
        if ok != expected:
            failed += 1
            print(f"{result} {label}")
            print(f"   기대={expected} 실제={ok} cat={cat} err={err}")
        else:
            print(f"{result} {label}  (cat={cat['category']}, needs_size={cat['needs_size']})")
    print(f"\n결과: {len(cases) - failed}/{len(cases)} pass, {failed} fail")
    return failed == 0


if __name__ == "__main__":
    sys.exit(0 if run_tests() else 1)
