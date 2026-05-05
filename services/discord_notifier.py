"""KREAM 자동화 — Discord 4채널 알림.

채널: bids / sales / errors / daily
- .env.local에서 DISCORD_WEBHOOK_{BIDS,SALES,ERRORS,DAILY} 로드
- Discord embed 형식 (title + description + fields + color)
- 60초 디바운싱 (같은 channel+title 반복 차단)
- 실패는 stderr 로그만 남기고 graceful skip (시스템 중단 X)
- .env.local 누락/URL 빈 값이면 그 채널만 skip
"""

import json
import sys
import time
import urllib.request
import urllib.error
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional

ENV_LOCAL = Path(__file__).resolve().parent.parent / ".env.local"

_WEBHOOKS: Dict[str, Optional[str]] = {
    "bids": None,
    "sales": None,
    "errors": None,
    "daily": None,
}
_ENV_LOADED = False

# alert_type/subject 키워드 → 채널 자동 매핑
_KEYWORD_MAP = [
    (("daily", "report", "weekly", "일일", "리포트", "주간"), "daily"),
    (("sale", "sold", "settle", "체결", "판매"), "sales"),
    (("bid", "rebid", "adjust", "입찰", "조정"), "bids"),
    (
        (
            "error", "fail", "exception", "critical", "warn",
            "auth", "relogin", "login", "sync", "blocked",
            "에러", "실패", "오류", "차단",
        ),
        "errors",
    ),
]
_DEFAULT_CHANNEL = "errors"

COLORS = {
    "success": 0x00FF00,
    "error": 0xFF0000,
    "info": 0x0099FF,
    "warn": 0xFFAA00,
}

_dedup: Dict[tuple, float] = {}
_DEDUP_WINDOW_SEC = 60


def _load_env() -> None:
    global _ENV_LOADED
    if _ENV_LOADED:
        return
    _ENV_LOADED = True
    if not ENV_LOCAL.exists():
        print(f"[discord] .env.local 없음: {ENV_LOCAL}", file=sys.stderr)
        return
    try:
        for raw in ENV_LOCAL.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            if not val:
                continue
            mapping = {
                "DISCORD_WEBHOOK_BIDS": "bids",
                "DISCORD_WEBHOOK_SALES": "sales",
                "DISCORD_WEBHOOK_ERRORS": "errors",
                "DISCORD_WEBHOOK_DAILY": "daily",
            }
            ch = mapping.get(key)
            if ch:
                _WEBHOOKS[ch] = val
    except Exception as e:
        print(f"[discord] .env.local 파싱 실패: {e}", file=sys.stderr)


def _resolve_channel_from_type(alert_type: str) -> str:
    s = (alert_type or "").lower()
    for keywords, ch in _KEYWORD_MAP:
        if any(k in s for k in keywords):
            return ch
    return _DEFAULT_CHANNEL


def _resolve_color_from_type(alert_type: str) -> int:
    s = (alert_type or "").lower()
    if any(k in s for k in ("error", "fail", "exception", "critical", "에러", "실패", "오류")):
        return COLORS["error"]
    if any(k in s for k in ("warn", "warning", "blocked", "차단", "경고")):
        return COLORS["warn"]
    if any(k in s for k in ("success", "complete", "성공", "완료")):
        return COLORS["success"]
    return COLORS["info"]


def _post_webhook(url: str, payload: dict, timeout: int = 8) -> bool:
    try:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=body,
            headers={
                "Content-Type": "application/json",
                # Discord 앞단 Cloudflare가 Python-urllib 기본 UA를 차단(error 1010)하므로 명시.
                "User-Agent": "KREAM-Automation-Notifier/1.0 (+local)",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return 200 <= resp.status < 300
    except urllib.error.HTTPError as e:
        try:
            err_body = e.read().decode("utf-8", errors="replace")[:300]
        except Exception:
            err_body = ""
        print(f"[discord] HTTP {e.code} {e.reason}: {err_body}", file=sys.stderr)
        return False
    except Exception as e:
        print(f"[discord] POST 실패: {e}", file=sys.stderr)
        return False


def send_discord(
    channel: str,
    title: str,
    message: str,
    color: Optional[int] = None,
    fields: Optional[List[Dict]] = None,
    dedupe: bool = True,
) -> bool:
    """Discord 채널에 embed 메시지 발송.

    Returns:
        True  발송 성공.
        False 미발송(웹훅 미설정/디바운스 차단/요청 실패) — 호출측 영향 X.
    """
    try:
        _load_env()

        if channel not in _WEBHOOKS:
            print(f"[discord] 알 수 없는 채널: {channel}", file=sys.stderr)
            return False

        url = _WEBHOOKS.get(channel)
        if not url:
            return False

        if dedupe:
            key = (channel, str(title)[:200])
            now = time.time()
            last = _dedup.get(key, 0)
            if now - last < _DEDUP_WINDOW_SEC:
                return False
            _dedup[key] = now
            if len(_dedup) > 500:
                cutoff = now - 3600
                for k, t in list(_dedup.items()):
                    if t < cutoff:
                        del _dedup[k]

        embed = {
            "title": str(title)[:256],
            "description": str(message)[:4000],
            "color": color if color is not None else COLORS["info"],
            "timestamp": datetime.utcnow().isoformat() + "Z",
        }
        if fields:
            embed["fields"] = [
                {
                    "name": str(f.get("name", "?"))[:256],
                    "value": str(f.get("value", ""))[:1024],
                    "inline": bool(f.get("inline", False)),
                }
                for f in fields[:25]
            ]

        return _post_webhook(url, {"embeds": [embed]})
    except Exception as e:
        print(f"[discord] send_discord 예외: {e}", file=sys.stderr)
        return False


def send_for_alert_type(
    alert_type: str,
    title: str,
    message: str,
    fields: Optional[List[Dict]] = None,
    dedupe: bool = True,
) -> bool:
    """alert_type/subject 키워드 기반 자동 채널 + 색상 매핑."""
    channel = _resolve_channel_from_type(f"{alert_type} {title}")
    color = _resolve_color_from_type(f"{alert_type} {title}")
    return send_discord(
        channel, title, message,
        color=color, fields=fields, dedupe=dedupe,
    )


def get_loaded_channels() -> List[str]:
    """웹훅이 로드된 채널 목록 (디버깅용)."""
    _load_env()
    return [ch for ch, url in _WEBHOOKS.items() if url]
