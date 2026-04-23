---
name: api-addition
description: 새 Flask API 추가 시 자동 적용됨
---

# API 추가 규칙

## 필수 포함

### 1. 에러 응답도 JSON (HTML 에러 페이지 금지)
```python
@app.route("/api/example", methods=["POST"])
def api_example():
    try:
        # 로직
        return jsonify({"ok": True, "data": result})
    except Exception as e:
        return jsonify({"error": str(e)}), 500
```

### 2. 응답 구조 표준화
- 성공: `{"ok": true, "data": ...}` 또는 `{"items": [...]}` 등 명확한 구조
- 실패: `{"ok": false, "error": "에러 메시지"}` 또는 `{"error": "에러 메시지"}`
- 빈 목록: `{"items": []}` (null 반환 금지)

### 3. 입력 검증
```python
data = request.json or {}
field = data.get("field", "").strip()
if not field:
    return jsonify({"error": "field 필수"}), 400
```

### 4. 라우트 충돌 검사
새 API 추가 후 반드시 실행:
```bash
grep -n '@app.route' kream_server.py | sort -t'"' -k2 | uniq -d -f1
```

### 5. curl 테스트
새 API마다 curl 테스트로 정상 동작 확인:
```bash
# GET 예시
curl -s http://localhost:5001/api/new-endpoint | python3 -m json.tool

# POST 예시
curl -s -X POST http://localhost:5001/api/new-endpoint \
  -H "Content-Type: application/json" \
  -d '{"key": "value"}' | python3 -m json.tool
```

## 금지사항
- HTML 에러 페이지 반환 금지 (Flask 기본 404/500)
- DB 커넥션 열어놓고 close 안 하는 것 금지
- 응답에 민감정보 포함 금지 (세션 토큰, 비밀번호 등)
