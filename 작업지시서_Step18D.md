# 작업지시서 — Step 18-D: 일일 자동화 + 운영 가시성 4건

> 의존: Step 18-C (커밋 4178a5b)
> 환경: macbook_overseas
> 절대 규칙 (CLAUDE.md) 모두 준수
> 자동화 토글 ON 변경 금지 (자동입찰/조정/재입찰/정리/PDF 모두 OFF 유지)

## 작업 #1: 작업 일지 자동 저장 스케줄러

### kream_server.py 수정

기존 APScheduler 또는 스케줄러 등록 부분 찾아서 작업 추가.
이미 같은 job_id가 있으면 add_job 시 replace_existing=True 사용.

```python
def _schedule_daily_log_save():
    """매일 23:55에 어제 일지를 daily_log/YYYY-MM-DD.md로 저장."""
    try:
        from datetime import datetime
        from pathlib import Path
        
        today = datetime.now().strftime('%Y-%m-%d')
        # _api_daily_log 함수 직접 호출
        with app.app_context():
            result = _api_daily_log(today)
            if hasattr(result, 'get_json'):
                data = result.get_json()
            else:
                data = json.loads(result.data) if hasattr(result, 'data') else result
        
        if data.get('ok'):
            log_dir = Path(__file__).parent / 'daily_log'
            log_dir.mkdir(exist_ok=True)
            log_path = log_dir / f'{today}.md'
            log_path.write_text(data['markdown'], encoding='utf-8')
            print(f"[DAILY-LOG] 저장 완료: {log_path}")
        else:
            print(f"[DAILY-LOG] 생성 실패: {data.get('error')}")
    except Exception as e:
        print(f"[DAILY-LOG] 스케줄러 에러: {e}")
        import sys; sys.stderr.write(f"daily-log scheduler error: {e}\n")

# 스케줄러 등록 (기존 scheduler 변수 활용)
# 매일 23:55 KST
try:
    scheduler.add_job(
        _schedule_daily_log_save,
        'cron',
        hour=23, minute=55,
        id='daily_log_save',
        replace_existing=True,
        misfire_grace_time=600
    )
    print("[SCHEDULER] daily_log_save 등록 (매일 23:55)")
except Exception as e:
    print(f"[SCHEDULER] daily_log_save 등록 실패: {e}")
```

scheduler 변수가 정확히 어떤 이름인지(보통 `scheduler` 또는 `bg_scheduler` 등) 코드에서 찾아서 사용.

## 작업 #2: 내 입찰 자동 동기화 + rank 변동 알림

기존 모니터링/판매수집 스케줄러 같은 패턴으로 추가:

