# KREAM × 허브넷 PDF 자동 다운로드 시스템 — 인수인계서 v4

작성일: 2026-04-30 (저녁, Step 9 완료 + 1868 잠복 버그 수정)
작업지시서 위치: ~/Desktop/kream_automation/작업지시서_1_허브넷봇_PDF자동다운로드_v1.md
이전 버전:
- v1 (2026-04-30 오전, Step 6 완료)
- v2 (2026-04-30 오후 초반, Step 7 완료)
- v3 (2026-04-30 오후 후반, Step 8 완료)

## 사용자 컨텍스트

승주님(juday): KREAM 셀러센터 자동화 운영. 중국 Dewu 소싱 → KREAM 판매.
SSRO/juday.pages.dev도 본인 직접 만듦. 직원분(부준명) SSRO SupplierPortal 추가 작업 중.

## 시스템 구분 (중요)

| 시스템 | 위치 | 스택 | 비고 |
|---|---|---|---|
| **KREAM 자동화** (주작업) | `~/Desktop/kream_automation/` | Flask + SQLite + Playwright + requests | 승주님이 만듦 |
| **허브넷** (외부) | https://kpartner.ehub24.net | jQuery + AJAX | 외부 시스템 |
| **SSRO** (별도 작업) | `~/Desktop/juday-erp/` (iCloud) | React + Supabase + Cloudflare Pages | 승주님이 만듦, 직원분이 일부 작업 |

## 작업 환경

- **현재 작업 머신**: MacBook Air (한국 위치)
- 사무실 iMac(`iseungjuui-iMac-2`, user `iseungju`)도 사용 가능 — 필요 시 Chrome 원격 데스크톱
- iCloud 동기화로 두 머신 간 파일 공유
- Cloudflare Tunnel로 외부에서 대시보드 접속 가능
- KREAM 일반사이트 접속 위치 제약 없음 (지금은 한국이라 가능)
- macOS Python 3.9, Playwright 1.58.0, chromium 145.0.7632.6 설치됨
- urllib3 NotOpenSSLWarning (LibreSSL 2.8.3) 출력되지만 무시 가능

## 작업지시서 1번 진척 (2026-04-30 저녁 기준)

### COMPLETED ✅ (Step 1~9)

- **Step 1 인프라**: price_history.db 백업, hubnet_orders/hubnet_pdf_log 테이블, sales_history에 컬럼 3개, labels/ 폴더, settings.json hubnet_* 6개 키, .gitignore 갱신

- **Step 2 로그인**: kream_hubnet_bot.py 신규, 로그인+세션 재사용 OK. auth_state_hubnet.json 정상 (PHPSESSID, 30일 유효)

- **Step 3 조회+저장**: fetch_hubnet_orders, upsert_hubnet_orders. SENSITIVE_KEYS frozenset, raw_data에서 제외. INSERT OR REPLACE

- **Step 4 매칭**: match_hubnet_to_kream, update_kream_sales_with_hbl, match_all_unmatched. 1차 정확 일치. 2차는 # TODO 스텁

- **Step 5 송장 HTML**: fetch_invoice_html. jQuery 배열 인코딩(`hbl_numbers[]` 튜플 리스트 ⭐), invoice_data=json.dumps(ensure_ascii=False)

- **Step 6 HTML→PDF**: html_to_pdf (sync_playwright, prefer_css_page_size, 11.50×16.51cm), download_invoice_pdf (단건 다운로드 + 중복 검사 + hubnet_pdf_log 기록)

- **Step 7 일괄 다운로드**: download_pending_invoices(limit, triggered_by). ORDER BY trade_date DESC, 사전 ensure_hubnet_logged_in() 1회, skipped 분기 self-healing 보정. 검증 5종 통과

- **Step 8 API 6개**: kream_server.py에 허브넷 통합 엔드포인트 추가. 응답 표준 `{success, data}` / `{success, error}`. 에러 응답 try/except로 JSON 반환. 라우트 충돌 0건. 검증 4종 통과

