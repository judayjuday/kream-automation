# 스스로(SSRO) 주문관리 시스템

## 🚀 빠른 시작

### 1. Supabase 설정

`.env.example` 파일을 복사해서 `.env` 파일 생성:

```bash
cp .env.example .env
```

`.env` 파일 열어서 실제 값 입력:

```
VITE_SUPABASE_URL=https://fbkqsznoxjwevhgjnujt.supabase.co
VITE_SUPABASE_ANON_KEY=실제_anon_key_여기에
```

### 2. 패키지 설치 (네트워크 필요)

```bash
npm install
```

### 3. 개발 서버 실행

```bash
npm run dev
```

브라우저에서 자동으로 열림: http://localhost:3000

## 📁 프로젝트 구조

```
ssro-app/
├── src/
│   ├── components/      # 재사용 컴포넌트
│   ├── pages/          # 페이지 컴포넌트
│   │   └── OrderCollection.jsx  # 주문 수집 페이지
│   ├── lib/            # 유틸리티
│   │   └── supabase.js # Supabase 클라이언트
│   ├── hooks/          # 커스텀 훅
│   ├── App.jsx         # 메인 앱
│   ├── main.jsx        # 엔트리 포인트
│   └── index.css       # 전역 CSS
├── .env                # 환경변수 (gitignore)
├── package.json        # 의존성
└── vite.config.js      # Vite 설정
```

## 🎯 현재 기능

- ✅ 엑셀 파일 드래그 앤 드롭 업로드
- ✅ 엑셀 데이터 미리보기
- ✅ Supabase DB 저장
  - raw_orders: 원본 데이터
  - orders: 변환된 주문 데이터
- ✅ 실시간 토스트 알림

## 🔜 개발 예정

- [ ] 개인통관부호 API 연동
- [ ] 품번/사이즈/컬러 자동 추출
- [ ] 중복 주문 감지
- [ ] 재고 소진 예측 대시보드

## 📝 노트

- React 18 + Vite
- Tailwind CSS
- Supabase (PostgreSQL)
