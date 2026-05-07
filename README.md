# KREAM 판매자센터 자동화

크로스보더 커머스(중국 → 한국) 자동화 시스템. KREAM 입찰/판매/송금/마진 분석 통합.

## 빠른 시작

```bash
# 서버 실행
cd ~/Desktop/kream_automation
nohup python3 kream_server.py > server.log 2>&1 & disown

# 대시보드 접속
http://localhost:5001/
```

## 주요 탭

| 탭 | 용도 | 단축키 |
|---|---|---|
| 🏠 홈 | 핵심 KPI 한눈에 (1분 자동 갱신) | Cmd+H |
| 💸 송금환율 | 송금 등록 / 영수증 첨부 / 매칭 | Cmd+R |
| 📈 인사이트 | 마진 추세 / 협력사 ROI / 카테고리 수익성 | Cmd+I |
| 🤖 자동 재입찰 모니터링 | 실시간 통계 / 백테스트 / 비상 정지 | Cmd+M |
| 🔍 데이터 품질 | 무결성 점수 / 미등록 모델 / 단가 추정 | Cmd+Q |
| 💾 백업 관리 | 일일/시간별 백업 / SHA256 검증 / Export | Cmd+B |
| 📋 단가표 | model_price_book / CSV 일괄 / 불일치 감지 | Cmd+P |
| 📚 API 카탈로그 | 250+ API 자동 문서화 | Cmd+A |
| 🔎 전역 검색 | 7개 테이블 통합 검색 | Cmd+/ |

## 시스템 구조

### 핵심 디렉토리
```
~/Desktop/kream_automation/
├── kream_server.py         # Flask 서버 (포트 5001)
├── kream_dashboard.html    # 대시보드 진입점
├── kream_bot.py            # Playwright 자동화
├── kream_collector.py      # KREAM 가격 수집
├── kream_adjuster.py       # 가격 자동 조정
├── price_history.db        # SQLite (WAL)
├── settings.json           # 환율/수수료/자동조정 설정
├── auth_state.json         # KREAM 세션 (보호 대상)
├── tabs/                   # 탭 HTML (9개)
├── services/               # 비즈니스 로직 (16개 모듈)
├── backups/                # 일일 + 시간별 백업
├── receipts/               # 송금 영수증 (git 미추적, 외부 백업)
└── .claude/                # Claude Code hooks + skills
```

### services/ 모듈 (16개)
| 모듈 | 역할 |
|---|---|
| auto_rebid.py | 자동 재입찰 dry-run/엔진 (수정 금지) |
| price_book.py | 단가표 lookup/upsert |
| remittance.py | 송금 CRUD / 매칭 / 영수증 |
| fx_pnl.py | 환율 손익 분석 |
| rebid_monitor.py | 자동 재입찰 모니터링 |
| daily_report.py | Discord 일일 리포트 + 알림 |
| rebid_simulator.py | 백테스트 |
| data_quality.py | 데이터 무결성 검증 |
| price_intelligence.py | 단가 추정 |
| backup_manager.py | 시간별 백업 |
| system_monitor.py | 디스크/DB 통계 |
| business_insights.py | 마진 추세 / ROI 분석 |
| global_search.py | 통합 검색 |
| data_export.py | CSV/JSON Export |
| api_catalog.py | API 자동 문서화 |
| headline.py | 홈 대시보드 |

### DB 테이블 주요 항목
- bid_cost — 입찰 시점 원가 (진실값, 마진 계산 우선)
- sales_history — 판매 이력 (조회만, 절대 변경 금지)
- remittance_history — 송금 이력 (USD/CNY 분리)
- remittance_supplier — 협력사 마스터
- remittance_invoice — 인보이스 추적 (1:N)
- remittance_receipt — 영수증 다중 첨부
- remittance_bid_match — 송금↔입찰 매칭
- model_price_book — 사장님 입력 단가표
- auto_rebid_log — 자동 재입찰 이력

## 절대 규칙 (CLAUDE.md 참조)

1. 가짜 값 사용 금지 (NULL 또는 거부)
2. sales_history DROP/DELETE 금지
3. price_history.db 직접 DROP/DELETE 금지
4. auth_state.json 백업 없이 덮어쓰기 금지
5. git push -f, git reset --hard 금지
6. TEST 데이터로 실제 입찰 금지
7. 인보이스 단가는 시스템 데이터로 사용 금지

## 핵심 비즈니스 로직

### 마진 계산
```
정산액 = 판매가 × (1 - 0.06 × 1.1) - 2,500
원가 = CNY × 환율 × 1.03 + 8,000
예상수익 = 정산액 - 원가
```

### 환율 폴백 체인 (calc_expected_profit)
1. remittance 매칭 환율 (가중평균) ← 최우선
2. bid_cost.exchange_rate
3. settings.exchange_rate (open.er-api.com)
4. 217 (안전 폴백)

### 자동 재입찰 6중 안전장치
1. 원가 매칭 (bid_cost → price_book → fuzzy)
2. 마진 하한 (min_profit, 기본 3,000원)
3. 6h 쿨다운
4. 일 한도 (auto_rebid_daily_max)
5. 실패율 차단 (>20% → 자동 OFF)
6. 스테일 체크 (수정 직전 재확인)

## 자주 쓰는 명령

```bash
# 서버 재시작 (kill 후 죽음 방지: nohup + disown)
lsof -ti:5001 | xargs kill -9; sleep 1
nohup python3 kream_server.py > server.log 2>&1 & disown

# Claude Code
cd ~/Desktop/kream_automation && claude --dangerously-skip-permissions

# 백업 (수동)
mkdir -p backups
cp price_history.db "backups/price_history.db.manual.$(date +%Y%m%d_%H%M%S)"

# 헬스체크
curl -s http://localhost:5001/api/health | python3 -m json.tool

# auto-rebid dry-run (회귀 검증)
curl -s -X POST http://localhost:5001/api/auto-rebid/dry-run \
  -H "Content-Type: application/json" -d '{"hours":720}' | python3 -m json.tool

# 자동 로그인 (KREAM 세션 만료 시)
python3 kream_bot.py --mode auto-login
```

## 신규 채팅 시작 시 체크리스트

1. KREAM_인수인계서_v15.md 읽기 (또는 v8 + v14 패치)
2. FUTURE_WORK.md 확인
3. CLAUDE.md 절대 규칙 7개 숙지
4. `git log --oneline -5` 직전 작업 확인
5. `curl /api/health` 서버 상태 확인
6. `bash /tmp/check_regression.sh` 회귀 기준선 확보 (auto-rebid 8건 유지가 표준)

## 운영 환경

- macOS (사장님 노트북, 한국)
- Python 3.9.6
- SQLite (WAL 모드)
- Flask + Playwright
- KREAM partner.kream.co.kr (판매자센터, JWT localStorage)
- KREAM kream.co.kr (일반사이트, 네이버 로그인)
- Cloudflare Tunnel (외부 접속)
- Discord webhook (일일 리포트 + 알림)
