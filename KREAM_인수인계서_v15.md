# KREAM 판매자센터 자동화 — 인수인계서 v15 (2026-05-07 통합본)

> v8(2026-04-29) ~ v14(2026-05-07) 모든 패치 통합본.
> 신규 채팅 시작 시 이 문서 하나만 읽으면 됩니다.

---

## 1. 한 줄 요약

크로스보더 커머스(중국 → KREAM) 자동화 시스템. **자동 재입찰 인프라 + 송금 환율 시스템 + 모니터링/분석 도구 + 데이터 품질/백업 강화** 모두 완성. **사장님이 송금 데이터 등록하고 ENABLE만 하면 즉시 가동.**

---

## 2. 시스템 진화 타임라인

| 시점 | Step | 핵심 |
|---|---|---|
| 2026-04-29 | v8 (Step 18-33) | 자동 재입찰 dry-run / 단가표 / 검증 시스템 |
| 2026-05-04 | v9 (Step 35-41) | dry-run executable 8건 검증 / FUTURE_WORK 도입 |
| 2026-05-07 | v10 (Step 42) | 송금 환율 시스템 인프라 (remittance_history) |
| 2026-05-07 | v11 (Step 42 Phase 2.5/2.6) | 영수증 첨부 / USD/CNY 분리 / 다중 영수증 |
| 2026-05-07 | v12 (Step 43) | 환율 손익 / 협력사 매칭 / 인보이스 추적 / 통계 |
| 2026-05-07 | v13 (Step 45) | 자동 재입찰 모니터링 / 백테스트 / 일일 리포트 |
| 2026-05-07 | v13 (Step 46) | 데이터 품질 / 단가표 인텔리전스 / 시간별 백업 |
| 2026-05-07 | v14 (Step 47) | 비즈니스 인사이트 / 전역 검색 / 홈 / 단축키 |

---

## 3. 현재 시스템 핵심 지표

- **API: 249개**
- **services 모듈: 16개**
- **대시보드 탭: 9개**
- **DB 테이블: 약 25개** (기존 17개 + 신규 8개)
- **auto-rebid dry-run: executable 8건 / 기대 마진 89,436원/회**
- **자동 재입찰 토글: OFF (사장님 ENABLE 대기)**
- **회귀 발생: 0건** (모든 변경 사항 검증 통과)

---

## 4. 핵심 워크플로우

### A. 송금 등록 (사장님 액션)
1. 대시보드 → 💸 송금환율 탭
2. 협력사 등록 (1회만)
3. 송금 본 등록:
   - USD/CNY 통화 선택
   - 한국 출금 KRW + 협력사 입금 CNY 입력
   - 영수증 1차 첨부 (송금증)
4. "📎 영수증 관리" → 추가 영수증 (입금명세서/인보이스)
5. 인보이스번호 연결
6. FIFO 또는 협력사 인지 매칭
7. 환율 손익 자동 계산

### B. 자동 재입찰 ENABLE (사장님 직접)
사전 조건:
- 송금 1건 이상 매칭됨
- 백테스트(45-4) 결과 양호
- Discord webhook 설정
- 일일 리포트 미리보기 정상

ENABLE 절차:
```bash
cd ~/Desktop/kream_automation
cp settings.json "backups/settings.json.before_enable.$(date +%Y%m%d_%H%M%S)"
python3 -c "
import json
s = json.load(open('settings.json'))
s['auto_rebid_enabled'] = True
s['auto_rebid_dry_run'] = False
s['auto_rebid_daily_max'] = 3
json.dump(s, open('settings.json','w'), ensure_ascii=False, indent=2)
"
lsof -ti:5001 | xargs kill -9; sleep 1
nohup python3 kream_server.py > server.log 2>&1 & disown
```

단계별 상향:
- Day 1: daily_max=3 (보수)
- Week 1: 5 (실패율 5% 이하)
- Week 2: 10
- Week 3: 15
- Week 4+: 20 (최대)

비상 정지: 대시보드 "🚨 비상 정지" 버튼 또는 settings.json 수정

### C. 일일 운영 (사장님 매일)
1. 🏠 홈 대시보드 → 오늘 KPI 확인
2. 🤖 자동 재입찰 모니터링 → 실패율/마진 확인
3. Discord 일일 리포트 23시 자동 수신 (설정 시)
4. 이상 알림 발생 시 즉시 비상 정지 검토

---

## 5. 신규 채팅 시작 가이드

### 첫 메시지 템플릿
```
KREAM_인수인계서_v15.md (또는 v8 + 패치 v9~v14) 읽었음.
직전 커밋 b0eace3 (Step 47 v14 패치).

현재 상태:
- 자동 재입찰 dry-run executable 8건 유지
- 자동 토글 OFF (사장님 ENABLE 대기)
- 단가표 N건 등록
- 송금 데이터 N건 / 매칭 N건
- 데이터 품질 점수 N점

오늘 작업: [구체 지시]
```

### 회귀 기준선 즉시 확보
```bash
curl -s -X POST http://localhost:5001/api/auto-rebid/dry-run \
  -H "Content-Type: application/json" -d '{"hours":720}' \
  | python3 -c "import sys, json; d=json.load(sys.stdin); r=d.get('result',{}); print(r.get('by_status',{}).get('GO','N/A'))" \
  > /tmp/baseline.txt
```

---

## 6. 절대 규칙 7개 (CLAUDE.md)