```python
# 이전 sync 결과 캐시 (rank 변동 비교용)
_last_rank_snapshot = {}

def _schedule_my_bids_sync_with_alert():
    """30분마다 내 입찰 sync + rank 변동 감지."""
    global _last_rank_snapshot
    try:
        from pathlib import Path
        # 1. sync 트리거 (백그라운드 task)
        # 직접 KREAM에 안 가고, 기존 my-bids/sync 라우트가 하는 일을 재활용
        # 단, 서버 자기 자신을 호출하지 않고 직접 함수 호출 권장
        # 만약 sync 함수가 별도 정의되지 않았다면 requests로 자기 호출
        try:
            import requests as rq
            sync_resp = rq.post('http://localhost:5001/api/my-bids/sync', timeout=120)
            sync_data = sync_resp.json() if sync_resp.status_code == 200 else {}
            sync_task_id = sync_data.get('taskId') or sync_data.get('task_id')
            
            # task 완료 대기 (최대 60초)
            if sync_task_id:
                import time
                for _ in range(20):
                    time.sleep(3)
                    task_resp = rq.get(f'http://localhost:5001/api/task/{sync_task_id}', timeout=5)
                    if task_resp.status_code == 200:
                        status = task_resp.json().get('status')
                        if status in ('done', 'completed', 'success'):
                            break
                        if status in ('failed', 'error'):
                            print(f"[BIDS-MONITOR] sync 실패")
                            return
        except Exception as e:
            print(f"[BIDS-MONITOR] sync 호출 에러: {e}")
            return
        
        # 2. 현재 rank 상태 읽기
        local_path = Path(__file__).parent / 'my_bids_local.json'
        if not local_path.exists():
            return
        local = json.loads(local_path.read_text(encoding='utf-8'))
        bids = local.get('bids', [])
        
        # order_id → rank 맵
        current = {b.get('orderId'): b.get('rank') for b in bids if b.get('orderId')}
        
        # 3. 직전 스냅샷과 비교 (1순위 → 다른 순위로 떨어진 건만)
        dropped = []
        for oid, rank in current.items():
            prev = _last_rank_snapshot.get(oid)
            if prev == 1 and rank and rank > 1:
                # 해당 입찰 정보 찾기
                bid_info = next((b for b in bids if b.get('orderId') == oid), {})
                dropped.append({
                    'orderId': oid,
                    'model': bid_info.get('model', '-'),
                    'size': bid_info.get('size', '-'),
                    'price': bid_info.get('price'),
                    'old_rank': prev,
                    'new_rank': rank,
                })
        
        # 4. dropped 건 있으면 알림
        if dropped:
            try:
                lines = [f"- {d['model']} {d['size']} {d.get('price','-')}원: rank 1 → {d['new_rank']}" for d in dropped]
                body = f"내 입찰 중 {len(dropped)}건이 1위에서 밀렸습니다.\n\n" + "\n".join(lines)
                # safe_send_alert 있으면 사용, 없으면 print
                try:
                    safe_send_alert(
                        subject=f"[KREAM] 입찰 순위 변동 {len(dropped)}건",
                        body=body,
                        alert_type='rank_drop'
                    )
                except NameError:
                    print(f"[BIDS-MONITOR] {body}")
            except Exception as e:
                print(f"[BIDS-MONITOR] 알림 에러: {e}")
        
        # 5. 스냅샷 업데이트
        _last_rank_snapshot = current
        print(f"[BIDS-MONITOR] sync 완료: {len(bids)}건, dropped {len(dropped)}")
    except Exception as e:
        print(f"[BIDS-MONITOR] 에러: {e}")

try:
    scheduler.add_job(
        _schedule_my_bids_sync_with_alert,
        'interval',
        minutes=30,
        id='my_bids_sync_monitor',
        replace_existing=True,
        misfire_grace_time=300
    )
    print("[SCHEDULER] my_bids_sync_monitor 등록 (30분 간격)")
except Exception as e:
    print(f"[SCHEDULER] my_bids_sync_monitor 등록 실패: {e}")
```

### 토글 라우트 (안전을 위해 OFF 가능)

```python
@app.route('/api/scheduler/bids-monitor/toggle', methods=['POST'])
def api_bids_monitor_toggle():
    data = request.get_json() or {}
    enabled = data.get('enabled', True)
    try:
        if enabled:
            try:
                scheduler.resume_job('my_bids_sync_monitor')
                return jsonify({'ok': True, 'enabled': True})
            except:
                # job 없으면 등록
                scheduler.add_job(
                    _schedule_my_bids_sync_with_alert,
                    'interval', minutes=30,
                    id='my_bids_sync_monitor',
                    replace_existing=True
                )
                return jsonify({'ok': True, 'enabled': True, 'created': True})
        else:
            scheduler.pause_job('my_bids_sync_monitor')
            return jsonify({'ok': True, 'enabled': False})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500
```

## 작업 #3: 주간 리포트 API

### 신규 라우트

