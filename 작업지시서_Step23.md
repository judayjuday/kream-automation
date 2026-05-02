# 작업지시서 — Step 23: 데이터 정합성 복구

> 환경: macbook_overseas (kream.co.kr 차단, partner 정상)
> 비즈니스: 구매대행
> 절대 규칙 (CLAUDE.md) + 자동 토글 ON 변경 금지

## 진단 결과 (2026-05-02 19:19)

1. **sync 0건 반환** — 태스크 success인데 bids 빈 배열
   - 판매자센터에 진짜 입찰 없거나
   - 페이지 구조 변경으로 셀렉터 안 잡힘
   
2. **bid_cost 48건 ↔ sales_history 8건 매칭 0건**
   - 판매 8건은 옛날 입찰 (bid_cost 도입 전)
   - bid_cost 48건은 최근 신규 입찰
   - order_id 시기 자체가 다름

## 작업 #1: sync 진단 라우트 (페이지 덤프)

### 신규 라우트: /api/diagnostics/sync-page-dump

```python
@app.route('/api/diagnostics/sync-page-dump', methods=['POST'])
def api_sync_page_dump():
    """판매자센터 입찰 페이지를 직접 열어서 HTML + 스크린샷 저장.
    sync가 0건 반환할 때 페이지 상태를 사장이 직접 확인."""
    try:
        import asyncio
        from pathlib import Path
        from datetime import datetime
        
        ts = datetime.now().strftime('%Y%m%d_%H%M%S')
        dump_dir = Path(__file__).parent / 'diagnostics'
        dump_dir.mkdir(exist_ok=True)
        
        html_path = dump_dir / f'sync_page_{ts}.html'
        png_path = dump_dir / f'sync_page_{ts}.png'
        
        async def dump():
            from playwright.async_api import async_playwright
            from kream_bot import create_browser, create_context, ensure_logged_in, dismiss_popups
            
            async with async_playwright() as p:
                browser = await create_browser(p, headless=True)
                context = await create_context(browser, storage='auth_state.json')
                page = await context.new_page()
                
                # 입찰 페이지 직접 이동
                await page.goto('https://partner.kream.co.kr/c2c/sell/bid', wait_until='domcontentloaded', timeout=30000)
                await page.wait_for_timeout(3000)
                
                # 로그인 상태 확인
                logged_in = await ensure_logged_in(page, context)
                
                # 팝업 닫기
                try:
                    await dismiss_popups(page)
                except: pass
                
                await page.wait_for_timeout(2000)
                
                # HTML 덤프
                html = await page.content()
                html_path.write_text(html, encoding='utf-8')
                
                # 스크린샷
                await page.screenshot(path=str(png_path), full_page=True)
                
                # 페이지 내 입찰 카운트 추출 시도 (여러 셀렉터 fallback)
                count_info = {}
                for selector_desc, selector in [
                    ('table_rows', 'table tbody tr'),
                    ('list_items', '.bid-item, .list-item, [class*="bid"]'),
                    ('total_text', '[class*="total"], [class*="count"]'),
                ]:
                    try:
                        elements = await page.query_selector_all(selector)
                        count_info[selector_desc] = len(elements)
                    except: 
                        count_info[selector_desc] = -1
                
                # URL 확인 (리다이렉트됐는지)
                final_url = page.url
                title = await page.title()
                
                await browser.close()
                
                return {
                    'logged_in': logged_in,
                    'final_url': final_url,
                    'title': title,
                    'count_info': count_info,
                    'html_size': len(html),
                }
        
        result = asyncio.run(dump())
        
        return jsonify({
            'ok': True,
            'timestamp': ts,
            'html_path': str(html_path),
            'screenshot_path': str(png_path),
            **result,
            'note': '스크린샷 + HTML 저장됨. 직접 열어서 입찰 보이는지 확인'
        })
    except Exception as e:
        import traceback
        return jsonify({'ok': False, 'error': str(e), 'trace': traceback.format_exc()}), 500
```

## 작업 #2: bid_cost 매칭 키 보강

### 신규 라우트: /api/real-margin (강화 버전)

기존 /api/real-margin이 있으면, fuzzy 매칭 추가하여 fallback 마진 계산.

기존 함수 안에서 매칭 로직 강화:

```python
# 기존 코드의 c.execute("SELECT s.order_id ... LEFT JOIN bid_cost b ON s.order_id = b.order_id ...") 
# 이 부분 다음에 fuzzy 매칭 추가:

# 1차: order_id exact 매칭 (기존)
# 2차: model + size 매칭 (fuzzy)
# 3차: model 평균 (last resort)

# 기존 처리 후, unmatched(confirmed=False)인 건들에 대해 추가 매칭 시도
fuzzy_matched_count = 0

for item in items:
    if not item.get('confirmed'):
        # model + size로 bid_cost 검색 (가장 최근 또는 평균)
        c.execute("""
            SELECT AVG(cny_price), AVG(exchange_rate), AVG(COALESCE(overseas_shipping, ?))
            FROM bid_cost
            WHERE model = ? AND (size = ? OR size = ?)
        """, (overseas_ship_default, item['model'], item.get('size'), 'ONE SIZE' if not item.get('size') else item.get('size')))
        row = c.fetchone()
        
        if row and row[0] is not None:
            cny, fx, ship = row
            est_cost = float(cny) * float(fx) * 1.03 + float(ship)
            settlement = item['sale_price'] * (1 - fee_rate * 1.1) - fixed_fee
            est_margin = settlement - est_cost
            item['cost'] = round(est_cost)
            item['margin'] = round(est_margin)
            item['confirmed'] = False  # 추정값임을 명시
            item['estimation_source'] = 'fuzzy_model_size'
            fuzzy_matched_count += 1
        else:
            # 3차: model만으로
            c.execute("""
                SELECT AVG(cny_price), AVG(exchange_rate), AVG(COALESCE(overseas_shipping, ?))
                FROM bid_cost
                WHERE model = ?
            """, (overseas_ship_default, item['model']))
            row2 = c.fetchone()
            if row2 and row2[0] is not None:
                cny, fx, ship = row2
                est_cost = float(cny) * float(fx) * 1.03 + float(ship)
                settlement = item['sale_price'] * (1 - fee_rate * 1.1) - fixed_fee
                est_margin = settlement - est_cost
                item['cost'] = round(est_cost)
                item['margin'] = round(est_margin)
                item['estimation_source'] = 'fuzzy_model_only'
                fuzzy_matched_count += 1

# 응답에 추가:
# 'estimated': {'count': fuzzy_matched_count, 'note': 'model+size 또는 model 평균치로 추정'}
```

