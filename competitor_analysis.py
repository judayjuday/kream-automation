"""
경쟁사 가격 분석 스크립트
- 得物 중국 원가 vs KREAM 해외배송 가격 비교
- 사이즈별 마진 분석
- 경쟁자 가격 전략 추정

사용법:
  python3 competitor_analysis.py                    # 오프라인 분석 (KREAM 가격 수동 입력)
  python3 competitor_analysis.py --fetch             # KREAM 서버 API로 실시간 수집
  python3 competitor_analysis.py --fetch --server http://localhost:5001
"""

import json
import math
import argparse
from datetime import datetime
from pathlib import Path

# ═══════════════════════════════════════════
# 데이터 정의
# ═══════════════════════════════════════════

CNY_RATE = 217.30        # 위안→원 환율
TARIFF_SHOE = 0.13       # 신발 관세율
SHIPPING_KRW = 8000      # 해외배송비
KREAM_FEE_RATE = 0.035   # KREAM 수수료 3.5%
KREAM_FEE_VAT = 0.10     # 수수료 부가세 10%
USD_LIMIT = 150           # 면세 한도 (USD)
USD_RATE = 1450           # USD→KRW (환율 추정)
CNY_MARGIN = 1.03         # 위안 구매 마진 3%

# 브랜드별 EU→KR 사이즈 변환
SIZE_MAP = {
    "onitsuka": {
        "EU36": "225", "EU37": "230", "EU37.5": "235", "EU38": "240",
        "EU39": "245", "EU39.5": "250", "EU40": "252.5", "EU40.5": "255",
        "EU41.5": "260", "EU42": "265", "EU42.5": "270", "EU43.5": "275",
        "EU44": "280", "EU44.5": "282.5", "EU45": "285", "EU46": "290",
    },
    "newbalance": {
        "EU35.5": "215", "EU36": "220", "EU37": "225", "EU37.5": "230",
        "EU38": "235", "EU38.5": "240", "EU39.5": "245", "EU40": "250",
        "EU40.5": "255", "EU41.5": "260", "EU42": "265", "EU42.5": "270",
        "EU43": "275", "EU44": "280", "EU44.5": "285", "EU45": "290",
    },
    "mizuno": {
        "EU36": "225", "EU36.5": "230", "EU37": "235", "EU38": "240",
        "EU38.5": "245", "EU39": "250", "EU40": "255", "EU40.5": "260",
        "EU41": "265", "EU42": "270", "EU42.5": "275", "EU43": "280",
        "EU44": "285", "EU44.5": "290", "EU45": "295",
    },
}

