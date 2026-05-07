# scripts/ — 운영 스크립트

사장님이 직접 실행하는 운영 스크립트 모음.

## backup_receipts.sh

receipts/ 폴더를 외장 SSD 또는 iCloud로 백업.

### 사용법

```bash
# 1. 대상 디스크 목록 확인
./scripts/backup_receipts.sh

# 2. 외장 SSD에 백업
./scripts/backup_receipts.sh /Volumes/MyBackupSSD

# 3. iCloud Drive에 백업
./scripts/backup_receipts.sh "$HOME/Library/Mobile Documents/com~apple~CloudDocs/kream_backups"
```

### 권장 일정
- **주 1회** 또는 영수증 등록 후 즉시
- 외장 SSD는 평소 분리 보관 (랜섬웨어 방지)
- iCloud는 자동 동기화되므로 추가 안전망

### 백업 구조
```
대상_경로/
└── kream_receipts_backup/
    ├── 20260507/        ← 오늘 날짜
    │   ├── 2026/
    │   │   └── 04/
    │   │       └── *.png
    └── backup_log.txt   ← 백업 이력
```

### 자동화 (선택)

cron으로 자동 실행하려면:
```bash
crontab -e
# 매주 일요일 오전 9시에 백업
0 9 * * 0 cd ~/Desktop/kream_automation && ./scripts/backup_receipts.sh /Volumes/MyBackupSSD >> ~/Desktop/kream_automation/server.log 2>&1
```

⚠️ 자동화 시 주의: 외장 SSD 미연결 상태에서는 실패함.
