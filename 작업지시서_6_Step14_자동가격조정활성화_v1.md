# 작업지시서 — Step 14: 자동 가격 조정 활성화

작성일: 2026-04-30 23:05
대상 시스템: KREAM 자동화 (`~/Desktop/kream_automation/`)
운영 머신: 맥북 (한국, 사무실 iMac OFF 상태)
관련 문서:
- `KREAM_허브넷통합_인수인계_v5.md` §9 (언더컷 자동 방어 시스템)
- `auto_execute_approvals()` 정의: kream_server.py:6698
- `_run_monitor_check()` 정의: kream_server.py:4477
예상 소요: 60~90분
다음 단계: Step 15 (识货 임포트) — 별도 세션 권장

---

## 0. 작업 목적

기존 코드는 박혀 있고 6중 안전장치(no_cost, profit_low, cooldown, daily_limit, failure_rate, stale_data) 모두 구현된 상태에서, `settings.auto_adjust_enabled=false`로 OFF 상태인 자동 가격 조정 시스템을 활성화한다.

**Step 13(자동 재입찰)과의 차이**:
- Step 13: 임시키 충돌 패치 + dry-run 옵션 추가 = 코드 수정 필요
- Step 14: 코드 수정 없음. **settings 1줄 + force 실행 검증 후 enable**

---

## 1. 핵심 원칙 — 절대 위반 금지

### 1.1 force 실행 ≠ dry-run
`auto_execute_approvals(force=True)`는 **실제로 KREAM에 가격 수정을 박습니다.** dry-run 아님.
- force 실행 결과를 검토 단계로 활용하지만, 그 자체가 운영 환경에 가격 변경
- 마진 4000원 하한 통과 + 모든 안전장치 통과한 건만 실행되므로 안전하지만, **실제 입찰 가격이 변함**

### 1.2 첫 force 실행 직전 상태 보존
- pending 7건 데이터를 force 실행 전에 캡처
- 실행 후 변경된 행을 추적 가능하도록

### 1.3 자기보호 메커니즘 신뢰
실패율 1시간 내 20% 초과 시 자동 OFF + 알림이 코드에 박혀 있음. 이 메커니즘이 안전망.

### 1.4 사무실 iMac OFF 상태 유지
DB 충돌 방지.

### 1.5 Step 13 자동 재입찰과 독립
자동 재입찰은 dry-run 모드로 운영 중 (auto_rebid_dry_run=true). Step 14 활성화는 자동 재입찰에 영향 주지 않음.

---

## 2. 변경 사항 — settings.json 1줄

```json
"auto_adjust_enabled": true
```

코드 변경 **없음**. 검증 후 마지막 단계에서만 변경.

---

## 3. 사전 안전 조치

```bash
cd ~/Desktop/kream_automation

# DB 백업
sqlite3 /Users/iseungju/Desktop/kream_automation/price_history.db \
  ".backup '/Users/iseungju/Desktop/kream_automation/price_history_backup_step14_pre.db'"

# settings 백업
cp settings.json settings.json.step14_pre.bak

# 현재 auto_adjust_enabled 값 (False여야 정상 출발선)
python3 -c "import json; print('auto_adjust_enabled =', json.load(open('settings.json')).get('auto_adjust_enabled'))"

# pending 7건 상태 캡처 (실행 전 스냅샷)
sqlite3 price_history.db "
  SELECT pa.id, pa.order_id, pa.model, pa.size, pa.old_price, pa.new_price,
         pa.expected_profit, pa.status, pa.created_at
  FROM price_adjustments pa
  WHERE pa.status IN ('pending','profit_low','deficit')
  ORDER BY pa.id
" > /tmp/pending_before_step14.txt
cat /tmp/pending_before_step14.txt

# 자동 가격 조정 통계 (실행 전)
curl -s http://localhost:5001/api/auto-adjust/status | python3 -m json.tool
```

---

## 4. 검증 시나리오 4종 — 활성화 전 필수

