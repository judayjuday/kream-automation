# KREAM × 허브넷 PDF 자동 다운로드 시스템 — 인수인계서 v2

작성일: 2026-04-30 (오후, Step 7 완료)
작업지시서 위치: ~/Desktop/kream_automation/작업지시서_1_허브넷봇_PDF자동다운로드_v1.md
이전 버전: KREAM_허브넷통합_인수인계_v1.md (2026-04-30 오전, Step 6 완료 시점)

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

## 작업지시서 1번 진척 (2026-04-30 오후 기준)

### COMPLETED ✅ (Step 1~7)

- **Step 1 인프라**: price_history.db 백업, hubnet_orders/hubnet_pdf_log 테이블, sales_history에 컬럼 3개(hbl_number, pdf_path, pdf_downloaded_at), labels/ 폴더, settings.json hubnet_* 6개 키, .gitignore 갱신

- **Step 2 로그인**: kream_hubnet_bot.py 신규, 로그인+세션 재사용 OK. auth_state_hubnet.json 정상 (PHPSESSID, 30일 유효)

- **Step 3 조회+저장**: fetch_hubnet_orders, upsert_hubnet_orders. SENSITIVE_KEYS=['consignee','consignee_phone','consignee_address'] frozenset, raw_data에서 제외. size(add38)/wdate 컬럼 추가됨. INSERT OR REPLACE

- **Step 4 매칭**: match_hubnet_to_kream, update_kream_sales_with_hbl, match_all_unmatched. 1차 정확 일치(`order_no=? AND order_status!='cancelled'`). 2차는 # TODO 스텁(raw_data에 KREAM model 없음). 검증: 매칭 가능 4건 100% 매칭, 양방향 정합성 통과

- **Step 5 송장 HTML**: fetch_invoice_html(session, hbl_numbers). jQuery 배열 인코딩(`hbl_numbers[]` 튜플 리스트 ⭐), invoice_data=json.dumps(ensure_ascii=False). RuntimeError 패턴(폴백 금지). 사용자 시각 검증 통과

- **Step 6 HTML→PDF**:
  - B단계 html_to_pdf(): sync_playwright(Q-1A 결정), prefer_css_page_size=True, print_background=True, `<base href>` 정규식 주입. 11.50×16.51cm. 사용자 시각 검증 통과
  - C단계 download_invoice_pdf(): sales_history 조회 → 파일명 `{HBL}_{model}_{size}_{YYYYMMDD}.pdf` → labels/{YYYYMM}/ → 중복 검사 → fetch+pdf → hubnet_pdf_log 기록. F-1~F-7 검증 통과. **F-8 사용자 시각 검증 ✅** (오전 PDF 샘플과 동일, 12:51 KST)

