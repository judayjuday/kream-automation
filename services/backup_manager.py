"""
백업 관리 — Step 46-4.

기존 일일 백업에 추가:
- 시간별 백업 (4시간마다)
- SHA256 무결성 해시
- 자동 정리 (7일 이상된 시간별 백업 삭제)
- 백업 목록 조회 API
"""
import sqlite3
import os
import shutil
import hashlib
import json
import glob
from typing import Dict, List, Any
from datetime import datetime, timedelta

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB_PATH = os.path.join(BASE_DIR, 'price_history.db')
BACKUP_DIR = os.path.join(BASE_DIR, 'backups')
HOURLY_DIR = os.path.join(BACKUP_DIR, 'hourly')


def _ensure_dirs():
    os.makedirs(HOURLY_DIR, exist_ok=True)


def _compute_sha256(file_path: str) -> str:
    h = hashlib.sha256()
    with open(file_path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()


def create_hourly_backup() -> Dict[str, Any]:
    """시간별 백업 (SQLite .backup 명령 사용 — 안전)."""
    _ensure_dirs()
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    backup_path = os.path.join(HOURLY_DIR, f'price_history.db.hourly.{timestamp}')

    # SQLite 안전 백업 (online backup API)
    try:
        src = sqlite3.connect(DB_PATH)
        dst = sqlite3.connect(backup_path)
        with dst:
            src.backup(dst)
        dst.close()
        src.close()
    except Exception as e:
        return {'success': False, 'error': f'backup failed: {e}'}

    # SHA256 + 메타데이터
    sha = _compute_sha256(backup_path)
    size = os.path.getsize(backup_path)

    meta_path = backup_path + '.meta.json'
    meta = {
        'timestamp': timestamp,
        'created_at': datetime.now().isoformat(),
        'size_bytes': size,
        'sha256': sha,
        'source': DB_PATH,
        'type': 'hourly',
    }
    with open(meta_path, 'w') as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)

    return {'success': True, 'path': backup_path, 'sha256': sha, 'size_bytes': size}


def cleanup_old_hourly(keep_days: int = 7) -> Dict[str, Any]:
    """N일 이상된 시간별 백업 정리."""
    _ensure_dirs()
    cutoff = datetime.now() - timedelta(days=keep_days)
    deleted = 0
    kept = 0
    errors = []

    for path in glob.glob(os.path.join(HOURLY_DIR, 'price_history.db.hourly.*')):
        if path.endswith('.meta.json'):
            continue
        try:
            mtime = datetime.fromtimestamp(os.path.getmtime(path))
            if mtime < cutoff:
                meta = path + '.meta.json'
                os.remove(path)
                if os.path.exists(meta):
                    os.remove(meta)
                deleted += 1
            else:
                kept += 1
        except Exception as e:
            errors.append(f'{path}: {e}')

    return {'success': True, 'deleted': deleted, 'kept': kept, 'errors': errors}


def list_backups() -> Dict[str, Any]:
    """모든 백업 목록 (일일 + 시간별)."""
    _ensure_dirs()
    daily = []
    hourly = []

    # 일일 (backups/ 직접)
    for path in sorted(glob.glob(os.path.join(BACKUP_DIR, 'price_history.db.*'))):
        if 'hourly' in path or path.endswith('.json'):
            continue
        if os.path.isdir(path):
            continue
        try:
            stat = os.stat(path)
            daily.append({
                'name': os.path.basename(path),
                'size_bytes': stat.st_size,
                'mtime': datetime.fromtimestamp(stat.st_mtime).isoformat(),
            })
        except Exception:
            pass

    # 시간별
    for path in sorted(glob.glob(os.path.join(HOURLY_DIR, 'price_history.db.hourly.*'))):
        if path.endswith('.meta.json'):
            continue
        try:
            stat = os.stat(path)
            meta_path = path + '.meta.json'
            meta = {}
            if os.path.exists(meta_path):
                with open(meta_path, 'r') as f:
                    meta = json.load(f)
            hourly.append({
                'name': os.path.basename(path),
                'size_bytes': stat.st_size,
                'mtime': datetime.fromtimestamp(stat.st_mtime).isoformat(),
                'sha256': meta.get('sha256'),
            })
        except Exception:
            pass

    total_size = sum(b['size_bytes'] for b in daily + hourly)
    return {
        'success': True,
        'daily_count': len(daily),
        'hourly_count': len(hourly),
        'total_size_bytes': total_size,
        'total_size_mb': round(total_size / 1024 / 1024, 2),
        'daily': daily[-30:],  # 최근 30개
        'hourly': hourly[-50:],
    }


def verify_backup(backup_filename: str) -> Dict[str, Any]:
    """백업 SHA256 무결성 검증."""
    # hourly만 SHA256 있음
    hourly_path = os.path.join(HOURLY_DIR, backup_filename)
    if not os.path.exists(hourly_path):
        return {'success': False, 'error': 'backup not found'}

    meta_path = hourly_path + '.meta.json'
    if not os.path.exists(meta_path):
        return {'success': False, 'error': 'meta file not found'}

    with open(meta_path, 'r') as f:
        meta = json.load(f)
    expected = meta.get('sha256')
    actual = _compute_sha256(hourly_path)

    return {
        'success': True,
        'match': expected == actual,
        'expected': expected,
        'actual': actual,
        'filename': backup_filename,
    }


def generate_external_backup_script() -> Dict[str, Any]:
    """
    receipts/ 외부 백업 스크립트 자동 생성.
    - rsync 또는 cp 명령어
    - 백업 대상 검증 (파일 수, 용량)
    """
    receipts_dir = os.path.join(BASE_DIR, 'receipts')
    if not os.path.exists(receipts_dir):
        return {'success': False, 'error': 'receipts/ not found'}

    # 통계
    file_count = 0
    total_size = 0
    for root, dirs, files in os.walk(receipts_dir):
        for f in files:
            if f.startswith('.'):
                continue
            file_count += 1
            try:
                total_size += os.path.getsize(os.path.join(root, f))
            except Exception:
                pass

    # 명령어 생성
    today = datetime.now().strftime('%Y%m%d')
    rsync_cmd = f'rsync -av --progress {receipts_dir}/ ~/iCloud_Backup/receipts_{today}/'
    cp_cmd = f'cp -r {receipts_dir} /Volumes/Backup_SSD/kream_receipts_{today}/'

    return {
        'success': True,
        'receipts_dir': receipts_dir,
        'file_count': file_count,
        'total_size_bytes': total_size,
        'total_size_mb': round(total_size / 1024 / 1024, 2),
        'commands': {
            'icloud_rsync': rsync_cmd,
            'external_ssd_cp': cp_cmd,
        },
        'note': 'receipts/ 는 git 추적 제외. 주 1회 외부 백업 권장.',
    }