# 得物 가격 데이터
PRODUCTS = [
    {
        "model": "1183B480-250",
        "name": "오니츠카 런스파크 크림 라이트블루",
        "brand": "onitsuka",
        "dewu_prices": {
            "EU36": 532, "EU37": 544, "EU37.5": 565, "EU38": 565,
            "EU39": 499, "EU39.5": 502, "EU40": 484, "EU40.5": 480,
            "EU41.5": 479, "EU42": 498, "EU42.5": 491, "EU43.5": 516,
            "EU44": 505, "EU44.5": 514, "EU45": 561, "EU46": 574,
        },
    },
    {
        "model": "M1906AD",
        "name": "뉴발란스 1906AD",
        "brand": "newbalance",
        "dewu_prices": {
            "EU36": 768, "EU37": 768, "EU37.5": 838, "EU38": 843,
            "EU38.5": 886, "EU39.5": 820, "EU40": 847, "EU40.5": 860,
            "EU41.5": 834, "EU42": 829, "EU42.5": 847, "EU43": 894,
            "EU44": 805, "EU44.5": 918, "EU45": 997,
        },
    },
    {
        "model": "M1906AG",
        "name": "뉴발란스 1906AG",
        "brand": "newbalance",
        "dewu_prices": {
            "EU36": 1018, "EU37": 959, "EU37.5": 1014, "EU38": 1022,
            "EU38.5": 1048, "EU39.5": 931, "EU40": 919, "EU40.5": 949,
            "EU41.5": 857, "EU42": 838, "EU42.5": 879, "EU43": 853,
            "EU44": 857, "EU44.5": 1141, "EU45": 1029,
        },
    },
    {
        "model": "1183B799-101",
        "name": "오니츠카 중국단독 B799",
        "brand": "onitsuka",
        "dewu_prices": {
            "EU36": 485, "EU37": 422, "EU37.5": 434, "EU38": 437,
            "EU39": 423, "EU39.5": 438, "EU40": 441, "EU40.5": 438,
            "EU41.5": 429, "EU42": 497, "EU42.5": 599, "EU43.5": 494,
            "EU44": 482, "EU44.5": 476, "EU45": 548, "EU46": 534,
        },
    },
    {
        "model": "1203A714-020",
        "name": "오니츠카 중국단독 A714",
        "brand": "onitsuka",
        "dewu_prices": {
            "EU37": 1067, "EU39": 1058, "EU39.5": 940, "EU40": 538,
            "EU40.5": 529, "EU41.5": 530, "EU42": 530, "EU42.5": 1422,
            "EU43.5": 538, "EU44": 699,
        },
    },
    {
        "model": "D1GH241906",
        "name": "미즈노 중국단독",
        "brand": "mizuno",
        "dewu_prices": {
            "EU36": 798, "EU36.5": 760, "EU37": 649, "EU38": 649,
            "EU38.5": 680, "EU39": 666, "EU40": 488, "EU40.5": 488,
            "EU41": 488, "EU42": 488, "EU42.5": 488, "EU43": 488,
            "EU44": 488, "EU44.5": 488,
        },
    },
]


# ═══════════════════════════════════════════
# 원가 계산
# ═══════════════════════════════════════════

def calc_total_cost(cny_price):
    """
    원가 계산:
    1. CNY 구매가 (위안 × 환율 × 마진)
    2. 관세 (USD $150 초과 시: CNY × 환율 × 관세율)
    3. 부가세 (관세 부과 시: (원화가 + 관세) × 10%)
    4. 배송비
    """
    krw_buy = round(cny_price * CNY_RATE * CNY_MARGIN)
    usd_equiv = cny_price * CNY_RATE / USD_RATE

    customs = 0
    import_vat = 0
    if usd_equiv > USD_LIMIT:
        customs = round(cny_price * CNY_RATE * TARIFF_SHOE)
        import_vat = round((cny_price * CNY_RATE + customs) * 0.10)

    total = krw_buy + customs + import_vat + SHIPPING_KRW
    return {
        "cny": cny_price,
        "krw_buy": krw_buy,
        "usd_equiv": round(usd_equiv, 1),
        "customs": customs,
        "import_vat": import_vat,
        "shipping": SHIPPING_KRW,
        "total_cost": total,
    }


def calc_kream_settlement(sell_price):
    """KREAM 판매 시 정산액"""
    commission = round(sell_price * KREAM_FEE_RATE)
    comm_vat = round(commission * KREAM_FEE_VAT)
    total_fee = commission + comm_vat
    return sell_price - total_fee


def calc_margin(sell_price, total_cost):
    """마진 계산 (정산액 - 원가)"""
    settlement = calc_kream_settlement(sell_price)
    margin = settlement - total_cost
    margin_rate = (margin / total_cost * 100) if total_cost > 0 else 0
    return {
        "sell_price": sell_price,
        "settlement": settlement,
        "margin": margin,
        "margin_rate": round(margin_rate, 1),
    }


# ═══════════════════════════════════════════
# KREAM 가격 수집 (서버 API)
# ═══════════════════════════════════════════

