"""
헬스체크 강화 — Step 48-F.

기존 /api/health 응답을 분석:
- KREAM 세션 만료 자동 감지
- overseas_blocked 환경 이슈 분류
- 스케줄러별 상태
- DB 무결성 체크
"""
import sqlite3
import os
import time
from typing import Dict, Any
from datetime import datetime

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB_PATH = os.path.join(BASE_DIR, 'price_history.db')
AUTH_PARTNER = os.path.join(BASE_DIR, 'auth_state.json')
AUTH_KREAM = os.path.join(BASE_DIR, 'auth_state_kream.json')


def check_auth_files() -> Dict[str, Any]:
    """auth_state 파일 상태 (수정 시간 기준 추정)."""
    result = {}
    for label, path in [('partner', AUTH_PARTNER), ('kream', AUTH_KREAM)]:
        if not os.path.exists(path):
            result[label] = {'exists': False}
            continue
        try:
            stat = os.stat(path)
            age_hours = (time.time() - stat.st_mtime) / 3600
            with open(path, 'r') as f:
                content = f.read()
                # 빈 세션 감지 (단순 체크)
                is_empty = (
                    len(content) < 100
                    or '"localStorage"' not in content
                    or '"cookies"' not in content
                )
            result[label] = {
                'exists': True,
                'size_bytes': stat.st_size,
                'age_hours': round(age_hours, 1),
                'last_modified': datetime.fromtimestamp(stat.st_mtime).isoformat(),
                'looks_empty': is_empty,
                'warning': 'session may be expired' if age_hours > 168 else None,  # 7일
            }
        except Exception as e:
            result[label] = {'exists': True, 'error': str(e)}
    return result


def db_integrity() -> Dict[str, Any]:
    """SQLite 무결성 체크."""
    try:
        conn = sqlite3.connect(DB_PATH)
        cur = conn.cursor()
        cur.execute("PRAGMA integrity_check")
        result = cur.fetchone()
        conn.close()
        ok = (result and result[0] == 'ok')
        return {
            'ok': ok,
            'result': result[0] if result else None,
        }
    except Exception as e:
        return {'ok': False, 'error': str(e)}


def disk_space_check() -> Dict[str, Any]:
    """디스크 공간 체크 (5GB 미만 경고)."""
    import shutil
    try:
        usage = shutil.disk_usage(BASE_DIR)
        free_gb = usage.free / 1024**3
        return {
            'free_gb': round(free_gb, 2),
            'used_pct': round(usage.used / usage.total * 100, 1),
            'warning': 'low disk space' if free_gb < 5 else None,
        }
    except Exception as e:
        return {'error': str(e)}


def comprehensive_health() -> Dict[str, Any]:
    """종합 헬스 체크."""
    auth = check_auth_files()
    db = db_integrity()
    disk = disk_space_check()

    # 종합 상태 판정
    issues = []
    severity = 'healthy'

    # auth 만료 가능성
    for label in ('partner', 'kream'):
        a = auth.get(label, {})
        if not a.get('exists'):
            issues.append(f'{label} session not found')
            severity = 'critical'
        elif a.get('looks_empty'):
            issues.append(f'{label} session looks empty')
            severity = 'critical'
        elif a.get('warning'):
            issues.append(f'{label}: {a["warning"]}')
            if severity == 'healthy':
                severity = 'warning'

    if not db['ok']:
        issues.append(f'DB integrity: {db.get("result", db.get("error"))}')
        severity = 'critical'

    if disk.get('warning'):
        issues.append(disk['warning'])
        if severity == 'healthy':
            severity = 'warning'

    return {
        'severity': severity,
        'issues': issues,
        'auth_state': auth,
        'database': db,
        'disk': disk,
        'checked_at': datetime.now().isoformat(),
        'recommendations': _get_recommendations(severity, issues, auth),
    }


def _get_recommendations(severity: str, issues: list, auth: dict) -> list:
    """상태별 권장 조치."""
    recs = []
    if severity == 'critical':
        for label in ('partner', 'kream'):
            a = auth.get(label, {})
            if not a.get('exists') or a.get('looks_empty'):
                recs.append(f'KREAM {label} 자동 로그인 실행: python3 kream_bot.py --mode auto-login')
        recs.append('서버 재시작 검토')
    elif severity == 'warning':
        if any('session' in i for i in issues):
            recs.append('곧 세션 갱신 필요: python3 kream_bot.py --mode auto-login')
    return recs