```python
@app.route('/api/weekly-report', methods=['GET'])
def api_weekly_report():
    """지난 7일 종합 리포트 (마크다운)."""
    try:
        from datetime import datetime, timedelta
        end = datetime.now()
        start = end - timedelta(days=7)
        start_str = start.strftime('%Y-%m-%d')
        end_str = end.strftime('%Y-%m-%d')
        
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        
        # 입찰
        c.execute("""
            SELECT COUNT(*), SUM(expected_profit) FROM price_adjustments
            WHERE DATE(executed_at) BETWEEN ? AND ? AND status='executed'
        """, (start_str, end_str))
        bid_row = c.fetchone()
        
        # 자동 조정
        c.execute("""
            SELECT COUNT(*) FROM auto_adjust_log
            WHERE DATE(executed_at) BETWEEN ? AND ?
        """, (start_str, end_str))
        adjust_count = c.fetchone()[0] or 0
        
        # 판매
        c.execute("""
            SELECT COUNT(*), SUM(sale_price) FROM sales_history
            WHERE DATE(trade_date) BETWEEN ? AND ?
        """, (start_str, end_str))
        sales_row = c.fetchone()
        
        # 일별 매출
        c.execute("""
            SELECT DATE(trade_date), COUNT(*), SUM(sale_price)
            FROM sales_history
            WHERE DATE(trade_date) BETWEEN ? AND ?
            GROUP BY DATE(trade_date) ORDER BY DATE(trade_date)
        """, (start_str, end_str))
        daily = c.fetchall()
        
        # 모델 TOP 5
        c.execute("""
            SELECT model, COUNT(*), SUM(sale_price)
            FROM sales_history
            WHERE DATE(trade_date) BETWEEN ? AND ?
            GROUP BY model ORDER BY COUNT(*) DESC LIMIT 5
        """, (start_str, end_str))
        top_models = c.fetchall()
        
        # 인증 실패
        try:
            c.execute("""
                SELECT COUNT(*) FROM notifications
                WHERE type='auth_failure' AND DATE(created_at) BETWEEN ? AND ?
            """, (start_str, end_str))
            auth_fails = c.fetchone()[0] or 0
        except:
            auth_fails = 0
        
        conn.close()
        
        # 마크다운 생성
        md = f"# 주간 리포트 — {start_str} ~ {end_str}\n\n"
        md += "## 📊 요약\n\n"
        md += f"- 입찰 실행: **{bid_row[0] or 0}건**\n"
        md += f"- 자동 가격조정: **{adjust_count}건**\n"
        md += f"- 판매 체결: **{sales_row[0] or 0}건** ({(sales_row[1] or 0):,}원)\n"
        md += f"- 인증 실패: **{auth_fails}건**\n\n"
        
        if daily:
            md += "## 📈 일별 매출\n\n| 날짜 | 건수 | 매출 |\n|---|---|---|\n"
            for d in daily:
                md += f"| {d[0]} | {d[1]} | {(d[2] or 0):,}원 |\n"
            md += "\n"
        
        if top_models:
            md += "## 🏆 모델 TOP 5\n\n| 모델 | 건수 | 매출 |\n|---|---|---|\n"
            for m in top_models:
                md += f"| {m[0]} | {m[1]} | {(m[2] or 0):,}원 |\n"
            md += "\n"
        
        if not (daily or top_models):
            md += "_지난 7일 판매 데이터 없음_\n"
        
        return jsonify({
            'ok': True,
            'period': {'start': start_str, 'end': end_str},
            'summary': {
                'bids_executed': bid_row[0] or 0,
                'adjustments': adjust_count,
                'sales_count': sales_row[0] or 0,
                'sales_revenue': sales_row[1] or 0,
                'auth_failures': auth_fails,
            },
            'markdown': md
        })
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.route('/api/weekly-report/save', methods=['POST'])
def api_weekly_report_save():
    """주간 리포트를 weekly_report/YYYY-WW.md로 저장."""
    try:
        from pathlib import Path
        from datetime import datetime
        result = api_weekly_report()
        if hasattr(result, 'get_json'):
            data = result.get_json()
        else:
            data = json.loads(result.data) if hasattr(result, 'data') else result
        if not data.get('ok'):
            return jsonify({'ok': False, 'error': 'report generation failed'}), 500
        
        now = datetime.now()
        week = now.isocalendar()[1]
        filename = f"{now.year}-W{week:02d}.md"
        rep_dir = Path(__file__).parent / 'weekly_report'
        rep_dir.mkdir(exist_ok=True)
        rep_path = rep_dir / filename
        rep_path.write_text(data['markdown'], encoding='utf-8')
        
        return jsonify({'ok': True, 'saved_to': str(rep_path), 'filename': filename})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


# 매주 월요일 0:05에 자동 저장
def _schedule_weekly_report_save():
    try:
        with app.app_context():
            r = api_weekly_report_save()
        print(f"[WEEKLY-REPORT] 자동 저장 트리거")
    except Exception as e:
        print(f"[WEEKLY-REPORT] 에러: {e}")

try:
    scheduler.add_job(
        _schedule_weekly_report_save,
        'cron',
        day_of_week='mon', hour=0, minute=5,
        id='weekly_report_save',
        replace_existing=True,
        misfire_grace_time=3600
    )
    print("[SCHEDULER] weekly_report_save 등록 (매주 월 0:05)")
except Exception as e:
    print(f"[SCHEDULER] weekly_report_save 등록 실패: {e}")
```

## 작업 #4: 시스템 상태 종합 페이지

### 신규 라우트: /admin/status (HTML)

