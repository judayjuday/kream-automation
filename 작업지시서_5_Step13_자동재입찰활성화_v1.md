# 작업지시서 — Step 13: 자동 재입찰 활성화 (임시키 패치 + dry-run 검증 + 활성화)

작성일: 2026-04-30 22:55
대상 시스템: KREAM 자동화 (`~/Desktop/kream_automation/`)
운영 머신: 맥북 (한국, 사무실 iMac OFF 상태)
관련 문서:
- `KREAM_허브넷통합_인수인계_v5.md`
- `auto_rebid_after_sale()` 정의: kream_server.py:7196
- `_run_sales_sync()` 호출처: kream_server.py:5828
예상 소요: 90~120분
다음 단계: Step 14 (자동 가격 조정 활성화 검토), Step 15+ (识货 임포트)

---

## 0. 작업 목적

기존에 코드는 박혀 있으나 `settings.auto_rebid_enabled=false`로 OFF 상태인 자동 재입찰 시스템을 활성화한다.
활성화 직전에 **임시키 충돌 위험**을 패치하고, **시뮬레이션 검증 5종** 통과 후에만 실제 ON.

함수 자체는 7중 안전장치(daily_max, bid_cost 체크, 루프 가드, KREAM 가격 매칭, 자기 입찰 제외, 가격 급변 ±10%, 마진 4000원 하한)가 들어있어 production-ready 품질이지만, 실제 운영 데이터에 한 번도 노출된 적이 없는 상태.

---

## 1. 핵심 원칙 — 절대 위반 금지

### 1.1 격리 원칙 ⭐
자동 재입찰 실패가 판매 수집을 망가뜨리면 안 됨.
- 호출부(_run_sales_sync 5828줄)는 이미 try/except로 감싸여 있음
- 함수 내부도 try/except 다중 격리 유지

### 1.2 데이터 안전성
- bid_cost UNIQUE 충돌 위험을 사전에 패치 (§2)
- 실제 입찰을 박는 단계 전에 7중 안전장치 모두 통과 확인
- 활성화 후에도 settings 토글로 즉시 OFF 가능

### 1.3 실제 입찰은 검증 후 마지막 단계
- 시뮬레이션 검증 5종 모두 통과
- 활성화는 `settings.auto_rebid_enabled=true` 한 줄
- 처음 며칠은 **server.log + auto_rebid_log 매일 점검**

### 1.4 사무실 iMac OFF 상태 유지
- 맥북에서만 운영 중. 두 머신 동시 운영 = DB 충돌 위험
- 본 작업 중 사무실 iMac 부팅 금지

---

## 2. 변경 사항 — 두 군데

### 2.1 임시키 충돌 패치 (kream_server.py)

`_execute_rebid` 또는 `_save_bid_cost` 호출부에서 `order_id` 생성 패턴을 수정.

#### 2.1.1 변경 위치 파악
```bash
grep -n "_rebid\"\|_rebid'" kream_server.py
```

#### 2.1.2 변경 내용
```python
# 변경 전
order_id=f"{product_id}_{size}_rebid"

# 변경 후
order_id=f"{product_id}_{size}_rebid_{int(time.time())}"
```

`time` 모듈은 이미 import돼 있음(Step 12에서 추가). 추가 import 불필요.

만약 `_execute_rebid` 함수 안에서 직접 임시키를 만든다면 그 함수의 해당 줄을 수정. 호출부에서 만든다면 호출부를 수정.
**모든 임시키 생성 지점**을 찾아서 수정 (일관성).

#### 2.1.3 patch 검증
```bash
# 패치 후
grep -n "_rebid\"\|_rebid'" kream_server.py
# → 모든 occurrence가 _rebid_{int(time.time())} 형태여야 함

python3 -m py_compile kream_server.py
```

### 2.2 settings.json 활성화 (검증 통과 후 마지막 단계)

```json
"auto_rebid_enabled": true
```

⚠️ **§4 시뮬레이션 검증 5종 모두 통과 후에만 변경.**

---

## 3. 사전 안전 조치

```bash
cd ~/Desktop/kream_automation

# DB 백업 (절대경로 + 파일명에 step13 명시)
sqlite3 /Users/iseungju/Desktop/kream_automation/price_history.db \
  ".backup '/Users/iseungju/Desktop/kream_automation/price_history_backup_step13_pre.db'"

# 핵심 파일 백업
cp kream_server.py kream_server.py.step13_pre.bak
cp settings.json settings.json.step13_pre.bak

# 현재 auto_rebid_enabled 값 (False여야 정상 출발선)
python3 -c "import json; print('auto_rebid_enabled =', json.load(open('settings.json')).get('auto_rebid_enabled'))"

# bid_cost 현황 (충돌 위험 사전 평가)
sqlite3 price_history.db "SELECT COUNT(*) FROM bid_cost; SELECT order_id FROM bid_cost WHERE order_id LIKE '%_rebid%' LIMIT 10"

# auto_rebid_log 현황 (현재 0건이어야 정상)
sqlite3 price_history.db "SELECT COUNT(*) FROM auto_rebid_log; SELECT * FROM auto_rebid_log LIMIT 5"
```

