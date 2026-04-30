# 작업지시서 — Step 10: 스케줄러 통합 (판매 수집 직후 허브넷 PDF 자동 다운로드)

작성일: 2026-04-30 (Step 9 + 운영 안정화 완료 직후)
대상 시스템: KREAM 자동화 (`~/Desktop/kream_automation/`)
관련 문서:
- `작업지시서_1_허브넷봇_PDF자동다운로드_v1.md` §4.2, §검증 시나리오 4종
- `KREAM_허브넷통합_인수인계_v5.md` (Step 9 + 운영안정화 완료 반영)
예상 소요: 30~60분 (작업 자체는 짧지만 검증이 핵심)
다음 단계: Step 11 프로덕션 활성화 (며칠 안정성 검증 후 hubnet_auto_pdf=true)

## 0. 작업 목적

Step 7~9까지 만든 허브넷 PDF 다운로드 기능을 **판매 수집 스케줄러와 자동 연결**한다.
판매 수집(30분 ±5분 지터) 완료 직후, 새로 매칭된 sales_history에 대해 자동으로 PDF 다운로드를 트리거.

## 1. 핵심 원칙 — 절대 위반 금지

### 1.1 격리 원칙 ⭐ (가장 중요)
허브넷 PDF 다운로드 실패가 **판매 수집 자체를 절대 망가뜨려서는 안 됨**.
- 모든 호출은 try/except로 감쌈
- 허브넷 실패 시 health_alerter.alert로 알림만 (판매 수집은 정상 완료 처리)
- 판매 수집 결과는 어떤 경우에도 보존

### 1.2 기본값 false
- settings.json의 `hubnet_auto_pdf`는 현재 `false` (Step 1에서 설정)
- 이번 작업에서도 **기본값 false 유지**. 자동 활성화 안 함
- Step 11에서 며칠 안정성 검증 후 수동으로 true 변경

### 1.3 새 코드 추가 안 함
- kream_hubnet_bot.py: 손대지 마. Step 7까지 완성된 download_pending_invoices()를 호출만 함
- 이번 작업은 **trigger 추가**가 전부. 새 다운로드 로직 만들지 마.

### 1.4 검증 시나리오 4종 모두 통과 필수
작업지시서 1번 §7.2의 4가지 시나리오:
- 시나리오 1: 정상 플로우 (판매 수집 → 자동 PDF 다운로드)
- 시나리오 2: 매칭 실패 케이스 (허브넷에 없는 KREAM 주문)
- 시나리오 3: 세션 만료 복구
- 시나리오 4: 격리 검증 (허브넷 차단 시 판매 수집 정상 완료)

## 2. 변경 위치 — 한 군데

### kream_server.py — `_run_sales_collection()` 함수 끝에 추가

기존 판매 수집 함수의 마지막에 트리거 추가. 함수 위치는 grep으로 확인:
```bash
grep -n "_run_sales_collection\|def.*sales.*collect" kream_server.py
```

추가 패턴 (작업지시서 1번 §4.2 참고):
```python
# 판매 수집 완료 시점에 추가
try:
    settings = _load_settings()  # 또는 기존 settings 로딩 함수
    if settings.get('hubnet_auto_pdf', False):  # 기본 false
        from kream_hubnet_bot import download_pending_invoices
        result = download_pending_invoices(
            limit=20,  # 한 사이클당 최대 20건
            triggered_by='scheduler'
        )
        if result['failed'] > 0:
            try:
                health_alerter.alert(
                    key='hubnet_pdf_failed',
                    severity='warning',
                    message=f"허브넷 PDF 다운로드 {result['failed']}건 실패"
                )
            except Exception:
                pass  # 알림 실패도 격리
        # 정상/실패 모두 server.log에 기록
        print(f"[HUBNET_AUTO] {result}")
except Exception as e:
    # ⚠️ 절대 raise 금지. 판매 수집은 이미 완료된 상태
    print(f"[HUBNET_AUTO_ERROR] {e}")
    try:
        health_alerter.alert(
            key='hubnet_pdf_trigger_error',
            severity='error',
            message=f"허브넷 자동 PDF 트리거 오류: {e}"
        )
    except Exception:
        pass
```

핵심 포인트:
- **3중 try/except**: 외부 try (전체 격리), download_pending_invoices 결과 분기 내 alert try (알림 실패 격리), trigger 오류 시 alert try (알림 실패 격리)
- limit=20: 한 사이클에 너무 많이 처리하면 다음 판매 수집 시각 영향. 20건이면 약 30~60초 (Step 9에서 평균 1.5초/건 확인됨)
- triggered_by='scheduler': hubnet_pdf_log에 출처 기록되어 나중에 manual과 구분 가능
- print으로 server.log 기록: 정상 실행 추적용

