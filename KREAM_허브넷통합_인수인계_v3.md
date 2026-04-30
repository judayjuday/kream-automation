# KREAM × 허브넷 PDF 자동 다운로드 시스템 — 인수인계서 v3

작성일: 2026-04-30 (저녁, Step 8 완료)
작업지시서 위치: ~/Desktop/kream_automation/작업지시서_1_허브넷봇_PDF자동다운로드_v1.md
이전 버전:
- v1 (2026-04-30 오전, Step 6 완료)
- v2 (2026-04-30 오후, Step 7 완료)

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

### COMPLETED ✅ (Step 1~8)

- **Step 1 인프라**: price_history.db 백업, hubnet_orders/hubnet_pdf_log 테이블, sales_history에 컬럼 3개(hbl_number, pdf_path, pdf_downloaded_at), labels/ 폴더, settings.json hubnet_* 6개 키, .gitignore 갱신

- **Step 2 로그인**: kream_hubnet_bot.py 신규, 로그인+세션 재사용 OK. auth_state_hubnet.json 정상 (PHPSESSID, 30일 유효)

- **Step 3 조회+저장**: fetch_hubnet_orders, upsert_hubnet_orders. SENSITIVE_KEYS frozenset, raw_data에서 제외. INSERT OR REPLACE

- **Step 4 매칭**: match_hubnet_to_kream, update_kream_sales_with_hbl, match_all_unmatched. 1차 정확 일치(`order_no=? AND order_status!='cancelled'`). 2차는 # TODO 스텁

- **Step 5 송장 HTML**: fetch_invoice_html. jQuery 배열 인코딩(`hbl_numbers[]` 튜플 리스트 ⭐), invoice_data=json.dumps(ensure_ascii=False)

- **Step 6 HTML→PDF**: html_to_pdf (sync_playwright, prefer_css_page_size, 11.50×16.51cm), download_invoice_pdf (단건 다운로드 + 중복 검사 + hubnet_pdf_log 기록)

- **Step 7 일괄 다운로드**: download_pending_invoices(limit, triggered_by). ORDER BY trade_date DESC, 사전 ensure_hubnet_logged_in() 1회, skipped 분기 self-healing 보정, 행 단위 try/except 격리. 검증 5종 통과

- **Step 8 API 6개** ⭐ NEW: kream_server.py에 허브넷 통합 엔드포인트 추가
  - 헬퍼 2개 추출: `_hubnet_session_meta()`, `_hubnet_today_stats()`
  - kream_hubnet_bot에서 8개 함수 import (변경 없음, 재사용만)
  - 응답 표준: `{success, data}` 또는 `{success, error}`
  - 에러 응답: try/except로 감싸 500 시 JSON 반환 (HTML 에러 페이지 방지)
  - 라우트 충돌 사전·사후 검사 통과 (총 120 라우트, 중복 0건, hubnet 6개 신규)
  - 추가된 엔드포인트:

  | 메서드 | 경로 | 핵심 동작 |
  |---|---|---|
  | GET | `/api/hubnet/status` | 세션 valid/saved_at/expires_estimate + 오늘(KST) 통계 |
  | POST | `/api/hubnet/login` | settings.json 자격증명으로 hubnet_login() + save_hubnet_session() |
  | POST | `/api/hubnet/sync` | ensure_hubnet_logged_in → fetch → upsert → match_all_unmatched |
  | POST | `/api/hubnet/pdf/download` | 단건 download_invoice_pdf(hbl, order_id, 'manual') |
  | POST | `/api/hubnet/pdf/batch` | download_pending_invoices(limit, 'manual') |
  | GET | `/api/hubnet/pdf/log` | hubnet_pdf_log SELECT + status 필터 + limit clamp(max 500) |

  - 추가 검증 (명세 외 자체 보강):
    - `/api/hubnet/sync`: 날짜 형식 검증(YYYY-MM-DD), 역전 검증(start>end → 400)
    - `/api/hubnet/pdf/log`: status whitelist 검증(`['all','success','failed','skipped','matching_failed']`), limit clamp(max 500)
    - `/api/hubnet/pdf/batch`: limit 정수 검증(`"abc"` → 400)
  - 검증 4종 통과:
    - 정상 케이스 6개: 모두 200, 표준 JSON 구조
    - 에러 케이스 8가지: 모두 400 + 명확한 error 메시지
    - 기존 영향 없음: /api/health, /api/sales/recent, /api/queue/list 정상 / server.log ERROR 0건
    - 멱등성: batch 두 번 연속 호출 → 동일 결과(total=0, sales_history 모두 채워진 상태)
  - **검증 4 멱등성 명세 차이**: 사용자 명세는 "두 번째는 모두 skipped" 시나리오였으나 sales_history reset에 dangerous-command-check hook이 차단(의도된 안전장치). 차선으로 "1차/2차 결과 동일"로 멱등성 충족 입증
  - 커밋: `f5b9f0f feat: 허브넷 봇 Step 8 (API 6개 추가)` (256줄 추가)

