# 종단 측량 뷰어 모바일 앱

**토목 공사 종단측량을 위한 Flutter 모바일 애플리케이션**

측점 데이터 관리, 레벨 계산, DXF 도면 뷰어를 하나의 앱에서 제공합니다.

---

## 📱 주요 기능

### 1. 데이터 관리
- 📊 측점 데이터 테이블 (가로 스크롤)
- 📁 Excel/CSV 파일 import/export
- 🔢 자동 보간 (플러스 체인: +5m, +10m, +15m)
- 🔍 측점 검색 및 필터링
- 💾 SQLite 로컬 저장소

### 2. 레벨 계산
- 📐 IH (기계고) 기반 레벨 계산
- 🎯 읽을 값 자동 계산: `IH - 계획고`
- ✂️ 절/성토 자동 판정 (CUT/FILL/ON_GRADE)
- 📝 현장 측정값 저장
- 📈 절/성토 통계

### 3. DXF 도면 뷰어
- 🗺️ DXF 파일 로드 및 표시
- 🔍 핀치 줌, 팬 제스처
- 📍 좌표 선택 (터치)
- 🎨 레이어 관리
- 📊 실시간 좌표 표시

### 4. 프로젝트 관리
- 📂 여러 프로젝트 관리
- ⚙️ 프로젝트별 설정
- 🔄 프로젝트 전환
- 💾 자동 저장

---

## 🚀 시작하기

### 필수 요구사항

- Flutter SDK 3.35.4 이상
- Dart 3.9.2 이상
- Android Studio 또는 VS Code
- Android 기기/에뮬레이터 또는 iOS 시뮬레이터

### 설치

```bash
# 저장소 클론
cd longitudinal_viewer_mobile

# 패키지 설치
flutter pub get

# 앱 실행
flutter run
```

---

## 📦 사용된 패키지

### 핵심 패키지
- `sqflite` - SQLite 데이터베이스
- `provider` - 상태 관리
- `excel` - Excel 파일 처리
- `csv` - CSV 파일 처리
- `file_picker` - 파일 선택
- `xml` - DXF 파일 파싱 (XML 기반)

### 유틸리티
- `path_provider` - 파일 경로
- `shared_preferences` - 설정 저장
- `intl` - 국제화 및 포맷팅
- `collection` - 컬렉션 유틸리티

---

## 🏗️ 프로젝트 구조

```
lib/
├── main.dart                    # 앱 진입점
├── models/                      # 데이터 모델
│   ├── station_data.dart        # 측점 데이터
│   └── project_data.dart        # 프로젝트 데이터
├── services/                    # 비즈니스 로직
│   ├── database_service.dart    # SQLite DB
│   ├── interpolation_service.dart # 보간
│   └── level_calculation_service.dart # 레벨 계산
├── screens/                     # 화면
│   ├── main_screen.dart         # 메인 (탭 네비게이션)
│   ├── data_table_screen.dart   # 데이터 테이블
│   ├── level_panel_screen.dart  # 레벨 계산
│   ├── dxf_viewer_screen.dart   # DXF 뷰어
│   └── projects_screen.dart     # 프로젝트 관리
├── widgets/                     # 재사용 위젯
└── utils/                       # 유틸리티
```

---

## 💾 데이터베이스 스키마

### projects 테이블
- `id` - 프로젝트 ID
- `name` - 프로젝트 이름
- `file_path` - Excel 파일 경로
- `created_at` - 생성일
- `last_modified` - 수정일
- `settings` - 프로젝트 설정 (JSON)
- `is_active` - 활성 프로젝트 여부

### stations 테이블
- `id` - 측점 ID
- `project_id` - 프로젝트 ID (FK)
- `no` - 측점 번호 (예: "NO.1+5")
- `distance` - 누가거리
- `gh`, `ip`, `gh_d`, `gh1~5` - 계획고 컬럼
- `x`, `y` - 좌표
- `actual_reading` - 읽은 값
- `target_reading` - 읽을 값
- `cut_fill` - 절/성토 차이
- `cut_fill_status` - 상태 (CUT/FILL/ON_GRADE)
- `is_interpolated` - 보간 데이터 여부

---

## 📐 레벨 계산 공식

### 읽을 값 (목표값)
```
읽을 값 = IH - 계획고
```

### 절/성토 차이
```
차이 = 읽을 값 - 읽은 값
```

### 절/성토 판정
- **CUT (절토)**: 차이 > 0.5mm → 파내야 함
- **FILL (성토)**: 차이 < -0.5mm → 쌓아야 함
- **ON_GRADE (계획고)**: -0.5mm ~ +0.5mm → 맞음

---

## 🔧 개발 현황

현재 개발 진행률: **약 15%**

✅ 완료:
- 프로젝트 초기 설정
- 데이터 모델 및 서비스
- UI 기본 구조 (4개 탭)

🔄 진행 중:
- Provider 상태 관리
- Excel 파일 처리
- 데이터 테이블 구현

📋 계획:
- DXF 뷰어 구현
- 측점 동기화
- 고급 기능

상세 진행상황: [DEVELOPMENT_CHECKLIST.md](DEVELOPMENT_CHECKLIST.md)

---

## 🎯 모바일 최적화

### 화면 구성
- **탭 기반 네비게이션** - 작은 화면에서 효율적
- **가로 스크롤 테이블** - 많은 컬럼 표시
- **플로팅 버튼** - 빠른 액세스
- **카드 레이아웃** - 정보 구조화

### 터치 최적화
- 큰 버튼 (최소 48x48)
- 핀치 줌 제스처
- 스와이프 네비게이션
- 탭하여 선택

---

## 📖 사용 가이드

### 1. 새 프로젝트 시작
1. '프로젝트' 탭 → '새 프로젝트'
2. 프로젝트 이름 입력
3. Excel 파일 가져오기 (선택)

### 2. 측점 데이터 입력
1. '데이터' 탭
2. Excel 가져오기 또는 수동 입력
3. 보간 실행 (플러스 체인 생성)

### 3. 레벨 계산
1. '레벨' 탭
2. 측점 선택
3. IH 입력 → 읽을 값 자동 계산
4. 읽은 값 입력 → 절/성토 자동 판정
5. 저장

### 4. DXF 도면에서 좌표 선택
1. '도면' 탭
2. DXF 파일 로드
3. 좌표 선택 모드 활성화
4. 도면에서 탭하여 좌표 선택
5. 측점에 좌표 저장

---

## 🔗 관련 프로젝트

- **Python 데스크톱 버전**: `../python/app/`
- **문서**: `../python/app/doc/`

---

## 📝 라이선스

MIT License

---

## 👨‍💻 개발자

YSC Engineering

---

## 🐛 버그 리포트 및 기능 제안

이슈를 제출하거나 Pull Request를 보내주세요.