---

## 4. 시뮬레이션 검증 5종 — 활성화 전 필수

⚠️ **이 검증은 자동 재입찰을 OFF 상태에서 함수만 직접 호출하여 동작을 관찰**한다.
**실제 KREAM에 입찰을 박지 않게** 한다.

### 시나리오 1: 임시키 패치 검증 (DB 직접 INSERT)
```bash
# 같은 product_id+size로 두 번 INSERT 시도 (1초 간격)
python3 -c "
import sqlite3, time, sys
db = '/Users/iseungju/Desktop/kream_automation/price_history.db'
conn = sqlite3.connect(db)
c = conn.cursor()
ts1 = int(time.time())
time.sleep(1)
ts2 = int(time.time())
try:
    c.execute('INSERT INTO bid_cost (order_id, model, size, cny_price, exchange_rate) VALUES (?, ?, ?, ?, ?)',
              (f'TEST_240_rebid_{ts1}', 'TEST_MODEL', '240', 100.0, 215.0))
    c.execute('INSERT INTO bid_cost (order_id, model, size, cny_price, exchange_rate) VALUES (?, ?, ?, ?, ?)',
              (f'TEST_240_rebid_{ts2}', 'TEST_MODEL', '240', 110.0, 215.0))
    conn.commit()
    print('✅ 두 번째 INSERT 성공 — 임시키 충돌 회피 확인')
except sqlite3.IntegrityError as e:
    print(f'❌ UNIQUE 충돌: {e}')
finally:
    # 정리
    c.execute('DELETE FROM bid_cost WHERE model=?', ('TEST_MODEL',))
    conn.commit()
    conn.close()
"
# → ✅ 두 번째 INSERT 성공
```

### 시나리오 2: 함수 OFF 상태 호출 (skipped_disabled 분기)
```bash
# 가짜 sale_records로 호출. auto_rebid_enabled=False이니 즉시 skipped_disabled
python3 -c "
import sys
sys.path.insert(0, '/Users/iseungju/Desktop/kream_automation')
from kream_server import auto_rebid_after_sale
fake_sales = [{'order_id': 'FAKE_001', 'model': 'JQ4110', 'size': '240', 'sale_price': 150000, 'product_id': '999999'}]
result = auto_rebid_after_sale(fake_sales)
print('결과:', result)
"
# → success=0, skipped=1, failed=0, details=[{reason:'skipped_disabled'}]
```

### 시나리오 3: 자동 재입찰 ON 상태에서 안전장치 분기 검증

⚠️ 이 시나리오는 **잠시 auto_rebid_enabled=true로 변경**해서 함수 호출. 호출 직후 **즉시 false 복원**.

```bash
# 3-1. 임시 ON
python3 -c "
import json
s = json.load(open('settings.json'))
s['_auto_rebid_enabled_orig'] = s.get('auto_rebid_enabled', False)
s['auto_rebid_enabled'] = True
json.dump(s, open('settings.json','w'), ensure_ascii=False, indent=2)
print('임시 ON 완료')
"

# 3-2. 안전장치 분기 케이스별 호출
python3 -c "
import sys
sys.path.insert(0, '/Users/iseungju/Desktop/kream_automation')
from kream_server import auto_rebid_after_sale

print('--- 케이스 A: 블랙리스트에 없는 모델 + bid_cost 없음 → skipped_no_cost ---')
fake_sales_a = [{'order_id': 'FAKE_NOCOST', 'model': 'NEVER_EXIST_MODEL', 'size': '240', 'sale_price': 150000, 'product_id': '999999'}]
result_a = auto_rebid_after_sale(fake_sales_a)
print('결과 A:', result_a)
print()

print('--- 케이스 B: 빈 sale_records → success=0, skipped=0, failed=0 ---')
result_b = auto_rebid_after_sale([])
print('결과 B:', result_b)
"

# 3-3. auto_rebid_log 확인 — skipped_no_cost 분기 기록되어야 함
sqlite3 price_history.db "
  SELECT id, order_id, model, size, action, decision_notes, executed_at
  FROM auto_rebid_log
  WHERE order_id LIKE 'FAKE_%'
  ORDER BY id DESC LIMIT 10
"

# 3-4. 즉시 false 복원
python3 -c "
import json
s = json.load(open('settings.json'))
s['auto_rebid_enabled'] = s.pop('_auto_rebid_enabled_orig', False)
json.dump(s, open('settings.json','w'), ensure_ascii=False, indent=2)
print('false 복원:', s['auto_rebid_enabled'])
"

# 3-5. 테스트 데이터 정리
sqlite3 price_history.db "DELETE FROM auto_rebid_log WHERE order_id LIKE 'FAKE_%'"
```

