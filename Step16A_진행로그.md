# Step 16-A Phase 2 진행 로그

이 파일에 각 Step별로 진행 상황과 검증 결과를 기록한다.

## 사전 백업 ✓
- price_history_backup_step16a_pre.db
- kream_server.py.step16a_pre.bak
- tabs/tab_adjust.html.step16a_pre.bak

## Step 1: bid_cost 스키마 마이그레이션 (cny_source 추가)
- [x] _init_bid_cost_table 함수 수정 (kream_server.py:231-249)
- [x] py_compile 통과
- [x] 서버 재시작
- [x] PRAGMA로 cny_source 컬럼 확인 (cid 9, TEXT)
- [x] 기존 행 'unknown' 마이그레이션 확인 (48건 → unknown)

## Step 2: _save_bid_cost 분기 추가
- [x] 함수 시그니처 변경 (cny_source 파라미터 추가)
- [x] 본문에 manual 우선 + shihuo 자동 채택 로직
- [x] 단일 connection 통합 (락 완화)
- [x] 호출자 4곳 변경 (라인 1513, 4123, 4162, 7280) — auto_rebid는 안정 키 적용
- [x] 호출자 2곳 cny_source='manual' 명시 (라인 5136, 5263)
- [x] py_compile 통과
- [x] 라우트 중복 0건 (130 routes)

## Step 3: shihuo activate/deactivate
- [x] api_shihuo_activate 신설
- [x] api_shihuo_deactivate 신설
- [x] api_shihuo_rollback 별칭으로 위임
- [x] py_compile 통과
- [x] 서버 재시작 + curl 검증 (activate: 45건, rollback alias: 45건)

## Step 4: /api/bid-cost/shihuo-diff
- [x] api_bid_cost_shihuo_diff 신설
- [x] py_compile 통과
- [x] curl 응답 ok=true 확인 (active_batch=shihuo_20260501_121000, count=0)

## Step 5: tab_adjust.html UI 추가
- [x] 라인 32 위치에 카드 + 모달 + JS 삽입
- [x] HTML 문법 체크 (HTMLParser OK)
- [ ] 브라우저 콘솔 에러 0건 (수동 확인 필요)

## Step 6: 회귀 테스트 5개
- [x] 6-1 시나리오 A: 식货 자동 채택 (JQ1501/265 → 337.0 채택, source=shihuo)
- [x] 6-2 시나리오 B: manual + 매칭 실패 스킵 (ZZZ_NOT_EXIST → 매칭 0)
- [x] 6-3 시나리오 C: shihuo-diff API 응답 구조 (count=1, diff_cny=-662.0)
- [x] 6-4 시나리오 D: ONE SIZE 처리 (CAST=0, 매칭 0)
- [x] 6-5 시나리오 E: activate/deactivate (45→0→45)
- [x] 6-6 시나리오 F: auto_rebid 안정 키 (UPSERT로 1행 유지)
- [x] 6-7 테스트 정리 (TEST_ 0건, bid_cost 48건 유지)

## 체크리스트
- [x] py_compile 통과
- [x] 라우트 중복 0 (133 routes)
- [x] /api/health 응답 200
- [x] /api/bid-cost/shihuo-diff JSON 응답 (ok:true, count:0)
- [x] /api/shihuo/activate/<batch_id> 정상
- [x] /api/shihuo/deactivate 정상
- [x] /api/shihuo/rollback/<batch_id> 별칭 동작
- [x] cny_source 컬럼 존재 + 기존 48건 = 'unknown'
- [x] 회귀 테스트 6-1~6-6 모두 통과
- [x] TEST_ 데이터 정리 완료 (bid_cost 48건 유지)
- [x] 백업 파일 보존