```python
@app.route('/admin/status', methods=['GET'])
def admin_status_page():
    """시스템 상태 종합 페이지 (HTML 직접 렌더)."""
    try:
        from pathlib import Path
        from datetime import datetime
        
        # 헬스 정보
        settings_path = Path(__file__).parent / 'settings.json'
        try:
            settings = json.loads(settings_path.read_text(encoding='utf-8'))
        except:
            settings = {}
        
        # 인증 파일 정보
        auth_files = {}
        for name in ['auth_state.json', 'auth_state_kream.json']:
            p = Path(__file__).parent / name
            if p.exists():
                mtime = datetime.fromtimestamp(p.stat().st_mtime)
                age_h = (datetime.now() - mtime).total_seconds() / 3600
                auth_files[name] = {
                    'exists': True,
                    'modified': mtime.strftime('%Y-%m-%d %H:%M'),
                    'age_hours': round(age_h, 1)
                }
            else:
                auth_files[name] = {'exists': False}
        
        # 스케줄러 상태
        scheduler_jobs = []
        try:
            for job in scheduler.get_jobs():
                scheduler_jobs.append({
                    'id': job.id,
                    'next_run': str(job.next_run_time) if job.next_run_time else 'paused',
                })
        except:
            pass
        
        # DB 통계
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("SELECT COUNT(*) FROM price_adjustments WHERE status='pending'")
        pa_pending = c.fetchone()[0] or 0
        c.execute("SELECT COUNT(*) FROM sales_history")
        sales_total = c.fetchone()[0] or 0
        c.execute("SELECT MAX(trade_date) FROM sales_history")
        last_sale = c.fetchone()[0] or '-'
        conn.close()
        
        # 자동 토글 6종 상태
        toggles = {
            '자동 입찰': settings.get('auto_bid_enabled', False),
            '자동 가격조정': settings.get('auto_adjust_enabled', False),
            '자동 재입찰': settings.get('auto_rebid_enabled', False),
            '자동 정리': settings.get('auto_cleanup_enabled', False),
            '허브넷 자동 PDF': settings.get('hubnet_auto_pdf_enabled', False),
            '사전 갱신': settings.get('session_refresh_enabled', True),
        }
        
        env = settings.get('environment', 'unknown')
        env_detail = settings.get('env_detection_detail', '-')
        
        # HTML 렌더
        html = f'''<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="UTF-8">
<title>시스템 상태 — KREAM 자동화</title>
<style>
body{{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#f9fafb;margin:0;padding:24px;color:#111}}
.container{{max-width:1100px;margin:0 auto}}
h1{{margin:0 0 24px 0}}
.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:16px;margin-bottom:24px}}
.card{{background:#fff;border:1px solid #e5e7eb;border-radius:8px;padding:16px}}
.card h2{{margin:0 0 12px 0;font-size:15px;color:#374151}}
.row{{display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid #f3f4f6;font-size:13px}}
.row:last-child{{border:none}}
.k{{color:#6b7280}}
.v{{font-weight:600}}
.ok{{color:#059669}}
.warn{{color:#d97706}}
.err{{color:#dc2626}}
.muted{{color:#9ca3af}}
.refresh{{padding:6px 14px;background:#2563eb;color:#fff;border:none;border-radius:6px;cursor:pointer;font-size:13px}}
table{{width:100%;font-size:12px;border-collapse:collapse}}
table td{{padding:6px;border-bottom:1px solid #f3f4f6}}
.badge{{display:inline-block;padding:2px 8px;border-radius:10px;font-size:11px}}
</style>
</head>
<body>
<div class="container">
<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px">
  <h1>🛠 시스템 상태</h1>
  <button class="refresh" onclick="location.reload()">새로고침</button>
</div>
<div style="font-size:12px;color:#6b7280;margin-bottom:16px">최종 갱신: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</div>

<div class="grid">

  <div class="card">
    <h2>🌐 환경</h2>
    <div class="row"><span class="k">environment</span><span class="v {('ok' if env=='imac_kr' else 'warn')}">{env}</span></div>
    <div class="row"><span class="k">detail</span><span class="v">{env_detail}</span></div>
    <div class="row"><span class="k">checked_at</span><span class="v muted">{settings.get('env_checked_at','-')[:16]}</span></div>
  </div>

  <div class="card">
    <h2>🔐 인증</h2>'''
        
        for name, info in auth_files.items():
            if info['exists']:
                cls = 'ok' if info['age_hours'] < 12 else ('warn' if info['age_hours'] < 24 else 'err')
                html += f'<div class="row"><span class="k">{name}</span><span class="v {cls}">{info["age_hours"]}h 전</span></div>'
            else:
                html += f'<div class="row"><span class="k">{name}</span><span class="v err">없음</span></div>'
        
        html += '''
  </div>

  <div class="card">
    <h2>⚙️ 자동 토글</h2>'''
        for name, val in toggles.items():
            cls = 'ok' if val else 'muted'
            badge = 'ON' if val else 'OFF'
            html += f'<div class="row"><span class="k">{name}</span><span class="badge {cls}">{badge}</span></div>'
        html += f'''
  </div>

  <div class="card">
    <h2>📅 스케줄러 ({len(scheduler_jobs)}개)</h2>'''
        if scheduler_jobs:
            for job in scheduler_jobs:
                next_run = str(job['next_run'])[:16] if job['next_run'] != 'paused' else 'paused'
                html += f'<div class="row"><span class="k">{job["id"]}</span><span class="v muted" style="font-size:11px">{next_run}</span></div>'
        else:
            html += '<div class="muted" style="font-size:13px">등록된 작업 없음</div>'
        html += f'''
  </div>

  <div class="card">
    <h2>📦 DB 현황</h2>
    <div class="row"><span class="k">조정 대기 (pending)</span><span class="v {('warn' if pa_pending > 10 else 'ok')}">{pa_pending}</span></div>
    <div class="row"><span class="k">판매 누적</span><span class="v">{sales_total}</span></div>
    <div class="row"><span class="k">최근 판매</span><span class="v muted">{last_sale}</span></div>
  </div>

  <div class="card">
    <h2>🔗 빠른 링크</h2>
    <div style="font-size:13px;line-height:1.8">
      <div><a href="/" style="color:#2563eb">📊 메인 대시보드</a></div>
      <div><a href="/api/health" style="color:#2563eb">/api/health</a></div>
      <div><a href="/api/daily-summary" style="color:#2563eb">/api/daily-summary</a></div>
      <div><a href="/api/daily-log/today" style="color:#2563eb">/api/daily-log/today</a></div>
      <div><a href="/api/weekly-report" style="color:#2563eb">/api/weekly-report</a></div>
    </div>
  </div>

</div>
</div>
</body>
</html>'''
        
        from flask import Response
        return Response(html, mimetype='text/html')
    except Exception as e:
        return f"<pre>Error: {e}</pre>", 500
```