- **Step 7 일괄 다운로드** ⭐ NEW: download_pending_invoices(limit, triggered_by) 구현
  - 시그니처: 인수인계서 v1 기준 (`limit=None, triggered_by='manual'`). 작업지시서 §3.1 원본(`limit=50, triggered_by='scheduler'`)과 다름 — Step 7은 CLI/수동 우선, 스케줄러 호출은 Step 10에서 명시적으로 triggered_by 전달
  - 반환: `{total, success, skipped, matching_failed, failed, errors:[]}`
  - 핵심 결정사항:
    - ORDER BY trade_date DESC, id DESC (최신 판매 우선 처리)
    - 사전 ensure_hubnet_logged_in() 1회 호출, RuntimeError → 즉시 중단 (불필요한 N회 retry 회피)
    - skipped 분기: sales_history.pdf_path가 NULL인 경우만 보정 갱신, 이미 채워졌으면 건드리지 않음 (self-healing 동작)
    - CLI verbose 토글: `if args.verbose and result['errors']` — errors 상세는 -v일 때만 출력
    - 행 단위 try/except 격리 (1건 실패가 batch 전체 멈추지 않음)
  - CLI: `python3 kream_hubnet_bot.py --mode download-pending [--limit N] [-v]`
  - 검증 5종 통과:
    - 검증 1 (기본 동작): total=0 (어제 처리된 4건 모두 채워진 상태)
    - 검증 2 (limit=1): total=1, skipped=1, ORDER BY 효과로 2026-04-28 건이 첫 번째 처리 확인
    - 검증 3 (무제한+멱등성): 3-A total=3 모두 skipped+보정, 3-B 즉시 재실행 → total=0
    - 검증 4 (양방향 정합성): sales_history.pdf_path 4 ↔ hubnet_pdf_log success distinct 4 ↔ labels/*.pdf 실제 파일 4 일치 ✅
    - 검증 5 (보정 케이스): "log success인데 pdf_path NULL"인 인위적 상태에서 `[INFO] skipped 보정: pdf_path 비어있음 → 갱신` 로그 4회 출력되며 모두 채워짐
  - **errors 분기 미검증**: dangerous-command-check hook이 더미 INSERT/DELETE 차단 (의도된 안전장치). 코드 분기 자체는 패치됐으므로 Step 10 스케줄러 자동 실행 후 자연 발생할 실패 케이스로 검증 예정
  - 커밋: `0818a1e feat: 허브넷 봇 Step 7 (download_pending_invoices) + hook 정리`

### PENDING (다음 단계 — Step 8부터)
- **Step 8 API** 6개 (kream_server.py 추가) — 작업지시서 §4.1
  - GET `/api/hubnet/status` — 세션 상태 + 통계
  - POST `/api/hubnet/login` — 수동 재로그인
  - POST `/api/hubnet/sync` — 데이터 수동 조회 (날짜 범위)
  - POST `/api/hubnet/pdf/download` — 특정 HBL PDF 강제 다운로드
  - POST `/api/hubnet/pdf/batch` — pending 일괄 다운로드 트리거 (Step 7 활용)
  - GET `/api/hubnet/pdf/log` — 다운로드 이력 조회 (`?limit=50&status=all`)
  - 모든 응답: `{success, data?, error?}` 표준 (CLAUDE.md `api-addition` SKILL 준수)
- **Step 9 UI** (tab_logistics.html에 허브넷 패널) — 작업지시서 §4.3
- **Step 10 스케줄러** 통합 (판매 수집 직후, hubnet_auto_pdf=false로 시작)

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

### 5. Step 7 self-healing 동작 (NEW)
- skipped 분기에서 sales_history.pdf_path NULL 보정 로직 덕분에, hubnet_pdf_log와 sales_history가 어긋난 상태(이전 작업 중단/실패 시 발생 가능)도 다음 download-pending 실행 시 자동 정합화됨
- 단, 무조건 덮어쓰기는 아님 — 이미 채워진 pdf_path는 보존

## KREAM 비즈니스 규칙 (필수 준수)

- **KREAM은 셀러에게 수취인 정보 제공 안 함** (PDF에도 마스킹: `Consignee: ***`)
- 일본 구매대행 환급 불가 (수취인 외국 거주 증명 불가)
- 시스템에 수취인 컬럼/필드 추가 금지
- consignee/consignee_phone/consignee_address는 raw_data에서도 제외 (SENSITIVE_KEYS frozenset)

## 핵심 기술 결정사항

### Q-1A: sync_playwright 선택 (Step 6)
- 작업지시서 §3.1엔 async def였으나 동기로 변경
- 이유: 모듈 전체 동기 통일(requests/sqlite3), CLI 진입점 간결, sync→async 경계 회피
- 코드 주석에 "Q-1A 결정(2026-04-30): 모듈 일관성을 위해 동기로 작성" 명시됨

### jQuery 배열 인코딩 (Step 5) ⭐
- PHP 백엔드는 `hbl_numbers[]=H1&hbl_numbers[]=H2` 형식만 배열 인식
- Python `requests` 기본 동작은 마지막 값만 받게 됨 → silent 버그
- 튜플 리스트로 명시: `data.append(('hbl_numbers[]', h))`

### ensure_ascii=False (Step 5)
- JSON.stringify와 동일하게 한글 보존
- PDF 변환 시 한글 깨짐 방지

### 페이지 사이즈: HTML CSS 그대로 (Step 6)
- 작업지시서 §3.1엔 A4 + 0.5cm 여백이었으나 11.5×16.5cm로 변경
- 이유: 송장 HTML의 `@page` CSS가 11.5×16.5cm 명시. 라벨 인쇄용이라 정확한 크기 필수
- prefer_css_page_size=True로 CSS 존중

### Step 7 시그니처: 인수인계서 우선 (Step 7) ⭐ NEW
- 작업지시서 §3.1: `download_pending_invoices(triggered_by='scheduler', limit=50)`
- 인수인계서 v1: `download_pending_invoices(limit=None, triggered_by='manual')`
- 인수인계서 기준 채택 — Step 7은 CLI/수동 우선이고, 스케줄러 호출은 Step 10에서 명시적으로 triggered_by='scheduler'를 넘기는 게 더 명확함. Q-1A와 같은 맥락(CLI 진입점 간결)

## 알려진 이슈 (작업과 무관)

### Stop hook 무한루프 (KREAM 측) — 해결됨 ✅
- v1 시점: `.disabled`로 비활성화한 상태였음
- v2 시점: `.claude/hooks/stop-checklist.sh` 삭제 완료, `.claude/settings.json`에서 Stop hook 항목 제거 완료
- Claude Code 종료 시 더이상 "No such file" 에러 안 남
- 무한루프 원인 잡고 다시 살릴 때 settings에 재등록할 예정 (선택 — 진행에는 무관)

### .gitignore의 settings.json 패턴 매치 이슈 (NEW)
- `.gitignore` 6번째 줄 `settings.json` 패턴이 루트 `settings.json`(자격증명 포함)뿐 아니라 `.claude/settings.json`(hook 설정, 공유돼야 함)도 무시함
- 의도: 루트만 무시 / 실제: 두 개 다 무시
- 영향: `.claude/settings.json`은 git에 안 올라감 (Stop hook 제거 변경도 push 안 됨)
- 해결책 (미적용): `.gitignore`의 `settings.json`을 `/settings.json`으로 변경 (루트 한정)
- 우선순위: 낮음 — 보안 위험은 없고, 다른 머신에서 hook 설정 동기화가 안 될 뿐

### SSRO 미해결 이슈 3개 (별도 작업)
1. **perri/lee/jungsn 로그인 실패**: "Database error querying schema". 비밀번호 hash 통일했는데도 안 됨. Auth Log: /token 500 에러 (huli만 200)
2. **페이지 수정 시 일부 탭 사라짐**: CS상담분석/log/통관배송추적
3. **통관검증/국내배송 cron job 자동 실행 안 됨**

→ 이 셋은 KREAM 작업과 별개. 별도 채팅 또는 별도 시간에 처리.

### KREAM 자동 백업 6일째 안 돌고 있음
- last_backup_age 153.9h
- 수동 백업은 잘 되고 있어 지금 문제 없음
- /api/health가 critical로 표시되지만 무시 가능 (이번 작업과 무관)
- 별도 작업지시서 존재: `CLAUDE_CODE_TASK_LASTSALE_HOOK.md` (last_sale 60시간 경과 이슈 진단/수정 + hook 개선) — 미실행

## 파일 구조

```
~/Desktop/kream_automation/
├── kream_hubnet_bot.py              # 메인 봇 (~1300줄, Step 1-7 완료)
├── kream_server.py                   # Flask 서버 (포트 5001) — Step 8에서 수정 예정
├── kream_dashboard.html              # 메인 대시보드
├── price_history.db                  # SQLite (WAL 모드)
├── auth_state_hubnet.json            # 허브넷 세션 (gitignore)
├── auth_state.json, auth_state_kream.json # 기존 KREAM 세션 (gitignore)
├── settings.json                     # 설정 (gitignore)
├── labels/{YYYYMM}/*.pdf             # 송장 PDF 저장 위치 ⭐
├── tabs/                             # 대시보드 탭 (모듈형)
│   └── tab_logistics.html            # 물류 관리 (Step 9에서 허브넷 패널 추가 예정)
├── 작업지시서_1_허브넷봇_PDF자동다운로드_v1.md
├── KREAM_허브넷_SSRO_통합아키텍처_v1.md
├── KREAM_허브넷통합_인수인계_v1.md   # 이전 버전 (Step 6 완료 시점)
├── KREAM_허브넷통합_인수인계_v2.md   # 현재 버전 (Step 7 완료 시점) ⭐
├── KREAM_인수인계서_v5.md            # 기존 KREAM 자동화 인수인계
└── .claude/
    ├── hooks/
    │   ├── syntax-check.sh           # 활성
    │   └── dangerous-command-check.sh # 활성
    └── settings.json                  # Stop hook 제거됨 (.gitignore 매치로 추적 안 됨)
```

## DB 테이블 (이번 작업 관련)

### hubnet_orders (Step 1 신규)
```
id, hbl_number(UNIQUE), order_no, shipper, product_name, quantity, weight,
volume_weight, origin, tracking, delivery_no, work_status, order_status,
raw_data(JSON), fetched_at, matched_kream_order_id, matched_at,
size, wdate
```

### hubnet_pdf_log (Step 1 신규)
```
id, hbl_number, kream_order_id, pdf_path, file_size,
status('success'|'failed'|'skipped'|'matching_failed'),
error_message, duration_ms, triggered_by('manual'|'scheduler'),
created_at
```

### sales_history (Step 1 컬럼 추가)
```
기존 컬럼... + hbl_number, pdf_path, pdf_downloaded_at
```

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

## 다음 작업: Step 8 명세

작업지시서 §4.1 + CLAUDE.md `api-addition` SKILL 준수.

목표: kream_server.py에 허브넷 관련 API 6개 추가.

| 메서드 | 경로 | 설명 | 핵심 동작 |
|---|---|---|---|
| GET | `/api/hubnet/status` | 세션 상태 + 통계 | auth_state_hubnet.json 존재/만료 체크, 오늘 다운로드 통계 |
| POST | `/api/hubnet/login` | 수동 재로그인 | settings.json에서 자격증명 읽어 hubnet_login() 호출 |
| POST | `/api/hubnet/sync` | 데이터 수동 조회 | body: `{start_date, end_date}` → fetch_hubnet_orders + upsert + match |
| POST | `/api/hubnet/pdf/download` | 단건 PDF 강제 다운로드 | body: `{hbl_number, [order_id]}` → download_invoice_pdf() |
| POST | `/api/hubnet/pdf/batch` | pending 일괄 다운로드 | body: `{[limit]}` → download_pending_invoices() |
| GET | `/api/hubnet/pdf/log` | 다운로드 이력 조회 | query: `?limit=50&status=all` → hubnet_pdf_log SELECT |

응답 표준: `{"success": bool, "data": ...} or {"success": false, "error": "..."}`

검증 (Step 8 끝):
- curl로 6개 엔드포인트 모두 호출
- 모든 응답이 표준 JSON 형식
- 에러 케이스 (잘못된 hbl, 만료 세션 등) 적절히 처리
- /api/health 정상 (서버 영향 없음)

## 빠른 참고

### 자주 쓰는 명령어
```bash
# 서버 실행
cd ~/Desktop/kream_automation
python3 kream_server.py

# Claude Code
claude --dangerously-skip-permissions

# 봇 CLI 모드들 (Step 7까지 완료된 시점)
python3 kream_hubnet_bot.py --mode auth -v       # 로그인
python3 kream_hubnet_bot.py --mode fetch --start 2026-04-21 --end 2026-04-28 -v
python3 kream_hubnet_bot.py --mode match -v      # KREAM ↔ 허브넷 매칭
python3 kream_hubnet_bot.py --mode html-test --hbl H2604252301517 -v
python3 kream_hubnet_bot.py --mode pdf-test --hbl H2604252301517 -v
python3 kream_hubnet_bot.py --mode download-pending -v          # 전체 일괄
python3 kream_hubnet_bot.py --mode download-pending --limit 5 -v # 5건만

# DB 확인
sqlite3 price_history.db "SELECT COUNT(*) FROM hubnet_orders;"
sqlite3 price_history.db "SELECT * FROM hubnet_pdf_log ORDER BY id DESC LIMIT 5;"
sqlite3 price_history.db "SELECT order_id, hbl_number, pdf_path FROM sales_history WHERE hbl_number IS NOT NULL;"

# 헬스체크
curl http://localhost:5001/api/health

# git 진척 확인
cd ~/Desktop/kream_automation && git log --oneline -10
```

### 최근 커밋 히스토리
```
0818a1e feat: 허브넷 봇 Step 7 (download_pending_invoices) + hook 정리  ⭐ 최신
0c77c13 feat: 허브넷 봇 Step 6 + 인수인계서 v1
84230d0 feat: 허브넷 봇 Step 6 (HTML→PDF 변환) 구현
a0f3207 feat: 허브넷 봇 Step 1-5 구현 (인프라+로그인+조회+매칭+HTML)
348c9e0 docs: 허브넷 연동 아키텍처 + 작업지시서 1번 추가
```