### 시나리오 1: failure_rate_1h 자동 OFF 메커니즘 확인
실제로 트리거하지 않고, 함수 정의를 코드 검토만.

```bash
# auto_execute_approvals 함수 안의 failure_rate 자동 OFF 분기 확인
sed -n '6713,6735p' kream_server.py
# → "if failure_rate > 0.2:" 블록 존재 확인
```

기대: failure_rate > 20% → settings.auto_adjust_enabled=False 자동 변경 + alerter 호출 코드 확인.

### 시나리오 2: force 실행 — pending 건 처리 시뮬레이션 ⭐ 가장 중요

⚠️ **이 시나리오는 실제 KREAM 가격 수정이 일어납니다.**

```bash
# enabled=false 상태에서 force=true로 1회 실행
curl -X POST http://localhost:5001/api/auto-adjust/run-once \
  -H "Content-Type: application/json" \
  -d '{}' | python3 -m json.tool
# → modified, skipped, failed, details 반환
```

⚠️ **만약 modified ≥ 1**이면, 실제 KREAM 입찰가가 변경됐다는 뜻. 결과 즉시 검토:
```bash
# modify 결과 확인
sqlite3 price_history.db "
  SELECT id, model, size, old_price, new_price, action, modify_result, executed_at
  FROM auto_adjust_log
  WHERE date(executed_at) = date('now')
  ORDER BY id DESC LIMIT 10
"

# pending 상태 변화
sqlite3 price_history.db "
  SELECT pa.id, pa.model, pa.size, pa.old_price, pa.new_price, pa.status
  FROM price_adjustments pa
  WHERE pa.status IN ('pending','profit_low','deficit','executed','failed')
    AND pa.id IN (189, 190, 191, 192, 193, 194, 196)
  ORDER BY pa.id
"
```

기대 결과 분류:
- **A) 정상 케이스**: modified=N, failed=0 — 6중 안전장치 통과 후 modify 성공
- **B) 실패 케이스**: failed≥1, action='modify_failed' + modify_result='playwright_error' (과거와 동일 패턴)
- **C) 스킵 케이스**: skipped.* 카운트 증가 (cooldown/profit_low/stale_data 등)

(A)면 활성화 가능. (B)면 §6 롤백 + Step 14.5(playwright_error 원인 진단) 별도 작업.

### 시나리오 3: 격리 검증 — 함수 실패해도 다른 스케줄러 영향 없음
```bash
# /api/health 정상
curl -s http://localhost:5001/api/health | python3 -m json.tool
# → status=healthy, schedulers 3개(backup/monitor/sales) 모두 running

# 판매 수집 별도 트리거
curl -X POST http://localhost:5001/api/sales/sync | python3 -m json.tool
# → ok=true (Step 13 dry-run도 정상 작동해야 함)
```

### 시나리오 4: settings 토글 동작
```bash
# enabled=true로 변경
python3 -c "
import json
s = json.load(open('settings.json'))
s['auto_adjust_enabled'] = True
json.dump(s, open('settings.json','w'), ensure_ascii=False, indent=2)
print('auto_adjust_enabled =', s['auto_adjust_enabled'])
"

# /api/auto-adjust/status 변화 확인
curl -s http://localhost:5001/api/auto-adjust/status | python3 -m json.tool
# → enabled=true

# 즉시 false로 다시 토글
python3 -c "
import json
s = json.load(open('settings.json'))
s['auto_adjust_enabled'] = False
json.dump(s, open('settings.json','w'), ensure_ascii=False, indent=2)
"

# /api/auto-adjust/status 다시 확인
curl -s http://localhost:5001/api/auto-adjust/status | python3 -m json.tool
# → enabled=false
```

기대: 토글 결과가 즉시 반영 (settings 매번 read).

---

## 5. 활성화 합격 기준