기대:
- 케이스 A: skipped=1 (skipped_no_cost), auto_rebid_log에 1건 기록
- 케이스 B: 빈 입력에 대한 정상 처리 (예외 없음)

### 시나리오 4: 자기 입찰 제외 검증 (가능하면)

이 시나리오는 실제 my_bids_local.json에 같은 모델+사이즈 입찰이 있어야 검증 가능. 없으면 "자연 발생 검증 불가, 실제 운영에서 차후 관찰"로 보고.

```bash
# 현재 my_bids_local.json에 있는 (model, size) 조합 확인
python3 -c "
import json
mb = json.load(open('my_bids_local.json'))
print(f'활성 입찰 수: {len(mb) if isinstance(mb, list) else \"unknown\"}')"
```

활성 입찰 1건 이상 있으면, 그 모델+사이즈로 가짜 sale_records 만들어 호출 → `skipped_margin_low` (자기 입찰 제외 사유)로 빠지는지 확인. 활성 입찰 없으면 시나리오 스킵.

### 시나리오 5: 격리 검증 — 함수가 예외 던져도 _run_sales_sync 영향 없음
```bash
# 5-1. _run_sales_sync 직접 호출
curl -X POST http://localhost:5001/api/sales/sync | python3 -m json.tool
# → ok=true, new_count=0 (또는 N), 어떤 경우에도 ok=true

# 5-2. /api/health 정상
curl -s http://localhost:5001/api/health | python3 -m json.tool
# → status=healthy, schedulers 3개 running
```

---

## 5. 활성화 합격 기준

| # | 기준 | 통과 조건 |
|---|---|---|
| 1 | 임시키 패치 | grep으로 모든 _rebid 패턴이 timestamp 포함 |
| 2 | py_compile | kream_server.py 통과 |
| 3 | 시나리오 1 | 두 번째 INSERT 성공 (UNIQUE 충돌 없음) |
| 4 | 시나리오 2 | OFF 상태 skipped_disabled 정상 |
| 5 | 시나리오 3-A | bid_cost 없음 → skipped_no_cost, log 기록 |
| 6 | 시나리오 3-B | 빈 입력 정상 처리 |
| 7 | 시나리오 3 후 복원 | auto_rebid_enabled=False 복원 + FAKE 로그 정리 |
| 8 | 시나리오 4 | (활성 입찰 있을 때) 자기 입찰 제외 정상 / 없으면 보고에 명시 |
| 9 | 시나리오 5 | 판매 수집 ok=true 유지 |
| 10 | /api/health | status=healthy + schedulers 3개 running |

**모두 ✅ → §6 활성화 가능**
**1개라도 ❌ → §7 롤백**

---

## 6. 활성화

### 6.1 settings.json 변경
```bash
python3 -c "
import json
s = json.load(open('settings.json'))
s['auto_rebid_enabled'] = True
json.dump(s, open('settings.json','w'), ensure_ascii=False, indent=2)
print('auto_rebid_enabled =', s['auto_rebid_enabled'])
"
```

### 6.2 서버 재시작
```bash
lsof -ti:5001 | xargs kill -9 2>/dev/null
sleep 1
nohup python3 kream_server.py > server.log 2>&1 &
disown
sleep 3
curl -s http://localhost:5001/api/health | python3 -m json.tool
# → status=healthy, schedulers 3개 running 유지
```

### 6.3 /api/auto-rebid/status 확인
```bash
curl -s http://localhost:5001/api/auto-rebid/status | python3 -m json.tool
# → enabled=true, today_success/skipped/failed 카운트
```

---

## 7. 롤백 시나리오

### 7.1 빠른 롤백 (settings 토글만)
```bash
python3 -c "
import json
s = json.load(open('settings.json'))
s['auto_rebid_enabled'] = False
json.dump(s, open('settings.json','w'), ensure_ascii=False, indent=2)
"
# 서버 재시작 안 해도 다음 _run_sales_sync 사이클부터 OFF 적용 (settings 매번 read)
```

### 7.2 코드 롤백 (임시키 패치 문제 시)
```bash
cp kream_server.py.step13_pre.bak kream_server.py
lsof -ti:5001 | xargs kill -9 2>/dev/null
sleep 1
nohup python3 kream_server.py > server.log 2>&1 &
disown
```

### 7.3 DB 롤백 (데이터 손상 시 — 사용자 명시적 승인 필요)
```bash
# Claude Code 임의 실행 금지
cp price_history_backup_step13_pre.db price_history.db
```