## 검증

1. python3 -m py_compile kream_server.py → 0
2. 서버 재시작
3. 스케줄러 확인:
   - /api/scheduler/* 또는 코드 내 scheduler.get_jobs()로 'daily_log_save', 'my_bids_sync_monitor', 'weekly_report_save' 3개 신규 등록 확인
4. /api/weekly-report → ok=true, markdown 키
5. /api/weekly-report/save POST → 파일 저장 성공
6. /admin/status → HTML 200 (text/html)
7. /api/scheduler/bids-monitor/toggle POST {"enabled":false} → ok=true
8. /api/scheduler/bids-monitor/toggle POST {"enabled":true} → ok=true
9. 회귀: /api/health, /api/queue/list, /api/help/register, /api/daily-summary

## 절대 규칙
- 자동 입찰/조정/재입찰/정리/PDF 토글 ON 변경 금지 (추가만, 변경 없음)
- 기존 스케줄러 작업 변경 금지 (추가만)
- DB 스키마 변경 금지
- 30분 sync 스케줄러는 기본 등록되지만, 운영 안전성 위해 처음 24h는 토글로 OFF 가능

## 커밋 메시지
```
feat(Step 18-D): 일일 자동화 + 운영 가시성 4건

- 작업 일지 자동 저장 스케줄러 (매일 23:55)
- 내 입찰 자동 sync + rank 변동 알림 스케줄러 (30분)
  - rank 1 → N 떨어진 건만 safe_send_alert (rank_drop)
  - /api/scheduler/bids-monitor/toggle 토글 추가
- /api/weekly-report + /save: 7일 종합 마크다운
  - 매주 월요일 0:05 자동 저장 (weekly_report/YYYY-WWW.md)
- /admin/status: 시스템 상태 종합 HTML 페이지
  - 환경/인증/토글/스케줄러/DB 한 화면

배경: 사람 손 안 타고 매일 돌게 + 사장이 매일 한 번만 보면 OK
```