def fetch_kream_prices(model, server_url="http://localhost:5001"):
    """KREAM 서버 API를 통해 상품 가격 수집"""
    import urllib.request
    import time

    print(f"  KREAM 검색: {model}")

    # 1) 검색 요청
    req_data = json.dumps({"model": model}).encode()
    req = urllib.request.Request(
        f"{server_url}/api/search",
        data=req_data,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            result = json.loads(resp.read())
    except Exception as e:
        print(f"    검색 요청 실패: {e}")
        return None

    task_id = result.get("taskId")
    if not task_id:
        print("    taskId 없음")
        return None

    # 2) 폴링
    for _ in range(60):
        time.sleep(3)
        try:
            with urllib.request.urlopen(f"{server_url}/api/task/{task_id}", timeout=10) as resp:
                task = json.loads(resp.read())
        except Exception:
            continue

        if task["status"] == "done":
            kream = task.get("result", {}).get("kream", {})
            print(f"    수집 완료: {kream.get('product_name', 'N/A')}")
            return kream
        elif task["status"] == "error":
            print(f"    수집 실패")
            return None

    print("    타임아웃")
    return None


def extract_overseas_sell_prices(kream_data):
    """
    KREAM 데이터에서 해외배송 판매입찰가 추출.
    sell_bids에서 사이즈별 최저 판매가를 반환.
    """
    sell_bids = kream_data.get("sell_bids", [])
    if not sell_bids:
        return {}

    # sell_bids: [{price, quantity, ...}, ...]
    # 사이즈별이 아니라 전체 최저가인 경우가 많음
    # 사이즈별 가격은 별도 수집이 필요할 수 있음
    prices = {}
    for bid in sell_bids:
        price = bid.get("price", 0)
        size = bid.get("size", "")
        if price and size:
            if size not in prices or price < prices[size]:
                prices[size] = price

    # 사이즈 정보 없으면 전체 최저가만 반환
    if not prices and sell_bids:
        lowest = min(b["price"] for b in sell_bids if b.get("price"))
        prices["ALL"] = lowest

    return prices


# ═══════════════════════════════════════════
# 분석
# ═══════════════════════════════════════════

def analyze_product(product, kream_prices=None):
    """상품별 경쟁사 마진 분석"""
    brand = product["brand"]
    size_map = SIZE_MAP.get(brand, {})
    dewu = product["dewu_prices"]

    results = []
    for eu_size, cny_price in dewu.items():
        kr_size = size_map.get(eu_size, "?")
        cost = calc_total_cost(cny_price)

        # KREAM 가격 (수집된 경우)
        kream_sell = None
        if kream_prices:
            kream_sell = kream_prices.get(kr_size) or kream_prices.get("ALL")

        margin_info = None
        if kream_sell:
            margin_info = calc_margin(kream_sell, cost["total_cost"])

        results.append({
            "eu_size": eu_size,
            "kr_size": kr_size,
            "cny": cny_price,
            **cost,
            "kream_sell": kream_sell,
            "margin": margin_info,
        })

    return results


def print_analysis(product, analysis):
    """분석 결과 출력"""
    print(f"\n{'='*90}")
    print(f"  {product['model']} - {product['name']}")
    print(f"{'='*90}")

    header = f"{'EU':>7} {'KR':>6} {'CNY':>6} {'원가':>10} {'관세':>7} "
    header += f"{'KREAM가':>10} {'정산액':>10} {'마진':>10} {'마진율':>7}"
    print(header)
    print("-" * 90)

    margins = []
    for r in analysis:
        line = f"{r['eu_size']:>7} {r['kr_size']:>6} {r['cny']:>5}¥ {r['total_cost']:>9,}원"
        line += f" {r['customs']:>6,}원"

        if r["margin"]:
            m = r["margin"]
            margins.append(m["margin_rate"])
            margin_str = f"{'+' if m['margin'] >= 0 else ''}{m['margin']:>8,}원"
            rate_str = f"{m['margin_rate']:>5.1f}%"
            line += f" {m['sell_price']:>9,}원 {m['settlement']:>9,}원 {margin_str} {rate_str}"
        else:
            line += f" {'미수집':>9} {'':>10} {'':>10} {'':>7}"

        print(line)

    if margins:
        avg = sum(margins) / len(margins)
        min_m = min(margins)
        max_m = max(margins)
        print("-" * 90)
        print(f"  평균 마진율: {avg:.1f}%  |  최저: {min_m:.1f}%  |  최고: {max_m:.1f}%")

        # 최저 마진 사이즈 찾기
        for r in analysis:
            if r["margin"] and r["margin"]["margin_rate"] == min_m:
                print(f"  최저 마진 사이즈: {r['eu_size']} ({r['kr_size']}) "
                      f"- CNY {r['cny']}¥ → {r['margin']['sell_price']:,}원 "
                      f"= {r['margin']['margin']:,}원 ({min_m:.1f}%)")
                break

    return margins


def estimate_pricing_strategy(all_margins):
    """경쟁자 가격 전략 추정"""
    print(f"\n{'='*90}")
    print("  경쟁자 가격 전략 추정")
    print(f"{'='*90}")

    if not all_margins:
        print("  분석 데이터 부족")
        return

    flat = []
    for product_margins in all_margins.values():
        flat.extend(product_margins)

    if not flat:
        print("  KREAM 가격 미수집 - 수집 후 재분석 필요")
        return

    avg = sum(flat) / len(flat)
    median = sorted(flat)[len(flat) // 2]
    min_m = min(flat)
    max_m = max(flat)

    print(f"\n  전체 평균 마진율: {avg:.1f}%")
    print(f"  중앙값 마진율: {median:.1f}%")
    print(f"  마진 범위: {min_m:.1f}% ~ {max_m:.1f}%")
    print(f"  분석 사이즈 수: {len(flat)}건")

    # 마진율 분포
    buckets = {"0% 미만 (적자)": 0, "0~5%": 0, "5~10%": 0, "10~15%": 0,
               "15~20%": 0, "20~30%": 0, "30%+": 0}
    for m in flat:
        if m < 0:
            buckets["0% 미만 (적자)"] += 1
        elif m < 5:
            buckets["0~5%"] += 1
        elif m < 10:
            buckets["5~10%"] += 1
        elif m < 15:
            buckets["10~15%"] += 1
        elif m < 20:
            buckets["15~20%"] += 1
        elif m < 30:
            buckets["20~30%"] += 1
        else:
            buckets["30%+"] += 1

    print("\n  마진율 분포:")
    for label, count in buckets.items():
        bar = "█" * count
        pct = count / len(flat) * 100
        print(f"    {label:>15}: {count:>3}건 ({pct:>5.1f}%) {bar}")

    # 전략 추정
    print("\n  추정 전략:")
    if avg < 5:
        print("  → 박리다매 전략: 매우 낮은 마진, 물량 위주")
        print("  → 진입 장벽 낮음, 가격 경쟁 치열")
    elif avg < 10:
        print("  → 적정 마진 전략: 시장 평균 수준")
        print("  → 안정적 수익, 가격 경쟁력 유지")
    elif avg < 15:
        print("  → 준프리미엄 전략: 평균 이상 마진")
        print("  → 경쟁자가 적거나, 독점 소싱 루트 보유 가능")
    else:
        print("  → 프리미엄 전략: 높은 마진")
        print("  → 희소 상품이거나, 경쟁 부재 상태")

    if min_m < 3:
        print(f"\n  주의: 최저 마진 {min_m:.1f}%는 환율 변동 시 적자 전환 가능")


def save_analysis_json(all_results, output_path="competitor_analysis_result.json"):
    """분석 결과를 JSON으로 저장"""
    output = {
        "analyzed_at": datetime.now().strftime("%Y-%m-%d %H:%M"),
        "params": {
            "cny_rate": CNY_RATE,
            "tariff": TARIFF_SHOE,
            "shipping": SHIPPING_KRW,
            "kream_fee": KREAM_FEE_RATE,
            "cny_margin": CNY_MARGIN,
        },
        "products": {},
    }

    for model, data in all_results.items():
        output["products"][model] = {
            "name": data["name"],
            "sizes": data["analysis"],
            "avg_margin": data.get("avg_margin"),
            "min_margin": data.get("min_margin"),
            "max_margin": data.get("max_margin"),
        }

    Path(output_path).write_text(json.dumps(output, ensure_ascii=False, indent=2, default=str))
    print(f"\n  결과 저장: {output_path}")


# ═══════════════════════════════════════════
# 메인
# ═══════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(description="경쟁사 가격 분석")
    parser.add_argument("--fetch", action="store_true", help="KREAM 서버 API로 가격 수집")
    parser.add_argument("--server", default="http://localhost:5001", help="서버 주소")
    parser.add_argument("--model", help="특정 모델만 분석 (콤마 구분)")
    args = parser.parse_args()

    print("=" * 90)
    print("  경쟁사 가격 분석")
    print(f"  환율: CNY {CNY_RATE}원 | 관세: {TARIFF_SHOE*100}% | 배송비: {SHIPPING_KRW:,}원")
    print(f"  KREAM 수수료: {KREAM_FEE_RATE*100}% + VAT {KREAM_FEE_VAT*100}%")
    print("=" * 90)

    target_models = args.model.split(",") if args.model else None

    all_margins = {}
    all_results = {}

    for product in PRODUCTS:
        model = product["model"]
        if target_models and model not in target_models:
            continue

        # KREAM 가격 수집
        kream_prices = None
        if args.fetch:
            kream_data = fetch_kream_prices(model, args.server)
            if kream_data:
                kream_prices = extract_overseas_sell_prices(kream_data)

        # 분석
        analysis = analyze_product(product, kream_prices)
        margins = print_analysis(product, analysis)
        all_margins[model] = margins

        # 결과 저장용
        serializable = []
        for r in analysis:
            entry = {k: v for k, v in r.items() if k != "margin"}
            if r["margin"]:
                entry.update(r["margin"])
            serializable.append(entry)

        all_results[model] = {
            "name": product["name"],
            "analysis": serializable,
            "avg_margin": round(sum(margins) / len(margins), 1) if margins else None,
            "min_margin": round(min(margins), 1) if margins else None,
            "max_margin": round(max(margins), 1) if margins else None,
        }

    # 전략 추정
    estimate_pricing_strategy(all_margins)

    # 원가 요약 (KREAM 가격 없이도 유용)
    print(f"\n{'='*90}")
    print("  원가 요약 (KREAM 가격 미수집 시 참고용)")
    print(f"{'='*90}")
    for product in PRODUCTS:
        model = product["model"]
        if target_models and model not in target_models:
            continue

        costs = [calc_total_cost(cny)["total_cost"] for cny in product["dewu_prices"].values()]
        avg_cost = sum(costs) // len(costs)
        min_cost = min(costs)
        max_cost = max(costs)

        # 손익분기 판매가 계산 (정산액 >= 원가)
        # settlement = sell * (1 - fee * 1.1)
        # sell = cost / (1 - fee * 1.1)
        effective_rate = 1 - KREAM_FEE_RATE * (1 + KREAM_FEE_VAT)
        break_even_avg = math.ceil(avg_cost / effective_rate / 1000) * 1000
        break_even_min = math.ceil(min_cost / effective_rate / 1000) * 1000

        # 10% 마진 판매가
        target_10 = math.ceil((avg_cost * 1.10) / effective_rate / 1000) * 1000
        # 15% 마진 판매가
        target_15 = math.ceil((avg_cost * 1.15) / effective_rate / 1000) * 1000

        print(f"\n  {model} ({product['name']})")
        print(f"    원가: {min_cost:,}원 ~ {max_cost:,}원 (평균 {avg_cost:,}원)")
        print(f"    손익분기: {break_even_min:,}원 (최저) / {break_even_avg:,}원 (평균)")
        print(f"    10%마진: {target_10:,}원 | 15%마진: {target_15:,}원")

    # JSON 저장
    save_analysis_json(all_results)


if __name__ == "__main__":
    main()
