"""
KREAM 자동화 — 경보 시스템
쿨다운 기반 이메일 알림 + 이력 파일 저장/복원
"""

import json
import smtplib
import traceback
from datetime import datetime, timedelta
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from pathlib import Path


ALERT_HISTORY_FILE = Path(__file__).parent / "alert_history.json"
SETTINGS_FILE = Path(__file__).parent / "settings.json"

EMAIL_SENDER = "judaykream@gmail.com"


def _load_settings():
    if SETTINGS_FILE.exists():
        try:
            return json.loads(SETTINGS_FILE.read_text())
        except Exception:
            pass
    return {}


class HealthAlert:
    def __init__(self):
        self._history = {}  # key → {"last_sent": ISO, "count": N}
        self._load_history()

    def _load_history(self):
        if ALERT_HISTORY_FILE.exists():
            try:
                self._history = json.loads(ALERT_HISTORY_FILE.read_text())
            except Exception:
                self._history = {}

    def _save_history(self):
        try:
            ALERT_HISTORY_FILE.write_text(
                json.dumps(self._history, ensure_ascii=False, indent=2)
            )
        except Exception as e:
            print(f"[경보] alert_history.json 저장 실패: {e}")

    def alert(self, key, message, cooldown_minutes=None, force=False):
        """
        알림 발송.
        - 같은 key는 cooldown 내 1회만 발송
        - force=True면 쿨다운 무시 (테스트용)
        - 반환: {"sent": bool, "reason": str}
        """
        settings = _load_settings()

        # 알림 비활성화 체크
        if not settings.get("alert_enabled", True) and not force:
            return {"sent": False, "reason": "알림 비활성화 상태"}

        # 쿨다운 결정
        if cooldown_minutes is None:
            cooldown_minutes = int(settings.get("alert_cooldown_minutes", 60))

        now = datetime.now()

        # 쿨다운 체크
        if not force and key in self._history:
            last_sent_str = self._history[key].get("last_sent")
            if last_sent_str:
                try:
                    last_sent = datetime.fromisoformat(last_sent_str)
                    if now - last_sent < timedelta(minutes=cooldown_minutes):
                        remaining = cooldown_minutes - (now - last_sent).total_seconds() / 60
                        return {
                            "sent": False,
                            "reason": f"쿨다운 중 ({remaining:.0f}분 남음)",
                        }
                except Exception:
                    pass

        # 이메일 발송
        result = self._send_email(key, message, settings, now, cooldown_minutes)

        # 이력 업데이트
        if result["sent"]:
            if key not in self._history:
                self._history[key] = {"count": 0}
            self._history[key]["last_sent"] = now.isoformat()
            self._history[key]["count"] = self._history[key].get("count", 0) + 1
            self._save_history()

        return result

    def _send_email(self, key, message, settings, now, cooldown_minutes):
        app_password = settings.get("gmail_app_password") or settings.get("emailAppPassword", "")
        if not app_password:
            return {"sent": False, "reason": "Gmail 앱 비밀번호 미설정"}

        receiver = settings.get("alert_email") or settings.get("kream_email", EMAIL_SENDER)
        subject = f"[KREAM 자동화 경보] {key}"

        next_alert_time = (now + timedelta(minutes=cooldown_minutes)).strftime("%Y-%m-%d %H:%M")
        body = f"""<html><body style="font-family:-apple-system,sans-serif">
<h2 style="color:#e74c3c">KREAM 자동화 경보</h2>
<table style="font-size:14px;line-height:1.8;border-collapse:collapse">
<tr><td style="padding:6px 16px 6px 0;font-weight:600;color:#666">경보 키</td>
    <td style="padding:6px 0"><code style="background:#f5f5f5;padding:2px 8px;border-radius:4px">{key}</code></td></tr>
<tr><td style="padding:6px 16px 6px 0;font-weight:600;color:#666">메시지</td>
    <td style="padding:6px 0">{message}</td></tr>
<tr><td style="padding:6px 16px 6px 0;font-weight:600;color:#666">발생 시각</td>
    <td style="padding:6px 0">{now.strftime('%Y-%m-%d %H:%M:%S')}</td></tr>
<tr><td style="padding:6px 16px 6px 0;font-weight:600;color:#666">다음 알림 가능</td>
    <td style="padding:6px 0">{next_alert_time}</td></tr>
</table>
<p style="margin-top:24px">
<a href="http://localhost:5001" style="background:#31b46e;color:#fff;padding:10px 24px;
text-decoration:none;border-radius:8px;font-weight:600;font-size:14px">대시보드 확인</a>
</p>
</body></html>"""

        msg = MIMEMultipart("alternative")
        msg["Subject"] = subject
        msg["From"] = EMAIL_SENDER
        msg["To"] = receiver
        msg.attach(MIMEText(body, "html", "utf-8"))

        try:
            with smtplib.SMTP_SSL("smtp.gmail.com", 465) as server:
                server.login(EMAIL_SENDER, app_password)
                server.send_message(msg)
            print(f"[경보] 이메일 발송 완료: {key} → {receiver}")
            return {"sent": True, "reason": "발송 완료", "to": receiver}
        except Exception as e:
            print(f"[경보] 이메일 발송 실패: {e}")
            return {"sent": False, "reason": f"발송 실패: {e}"}

    def get_history(self):
        return dict(self._history)