기존 confirmed/unknown_cost 분류 유지하되, 새로운 estimated 카테고리 추가.

## 작업 #3: sync 0건 자동 경고

기존 my_bids_sync_monitor 스케줄러 또는 sync 결과 처리 부분에 추가:

```python
def _check_sync_health():
    """sync 결과가 0건이면 알림."""
    try:
        from pathlib import Path
        local_path = Path(__file__).parent / 'my_bids_local.json'
        if not local_path.exists():
            return
        
        local = json.loads(local_path.read_text(encoding='utf-8'))
        bids_count = len(local.get('bids', []))
        last_sync = local.get('last_sync') or local.get('updated_at')
        
        # 마지막 sync가 최근 1시간 이내인데 0건이면 경고
        if bids_count == 0:
            from datetime import datetime, timedelta
            try:
                if last_sync:
                    last_sync_dt = datetime.strptime(last_sync, '%Y/%m/%d %H:%M') if '/' in last_sync else datetime.fromisoformat(last_sync)
                    if datetime.now() - last_sync_dt < timedelta(hours=1):
                        # 최근 sync인데 0건 = 비정상
                        try:
                            safe_send_alert(
                                subject='[KREAM] sync 0건 경고',
                                body=f'판매자센터 sync 결과 0건. 페이지 파싱 깨졌을 가능성.\n\n/api/diagnostics/sync-page-dump 호출하여 확인 필요.',
                                alert_type='sync_zero'
                            )
                        except: pass
            except Exception:
                pass
    except Exception:
        pass
```

기존 scheduler에 추가:

```python
try:
    scheduler.add_job(
        _check_sync_health,
        'interval', minutes=35,  # sync 후 5분 후
        id='sync_health_check',
        replace_existing=True,
        misfire_grace_time=300
    )
    print("[SCHEDULER] sync_health_check 등록 (35분 간격)")
except Exception as e:
    print(f"[SCHEDULER] sync_health_check 등록 실패: {e}")
```

## 작업 #4: 진단 페이지 (대시보드)

### 신규 라우트: /api/diagnostics/list-dumps

```python
@app.route('/api/diagnostics/list-dumps', methods=['GET'])
def api_diagnostics_list_dumps():
    """저장된 진단 덤프 목록."""
    try:
        from pathlib import Path
        dump_dir = Path(__file__).parent / 'diagnostics'
        if not dump_dir.exists():
            return jsonify({'ok': True, 'dumps': []})
        
        dumps = []
        for f in sorted(dump_dir.glob('sync_page_*.png'), reverse=True)[:20]:
            html_f = f.with_suffix('.html')
            dumps.append({
                'timestamp': f.stem.replace('sync_page_', ''),
                'screenshot': f.name,
                'html': html_f.name if html_f.exists() else None,
                'size_mb': round(f.stat().st_size / 1024 / 1024, 2),
            })
        
        return jsonify({'ok': True, 'dumps': dumps})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


# 정적 파일 서빙용
@app.route('/diagnostics/<path:filename>', methods=['GET'])
def serve_diagnostics(filename):
    """진단 파일 (스크린샷, HTML) 직접 접근."""
    from pathlib import Path
    from flask import send_from_directory
    dump_dir = Path(__file__).parent / 'diagnostics'
    return send_from_directory(str(dump_dir), filename)
```

## 검증

1. python3 -m py_compile kream_server.py → 0
2. 서버 재시작
3. /api/diagnostics/list-dumps → ok=true (빈 배열이라도 OK)
4. /api/real-margin?days=30 → 응답에 estimated 또는 confirmed 정보 (구조 변경 OK, 매칭 보강)
5. /api/diagnostics/sync-page-dump POST → 비동기로 실행되므로 결과는 시간 걸림
   - 첫 호출만 검증: 응답 ok=true, html_path/screenshot_path 키 존재 여부
6. 회귀: capital-status, daily-summary, cleanup/diagnose, conversion-rate

## 절대 규칙
- sync 동작 자체 변경 금지 (진단만 추가)
- 기존 라우트 시그니처 변경 금지 (real-margin은 응답에 키 추가만)
- DB 스키마 변경 금지

## 커밋 메시지
```
feat(Step 23): 데이터 정합성 복구

- /api/diagnostics/sync-page-dump: 판매자센터 페이지 직접 캡처
  HTML + 스크린샷 저장 (sync 0건 시 진단)
- /api/diagnostics/list-dumps + /diagnostics/<file> 서빙
- /api/real-margin 매칭 보강:
  1차 order_id exact, 2차 model+size fuzzy, 3차 model 평균
  estimated 분류 추가
- _check_sync_health 스케줄러: sync 0건 자동 경고

배경: sync 0건 반환 + bid_cost 시기 미스매치 진단/복구
```
