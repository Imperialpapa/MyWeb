# 할 일

## 바로 할 것
- [ ] **운영자 지정**: Supabase SQL Editor 에서 실행 (README 6단계). 실행 후 사이트에 "운영자" 표시·"검토함" 버튼 확인
  ```sql
  update public.profiles set is_admin = true
    where id = (select id from auth.users where email = '카카오 계정 이메일');
  ```
- [ ] **Supabase 이메일 템플릿**에 `{{ .Token }}` 넣기 (README 3단계). 안 넣으면 메일에 6자리 코드가 안 실림
- [ ] Supabase **URL Configuration**: `Site URL` = 공개 주소, `Redirect URLs` 에 `https://my-web-imperialpapas-projects.vercel.app/**` 확인
- [ ] 팀원 2~3명에게 공개 주소 공유해서 카카오 로그인·올리기·검색 한 번씩 해 보게 하기

## 사이트 다듬기
- [ ] `icon.png` 를 파비콘(브라우저 탭)과 카카오톡 링크 미리보기(`og:image`)로 연결
- [ ] 카카오톡 공유 시 제목·설명 미리보기 문구 정하기 (`og:title`, `og:description`)
- [ ] 모바일에서 종류·분야 필터도 너무 길면 접기 검토
- [ ] 첫 방문자용 짧은 안내 (무엇을 올리는 곳인지 한 줄, 로그인은 카카오 한 번)
- [ ] 로그인 창에서 이메일 방식은 "다른 방법으로 로그인" 아래에 숨길지 검토

## 로그인·계정
- [ ] Google 로그인 추가 여부 결정. 붙이면 Google Cloud OAuth 클라이언트 생성 후 `config.js` `AUTH_PROVIDERS` 에 `"google"` 추가
- [ ] 카카오 앱: 사업자등록번호가 생기면 비즈니스 정보 갱신 → 이메일 **필수 동의** 로 변경 (지금은 선택 동의라 이메일 없는 계정이 생길 수 있음)
- [ ] 같은 사람이 카카오·이메일로 각각 가입해 계정이 둘이 되는 경우 대응 (안내 문구 또는 계정 연결)

## 운영
- [ ] 사용자가 늘면 Supabase **SMTP** 를 Resend 등 외부 서비스로 교체 (기본 메일은 시간당 몇 통 제한)
- [ ] 도메인 연결 (Vercel Settings → Domains). 연결 후 Supabase `Site URL`, 카카오 플랫폼 도메인도 갱신
- [ ] Supabase 무료 티어 한도(용량·요청) 모니터링, 백업은 `⋯ → 파일로 관리 → JSON 내보내기` 로 주기적으로
- [ ] `gh auth setup-git` 실행해 두기 (푸시 시 자격 증명 창 멈춤 방지)

## 나중에
- [ ] 분야·하위분야 확장 (지금은 개발·도구 / 생활·건강·취미 2개)
- [ ] 자료 품질 관리 규칙: 신고 검토 기준, 중복 링크 처리
- [ ] 아티팩트 버전("도구함")은 조직 내부 전용이므로 정리하거나 링크만 남기기
