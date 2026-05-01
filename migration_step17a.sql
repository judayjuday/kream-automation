BEGIN;

CREATE TABLE IF NOT EXISTS model_category (
    model TEXT PRIMARY KEY,
    category TEXT NOT NULL,
    source TEXT NOT NULL,
    needs_size INTEGER NOT NULL,
    cached_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    notes TEXT
);
CREATE INDEX IF NOT EXISTS idx_model_category_needs_size ON model_category(needs_size);

INSERT OR IGNORE INTO model_category (model, category, source, needs_size, notes)
SELECT DISTINCT
    model,
    category,
    'shihuo' AS source,
    CASE WHEN category = 'bags' THEN 0 ELSE 1 END AS needs_size,
    '식货 활성 batch 자동 추론'
FROM shihuo_prices
WHERE active=1 AND category IS NOT NULL;

-- Step 17-C: IX7694 가방 manual 등록 (사용자 확인)
INSERT OR IGNORE INTO model_category (model, category, source, needs_size, notes)
VALUES ('IX7694','bags','manual',0,'사용자 확인 가방 (Step 17-C)');

COMMIT;
