# 작업지시서 — JQ4110 ONE_SIZE 시나리오

> 작성: 20260502_112009 (자동 생성)
> 모델: JQ4110 — (W) 아디다스 오즈가이아 트리플 블랙
> 시나리오: ONE_SIZE
> 현재 입찰: 3건, 사이즈: ONE SIZE

## 환경 제약
- 맥북(해외)에서 실행 중
- kream.co.kr 차단 → 시장 가격 신규 수집 불가
- partner.kream.co.kr만 접속 가능 → 입찰 관리는 가능
- 가격 수집 필요한 작업은 SKIP하고 사유 기록

## 절대 규칙 (CLAUDE.md)
1. 원가 없으면 NULL (가짜 값 금지)
2. 판매 완료 건 수정/삭제 금지
3. price_history.db DROP/DELETE 금지
4. auth_state.json 백업 없이 덮어쓰기 금지
5. git push -f, git reset --hard 금지
6. 테스트 데이터로 실제 입찰 금지
7. 자동 토글 ON 변경 금지 (현재 OFF 유지)

## 진행 작업

### 작업 #1: JQ4110 입찰 종합 진단
```python
# Python으로 sqlite3 + my_bids_local.json 분석
import sqlite3, json
from pathlib import Path

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

# 사이즈별 그룹화 (중복 검증)
from collections import defaultdict
by_size = defaultdict(list)
for b in jq:
    by_size[b.get('size')].append(b)

for size, bids in by_size.items():
    if len(bids) > 2:  # 규칙: 사이즈당 2건
        result['duplicates_by_size'][size] = {
            'count': len(bids),
            'bids': sorted(bids, key=lambda x: -x.get('price', 0)),
            'recommendation': f'가장 비싼 {len(bids)-2}건 삭제 권장 (사용자 확인 후 실행)'
        }

# bid_cost 누락 확인
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
        # 마진 계산
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

# 저장
out_path = f'jq4110_report_20260502_112009.json'
Path(out_path).write_text(json.dumps(result, ensure_ascii=False, indent=2))
print(f'리포트 저장: {out_path}')
print(f'입찰: {len(result["bids"])}건')
print(f'원가 누락: {len(result["missing_cost"])}건')
print(f'중복 사이즈: {len(result["duplicates_by_size"])}개')
print(f'마진 분석: {len(result["margin_analysis"])}건')
```

### 작업 #2: 모니터링 1회 실행
```bash
curl -s -X POST http://localhost:5001/api/monitor/run-once
```

### 작업 #3: 결과 검증
- jq4110_report_20260502_112009.json 존재 확인
- /api/health 200 확인
- /api/queue/list 200 확인

### 작업 #4: 시나리오별 추가 작업

**ONE_SIZE 시나리오:**
- 입찰 3건 모두 ONE SIZE → 규칙상 비정상 (사이즈당 2건)
- 가장 비싼 건 삭제 후보로 리포트에 기록
- 실제 삭제는 안 함 (사용자 확인 필요)

**NO_BIDS 시나리오:**
- 입찰 없음 → 리포트만 생성하고 종료
- 시장 가격 수집 필요 (맥북 환경 차단으로 진행 불가)
- "사무실 iMac 또는 VPN 환경에서 가격 수집 필요" 명시

**MULTI_SIZE 시나리오:**
- 사이즈별 마진 분석
- 마진 4,000원 미달 사이즈 알림

## 커밋 메시지
```
ops(JQ4110): ONE_SIZE 시나리오 진단 + 리포트 생성

- 입찰 3건 종합 분석
- bid_cost 누락 확인
- 마진 분석 + 중복 검증
- 모니터링 1회 실행

리포트: jq4110_report_20260502_112009.json
```

## 금지 사항
- 입찰 자동 삭제 금지 (사용자 확인 필요)
- bid_cost에 가짜 CNY 입력 금지 (NULL 유지)
- 자동 토글 변경 금지
- kream.co.kr 직접 접속 시도 금지 (차단됨)
