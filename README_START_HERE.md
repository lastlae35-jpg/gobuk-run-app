# 거북팀 훈련 입력 웹앱 새 설치 설명서

이번 버전은 처음부터 다시 시작하는 깨끗한 버전입니다.
기존에 꼬인 파일, 패치 파일은 전부 무시하고 이 폴더의 파일만 사용하세요.

## 들어있는 기능

- 모바일 보기 최적화
- 이름 + 비밀번호 로그인
- 회원가입 창
- 가입 전 보안 안내문구와 확인 체크박스
- 본인 훈련 기록 입력/수정/삭제
- 내 현황: 누적거리, 거리 달성률, 실행률
- 내 정보 입력/수정
- 비밀번호 변경
- 관리자 전체 현황 확인
- 관리자 회원 추가
- 관리자 회원정보/기록 CSV 다운로드
- 거북팀 4시간 20분 언더 하계 훈련표 154일치 포함

## 파일 역할

```text
index.html                         화면 뼈대
style.css                          디자인
app.js                             기능
config.js                          Supabase 연결 설정, 딱 4줄만 있어야 함
01_SUPABASE_FULL_RESET_INSTALL.sql Supabase 전체 새 설치 SQL
```

## 1단계. Supabase 새 프로젝트 만들기

Supabase에 로그인한 뒤 새 프로젝트를 만듭니다.

```text
New project
→ 프로젝트 이름 입력 예: gobuk-run-fresh
→ Database Password 설정
→ Region 선택
→ Create new project
```

## 2단계. Supabase SQL 실행

Supabase 프로젝트에서:

```text
SQL Editor
→ New query
```

`01_SUPABASE_FULL_RESET_INSTALL.sql` 파일 내용을 전부 복사해서 붙여넣고 Run 합니다.

성공하면 마지막에 이런 결과가 나옵니다.

```text
status: 설치 완료
training_plan_count: 154
member_count: 1
```

초기 관리자 계정은 아래입니다.

```text
이름: 관리자
비밀번호: 1234
```

## 3단계. Supabase URL과 key 복사

Supabase에서:

```text
Project Settings
→ API
```

아래 2개를 복사합니다.

```text
Project URL
anon public key 또는 publishable key
```

절대 넣으면 안 되는 것:

```text
service_role key
secret key
```

## 4단계. config.js 수정

`config.js` 파일은 딱 4줄이어야 합니다.
파일이 길면 전부 지우고 아래 4줄만 남기세요.

```js
window.GOBUK_CONFIG = {
  supabaseUrl: "https://YOUR-PROJECT.supabase.co",
  supabaseAnonKey: "YOUR_PUBLIC_ANON_KEY"
};
```

위 2곳을 본인 Supabase 값으로 바꿉니다.

```js
window.GOBUK_CONFIG = {
  supabaseUrl: "https://abcdxyz.supabase.co",
  supabaseAnonKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6..."
};
```

## 5단계. GitHub 새 저장소 만들기

GitHub에서 새 저장소를 만듭니다.

```text
New repository
→ 이름 예: gobuk-run-fresh
→ Public
→ Create repository
```

## 6단계. 파일 업로드

GitHub 저장소 첫 화면에서:

```text
Add file
→ Upload files
```

아래 파일 5개를 저장소 맨 위에 바로 올립니다.

```text
index.html
style.css
app.js
config.js
01_SUPABASE_FULL_RESET_INSTALL.sql
```

정상 구조:

```text
gobuk-run-fresh
├ index.html
├ style.css
├ app.js
├ config.js
└ 01_SUPABASE_FULL_RESET_INSTALL.sql
```

나쁜 구조:

```text
gobuk-run-fresh
└ gobuk_run_app_fresh
   ├ index.html
   ├ style.css
   └ app.js
```

폴더째 올리면 안 됩니다. 파일만 올리세요.

## 7단계. GitHub Pages 켜기

GitHub 저장소에서:

```text
Settings
→ Pages
```

아래처럼 설정합니다.

```text
Source: Deploy from a branch
Branch: main
Folder: /root
Save
```

잠시 기다리면 주소가 나옵니다.

```text
https://내아이디.github.io/gobuk-run-fresh/
```

이 주소가 실제 앱 주소입니다.

## 8단계. 앱 접속 후 테스트

앱 주소로 접속 후 관리자 로그인:

```text
이름: 관리자
비밀번호: 1234
```

로그인 후 바로 할 일:

```text
내 정보 → 비밀번호 변경
```

기본 관리자 비밀번호 1234는 운영 전에 꼭 바꾸세요.

## 404가 뜰 때

대부분 이 문제입니다.

```text
index.html이 저장소 맨 위/root에 없음
GitHub Pages 설정이 main / root가 아님
Pages 배포가 아직 완료되지 않음
```

GitHub 저장소 첫 화면에 `index.html`이 바로 보여야 합니다.

## Supabase 설정이 필요합니다 라고 뜰 때

`config.js`가 없거나 값이 아직 아래 상태입니다.

```js
supabaseUrl: "https://YOUR-PROJECT.supabase.co"
supabaseAnonKey: "YOUR_PUBLIC_ANON_KEY"
```

`config.js`를 4줄만 남기고 본인 Supabase 값으로 바꾸세요.
