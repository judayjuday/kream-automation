"""
시스템 모니터링 — Step 46-8.
디스크 사용량 + 폴더별 용량 + DB 통계.
"""
import os
import shutil
import sqlite3
from typing import Dict, Any
from datetime import datetime

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB_PATH = os.path.join(BASE_DIR, 'price_history.db')


def disk_usage() -> Dict[str, Any]:
    """디스크 전체 사용량."""
    try:
        usage = shutil.disk_usage(BASE_DIR)
        return {
            'total_bytes': usage.total,
            'used_bytes': usage.used,
            'free_bytes': usage.free,
            'total_gb': round(usage.total / 1024**3, 2),
            'used_gb': round(usage.used / 1024**3, 2),
            'free_gb': round(usage.free / 1024**3, 2),
            'used_pct': round(usage.used / usage.total * 100, 1),
        }
    except Exception as e:
        return {'error': str(e)}


def folder_sizes() -> Dict[str, Any]:
    """프로젝트 주요 폴더 크기."""
    targets = ['backups', 'receipts', 'tabs', 'services', '.claude']
    results = {}
    for t in targets:
        path = os.path.join(BASE_DIR, t)
        if not os.path.exists(path):
            results[t] = {'exists': False}
            continue
        total = 0
        files = 0
        for root, dirs, fs in os.walk(path):
            for f in fs:
                try:
                    total += os.path.getsize(os.path.join(root, f))
                    files += 1
                except Exception:
                    pass
        results[t] = {
            'exists': True,
            'size_bytes': total,
            'size_mb': round(total / 1024**2, 2),
            'file_count': files,
        }
    return results


def db_stats() -> Dict[str, Any]:
    """DB 테이블별 레코드 수."""
    if not os.path.exists(DB_PATH):
        return {'error': 'DB not found'}

    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        cur = conn.cursor()
        cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
        tables = [r['name'] for r in cur.fetchall()]

        stats = {}
        for t in tables:
            try:
                cur.execute(f"SELECT COUNT(*) as cnt FROM {t}")
                stats[t] = cur.fetchone()['cnt']
            except Exception as e:
                stats[t] = f'error: {e}'

        size = os.path.getsize(DB_PATH)
        return {
            'db_size_bytes': size,
            'db_size_mb': round(size / 1024**2, 2),
            'table_count': len(tables),
            'records': stats,
        }
    finally:
        conn.close()


def system_overview() -> Dict[str, Any]:
    return {
        'checked_at': datetime.now().isoformat(),
        'disk': disk_usage(),
        'folders': folder_sizes(),
        'database': db_stats(),
    }
