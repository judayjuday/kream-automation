# KREAM 판매자센터 자동화

Playwright 기반 KREAM 판매자센터 상품 고시정보 입력 & 입찰 자동화 도구

## 설치

```bash
# 1. Python 패키지 설치
pip install playwright openpyxl

# 2. Playwright 브라우저 설치
playwright install chromium
```

## 파일 구조

```
kream_automation/
├── kream_bot.py              # 메인 자동화 스크립트
├── kream_data_template.xlsx  # 데이터 입력용 엑셀 템플릿
├── auth_state.json           # (자동 생성) 로그인 상태 저장
└── README.md
```

## 사용법

### 1단계: 엑셀에 데이터 입력

`kream_data_template.xlsx`을 열어서:

- **상품정보** 시트: 상품별 고시정보 입력
- **입찰데이터** 시트: 입찰할 상품/가격/기간 입력
- **설정** 시트: 로그인 정보, 딜레이 등 설정

### 2단계: 실행

```bash
# 상품 고시정보만 입력
python kream_bot.py --mode product

# 입찰만 등록
python kream_bot.py --mode bid

# 둘 다
python kream_bot.py --mode all

# 다른 엑셀 파일 지정
python kream_bot.py --mode product --excel my_data.xlsx
```

### 3단계: 첫 실행 시 로그인

- 설정 시트에 이메일/비밀번호를 넣으면 자동 로그인 시도
- 비밀번호를 비워두면 브라우저에서 수동 로그인 → Enter
- 로그인 후 `auth_state.json`에 세션 저장 → 다음부턴 자동

## 엑셀 필드 ↔ KREAM 폼 매핑

| 엑셀 컬럼 | KREAM 필드 | input name / 타입 |
|---|---|---|
| product_id | 상품 ID | URL 경로 |
| 고시카테고리 | 고시 카테고리 | categoryName (드롭다운) |
| 종류 | 종류 | attributeSet.0.value |
| 소재 | 소재 | attributeSet.1.value |
| 색상 | 색상 | attributeSet.2.value |
| 크기 | 크기 | attributeSet.3.value |
| 제조자_수입자 | 제조자/수입자 | attributeSet.4.value |
| 제조국 | 제조국 | attributeSet.5.value |
| 취급시_주의사항 | 취급시 주의사항 | attributeSet.6.value |
| 품질보증기준 | 품질보증기준 | attributeSet.7.value |
| AS_전화번호 | AS 책임자와 전화번호 | attributeSet.8.value |
| 원산지 | 원산지 | countryOfOriginId (드롭다운) |
| HS코드 | HS 코드 | hsCodeId (드롭다운) |
| 상품무게_kg | 상품 무게(kg) | productWeight |
| 박스가로_cm | 박스 가로(cm) | boxWidth |
| 박스세로_cm | 박스 세로(cm) | boxHeight |
| 박스높이_cm | 박스 높이(cm) | boxDepth |

## 주의사항

- KREAM은 Next.js(React) 기반이라 단순 `.fill()`이 안 먹힐 수 있음
  → `react_clear_and_fill()` 함수에서 키보드 이벤트로 처리
- 드롭다운(고시카테고리, 원산지, HS코드)은 텍스트 매칭으로 선택
- KREAM UI가 업데이트되면 셀렉터 수정 필요할 수 있음
- 과도한 속도로 돌리면 차단 가능 → delay 설정 권장 (최소 2~3초)

## 입찰 자동화 완성하려면

입찰 페이지(`/business/ask-sales` 또는 `/business/products`)의 HTML을 
Ctrl+S로 저장해서 보내주시면 셀렉터를 맞춰드립니다.

## 해외 가격 수집 프로그램 연동

가격 수집 프로그램에서 CSV/엑셀로 출력 → 이 엑셀 템플릿 형식에 맞춰 변환 → 
kream_bot.py로 자동 입찰하면 파이프라인 완성입니다.
