---
name: db-migration
description: DB 스키마 변경 (ALTER TABLE, 새 컬럼 추가) 시 자동 적용됨
---

# DB 마이그레이션 규칙

## 필수 확인사항
1. ALTER TABLE ADD COLUMN 시 반드시 NULL 허용 (기존 데이터 안 깨짐)
2. DROP COLUMN은 사용자 확인 필수 — 절대 자의적 삭제 금지
3. 인덱스 추가 시 이름 규칙: `idx_테이블_컬럼`
4. 마이그레이션 후 기존 데이터 건수 확인: `SELECT COUNT(*) FROM 테이블명;`
5. NOT NULL 컬럼은 DEFAULT 값 필수 지정

## 예시

```sql
-- 좋음 (NULL 허용, 기존 행 영향 없음)
ALTER TABLE bid_cost ADD COLUMN memo TEXT;

-- 좋음 (DEFAULT 지정)
ALTER TABLE bid_cost ADD COLUMN is_active INTEGER DEFAULT 1;

-- 나쁨 (NOT NULL + DEFAULT 없음 → 기존 행에서 에러)
ALTER TABLE bid_cost ADD COLUMN memo TEXT NOT NULL;
```

## 마이그레이션 패턴
```python
# CREATE TABLE IF NOT EXISTS → 테이블 없으면 생성
# 컬럼 추가는 try/except로 감싸기 (이미 있으면 스킵)
try:
    conn.execute("ALTER TABLE 테이블 ADD COLUMN 컬럼 타입")
except sqlite3.OperationalError:
    pass  # 이미 존재
```

## 금지사항
- DROP TABLE 금지 (CLAUDE.md 절대 규칙)
- DELETE FROM 금지 (테스트 데이터 제외: WHERE order_id LIKE 'TEST_%')
- 프로덕션 DB 직접 수정 금지 — 반드시 코드에서 마이그레이션
