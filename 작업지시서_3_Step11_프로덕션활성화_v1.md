# 작업지시서 — Step 11: 허브넷 PDF 자동 다운로드 프로덕션 활성화

작성일: 2026-04-30
대상 시스템: KREAM 자동화 (`~/Desktop/kream_automation/`)
선행 작업: Step 10 완료 (커밋 `9a6fbf4`, 2026-04-30)
관련 문서:
- `작업지시서_2_Step10_스케줄러통합_v1.md` §8 (다음 단계 명시)
- `KREAM_허브넷통합_인수인계_v5.md`
예상 소요: 30분 (활성화 자체는 1분, 1사이클 관찰이 핵심)
다음 단계: Step 12 (사이즈 변환 시스템) — 별도 작업, 병렬 진행 가능

---

## 0. 작업 목적

Step 10에서 만든 자동 트리거를 실제 운영 환경에서 켠다.
`settings.json`의 `hubnet_auto_pdf=false` → `true`로 전환하고,
**1사이클(약 30분 + 5분 지터) 동안 실제 PDF 다운로드 경로가 정상 동작하는지 검증**한다.

Step 10 검증은 다운로드 대상 0건 환경에서 수행됐기 때문에 트리거 호출까지만 검증된 상태.
Step 11에서 실제 PDF 다운로드 경로(매칭, 다운로드, sales_history 갱신)를 라이브로 검증한다.

---

## 1. 핵심 원칙 — 절대 위반 금지

### 1.1 사용자 결정 단계 ⭐
- Claude Code 임의 활성화 **금지**
- 본 지시서 §3의 사전 조건 모두 통과해야만 §4 활성화 단계 진입
- 사전 조건 미통과 시 **즉시 중단하고 사용자에게 보고**

### 1.2 예비 라이브 검증 필수
- 다운로드 대상이 실제로 누적된 시점에 **1사이클만 켜서** 진짜 PDF 다운로드 경로를 검증
- 1사이클 ≈ 30분 + 5분 지터. 그 시간 안에 결과 안 나오면 추가 1사이클까지만 대기

### 1.3 즉시 롤백 가능 상태 유지
- 활성화 후에도 토글 OFF로 즉시 무력화 가능 (코드 변경 없음)
- 4종 안전장치(외부 try, lock, alerter, 결과 인쇄)는 살아있어야 함

### 1.4 격리 원칙 재확인
- Step 10에서 입증된 "허브넷 실패가 판매 수집을 망가뜨리지 않음"을 라이브 환경에서도 재확인
- 활성화 중 단 한 번이라도 판매 수집 `ok=false` 발생 시 즉시 롤백

---

## 2. 변경 위치 — settings.json 1줄

```json
"hubnet_auto_pdf": true
```

코드 변경 **없음**. `/api/hubnet/auto-toggle` API 또는 직접 편집으로 변경 가능.

---

## 3. 사전 조건 (모두 통과해야 §4 진입)

```bash
cd ~/Desktop/kream_automation

# [조건 1] 다운로드 대상 ≥ 1건
sqlite3 price_history.db \
  "SELECT COUNT(*) FROM sales_history WHERE hbl_number IS NOT NULL AND pdf_path IS NULL"
# → 1 이상이어야 함. 0이면 중단 (관찰할 게 없음)

# [조건 2] Step 10 트리거 누적 정상
grep -c "\[HUBNET_AUTO\]" server.log
# → 14 이상 권장 (30분 × 2회/시간 × 7일 ≈ 336이론치, 14는 7일 × 2회 최소선)

# [조건 3] alert_history에 hubnet 관련 critical/error 0건
grep -iE "hubnet.*critical|hubnet.*error|hubnet_pdf_trigger_error" alert_history.json | wc -l
# → 0이어야 함. 1 이상이면 원인 파악 후 진입

# [조건 4] /api/health 정상
curl -s http://localhost:5001/api/health | python3 -m json.tool
# → status=healthy, schedulers 3개(backup, monitor, sales) 모두 running

# [조건 5] hubnet 봇 단독 동작 확인 (수동 다운로드 테스트)
curl -s -X POST http://localhost:5001/api/hubnet/download-now | python3 -m json.tool
# → success/failed 카운트가 정상 dict로 반환 (오류 응답 아니어야 함)

# [조건 6] auth_state_hubnet.json 신선도
ls -la auth_state_hubnet.json
# → 24시간 이내 갱신된 상태 권장. 그 이상이면 hubnet 수동 로그인 후 진입
```