### settings.json — 변경 없음
`hubnet_auto_pdf: false` 그대로 유지. Step 11에서 사용자가 수동으로 true 변경.

## 3. 검증 시나리오 4종 (작업지시서 1번 §7.2)

### 시나리오 1: 정상 플로우
**전제**: hubnet_auto_pdf=true 임시 설정 (테스트 후 false 복원)

```bash
# 1. 임시로 자동 다운로드 활성화
curl -X POST http://localhost:5001/api/hubnet/auto-toggle \
  -H "Content-Type: application/json" -d '{"enabled":true}' | python3 -m json.tool

# 2. 현재 sales_history 상태 백업 (수정 안 됨, 조회만)
sqlite3 price_history.db "SELECT COUNT(*) FROM sales_history WHERE hbl_number IS NOT NULL AND pdf_path IS NULL"

# 3. 판매 수집 수동 실행 (스케줄러 트리거 강제)
curl -X POST http://localhost:5001/api/sales/sync | python3 -m json.tool

# 4. 30초 대기 후 server.log 확인 — [HUBNET_AUTO] 라인 발견되어야 함
sleep 30
tail -50 server.log | grep -i hubnet

# 5. hubnet_pdf_log 확인 — triggered_by='scheduler' 새 행 있어야 함
sqlite3 price_history.db "SELECT * FROM hubnet_pdf_log WHERE triggered_by='scheduler' ORDER BY id DESC LIMIT 5"

# 6. 검증 종료 후 원상 복구
curl -X POST http://localhost:5001/api/hubnet/auto-toggle \
  -H "Content-Type: application/json" -d '{"enabled":false}' | python3 -m json.tool
```

기대 결과:
- server.log에 `[HUBNET_AUTO] {total: ..., success: ..., ...}` 라인 출력
- hubnet_pdf_log에 triggered_by='scheduler' 새 행 추가
- /api/health 정상 (status=healthy 유지)

### 시나리오 2: 매칭 실패 케이스
**전제**: hubnet_auto_pdf=true (시나리오 1과 동일 환경)

매칭 실패는 자연 발생: 허브넷에 없는 KREAM 주문이 sales_history에 있으면 자동으로 발생함. 만약 자연 발생 안 하면 그대로 두고 "현재 데이터에 매칭 실패 케이스 없음"으로 보고하면 됨.

기대 결과:
- 매칭 실패 건은 hubnet_pdf_log에 status='matching_failed'로 기록
- 다른 정상 건은 정상 처리 (1건의 매칭 실패가 batch 전체 멈추지 않음)

### 시나리오 3: 세션 만료 복구
**전제**: hubnet_auto_pdf=true

```bash
# 1. auth_state_hubnet.json 백업
cp auth_state_hubnet.json auth_state_hubnet.json.test_backup

# 2. 세션 파일 일부러 손상 (파일 끝에 garbage 추가 또는 빈 파일로)
echo "{}" > auth_state_hubnet.json

# 3. 판매 수집 트리거
curl -X POST http://localhost:5001/api/sales/sync

# 4. server.log 확인 — ensure_hubnet_logged_in()이 자동 재로그인 시도
sleep 30
tail -100 server.log | grep -i "hubnet\|login"

# 5. auth_state_hubnet.json 새로 갱신됐는지 확인
ls -la auth_state_hubnet.json
# 파일 크기가 의미 있는 값이어야 함 (빈 {} 아니라)

# 6. 원상 복구
mv auth_state_hubnet.json.test_backup auth_state_hubnet.json

# 7. 정리
curl -X POST http://localhost:5001/api/hubnet/auto-toggle \
  -H "Content-Type: application/json" -d '{"enabled":false}'
```

기대 결과:
- 세션 손상 직후에도 download_pending_invoices가 자동 재로그인 후 정상 처리
- server.log에 재로그인 흔적
- 판매 수집은 어떤 경우에도 정상 완료

### 시나리오 4: 격리 검증 ⭐ (가장 중요)
**전제**: 허브넷 측이 응답 안 하는 상황 시뮬

