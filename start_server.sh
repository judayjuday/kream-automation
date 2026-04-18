#!/bin/bash
# KREAM 자동화 서버 watchdog
# 사용법: bash start_server.sh &
# 중지: kill $(cat server_watchdog.pid)

cd "$(dirname "$0")"
echo $$ > server_watchdog.pid

CRASH_LOG="crash_log.txt"
SERVER_LOG="server.log"
PORT=5001
RESTART_DELAY=3

echo "[watchdog] 시작: $(date)" | tee -a "$CRASH_LOG"

cleanup() {
    echo "[watchdog] 종료: $(date)" | tee -a "$CRASH_LOG"
    lsof -ti:$PORT | xargs kill -9 2>/dev/null
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