---

## 8. 자동 롤백 트리거 (활성화 후 24시간 모니터링)

다음 신호 중 하나라도 발생 시 즉시 §7.1 실행:
- `auto_rebid_log`의 `rebid_failed` 비율이 1시간 내 30% 초과
- `_log_auto_rebid` 호출 자체가 1시간에 100건 초과 (루프 가드 무력화 의심)
- 판매 수집 `ok=false` 발생
- /api/health에 schedulers 중 하나라도 stopped/error
- alert_history.json에 `auto_rebid_loop_guard` 또는 `auto_rebid_price_shift` 알림 24시간 내 5건 이상

---

## 9. 절대 규칙

- ⚠️ §4 시뮬레이션 5종 모두 통과 전 §6 활성화 금지
- ⚠️ 시나리오 3 후 settings 복원 + FAKE 로그 정리 필수
- ⚠️ 사무실 iMac 부팅 금지 (DB 충돌 방지)
- ⚠️ kream_bot.py / kream_hubnet_bot.py / size_converter.py 무수정
- ⚠️ DB 스키마 변경 금지
- ⚠️ DB 복원은 사용자 승인 후에만
- ⚠️ git push -f, git reset --hard 금지

---

## 10. 합격 후 후속 작업

1. **24시간 모니터링** (다음날 새벽 점검):
   ```bash
   curl -s http://localhost:5001/api/auto-rebid/status | python3 -m json.tool
   sqlite3 price_history.db "SELECT action, COUNT(*) FROM auto_rebid_log WHERE date(executed_at)=date('now') GROUP BY action"
   tail -200 server.log | grep -i auto_rebid
   ```
2. **48시간 후**: 첫 실제 재입찰 케이스 발생 여부 확인. 발생했으면 결과 리뷰
3. **1주일 후**: 누적 통계로 정책 조정 여부 판단

---

## 11. 보고 형식

```markdown
## Step 13 자동 재입찰 활성화 보고

### 1) 변경 파일 + 라인 번호
- kream_server.py: 임시키 패치 N라인 (모든 _rebid occurrence)
- settings.json: auto_rebid_enabled true (활성화 합격 후)

### 2) 시뮬레이션 5종 결과
| # | 시나리오 | 결과 | 핵심 발견 |
|---|---|---|---|
| 1 | 임시키 패치 | ✅/❌ | UNIQUE 충돌 회피 |
| 2 | OFF 상태 | ✅/❌ | skipped_disabled |
| 3-A | bid_cost 없음 | ✅/❌ | skipped_no_cost + log |
| 3-B | 빈 입력 | ✅/❌ | 예외 없음 |
| 4 | 자기 입찰 제외 | ✅/❌/N/A | (활성 입찰 있을 시) |
| 5 | 격리 검증 | ✅/❌ | ok=true 유지 |

### 3) 합격 기준 10개
| # | 기준 | 결과 |
|---|---|---|
| ... | ... | ✅/❌ |

### 4) 활성화
- auto_rebid_enabled: true (시각: HH:MM)
- /api/auto-rebid/status: enabled=true 확인
- /api/health: healthy

### 5) 롤백 가능 상태 확인
- 백업 파일: kream_server.py.step13_pre.bak, price_history_backup_step13_pre.db
- 토글 OFF 명령 검증 완료

### 6) git diff --stat
...

### 7) 24시간 모니터링 명령 안내
...
```

---

## 12. 부록 A — 명세 외 보강 후보 (Claude Code 판단)

다음 항목은 명세에 없지만 추가 시 안전성 향상. 진행 여부는 Claude Code가 판단:

- **dry-run 모드 추가**: settings에 `auto_rebid_dry_run` 플래그 추가. true면 실제 입찰 박지 않고 의사결정만 로그. 첫 며칠 dry-run으로 운영 후 false로 전환하는 점진적 방식
- **임시키에 sale_price 추가**: `_rebid_{ts}_{sold_price}` → 같은 시각 다중 재입찰 구분 강화. ts(초)만으로도 충분하지만 가독성 추가
- **활성화 후 첫 1시간 알림 강화**: `auto_rebid_first_run` 알림 1회 발송 → 사용자가 활성화 직후 모니터링 시작 알림

특히 **dry-run 모드는 매우 권장**. 첫 실제 케이스가 어떻게 동작하는지 위험 없이 관찰 가능. 채택 시 명세 외 항목으로 명시하고 보고에 포함.

---

## 13. 다음 단계

Step 13 완료 + 1~3일 안정성 확인 후:
- Step 14: 자동 가격 조정 활성화 검토 (현재 pending 7건 모두 원가 보유 → 켜도 안전 가능성)
- Step 15+: 识货 임포트 (Step 12 인프라 재사용)
