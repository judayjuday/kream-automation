# KREAM × 허브넷 PDF 자동 다운로드 시스템 — 인수인계서 v5

작성일: 2026-04-30 (저녁, Step 9 + 운영 안정화 완료)
작업지시서:
- `작업지시서_1_허브넷봇_PDF자동다운로드_v1.md` (메인)
- `작업지시서_운영안정화_v1.md` (완료, 4월 30일 처리)
- `작업지시서_2_Step10_스케줄러통합_v1.md` ⭐ 다음 작업
이전 버전:
- v1 (Step 6 완료) / v2 (Step 7 완료) / v3 (Step 8 완료)
- v4 (Step 9 + 1868 수정 완료) — git에 푸시되지 않은 로컬 v4. v5가 통합 최신본

## 사용자 컨텍스트

승주님(juday): KREAM 셀러센터 자동화 운영. 중국 Dewu 소싱 → KREAM 판매.
SSRO/juday.pages.dev도 본인 직접 만듦. 직원분(부준명) SSRO SupplierPortal 추가 작업 중.

## 시스템 구분

| 시스템 | 위치 | 스택 |
|---|---|---|
| **KREAM 자동화** (주작업) | `~/Desktop/kream_automation/` | Flask + SQLite + Playwright + requests |
| **허브넷** (외부) | https://kpartner.ehub24.net | jQuery + AJAX |
| **SSRO** (별도) | `~/Desktop/juday-erp/` | React + Supabase + Cloudflare Pages |

## 작업 환경

- 현재 작업 머신: MacBook Air (한국 위치)
- 사무실 iMac도 사용 가능 (Chrome 원격 데스크톱)
- macOS Python 3.9, Playwright 1.58.0
- Cloudflare Tunnel로 외부 접속 가능

## 작업지시서 1번 진척

### COMPLETED ✅ (Step 1~9 + 운영 안정화)

#### Step 1~6: 인프라 + 봇 본체
- DB 테이블 신규 (hubnet_orders, hubnet_pdf_log) + sales_history 컬럼 3개 추가
- kream_hubnet_bot.py 신규 (~1300줄)
- 로그인/세션 재사용/조회/매칭/송장 HTML/HTML→PDF 모두 완성
- 11.50×16.51cm 라벨 PDF, sync_playwright 일관성, jQuery 배열 인코딩 ⭐

#### Step 7: 일괄 다운로드
- `download_pending_invoices(limit, triggered_by)` 구현
- ORDER BY trade_date DESC, 사전 ensure_hubnet_logged_in() 1회, skipped 분기 self-healing 보정
- 검증 5종 통과
- 커밋: `0818a1e`

#### Step 8: API 6개
- kream_server.py에 허브넷 통합 엔드포인트 추가
- 응답 표준 `{success, data}` / `{success, error}`
- 헬퍼 2개 추출: `_hubnet_session_meta()`, `_hubnet_today_stats()`
- 검증 4종 통과
- 커밋: `f5b9f0f`

#### Step 9: 대시보드 UI
- 백엔드 보강 3가지:
  - GET `/labels/<path:filename>`: send_from_directory + path traversal 차단 + 404 JSON
  - POST `/api/hubnet/auto-toggle`: bool 검증 + atomic write
  - GET `/api/hubnet/status` 확장: today에 `avg_duration_ms` + `auto_pdf_enabled` 추가
- 프론트엔드:
  - tabs/tab_logistics.html 최상단 허브넷 패널 카드 + 동기화 모달
  - kream_dashboard.html에 hubnet JS 14개 함수 + loadLogisticsAll에 hubnetInit() 호출 (try/catch 격리)
  - 디자인 시스템 일관 (var(--card), .btn, .btn-primary, table, .text-muted)
