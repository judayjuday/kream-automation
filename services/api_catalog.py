"""
API 자동 카탈로그 — Step 47-6.
Flask 앱의 모든 라우트 자동 스캔 + 분류.
"""
from typing import Dict, Any
from collections import defaultdict


def categorize_endpoint(path: str) -> str:
    """경로에서 카테고리 추출."""
    parts = path.strip('/').split('/')
    if len(parts) < 2:
        return 'misc'
    if parts[0] != 'api':
        return 'page'
    return parts[1] if len(parts) > 1 else 'api'


def scan_routes(flask_app) -> Dict[str, Any]:
    """Flask 앱 라우트 전체 스캔."""
    routes = []
    by_category = defaultdict(list)

    for rule in flask_app.url_map.iter_rules():
        methods = sorted([m for m in rule.methods if m not in ('HEAD', 'OPTIONS')])
        path = str(rule.rule)
        endpoint = rule.endpoint

        # docstring 추출
        view_func = flask_app.view_functions.get(endpoint)
        doc = (view_func.__doc__ or '').strip().split('\n')[0] if view_func else ''

        item = {
            'path': path,
            'methods': methods,
            'endpoint': endpoint,
            'doc': doc,
            'category': categorize_endpoint(path),
        }
        routes.append(item)
        by_category[item['category']].append(item)

    # 정렬
    for cat in by_category:
        by_category[cat].sort(key=lambda x: x['path'])

    return {
        'total_count': len(routes),
        'categories': dict(by_category),
        'category_counts': {k: len(v) for k, v in by_category.items()},
    }