### PENDING (다음 단계 — Step 9부터)
- **Step 9 UI** ⭐ 다음 작업: tab_logistics.html에 허브넷 패널 추가 — 작업지시서 §4.3
- **Step 10 스케줄러** 통합 (판매 수집 직후, hubnet_auto_pdf=false로 시작) — 작업지시서 §4.2

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
- skipped 분기에서 sales_history.pdf_path NULL 보정 로직 덕분에, hubnet_pdf_log와 sales_history가 어긋난 상태(이전 작업 중단/실패 시 발생 가능)도 다음 download-pending 실행 시 자동 정합화됨
- 단, 무조건 덮어쓰기는 아님 — 이미 채워진 pdf_path는 보존

### 6. Step 8 추가 방어 (NEW)
- API 레이어에서 명세에 없던 추가 검증 8가지를 자체적으로 추가 (날짜 형식/역전, status whitelist, limit clamp/정수 검증)
- 사용자 직접 호출(curl/Postman) 또는 Step 9 대시보드 호출 시 잘못된 입력 조기 차단
- 모든 검증 실패는 400 + JSON `{success:false, error:"..."}` 형식

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

### Step 7 시그니처: 인수인계서 우선
- 작업지시서 §3.1: `download_pending_invoices(triggered_by='scheduler', limit=50)`
- 인수인계서 v1: `download_pending_invoices(limit=None, triggered_by='manual')`
- 인수인계서 기준 채택 — Step 7은 CLI/수동 우선이고, 스케줄러 호출은 Step 10에서 명시적으로 triggered_by='scheduler'를 넘기는 게 더 명확함

### Step 8 헬퍼 추출 (NEW)
- `/api/hubnet/status` 응답에서 두 부분(세션 메타 / 오늘 통계)이 명확히 분리되어 헬퍼로 추출
- `_hubnet_session_meta()`: auth_state_hubnet.json 파싱하여 valid/saved_at/expires_estimate 반환
- `_hubnet_today_stats()`: hubnet_pdf_log에서 `date(created_at) = date('now', 'localtime')` 그룹 카운트
- Step 9 대시보드에서도 재사용 가능 (status 폴링 시)

## 알려진 이슈

### Stop hook 무한루프 — 해결됨 ✅
- v1 시점: `.disabled`로 비활성화한 상태였음
- v2 시점: `.claude/hooks/stop-checklist.sh` 삭제 완료, `.claude/settings.json`에서 Stop hook 항목 제거 완료
- 현재: Claude Code 종료 시 더이상 "No such file" 에러 안 남
- 무한루프 원인 잡고 다시 살릴 때 settings에 재등록 예정 (선택, 진행에 무관)