| # | 기준 | 통과 조건 |
|---|---|---|
| 1 | 시나리오 1 | failure_rate 자동 OFF 코드 확인 |
| 2 | 시나리오 2 | modified ≥ 1 + failed = 0 (정상 케이스 A) |
| 3 | 시나리오 2 보조 | failed > 0이면 결과 분석 후 진행 여부 결정 |
| 4 | 시나리오 3 | /api/health healthy, schedulers 3개 running |
| 5 | 시나리오 3 보조 | /api/sales/sync ok=true |
| 6 | 시나리오 4 | settings 토글 즉시 반영 |
| 7 | auto_adjust_log 정합성 | 새 행 → modify_result 기록됨 |

**기준 1·4·5·6·7 모두 ✅ + 기준 2가 정상(A) → §6 활성화**
**기준 2가 (B) 또는 (C) → 사용자에게 보고 후 결정**

---

## 6. 활성화

### 6.1 settings.json 변경
```bash
python3 -c "
import json
s = json.load(open('settings.json'))
s['auto_adjust_enabled'] = True
json.dump(s, open('settings.json','w'), ensure_ascii=False, indent=2)
print('auto_adjust_enabled =', s['auto_adjust_enabled'])
"
```

### 6.2 서버 재시작 (선택)
settings 매번 read이므로 재시작 불필요. 다만 깔끔하게 가려면:
```bash
lsof -ti:5001 | xargs kill -9 2>/dev/null
sleep 1
nohup python3 kream_server.py > server.log 2>&1 &
disown
sleep 3
curl -s http://localhost:5001/api/health | python3 -m json.tool
```

### 6.3 활성화 확인
```bash
curl -s http://localhost:5001/api/auto-adjust/status | python3 -m json.tool
# → enabled=true, daily_max=10, min_profit=4000

curl -s http://localhost:5001/api/health | python3 -m json.tool
# → status=healthy, schedulers 3개 running
```

---

## 7. 롤백 시나리오

### 7.1 빠른 롤백 (settings 토글)
```bash
python3 -c "
import json
s = json.load(open('settings.json'))
s['auto_adjust_enabled'] = False
json.dump(s, open('settings.json','w'), ensure_ascii=False, indent=2)
"
# settings 매번 read이므로 즉시 반영. 다음 모니터링 사이클부터 OFF.
```

### 7.2 settings 복원 (백업본)
```bash
cp settings.json.step14_pre.bak settings.json
lsof -ti:5001 | xargs kill -9 2>/dev/null
sleep 1
nohup python3 kream_server.py > server.log 2>&1 &
disown
```

### 7.3 DB 롤백 (사용자 명시적 승인 필요)
```bash
# Claude Code 임의 실행 금지
cp price_history_backup_step14_pre.db price_history.db
```

### 7.4 가격 수정 자체를 되돌려야 할 경우
**복잡. 사용자 결정.** auto_adjust_log를 보고 modified된 건의 old_price를 KREAM에 다시 박아야 함. Step 14 범위 밖.

---

## 8. 자동 롤백 트리거 (활성화 후 24시간 모니터링)

다음 신호 중 하나라도 발생 시 즉시 §7.1 실행:
- `auto_adjust_log`의 `modify_failed` 비율이 1시간 내 30% 초과 (자동 OFF 메커니즘이 잡지만, 사용자가 더 빠르게 대응)
- alert_history.json에 `auto_adjust_disabled` 알림 발생 (failure_rate_exceeded 자동 OFF)
- /api/health에 schedulers 중 하나라도 stopped/error
- 모니터링 스케줄러 사이클 + auto_execute_approvals 호출에서 traceback 발생
- 24시간 내 modified 카운트가 비정상적으로 많음 (예: pending 7건 환경에서 100건 modified)

---

## 9. 절대 규칙

- ⚠️ §4 시나리오 1·3·4·6 모두 통과 전 §6 활성화 금지
- ⚠️ 시나리오 2의 (B) 케이스(modify_failed) 발생 시 사용자 보고 + 결정
- ⚠️ 사무실 iMac 부팅 금지
- ⚠️ kream_server.py / kream_bot.py / kream_adjuster.py 무수정
- ⚠️ DB 스키마 변경 금지
- ⚠️ DB 복원은 사용자 승인 후에만
- ⚠️ Step 13 자동 재입찰 dry-run 설정에 영향 주지 마