- 결정 사항 (사용자 확정):
  - PDF 미리보기: Flask 정적 서빙 (file:// 안 씀, Cloudflare Tunnel 호환)
  - 자동 토글: 전용 API 신설 (기존 /api/settings 안 건드림)
  - 평균 소요: status API에 avg_duration_ms 추가
  - 폴링: 자동 안 함, [새로고침] 버튼만
- 검증 5종 + 사용자 시각 검증 ✅
- 커밋: `a2d46f5`

#### 1868 잠복 버그 수정 (Step 9 무관, 같은 커밋)
- 증상: `Uncaught TypeError: Cannot set properties of null (setting 'value') at loadSettings ((index):1868:51)`
- 여파: 신호등 회색 + 환율 "로딩 중..." 무한 (백엔드 정상)
- 원인: settings 탭 동적 로드 전 loadSettings 호출 → set-cny-rate 등 7개 input null
- 수정: `_setVal` 헬퍼로 7개 input null 가드 + checkbox 4개도 null 가드
- git diff HEAD~1로 검증: Step 9 이전부터 잠복하던 버그
- 사용자 검증 ✅: 신호등 정상, 환율 215.38원 표시

#### 운영 안정화 (작업지시서_운영안정화_v1.md, 완료 ✅)

진단 결과 (4종):

| § | 이슈 | 진단 | 처리 |
|---|---|---|---|
| 1.1 | 백업 스케줄러 부재 | 코드에 정의 없음, backup_db.sh는 도구로만 존재 | ✅ 옵션 A 적용 |
| 1.2 | auth_state_kream | 정상 (0.3h) | ⚪ 무이슈 |
| 1.3 | last_sale 작업지시서 | 작업 1·2 모두 이미 해소됨 | ✅ archive 이동 |
| 1.4 | 1408 innerHTML | 1868과 같은 패턴 (catch 블록) | ✅ 가드 추가 |

수정 내용:
- §1.1: kream_server.py에 `_backup_timer` 추가 (monitor/sales와 동일 Timer 패턴)
  - subprocess.run으로 backup_db.sh 호출, timeout 180s, try/except 격리
  - 첫 트리거 60초 후, 이후 24h 주기 자체 재등록
  - /api/health schedulers에 backup 키 노출
  - backup_db.sh 자체 7일 보관 정책 (find -mtime +7 -delete)
- §1.4: kream_dashboard.html loadBatchHistory catch + renderBatchHistory에 null 가드 2곳
  - history 탭 미로드 시 silent skip
- §1.3: archive/CLAUDE_CODE_TASK_LASTSALE_HOOK_processed_2026-04-30.md
  - 작업 1: bb45146 fix(kream-operator)로 이미 처리
  - 작업 2: 1fcf5e8 chore(hooks)로 이미 처리

검증:
- /api/health status: warning → **healthy** ✅
- last_backup_age 156.6h → **0.0h** ✅
- schedulers: {backup, monitor, sales} 모두 running
- server.log ERROR 0건
- 커밋: `adfcd2b`

### PENDING (다음 단계)
- **Step 10 스케줄러 통합** ⭐ 다음 작업 — 작업지시서_2_Step10_스케줄러통합_v1.md
- Step 11 (프로덕션 활성화) — 며칠 안정성 검증 후 hubnet_auto_pdf=true

## 운영 이슈 (별도 트랙)

### 기존 물류 관리 UI 이슈 (Step 11 이후 별도 작업)
사용자 보고 (2026-04-30 검증 중):
- 발송 요청 버튼 동작 안 함
- 협력자(huli/정소남/perri 등) 선택 UI 필요
- 작업지시서 1번(허브넷 통합)과 별개 트랙

### labels/ 폴더 git 추적 위험
- `labels/202604/*.pdf` untracked로 누적 중
- `.gitignore`에 `labels/` 추가 필요 (미적용)
- 우선순위: 낮음

### .gitignore의 settings.json 패턴 매치 이슈
- 6번째 줄 `settings.json`이 `.claude/settings.json`도 무시함
- 해결책 (미적용): `/settings.json`으로 변경 (루트 한정)
- 우선순위: 낮음

### SSRO 미해결 이슈 3개 (별도 작업, KREAM 무관)
1. perri/lee/jungsn 로그인 실패
2. 페이지 수정 시 일부 탭 사라짐
3. 통관검증/국내배송 cron job 자동 실행 안 됨

## 주요 발견 (메모)

### 1. 허브넷 list_ajax 응답 구조
add1=주문번호, add2=HBL, add3=송하인, add9=품명(영문), add10=수량, add12=중량, add16=볼륨중량, add17=USD단가, add26=Origin, add33=HS코드, add38=사이즈⭐, add56=택배번호, wdate=등록일시, tracking, order_yn(Y=취소). raw_data에 KREAM model 코드 **없음**.

### 2. 송장 HTML 구조
- POST `/list_ajax` mode=get_print_invoice + hbl_numbers[] → JSON 응답
- POST `/kream_invoice_print` invoice_data=JSON.stringify(data) → HTML 응답
- HTML에 `Model No. 1203A243-100`, `Option 230` 포함 → Step 4 2차 매칭 백업 경로 가능 (미래)

### 3. 운영 인사이트 (Step 4)
- KREAM 판매 → 허브넷 접수까지 시간차 있음
- 같은 날 trade_date라도 fetch 시점에 허브넷 미접수 가능
- → Step 10 재시도 로직에 반영 필요

### 4. Step 7 self-healing
- skipped 분기에서 sales_history.pdf_path NULL 보정
- 이미 채워진 pdf_path는 보존

### 5. Step 8 추가 방어
- API 레이어에서 명세 외 추가 검증 8가지 (날짜 형식/역전, status whitelist, limit clamp/정수)

### 6. 동적 탭 로드 패턴의 잠복 버그 위험성
- kream_dashboard.html은 탭별 HTML을 _loadTab fetch로 동적 삽입
- 페이지 로드 직후 active 탭(register)의 DOM만 존재
- top-level 스크립트가 다른 탭 요소에 즉시 접근하면 null 에러
- 1868(loadSettings), 1408(innerHTML) 모두 같은 패턴
- 향후 코드 추가 시 `getElementById` 결과는 항상 null 체크
- **표준 패턴**: `const _setVal = (id, val) => { const el = document.getElementById(id); if (el) el.value = val; }`

### 7. 운영 스케줄러 패턴
- monitor, sales, health_alert, **backup** (NEW) — 4개 모두 동일 Timer 패턴
- 새 스케줄러 추가 시: 같은 패턴 따름, try/except 격리 필수
- 자체 재등록 (`_xxx_tick()` 내부에서 다음 Timer 등록)이 표준
- /api/health schedulers에 노출

## KREAM 비즈니스 규칙

- KREAM은 셀러에게 수취인 정보 제공 안 함 (PDF에도 마스킹: `Consignee: ***`)
- 일본 구매대행 환급 불가
- 시스템에 수취인 컬럼/필드 추가 금지
- consignee 관련 키는 raw_data에서도 제외 (SENSITIVE_KEYS frozenset)

## 핵심 기술 결정사항

- **Q-1A** (Step 6): sync_playwright 선택 (모듈 일관성)
- **jQuery 배열 인코딩** (Step 5): 튜플 리스트 `[('hbl_numbers[]', h)]`
- **ensure_ascii=False** (Step 5): JSON.stringify와 동일 한글 보존
- **페이지 사이즈** (Step 6): 11.5×16.5cm CSS 그대로 (prefer_css_page_size=True)
- **Step 7 시그니처**: 인수인계서 우선 (`limit=None, triggered_by='manual'`)
- **Step 8 헬퍼 추출**: `_hubnet_session_meta()`, `_hubnet_today_stats()`
- **Step 9 결정** (사용자 확정): Flask 정적 서빙, 전용 토글 API, avg_duration_ms 추가, 폴링 안 함
- **null 가드 헬퍼 패턴** (1868/1408): `_setVal`, `_setHTML` 패턴이 동적 탭 환경에서의 표준
- **백업 스케줄러 패턴** (운영안정화 §1.1): Timer 자체 재등록, subprocess.run + timeout, try/except 격리

## 파일 구조

```
~/Desktop/kream_automation/
├── kream_hubnet_bot.py              # 메인 봇 (~1300줄, Step 1-7 완료)
├── kream_server.py                   # Flask 서버 (~8500줄, 122 라우트, Step 8-9 + 운영안정화)
├── kream_dashboard.html              # 메인 대시보드 (Step 9 hubnet JS, 1868/1408 가드)
├── price_history.db                  # SQLite (WAL 모드)
├── auth_state_hubnet.json            # 허브넷 세션 (gitignore)
├── auth_state.json, auth_state_kream.json # KREAM 세션 (gitignore)
├── settings.json                     # 설정 (gitignore)
├── backup_db.sh                      # 백업 스크립트 (7일 보관 정책)
├── backup.log                        # 백업 실행 로그
├── labels/{YYYYMM}/*.pdf             # 송장 PDF 저장 (.gitignore 추가 필요)
├── tabs/                             # 대시보드 탭 (모듈형)
│   └── tab_logistics.html            # 물류 관리 (Step 9 허브넷 패널 추가)
├── 작업지시서_1_허브넷봇_PDF자동다운로드_v1.md
├── 작업지시서_2_Step10_스케줄러통합_v1.md  # ⭐ NEW (다음 작업)
├── KREAM_허브넷_SSRO_통합아키텍처_v1.md
├── KREAM_허브넷통합_인수인계_v1~v5.md  # v5가 현재 최신
├── KREAM_인수인계서_v7.md            # 기존 KREAM 자동화 인수인계
└── archive/                          # 처리 완료 작업지시서들
    └── CLAUDE_CODE_TASK_LASTSALE_HOOK_processed_2026-04-30.md
└── .claude/
    ├── hooks/
    │   ├── syntax-check.sh           # 활성
    │   └── dangerous-command-check.sh # 활성
    └── settings.json                  # Stop hook 제거됨 (.gitignore 매치로 추적 안 됨)
```

## DB 테이블

### hubnet_orders, hubnet_pdf_log (Step 1 신규)
v3와 동일

### sales_history (Step 1 컬럼 추가)
hbl_number, pdf_path, pdf_downloaded_at

## settings.json 키

```json
{
  "hubnet_email": "judaykream@gmail.com",
  "hubnet_password": "1234",
  "hubnet_session_path": "/Users/iseungju/Desktop/kream_automation/auth_state_hubnet.json",
  "hubnet_pdf_dir": "/Users/iseungju/Desktop/kream_automation/labels",
  "hubnet_auto_pdf": false,
  "hubnet_fetch_days": 7
}
```

## 자주 쓰는 명령어

```bash
# 서버 실행
cd ~/Desktop/kream_automation
python3 kream_server.py

# Claude Code
claude --dangerously-skip-permissions

# 봇 CLI 모드들 (Step 7까지)
python3 kream_hubnet_bot.py --mode auth -v
python3 kream_hubnet_bot.py --mode fetch --start 2026-04-21 --end 2026-04-28 -v
python3 kream_hubnet_bot.py --mode match -v
python3 kream_hubnet_bot.py --mode html-test --hbl H2604252301517 -v
python3 kream_hubnet_bot.py --mode pdf-test --hbl H2604252301517 -v
python3 kream_hubnet_bot.py --mode download-pending -v

# 허브넷 API (Step 8)
curl http://localhost:5001/api/hubnet/status | python3 -m json.tool
curl -X POST http://localhost:5001/api/hubnet/login | python3 -m json.tool
curl -X POST http://localhost:5001/api/hubnet/sync \
  -H "Content-Type: application/json" \
  -d '{"start_date":"2026-04-21","end_date":"2026-04-28"}' | python3 -m json.tool
curl -X POST http://localhost:5001/api/hubnet/pdf/batch \
  -H "Content-Type: application/json" -d '{}' | python3 -m json.tool
curl "http://localhost:5001/api/hubnet/pdf/log?limit=10" | python3 -m json.tool

# Step 9 추가 API
curl -I http://localhost:5001/labels/202604/H2604252301517_1203A243-100_230_20260425.pdf
curl -X POST http://localhost:5001/api/hubnet/auto-toggle \
  -H "Content-Type: application/json" -d '{"enabled":true}' | python3 -m json.tool

# DB 확인
sqlite3 price_history.db "SELECT COUNT(*) FROM hubnet_orders;"
sqlite3 price_history.db "SELECT * FROM hubnet_pdf_log ORDER BY id DESC LIMIT 5;"

# 헬스체크 (운영안정화 후 healthy 유지 중)
curl http://localhost:5001/api/health

# 서버 재시작 (kill -9 후 죽는 이슈 방지 패턴)
lsof -ti:5001 | xargs kill -9 2>/dev/null
nohup python3 kream_server.py > server.log 2>&1 &
disown
sleep 2
curl -s http://localhost:5001/api/health

# 수동 백업 (스케줄러와 별개)
bash backup_db.sh
```

## 최근 커밋 히스토리

```
adfcd2b fix: 운영 안정화 — 백업 스케줄러 + 1408 잠복 + last_sale archive  ⭐ 최신
a2d46f5 feat: 허브넷 봇 Step 9 (대시보드 UI) + 1868 잠복 버그 수정
77a651c docs: 인수인계서 v3 (Step 8 완료 반영)
f5b9f0f feat: 허브넷 봇 Step 8 (API 6개 추가)
4575cbb docs: 인수인계서 v2 (Step 7 완료 반영)
0818a1e feat: 허브넷 봇 Step 7 (download_pending_invoices) + hook 정리
0c77c13 feat: 허브넷 봇 Step 6 + 인수인계서 v1
```

## 다음 채팅 시작 가이드

1. **첨부 파일 2개**:
   - `KREAM_허브넷통합_인수인계_v5.md` (이 파일)
   - `작업지시서_2_Step10_스케줄러통합_v1.md`

2. **첫 메시지 템플릿**:
```
이 프로젝트는 KREAM × 허브넷 송장 PDF 자동 다운로드 시스템 구축이야.
2026-04-30에 Step 9 + 운영 안정화까지 완료, 다음은 Step 10 (스케줄러 통합).

== 작업 환경 ==
- 폴더: ~/Desktop/kream_automation/
- 작업 머신: MacBook Air (한국)
- Claude Code: claude --dangerously-skip-permissions
- 서버: python3 kream_server.py (포트 5001)
- 한국어로 대화

== 첨부 파일 ==
- KREAM_허브넷통합_인수인계_v5.md (Step 9 + 운영안정화 완료 반영)
- 작업지시서_2_Step10_스케줄러통합_v1.md

이거 읽고 컨텍스트 파악한 다음, Step 10 작업지시서대로 Claude Code에 보낼 메시지 만들어줘.
시각 검증/시뮬 검증 시나리오 4종 모두 포함하고, 격리 원칙(허브넷 실패해도 판매 수집 정상) 강조해서.
```

3. **Step 10 시작 전 확인사항**:
   - 시스템이 healthy 상태인지 (`/api/health`)
   - 모든 스케줄러 running인지 (backup, monitor, sales)
   - 어제까지 작업한 커밋이 push 상태인지 (`git log --oneline -5`)