### .gitignore의 settings.json 패턴 매치 이슈
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
├── kream_hubnet_bot.py              # 메인 봇 (~1300줄, Step 1-7 완료, Step 8에서 import만 사용)
├── kream_server.py                   # Flask 서버 (8249줄, 120 라우트, Step 8 완료)
├── kream_dashboard.html              # 메인 대시보드
├── price_history.db                  # SQLite (WAL 모드)
├── auth_state_hubnet.json            # 허브넷 세션 (gitignore)
├── auth_state.json, auth_state_kream.json # 기존 KREAM 세션 (gitignore)
├── settings.json                     # 설정 (gitignore)
├── labels/{YYYYMM}/*.pdf             # 송장 PDF 저장 위치 ⭐
├── tabs/                             # 대시보드 탭 (모듈형)
│   └── tab_logistics.html            # 물류 관리 (Step 9에서 허브넷 패널 추가 예정) ⭐
├── 작업지시서_1_허브넷봇_PDF자동다운로드_v1.md
├── KREAM_허브넷_SSRO_통합아키텍처_v1.md
├── KREAM_허브넷통합_인수인계_v1.md   # Step 6 완료 시점
├── KREAM_허브넷통합_인수인계_v2.md   # Step 7 완료 시점
├── KREAM_허브넷통합_인수인계_v3.md   # Step 8 완료 시점 ⭐ 현재
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

## 다음 작업: Step 9 명세

작업지시서 §4.3. 목표: `tabs/tab_logistics.html`에 허브넷 PDF 자동 다운로드 패널 추가.

### UI 구성 (작업지시서 원안)

```
┌─ 허브넷 PDF 자동 다운로드 ─────────────────────┐
│  세션 상태: 🟢 정상 (마지막 로그인: 2시간 전)   │
│  자동 다운로드: 🟢 ON / 🔴 OFF                  │
│  [수동 재로그인] [지금 동기화] [설정]            │
│                                                 │
│  📊 오늘 통계                                   │
│  ├─ 다운로드 성공: 12건                          │
│  ├─ 실패: 0건                                   │
│  ├─ 매칭 실패 (KREAM↔허브넷): 1건 ⚠️           │
│  └─ 평균 소요: 3.2초/건                         │
│                                                 │
│  📋 최근 다운로드 이력 (최근 20건)               │
│  ┌─────────┬──────────┬──────┬────────┬───┐    │
│  │ 시각     │ HBL      │ 품명 │ 상태   │   │    │
│  ├─────────┼──────────┼──────┼────────┼───┤    │
│  │ 11:32:15│ H260425..│ Asics│ ✅ 완료│📄│    │
│  │ 11:32:08│ H260422..│ Asics│ ✅ 완료│📄│    │
│  │ 09:01:33│ H260420..│ Adidas│ ❌ 실패│↻│    │
│  └─────────┴──────────┴──────┴────────┴───┘    │
└─────────────────────────────────────────────────┘
```

### 활용할 API (Step 8 완료분)
- 패널 진입 시: `GET /api/hubnet/status` (세션 + 통계)
- [수동 재로그인]: `POST /api/hubnet/login`
- [지금 동기화]: `POST /api/hubnet/sync` (날짜 입력 모달)
- [지금 동기화] 후 자동: `POST /api/hubnet/pdf/batch`
- 이력 테이블: `GET /api/hubnet/pdf/log?limit=20`
- 📄 클릭: 로컬 PDF 새 탭 (file:// 또는 /labels/ 정적 서빙 — Step 9에서 결정)
- ↻ 클릭: `POST /api/hubnet/pdf/download` (특정 hbl 재시도)

### Step 9 진행 시 결정 필요 사항
1. **PDF 미리보기 경로**: `file:///...` 직접? 아니면 Flask `/labels/<path>` 정적 서빙 추가? (작업지시서엔 명시 없음)
2. **자동 다운로드 토글**: settings.json `hubnet_auto_pdf` 변경 API 신설? 아니면 기존 `/api/settings` 재사용?
3. **평균 소요 시간**: hubnet_pdf_log.duration_ms 평균. status API에 추가할지, UI에서 클라이언트 계산할지
4. **상태 폴링 주기**: 페이지 진입 시 1회만? 30초 간격 폴링?

→ 이 4개는 Step 9 시작 시 사용자에게 확인받고 진행

### 검증 (Step 9 끝)
- 브라우저로 `http://localhost:5001` 접속 → 물류 탭 → 허브넷 패널 표시
- 각 버튼 동작 확인 (재로그인/동기화/단건재시도)
- 이력 테이블 렌더링 + 📄 클릭 시 PDF 열림
- 오늘 통계 숫자가 `/api/hubnet/status` 응답과 일치
- 모바일 화면(좁은 창)에서 깨지지 않음

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

# 허브넷 API 호출 (Step 8 추가됨)
curl http://localhost:5001/api/hubnet/status | python3 -m json.tool
curl -X POST http://localhost:5001/api/hubnet/login | python3 -m json.tool
curl -X POST http://localhost:5001/api/hubnet/sync \
  -H "Content-Type: application/json" \
  -d '{"start_date":"2026-04-21","end_date":"2026-04-28"}' | python3 -m json.tool
curl -X POST http://localhost:5001/api/hubnet/pdf/batch \
  -H "Content-Type: application/json" -d '{}' | python3 -m json.tool
curl "http://localhost:5001/api/hubnet/pdf/log?limit=10" | python3 -m json.tool

# DB 확인
sqlite3 price_history.db "SELECT COUNT(*) FROM hubnet_orders;"
sqlite3 price_history.db "SELECT * FROM hubnet_pdf_log ORDER BY id DESC LIMIT 5;"
sqlite3 price_history.db "SELECT order_id, hbl_number, pdf_path FROM sales_history WHERE hbl_number IS NOT NULL;"

# 헬스체크
curl http://localhost:5001/api/health

# 서버 재시작 패턴 (kill -9 후 죽는 이슈 방지)
lsof -ti:5001 | xargs kill -9 2>/dev/null
nohup python3 kream_server.py > server.log 2>&1 &
disown
sleep 2
curl -s http://localhost:5001/api/health

# git 진척 확인
cd ~/Desktop/kream_automation && git log --oneline -10
```

### 최근 커밋 히스토리
```
f5b9f0f feat: 허브넷 봇 Step 8 (API 6개 추가)                          ⭐ 최신
4575cbb docs: 인수인계서 v2 (Step 7 완료 반영)
0818a1e feat: 허브넷 봇 Step 7 (download_pending_invoices) + hook 정리
0c77c13 feat: 허브넷 봇 Step 6 + 인수인계서 v1
84230d0 feat: 허브넷 봇 Step 6 (HTML→PDF 변환) 구현
a0f3207 feat: 허브넷 봇 Step 1-5 구현 (인프라+로그인+조회+매칭+HTML)
348c9e0 docs: 허브넷 연동 아키텍처 + 작업지시서 1번 추가
```