1. **가짜 값 금지** — 데이터 없으면 NULL, 가짜 값 절대 X
2. **sales_history DROP/DELETE 금지** — 판매 완료 데이터는 진실값
3. **price_history.db 직접 DROP/DELETE 금지** — 마이그레이션만
4. **auth_state.json 백업 없이 덮어쓰기 금지** — JWT localStorage 보호
5. **git push -f, git reset --hard 금지** — 정상 push만
6. **TEST 데이터 입찰 금지** — 실제 거래 환경 보호
7. **인보이스 단가 시스템 데이터 사용 금지** — 통관/세무용 명목 단가

---

## 7. 데이터 신뢰도 우선순위

| 순위 | 데이터 | 용도 |
|---|---|---|
| 1 | bid_cost (실제 입찰 시점) | 진실값, 마진 계산 |
| 2 | model_price_book (사장님 입력) | 폴백 |
| 3 | bid_cost fuzzy (size 안 맞음) | 최종 폴백 |
| ❌ | 인보이스 단가 | 사용 금지 |

환율 우선순위:
1. remittance 매칭 환율 (가중평균)
2. bid_cost.exchange_rate
3. settings.exchange_rate
4. 217 (폴백)

---

## 8. 자동 재입찰 핵심 정보

### dry-run 결과 (최신)
- 후보: 11건
- GO: 8건
- 기대 마진 합계: 89,436원/회
- min_profit: 3,000원
- daily_max: 20 (현재 OFF)

### 6중 안전장치
1. 원가 매칭 (bid_cost → price_book → fuzzy)
2. 마진 하한 (3,000원)
3. 6h 쿨다운
4. 일 한도 (daily_max)
5. 실패율 차단 (>20% 자동 OFF)
6. 스테일 체크

### KREAM 운영 특수성
- **운송장 정시 자동 발급:** 매시 정각 허브넷이 자동 발급
- **발송 후 고객 취소 불가:** 자동 재입찰에 매우 우호적
- **결과:** 6h 쿨다운 + 동일가 재입찰 정책

---

## 9. 9개 탭 빠른 참조

| 탭 | 단축키 | 핵심 기능 |
|---|---|---|
| 🏠 홈 | Cmd+H | 핵심 KPI / 1분 자동 갱신 |
| 💸 송금환율 | Cmd+R | 송금 등록 / 매칭 / 환율 손익 / 영수증 다중 첨부 |
| 📈 인사이트 | Cmd+I | 마진 추세 / 협력사 ROI / 카테고리 수익성 |
| 🤖 자동 재입찰 모니터링 | Cmd+M | 실시간 통계 / 백테스트 / 비상 정지 / ROI 분석 |
| 🔍 데이터 품질 | Cmd+Q | 무결성 점수 / 미등록 모델 / 단가 추정 |
| 💾 백업 관리 | Cmd+B | 일일/시간별 / SHA256 / Export / 시스템 모니터링 |
| 📋 단가표 | Cmd+P | model_price_book / CSV 일괄 / 불일치 감지 |
| 📚 API 카탈로그 | Cmd+A | 249개 API 자동 문서화 |
| 🔎 전역 검색 | Cmd+/ | 7개 테이블 통합 검색 |

---

## 10. FUTURE_WORK 진행도

### ✅ 완료
- 송금 환율 시스템 인프라 (Step 42)
- 영수증 다중 첨부 (Step 42-Phase 2.6)
- 환율 손익 + 협력사 매칭 (Step 43)
- 자동 재입찰 모니터링 (Step 45)
- 데이터 품질 + 백업 강화 (Step 46)
- 비즈니스 인사이트 + UX (Step 47)

### 📋 대기 (사장님 결정)
- Step 44: 자동 재입찰 ENABLE
- 송금 데이터 누적 후 환율 손익 그래프
- 브랜드별 사이즈표 시드

### 📋 백로그
- 모듈 분리 (kream_server.py 6,800줄+ → server/)
- KREAM 백엔드 Railway 이전
- 협력사 자동 추천 시스템

---

## 11. 운영 환경

### 작업 환경
- macOS (한국)
- Python 3.9.6
- SQLite WAL 모드
- Flask + Playwright + APScheduler

### 외부 의존성
- KREAM partner.kream.co.kr (판매자센터)
- KREAM kream.co.kr (일반사이트)
- Gmail IMAP (OTP 자동 수신)
- Naver (KREAM 로그인 연동)
- open.er-api.com (환율)
- Discord webhook (알림)
- Cloudflare Tunnel (외부 접속)
- GitHub: judayjuday/kream-automation (Private)

### 백업 정책
- 일일 백업: 작업 전 수동
- 시간별 백업: 4시간마다 자동 (SHA256)
- 자동 정리: 7일 이상된 hourly 매일 00:30
- receipts/ 외부 백업: 외장 SSD/iCloud 주 1회 (사장님 수동)

---

## 12. 알려진 이슈 / 주의사항

| # | 이슈 | 상태 | 대응 |
|---|---|---|---|
| 1 | 해외에서 kream.co.kr 차단 | 환경 제약 | 한국에서 작업 |
| 2 | KREAM 세션 만료 | 정기 발생 | `python3 kream_bot.py --mode auto-login` |
| 3 | API 캡처 타이밍 | 간헐적 | DOM/JSON-LD fallback |
| 4 | kream_dashboard.html 7,000줄+ | 관리 어려움 | 짧게 요청 |
| 5 | place_bid orderId 미반환 | 구조적 | bid_cost 임시키 사용 |

---

## 13. 다음 작업 우선순위 (제 추천)

1. **사장님 송금 등록** (현재 진행 중)
2. **FIFO 매칭 + 환율 손익 검증**
3. **백테스트 결과 검토**
4. **Step 44 ENABLE (보수 모드 daily_max=3)**
5. **1주일 운영 후 데이터 누적**
6. **단계별 daily_max 상향**
7. **이후 신규 작업은 사용 패턴 보고 결정**
