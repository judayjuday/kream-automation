import sqlite3, json
from pathlib import Path
from collections import defaultdict

mybids = json.loads(Path('my_bids_local.json').read_text())
jq = [b for b in mybids.get('bids', []) if b.get('model') == 'JQ4110']

conn = sqlite3.connect('price_history.db')
c = conn.cursor()

result = {
    'model': 'JQ4110',
    'scenario': 'ONE_SIZE',
    'bids': [],
    'missing_cost': [],
    'duplicates_by_size': {},
    'margin_analysis': []
}

by_size = defaultdict(list)
for b in jq:
    by_size[b.get('size')].append(b)

for size, bids in by_size.items():
    if len(bids) > 2:
        result['duplicates_by_size'][size] = {
            'count': len(bids),
            'bids': sorted(bids, key=lambda x: -x.get('price', 0)),
            'recommendation': f'가장 비싼 {len(bids)-2}건 삭제 권장 (사용자 확인 후 실행)'
        }

for b in jq:
    oid = b.get('orderId')
    c.execute('SELECT cny_price, exchange_rate, overseas_shipping FROM bid_cost WHERE order_id=?', (oid,))
    row = c.fetchone()
    if not row:
        result['missing_cost'].append({
            'order_id': oid,
            'size': b.get('size'),
            'price': b.get('price')
        })
    else:
        cny, fx, ship = row
        if cny and fx:
            cost = cny * fx * 1.03 + (ship or 8000)
            settlement = b['price'] * (1 - 0.06 * 1.1) - 2500
            margin = settlement - cost
            result['margin_analysis'].append({
                'order_id': oid,
                'size': b.get('size'),
                'price': b['price'],
                'cost': round(cost),
                'settlement': round(settlement),
                'margin': round(margin),
                'status': 'OK' if margin >= 4000 else 'LOW' if margin >= 0 else 'DEFICIT'
            })
    result['bids'].append(b)

conn.close()

out_path = f'jq4110_report_20260502_112009.json'
Path(out_path).write_text(json.dumps(result, ensure_ascii=False, indent=2))
print(f'리포트 저장: {out_path}')
print(f'입찰: {len(result["bids"])}건')
print(f'원가 누락: {len(result["missing_cost"])}건')
print(f'중복 사이즈: {len(result["duplicates_by_size"])}개')
print(f'마진 분석: {len(result["margin_analysis"])}건')