- **Step 9 대시보드 UI** ⭐ NEW: tabs/tab_logistics.html에 허브넷 패널 추가
  - 백엔드 보강 3가지:
    - GET `/labels/<path:filename>`: send_from_directory + path traversal 차단(`..` 명시 검사) + 404 JSON
    - POST `/api/hubnet/auto-toggle`: bool 검증 + atomic write(`.tmp.replace`)
    - GET `/api/hubnet/status` 확장: today에 `avg_duration_ms` + `auto_pdf_enabled` 필드 추가
  - 프론트엔드:
    - tabs/tab_logistics.html 최상단에 허브넷 패널 카드 + 동기화 모달 추가 (기존 콘텐츠 무수정)
    - kream_dashboard.html에 hubnet JS 14개 함수 + loadLogisticsAll에 hubnetInit() 호출 (try/catch 격리)
    - 디자인 시스템 일관 (var(--card), .btn, .btn-primary, table, .text-muted 등 재사용)
  - 결정 사항(사용자 확정):
    - PDF 미리보기: Flask 정적 서빙 (file:// 안 씀, Cloudflare Tunnel 호환)
    - 자동 토글: 전용 API 신설 (기존 /api/settings 안 건드림)
    - 평균 소요: status API에 avg_duration_ms 추가
    - 폴링: 자동 안 함, [새로고침] 버튼만
  - 검증 5종 통과:
    - 정상 응답 6개 모두 200 + 표준 JSON
    - 에러 케이스 (path traversal 차단, enabled=null/누락 → 400)
    - 모바일 폭 자동 wrap (CSS-only)
    - 회귀 테스트 5개 정상
    - 검증 종료 후 hubnet_auto_pdf=false로 복원
  - **사용자 시각 검증 ✅**: 물류 관리 탭 진입 → 패널 표시, 모든 액션 동작 확인
  - 커밋: `a2d46f5 feat: 허브넷 봇 Step 9 (대시보드 UI) + 1868 잠복 버그 수정`

- **1868 잠복 버그 수정** ⭐ NEW (Step 9 무관, 같은 커밋):
  - 증상: 콘솔 `Uncaught TypeError: Cannot set properties of null (setting 'value') at loadSettings ((index):1868:51)`
  - 여파: 신호등 3개 회색 + 환율 "로딩 중..." 무한 (백엔드는 정상)
  - 원인: settings 탭이 동적 로드(_loadTab fetch)인데 페이지 로드 직후 line 6770에서 loadSettings() 즉시 호출. settings input 7개(set-cny-rate 등)가 DOM에 없어 getElementById(...) = null. throw로 인해 6770 이후 top-level 스크립트 차단 → checkSessionStatus(), setInterval, fetchExchangeRate(true) 등록 실패
  - 수정: kream_dashboard.html line 1867~1894. `_setVal` 헬퍼로 7개 input null 가드 + checkbox 4개도 null 가드
  - git diff HEAD~1로 검증: Step 9 무관 잠복 버그 (Step 9 이전부터 존재)
  - 사용자 검증 ✅: 신호등 3개 색 들어옴, 환율 215.38원 표시, 콘솔에서 1868 에러 사라짐

### PENDING (다음 단계 — Step 10 + 운영 안정화)
- **운영 안정화** (Step 10 이전 필수): 4가지 이슈 진단/수정 — 작업지시서_운영안정화_v1.md
- **Step 10 스케줄러 통합** (작업지시서 1번 §4.2)

## 운영 안정화 작업 (진행 예정) ⭐ NEW

작업지시서: `작업지시서_운영안정화_v1.md`
이유: Step 10이 새 스케줄러를 추가하는 작업인데, 기존 스케줄러 일부가 멈춰있는 환경에서 진행하면 디버깅 어려움.

### 4가지 이슈

| # | 이슈 | 증상 | 우선순위 |
|---|---|---|---|
| 1 | 자동 백업 6일째 멈춤 | last_backup_age_hours: 156.1 | 중 |
| 2 | auth_state_kream 자동 갱신 안 됨 | auth_kream.age_hours: 39.9, 이메일 알림 "CRITICAL: KREAM 인증 38.7시간 경과" | 높음 |
| 3 | last_sale 작업지시서 미실행 | CLAUDE_CODE_TASK_LASTSALE_HOOK.md 누적 | 낮음 (현재 last_sale_age=1.7h 정상) |
| 4 | 1408번 줄 innerHTML 잠복 | 콘솔 `Uncaught (in promise) TypeError ((index):1408:61)` | 낮음 (in promise라 외부 영향 없음) |

### 진행 방식 (작업지시서 §6)
1. 진단 단계 먼저 4가지 모두 완료
2. 진단 결과 사용자에게 보고 → 사용자가 어느 이슈 수정할지 선택
3. 선택된 이슈만 수정 진행

## 주요 발견 (메모)

### 1. 허브넷 list_ajax 응답 구조
- 매핑된 필드: add1=주문번호, add2=HBL, add3=송하인, add9=품명(영문), add10=수량, add12=중량, add16=볼륨중량, add17=USD단가, add26=Origin, add33=HS코드, add38=사이즈⭐, add56=택배번호, wdate=등록일시, tracking, order_yn(Y=취소)
- raw_data에 KREAM model 코드(1203A243-100 등) **없음** — 영문 상품명만

### 2. 송장 HTML 구조 (Step 5에서 발견)
- POST `/list_ajax` mode=get_print_invoice + hbl_numbers[] → JSON 응답
- POST `/kream_invoice_print` invoice_data=JSON.stringify(data) → HTML 응답
- HTML에는 `<title>KREAM B/L 라벨 출력</title>`, `@page { size: 11.5cm 16.5cm; }` 포함
- ⭐ HTML에는 `Model No. 1203A243-100`, `Option 230` 포함 → **Step 4 2차 매칭 백업 경로** 가능 (미래)

### 3. 운영 인사이트 (Step 4에서 발견)
- KREAM 판매 → 허브넷 접수까지 시간차 있음
- 같은 날 trade_date라도 fetch 시점에 허브넷 미접수 가능
- → Step 10 재시도 로직에 반영 필요

### 4. KREAM ↔ 허브넷 ID 형식
- `A-SN160261934`, `A-AC158171875` 형식 100% 동일
- 1차 매칭은 단순 동등 비교(`WHERE order_no = ?`)로 충분

### 5. Step 7 self-healing 동작
- skipped 분기에서 sales_history.pdf_path NULL 보정 로직 덕분에, hubnet_pdf_log와 sales_history가 어긋난 상태도 다음 download-pending 실행 시 자동 정합화됨
- 이미 채워진 pdf_path는 보존 (무조건 덮어쓰지 않음)

### 6. Step 8 추가 방어
- API 레이어에서 명세 외 추가 검증 8가지 (날짜 형식/역전, status whitelist, limit clamp/정수)
- 사용자 직접 호출 또는 Step 9 대시보드 호출 시 잘못된 입력 조기 차단

### 7. 동적 탭 로드 패턴의 잠복 버그 위험성 (NEW)
- kream_dashboard.html은 탭별 HTML을 _loadTab fetch로 동적 삽입
- 페이지 로드 직후에는 active 탭(register)의 DOM만 존재
- top-level 스크립트가 다른 탭의 요소에 즉시 접근하면 null 에러 발생
- **1868**(loadSettings) 수정 완료, **1408**(innerHTML) 미수정 (운영 안정화에서 처리 예정)
- 향후 코드 추가 시 동일 패턴 주의 — `getElementById` 결과는 항상 null 체크

## KREAM 비즈니스 규칙 (필수 준수)

- **KREAM은 셀러에게 수취인 정보 제공 안 함** (PDF에도 마스킹: `Consignee: ***`)
- 일본 구매대행 환급 불가 (수취인 외국 거주 증명 불가)
- 시스템에 수취인 컬럼/필드 추가 금지
- consignee/consignee_phone/consignee_address는 raw_data에서도 제외 (SENSITIVE_KEYS frozenset)

## 핵심 기술 결정사항

### Q-1A: sync_playwright 선택 (Step 6)
- async def → 동기로 변경. 이유: 모듈 일관성, CLI 진입점 간결, sync→async 경계 회피

### jQuery 배열 인코딩 (Step 5) ⭐
- PHP 백엔드는 `hbl_numbers[]=H1&hbl_numbers[]=H2` 형식만 배열 인식
- 튜플 리스트로 명시: `data.append(('hbl_numbers[]', h))`

### ensure_ascii=False (Step 5)
- JSON.stringify와 동일하게 한글 보존, PDF 변환 시 한글 깨짐 방지

### 페이지 사이즈: HTML CSS 그대로 (Step 6)
- 송장 HTML의 `@page` CSS가 11.5×16.5cm 명시. prefer_css_page_size=True

### Step 7 시그니처: 인수인계서 우선
- 작업지시서 §3.1: `download_pending_invoices(triggered_by='scheduler', limit=50)`
- 인수인계서 v1: `download_pending_invoices(limit=None, triggered_by='manual')`
- 인수인계서 기준 채택 — Step 7은 CLI/수동 우선

### Step 8 헬퍼 추출
- `_hubnet_session_meta()`: auth_state_hubnet.json 파싱
- `_hubnet_today_stats()`: 오늘 통계 (KST date 기준)

### Step 9 결정 사항 (사용자 확정)
- PDF 미리보기: Flask `/labels/<path>` 정적 서빙 (file:// 안 씀)
- 자동 토글: 전용 API `/api/hubnet/auto-toggle` 신설
- 평균 소요: status API에 `avg_duration_ms` 추가
- 폴링: 자동 안 함, [새로고침] 버튼만

### 1868 수정: null 가드 헬퍼 패턴
- `_setVal = (id, val) => { const el = document.getElementById(id); if (el) el.value = val; }`
- 동적 탭 로드 페이지에서 안전한 DOM 접근 표준 패턴
- 운영 안정화에서 1408 수정 시에도 동일 패턴 적용 예정

## 알려진 이슈

### 운영 이슈 4가지 (운영 안정화 작업지시서로 처리 예정)
위 §"운영 안정화 작업" 섹션 참조

### Stop hook 무한루프 — 해결됨 ✅
- v2 시점: `.claude/hooks/stop-checklist.sh` 삭제, `.claude/settings.json`에서 Stop hook 항목 제거
- 현재: Claude Code 종료 시 더이상 "No such file" 에러 안 남

### .gitignore의 settings.json 패턴 매치 이슈
- `.gitignore` 6번째 줄 `settings.json` 패턴이 루트 `settings.json`(자격증명 포함)뿐 아니라 `.claude/settings.json`도 무시
- 해결책 (미적용): `.gitignore`의 `settings.json`을 `/settings.json`으로 변경
- 우선순위: 낮음

### labels/ 폴더 git 추적 위험 (NEW)
- `labels/202604/*.pdf` 4건이 untracked로 잡힘
- PDF는 자동 다운로드 결과물이라 git 추적 대상 아님
- 해결책 (미적용): `.gitignore`에 `labels/` 추가
- Step 10 들어가기 전 또는 운영 안정화 작업 중 같이 정리 권장

### SSRO 미해결 이슈 3개 (별도 작업)
1. perri/lee/jungsn 로그인 실패: "Database error querying schema". 비밀번호 hash 통일했는데도 안 됨
2. 페이지 수정 시 일부 탭 사라짐: CS상담분석/log/통관배송추적
3. 통관검증/국내배송 cron job 자동 실행 안 됨

→ 이 셋은 KREAM 작업과 별개

### 기존 물류 관리 UI 이슈 (NEW, 별도 작업)
- 사용자 보고: "발송 요청 버튼 동작 안 함"
- 사용자 보고: "협력자(huli/정소남/perri 등) 선택 UI 필요"
- 작업지시서 1번(허브넷 통합)과 별개 트랙
- Step 11 이후 별도 작업으로 처리 예정

## 파일 구조

```
~/Desktop/kream_automation/
├── kream_hubnet_bot.py              # 메인 봇 (~1300줄, Step 1-7 완료)
├── kream_server.py                   # Flask 서버 (~8500줄, 122 라우트, Step 8-9 완료)
├── kream_dashboard.html              # 메인 대시보드 (Step 9 hubnet JS 14개 추가, 1868 수정)
├── price_history.db                  # SQLite (WAL 모드)
├── auth_state_hubnet.json            # 허브넷 세션 (gitignore)
├── auth_state.json, auth_state_kream.json # 기존 KREAM 세션 (gitignore)
├── settings.json                     # 설정 (gitignore)
├── labels/{YYYYMM}/*.pdf             # 송장 PDF 저장 위치 ⭐ (.gitignore 추가 필요)
├── tabs/                             # 대시보드 탭 (모듈형)
│   └── tab_logistics.html            # 물류 관리 (Step 9에서 허브넷 패널 추가)
├── 작업지시서_1_허브넷봇_PDF자동다운로드_v1.md
├── 작업지시서_운영안정화_v1.md       # ⭐ NEW
├── KREAM_허브넷_SSRO_통합아키텍처_v1.md
├── KREAM_허브넷통합_인수인계_v1.md   # Step 6
├── KREAM_허브넷통합_인수인계_v2.md   # Step 7
├── KREAM_허브넷통합_인수인계_v3.md   # Step 8
├── KREAM_허브넷통합_인수인계_v4.md   # Step 9 + 1868 ⭐ 현재
├── KREAM_인수인계서_v7.md            # 기존 KREAM 자동화 인수인계
├── CLAUDE_CODE_TASK_LASTSALE_HOOK.md # 미실행 진단 작업지시서
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
v3와 동일 (hbl_number, pdf_path, pdf_downloaded_at)

## settings.json 키 (Step 1 추가)

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

## 다음 작업 순서

### A. 운영 안정화 (작업지시서_운영안정화_v1.md) — 즉시 진행
1. 진단 단계 (§1) 4가지 모두 완료
2. 결과 사용자 보고
3. 사용자 선택 후 수정

### B. Step 10 스케줄러 통합 (작업지시서 1번 §4.2) — 운영 안정화 후
- 판매 수집 직후 허브넷 PDF 자동 다운로드 트리거
- 격리: try/except로 감싸기 (허브넷 실패 시 판매 수집 영향 X)
- settings의 `hubnet_auto_pdf` 체크 (기본 false)
- 검증: 수동 트리거 → 자동 다운로드 + 일부러 허브넷 실패 시 판매 수집 정상 완료

## 빠른 참고

### 자주 쓰는 명령어
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
curl http://localhost:5001/labels/202604/H2604252301517_1203A243-100_230_20260425.pdf -I
curl -X POST http://localhost:5001/api/hubnet/auto-toggle \
  -H "Content-Type: application/json" -d '{"enabled":true}' | python3 -m json.tool

# DB 확인
sqlite3 price_history.db "SELECT COUNT(*) FROM hubnet_orders;"
sqlite3 price_history.db "SELECT * FROM hubnet_pdf_log ORDER BY id DESC LIMIT 5;"

# 헬스체크
curl http://localhost:5001/api/health

# 서버 재시작 (kill -9 후 죽는 이슈 방지 패턴)
lsof -ti:5001 | xargs kill -9 2>/dev/null
nohup python3 kream_server.py > server.log 2>&1 &
disown
sleep 2
curl -s http://localhost:5001/api/health

# git 진척
cd ~/Desktop/kream_automation && git log --oneline -10
```

### 최근 커밋 히스토리
```
a2d46f5 feat: 허브넷 봇 Step 9 (대시보드 UI) + 1868 잠복 버그 수정     ⭐ 최신
77a651c docs: 인수인계서 v3 (Step 8 완료 반영)
f5b9f0f feat: 허브넷 봇 Step 8 (API 6개 추가)
4575cbb docs: 인수인계서 v2 (Step 7 완료 반영)
0818a1e feat: 허브넷 봇 Step 7 (download_pending_invoices) + hook 정리
0c77c13 feat: 허브넷 봇 Step 6 + 인수인계서 v1
```
