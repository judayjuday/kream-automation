#!/bin/bash
# KREAM 자동화 서버 watchdog + Cloudflare Tunnel
# 사용법:
#   bash start_server.sh          # 서버만 실행 (watchdog)
#   bash start_server.sh --tunnel # 서버 + Cloudflare Tunnel
# 중지: kill $(cat server_watchdog.pid)

cd "$(dirname "$0")"
echo $$ > server_watchdog.pid

CRASH_LOG="crash_log.txt"
SERVER_LOG="server.log"
PORT=5001
RESTART_DELAY=3
USE_TUNNEL=false
TUNNEL_PID=""

# --tunnel 옵션 확인
for arg in "$@"; do
    if [ "$arg" = "--tunnel" ]; then
        USE_TUNNEL=true
    fi
done

echo "[watchdog] 시작: $(date)" | tee -a "$CRASH_LOG"
if [ "$USE_TUNNEL" = true ]; then
    echo "[watchdog] Cloudflare Tunnel 모드" | tee -a "$CRASH_LOG"
fi

cleanup() {
    echo "[watchdog] 종료: $(date)" | tee -a "$CRASH_LOG"
    lsof -ti:$PORT | xargs kill -9 2>/dev/null
    [ -n "$TUNNEL_PID" ] && kill $TUNNEL_PID 2>/dev/null
    rm -f server_watchdog.pid
    exit 0
}
trap cleanup SIGINT SIGTERM

while true; do
    # 기존 서버 종료
    lsof -ti:$PORT | xargs kill -9 2>/dev/null
    sleep 1

    echo "[watchdog] 서버 시작: $(date)" | tee -a "$CRASH_LOG"
    python3 -u kream_server.py >> "$SERVER_LOG" 2>&1 &
    SERVER_PID=$!
    echo "[watchdog] PID: $SERVER_PID"

    # Tunnel 시작
    if [ "$USE_TUNNEL" = true ] && [ -z "$TUNNEL_PID" ]; then
        if command -v cloudflared &> /dev/null; then
            sleep 2  # 서버 시작 대기
            echo "[watchdog] Cloudflare Tunnel 시작..."
            cloudflared tunnel --url http://localhost:$PORT 2>&1 | tee tunnel.log &
            TUNNEL_PID=$!
            # URL 추출 대기
            sleep 5
            TUNNEL_URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' tunnel.log | head -1)
            if [ -n "$TUNNEL_URL" ]; then
                echo ""
                echo "============================================"
                echo "  Tunnel URL: $TUNNEL_URL"
                echo "============================================"
                echo ""
                # macOS clipboard 복사
                echo "$TUNNEL_URL" | pbcopy 2>/dev/null && echo "[watchdog] URL 클립보드에 복사됨"
            fi
        else
            echo "[watchdog] cloudflared 미설치 — brew install cloudflared"
            USE_TUNNEL=false
        fi
    fi

    # 서버 프로세스 감시
    wait $SERVER_PID
    EXIT_CODE=$?

    if [ $EXIT_CODE -eq 0 ]; then
        echo "[watchdog] 서버 정상 종료 (exit $EXIT_CODE): $(date)" | tee -a "$CRASH_LOG"
        break
    fi

    echo "[watchdog] 서버 크래시! exit=$EXIT_CODE: $(date)" | tee -a "$CRASH_LOG"
    echo "[watchdog] ${RESTART_DELAY}초 후 재시작..." | tee -a "$CRASH_LOG"
    sleep $RESTART_DELAY
done