**6개 조건 결과를 표로 정리해서 보고. 1개라도 ❌면 §4 금지.**

---

## 4. 활성화 절차

### 4.1 사전 백업

```bash
cd ~/Desktop/kream_automation

cp settings.json settings.json.step11_pre.bak

sqlite3 /Users/iseungju/Desktop/kream_automation/price_history.db \
  ".backup '/Users/iseungju/Desktop/kream_automation/price_history_backup_step11_pre.db'"

ls -la settings.json.step11_pre.bak price_history_backup_step11_pre.db
```

### 4.2 토글 ON

```bash
curl -X POST http://localhost:5001/api/hubnet/auto-toggle \
  -H "Content-Type: application/json" \
  -d '{"enabled":true}' | python3 -m json.tool
# → {"ok":true, "enabled":true, "previous":false}

# settings.json 반영 확인
python3 -c "import json; print('hubnet_auto_pdf =', json.load(open('settings.json')).get('hubnet_auto_pdf'))"
# → True
```

### 4.3 다음 판매 수집 시각 확인 + 1사이클 대기

```bash
curl -s http://localhost:5001/api/sales/scheduler/status | python3 -m json.tool
# → next_run 시각 확인. 그 시각 + 5분(지터) + 60초(다운로드 여유)까지 대기.

# 활성화 시각 + 35분 후 (보수적)
sleep 2100   # 35분
```

### 4.4 결과 관찰

```bash
# 트리거 출력
tail -200 server.log | grep -iE "HUBNET_AUTO|판매수집"

# scheduler 트리거된 새 행 + status 분포
sqlite3 price_history.db \
  "SELECT triggered_by, status, COUNT(*) FROM hubnet_pdf_log
   WHERE created_at > datetime('now','-1 hour')
   GROUP BY triggered_by, status"

# pdf_path 갱신 확인 (양방향 정합성)
sqlite3 price_history.db \
  "SELECT order_id, hbl_number,
   CASE WHEN pdf_path IS NULL THEN '미갱신' ELSE '갱신됨' END AS pdf_status
   FROM sales_history
   WHERE hbl_number IS NOT NULL
     AND pdf_downloaded_at > datetime('now','-1 hour')
   LIMIT 20"

# 격리 재확인
curl -s http://localhost:5001/api/health | python3 -m json.tool
```

---

## 5. 활성화 합격 기준

| # | 기준 | 통과 조건 |
|---|---|---|
| 1 | server.log 트리거 출력 | `[HUBNET_AUTO]` 새 라인, `total >= 1` |
| 2 | hubnet_pdf_log | `triggered_by='scheduler'` 새 행 ≥ 1 |
| 3 | status 분포 | `success` 또는 `skipped` 비율 ≥ 70% |
| 4 | pdf_path 갱신 | `success` 행에 `pdf_path` NOT NULL (양방향 정합성) |
| 5 | /api/health | `status=healthy` 유지 |
| 6 | schedulers | 3개 모두 `running` 유지 |
| 7 | 판매 수집 ok | `true` 유지 (격리 원칙 재확인) |

**기준 중 1개라도 ❌ → §6 즉시 롤백.**

---

## 6. 롤백 시나리오

### 6.1 빠른 롤백 (코드 변경 없음, 토글만 OFF)

```bash
curl -X POST http://localhost:5001/api/hubnet/auto-toggle \
  -H "Content-Type: application/json" \
  -d '{"enabled":false}'

# 확인
python3 -c "import json; print('hubnet_auto_pdf =', json.load(open('settings.json')).get('hubnet_auto_pdf'))"
# → False
```

### 6.2 settings 복원 (토글이 안 통할 때)