---

## 10. 합격 후 후속 작업

1. **24시간 모니터링** (다음날 새벽):
   ```bash
   curl -s http://localhost:5001/api/auto-adjust/status | python3 -m json.tool
   sqlite3 price_history.db "
     SELECT action, COUNT(*) FROM auto_adjust_log
     WHERE date(executed_at)=date('now')
     GROUP BY action
   "
   tail -200 server.log | grep -iE "auto_adjust|언더컷"
   ```
2. **48시간 후**: 모니터링 사이클별 (8,10,12,14,16,18,20,22시) 동작 패턴 확인
3. **1주일 후**: modify_failed 누적 비율 확인. playwright_error 패턴 반복되면 Step 14.5 필요

---

## 11. 보고 형식

```markdown
## Step 14 자동 가격 조정 활성화 보고

### 1) 사전 상태
- pending 건 수: 7
- 모든 pending 원가 보유 여부: ✅
- 활성화 전 auto_adjust_log 통계: modified=1, modify_failed=2, skipped=41

### 2) 시나리오 4종 결과
| # | 시나리오 | 결과 | 핵심 발견 |
|---|---|---|---|
| 1 | failure_rate 자동 OFF 코드 확인 | ✅/❌ | - |
| 2 | force 실행 (pending 처리) | ✅/⚠️/❌ | modified=N, failed=N, skipped=N |
| 3 | 격리 검증 | ✅/❌ | health, schedulers |
| 4 | settings 토글 즉시 반영 | ✅/❌ | - |

### 3) 시나리오 2 상세 (force 실행 결과)
- modified: N건 (실제 KREAM 가격 수정됨)
- failed: N건 (modify_failed + modify_result 사유)
- skipped: {no_cost, profit_low, cooldown, daily_limit, failure_rate, stale_data}
- pending 상태 변화: 7건 중 N건 executed/failed로 전환

### 4) 합격 기준 7개
| # | 기준 | 결과 |
|---|---|---|
| ... | ... | ✅/❌ |

### 5) 활성화
- auto_adjust_enabled: true (시각: HH:MM)
- /api/auto-adjust/status: enabled=true 확인
- /api/health: healthy

### 6) 백업 파일 보존
- settings.json.step14_pre.bak ✅
- price_history_backup_step14_pre.db ✅

### 7) git diff
- (코드 변경 없음 → settings.json만 변경, .gitignore 제외)

### 8) 다음 모니터링
- 24시간 후 점검 명령 안내
```

---

## 12. 다음 단계

Step 14 완료 + 며칠 안정성 확인 후:
- Step 15+ (识货 임포트): 별도 세션 권장
- Step 14.5 (playwright_error 원인 진단): 필요 시 별도 작업
- Step 11 (허브넷 활성화): 다운로드 대상 누적 + 트리거 누적 후

---

## 13. 부록 — 명세 외 보강 후보 (Claude Code 판단)

다음 항목은 명세에 없지만 추가 시 안전성 향상. 진행 여부는 Claude Code가 판단:

- **dry-run 옵션 추가**: settings.json에 `auto_adjust_dry_run` 키 추가 + 함수 내 분기.
  Step 13과 동일 패턴. 다만 자동 가격 조정은 이미 6중 안전장치가 강력하고 force 옵션이 시뮬 역할 수행 가능하므로 **미채택 권장**.
- **활성화 직후 첫 1시간 알림 강화**: `auto_adjust_first_run` 알림 1회 발송. 채택 시 명세 외로 명시.
- **modify_failed 패턴 분석 자동화**: 24시간마다 modify_result 그룹화하여 알림. **별도 Step 권장**.

판단 기준: 코드 추가 최소화. 자동 가격 조정은 이미 풀스택 함수라 추가 보강 거의 필요 없음.