```bash
# 1. settings.json의 hubnet_session_path를 일부러 잘못된 경로로 변경
# 또는 hubnet_email/password를 잘못된 값으로 임시 변경
# 또는 인터넷 연결 끊기 (가장 확실)

# 2. hubnet_auto_pdf=true 설정
curl -X POST http://localhost:5001/api/hubnet/auto-toggle \
  -H "Content-Type: application/json" -d '{"enabled":true}'

# 3. 판매 수집 트리거
curl -X POST http://localhost:5001/api/sales/sync

# 4. 판매 수집 결과 정상 반환 확인 (success=true)
# 응답 JSON에 success가 true여야 함

# 5. server.log 확인 — [HUBNET_AUTO_ERROR] 또는 실패 로그 발견
sleep 30
tail -100 server.log | grep -i "hubnet"

# 6. 다른 스케줄러 정상 동작 확인
curl http://localhost:5001/api/health | python3 -m json.tool
# schedulers: {backup, monitor, sales} 모두 running 유지

# 7. 원상 복구 + 자동 토글 OFF
# settings.json 원래대로
curl -X POST http://localhost:5001/api/hubnet/auto-toggle \
  -H "Content-Type: application/json" -d '{"enabled":false}'
```

기대 결과:
- 판매 수집 자체는 정상 완료 (`success: true`)
- /api/health에 다른 스케줄러 영향 없음
- server.log에 허브넷 실패 알림 (그러나 판매 수집 결과는 정상)
- alert_history.json에 알림 추가 (선택, 알림 시스템 동작 시)

## 4. 변경 안 할 것

- kream_hubnet_bot.py (Step 7까지 완성)
- DB 스키마
- 기존 API 엔드포인트
- price_history.db 백업 불필요 (스키마 변경 없음)
- 기존 _run_sales_collection() 함수의 핵심 로직 (트리거 추가만)

## 5. 보고 형식

각 검증 결과 보고:

| 시나리오 | 결과 | 핵심 발견 |
|---|---|---|
| 1 정상 플로우 | ✅/❌ | server.log 라인, hubnet_pdf_log 행 수 |
| 2 매칭 실패 | ✅/❌ | matching_failed 분류 정상 여부 |
| 3 세션 만료 | ✅/❌ | 자동 재로그인 동작 여부 |
| 4 격리 검증 | ✅/❌ | 판매 수집 success=true 유지 여부 |

추가 보고:
- 변경된 파일 + 라인 번호
- _run_sales_collection() 트리거 추가 위치
- 검증 종료 후 hubnet_auto_pdf=false 복원 확인
- /api/health 응답 (schedulers 모두 running)

## 6. 절대 규칙

- ⚠️ 격리 원칙 위반 금지. 어떤 경우에도 판매 수집을 망가뜨리면 안 됨
- ⚠️ try/except 누락 금지. 외부/내부/알림 모두 try/except
- ⚠️ raise 금지. 트리거 코드는 어떤 예외도 외부로 던지지 마
- ⚠️ kream_hubnet_bot.py 무수정
- ⚠️ DB 스키마 변경 금지
- ⚠️ 검증 종료 후 hubnet_auto_pdf=false 원상 복구 필수
- ⚠️ 시나리오 3, 4의 임시 변경(세션 파일, settings)은 반드시 원상 복구

## 7. 진행 방식

1. **변경 위치 파악**: `_run_sales_collection()` 함수 위치 + 끝 라인 확인
2. **트리거 코드 추가**: §2 패턴대로 try/except 3중 격리
3. **구문 검증**: py_compile 통과
4. **라우트 충돌 검사**: 새 라우트 추가 안 했으니 0건이어야 함
5. **서버 재시작**: nohup + disown 패턴
6. **/api/health 정상 확인**: status=healthy, schedulers 모두 running
7. **검증 시나리오 4종 순서대로 실행**: 1 → 2 → 3 → 4
8. **각 시나리오 종료 후 원상 복구**
9. **최종 보고**: 표 + 추가 사항

## 8. 다음 단계 (Step 11, 별도 작업)

이 작업 완료 후 며칠 동안 다음 사항 모니터링:
- /api/hubnet/status에서 자동 다운로드 통계 확인
- server.log에 [HUBNET_AUTO] 라인 정상 누적
- alert_history.json에 허브넷 관련 알림 빈도 확인
- 문제 없으면 settings.json의 hubnet_auto_pdf=true로 변경

Step 11은 **사용자 결정** 단계. Claude Code가 임의로 활성화 금지.

## 부록 A. 명세 외 자체 보강 후보 (Claude Code 판단)

다음 항목은 명세에 없지만 추가 시 안전성 향상. 진행 여부는 Claude Code가 판단:

- **세마포어**: 동시에 여러 판매 수집이 트리거되면 download_pending_invoices가 중복 실행될 위험. asyncio.Lock 또는 threading.Lock으로 동시 실행 1개로 제한
- **타임아웃**: download_pending_invoices 자체에 타임아웃 (예: 5분). 그 안에 못 끝내면 다음 사이클로 넘김
- **정상 실행 카운터**: 연속 N회 정상 실행 시 알림 (Step 11 활성화 결정 도움)

이런 보강 추가 시 명세 외 항목으로 명시하고 보고에 포함.