```bash
cp settings.json.step11_pre.bak settings.json
lsof -ti:5001 | xargs kill -9 2>/dev/null
sleep 1
nohup python3 kream_server.py > server.log 2>&1 &
disown
sleep 3
curl -s http://localhost:5001/api/health | python3 -m json.tool
```

### 6.3 DB 복원 (양방향 정합성 깨졌을 때만)

```bash
# ⚠️ 사용자 명시적 승인 후에만 실행
cp price_history_backup_step11_pre.db price_history.db
# Claude Code는 이 명령을 **임의로 실행 금지**
```

---

## 7. 자동 롤백 트리거 (다음 신호 발생 시 즉시 6.1 실행)

- `[HUBNET_AUTO_ERROR]` 라인이 1사이클 내 3건 이상
- alert_history.json에 hubnet 관련 alert 1사이클 내 5건 이상
- /api/health에 schedulers 중 하나라도 `stopped`/`error`
- 판매 수집 `ok=false` 발생
- sales_history.pdf_path 갱신 누락 발견 (success 보고됐는데 NULL)

위 신호 중 하나라도 감지되면 **즉시** §6.1 실행 후 사용자에게 보고.

---

## 8. 절대 규칙

- ⚠️ §3 사전 조건 미통과 시 §4 진입 금지
- ⚠️ 1사이클 관찰 없이 "잘 돌아간다" 단정 금지
- ⚠️ 격리 원칙 위반 시 즉시 롤백
- ⚠️ 코드 수정 금지 (settings.json만 변경)
- ⚠️ 활성화 후에도 백업본은 1주일 보존
- ⚠️ DB 복원은 사용자 승인 후에만

---

## 9. 합격 후 후속 작업

1. **1주일 모니터링**:
   - 매일 1회 `tail server.log | grep HUBNET_AUTO` 점검
   - `[HUBNET_AUTO_ERROR]` 누적이 0건 유지되는지 확인
2. **pdf_path 정합성 주간 검증**:
   ```bash
   sqlite3 price_history.db "
     SELECT COUNT(*) FROM sales_history
     WHERE hbl_number IS NOT NULL
       AND pdf_path IS NULL
       AND id IN (SELECT id FROM sales_history WHERE id <= (SELECT MAX(id)-100 FROM sales_history))"
   # 7일 이상 누적된 미다운로드 잔여물 확인. 0이 이상적.
   ```
3. **문제 없으면**: Step 12 (사이즈 변환 시스템) 진행

---

## 10. 보고 형식

```markdown
## Step 11 활성화 보고

### 사전 조건 점검
| # | 조건 | 결과 | 값 |
|---|---|---|---|
| 1 | 다운로드 대상 ≥ 1건 | ✅/❌ | N건 |
| 2 | Step 10 트리거 누적 ≥ 14 | ✅/❌ | N회 |
| 3 | hubnet critical/error 0건 | ✅/❌ | N건 |
| 4 | /api/health healthy | ✅/❌ | - |
| 5 | hubnet 단독 동작 | ✅/❌ | success=N, failed=N |
| 6 | auth_state_hubnet 신선도 | ✅/❌ | N시간 전 |

### 활성화
- 시각: YYYY-MM-DD HH:MM
- 토글 응답: {"enabled":true, "previous":false}

### 1사이클 결과
- next_run: HH:MM
- 대기 시간: N분
- 트리거 결과: total=N, success=N, failed=N, skipped=N

### 합격 기준 점검
| # | 기준 | 결과 |
|---|---|---|
| 1 | [HUBNET_AUTO] 라인 | ✅/❌ |
| 2 | scheduler 새 행 | ✅/❌ |
| 3 | success/skipped ≥ 70% | ✅/❌ |
| 4 | pdf_path 갱신 | ✅/❌ |
| 5 | /api/health healthy | ✅/❌ |
| 6 | schedulers 3개 running | ✅/❌ |
| 7 | 판매 수집 ok=true | ✅/❌ |

### 결론
- 활성화 유지 / 롤백 (둘 중 하나)
- 사유: ...
```

---

## 11. 다음 단계

- 1주일 안정성 확인 후 → Step 12 (사이즈 변환 시스템)
- 또는 Step 12를 병렬로 시작 (별도 영역이라 충돌 없음)

