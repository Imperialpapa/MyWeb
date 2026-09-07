# 작업 기록

## 2026-09-07

### 분야
- **AI 에이전트** 분야 추가 (하위: 에이전트 도구, 프레임워크·SDK, MCP·연동, 프롬프트·스킬, 학습자료)
- `supabase/seed-3.sql`: settings.categories 에 분야를 합치는 SQL(중복 실행 안전) + 자료 11개
- `supabase/seed-3.json`: 같은 내용. 운영자로 JSON 가져오기 하면 분야도 같이 들어감
- `schema.sql` 기본 분야, `index.html` 미리보기 기본 분야(DEFAULT_CATS)에 반영
- Supabase 에 `seed-3.sql` 실행 완료. settings 에 분야 3개(개발·도구, 생활·건강·취미, AI 에이전트), 자료 총 49개 확인
- **유머** 분야 추가 (하위: 만화·웹툰, 개발자 유머, 밈·인터넷 문화, 이스터에그·장난)
- `supabase/seed-4.sql`: 같은 방식의 분야 합치기 SQL(중복 실행 안전) + 자료 12개 (링크 9, 스니펫 2, 메모 1)
- `supabase/seed-4.json`: 같은 내용. 운영자로 JSON 가져오기 하면 분야도 같이 들어감
- `schema.sql` 기본 분야, `index.html` DEFAULT_CATS 에 반영. **Supabase 실행은 아직 안 함**
- 자료는 출처가 분명한 곳(공식 사이트·위키·공개 저장소)만. 정치·종교 풍자, 특정 인물 조롱, 밈 이미지 직링크는 제외
- `add-category.md` 5단계 변환 스크립트 주의: 정규식을 템플릿 리터럴로 만들어서 `\d` `\w` `\(` 의 역슬래시가 사라진다(매칭 0건). 역슬래시를 두 번 쓴 판으로 변환했다. 같은 이유로 `seed-3.json` 은 본문 줄바꿈이 진짜 줄바꿈이 아니라 문자 그대로 `\n` 으로 들어가 있다 (SQL 로 넣었으므로 실제 DB 는 정상). `seed-4.json` 은 줄바꿈을 제대로 넣었다

### 에이전트
- `.claude/agents/add-category.md`: 분야 추가 전담 Claude Code 서브에이전트. seed SQL/JSON 생성, 기본 분야·README 갱신, JSON 검증까지 수행

### 서비스 안 AI 에이전트 (분류 담당)
- `supabase/functions/ai/index.ts`: Supabase Edge Function. 브라우저 대신 Claude API(`claude-opus-5`, 구조화 출력)를 호출. 세 가지 일:
  - `suggest` — 올릴 때 분야·하위분야·태그(빈 제목·설명도) 제안. 로그인 사용자
  - `organize` — 항목 30개씩 다시 분류해 바꿀 것만 제안. 운영자
  - `taxonomy` — 전체 자료를 보고 분야·하위분야 구조 개편안. 운영자
  - 함수는 읽기만 하고, 적용은 브라우저가 사용자 권한(RLS)으로 함. 로그인·운영자 확인은 함수 안에서 직접
- `index.html`: 새 항목 창에 **✦ AI 분류 제안** 버튼, 분야 옆·더 보기에 운영자용 **✦ AI 정리** 창(재분류 표 → 체크 적용, 구조 개편안 → 고쳐서 저장). `patch` 가 분야·태그도 고치도록 확장. 분야 텍스트 파싱을 `catsToText`/`parseCatText` 로 분리
- `config.js` `AI: true` 스위치. `supabase/config.toml`(함수 JWT 게이트웨이 검사 끔), `.gitignore` 에 CLI 작업 폴더
- README 7단계 "AI 기능 켜기" (Anthropic 키 발급 → `npx supabase` 로 secret 등록·배포)
- **배포 완료** (2026-09-07): Edge Function `ai` 배포, `ANTHROPIC_API_KEY` secret 등록, `schema.sql` 재실행, Vercel 배포 확인
  - 확인한 것: 인증 없이 호출 → 401, CORS preflight → 200, 배포된 index.html 에 감사 수정 반영됨
  - `supabase login` 은 브라우저(TTY)가 필요해 Claude Code 안에서는 안 되고 별도 PowerShell 창에서 해야 한다
  - `secrets list` 는 키를 해시로만 보여 준다 (실제 값 노출 없음)
  - 첫 등록 때 안내문의 `sk-ant-...` 를 그대로 넣어 "ANTHROPIC_API_KEY 가 올바르지 않습니다" 가 났다.
    `secrets list` 의 해시와 후보 문자열의 SHA-256 을 비교해 원인을 특정했고, 실제 키로 다시 등록하니 재배포 없이 바로 동작했다.
  - **AI 분류 제안 동작 확인 완료** (사이트에서 항목 추가 성공)

### 코드 감사 (다중 에이전트, 발견 83건)
6개 관점(로직·보안·Edge Function·성능·데이터·UX)으로 탐색한 뒤 발견마다 3명이 반박을 시도하는 방식으로 검증. **고친 것:**

| 문제 | 고친 곳 |
|---|---|
| **저장형 XSS** — 항목·모음·신고의 id 가 `data-*` 속성에 이스케이프 없이 들어가, 로그인한 누구나 방문자(운영자 포함) 브라우저에서 스크립트를 실행시킬 수 있었음 | `index.html` 속성 15곳 `esc()`, 가져오기 id 검증, `schema.sql` id 형식 제약 |
| **운영자가 남의 항목을 수정하면 항상 42501 실패** — `upsert` 는 Postgres 가 INSERT 정책(`owner_id = auth.uid()`)을 새 행에도 적용한다 | `put`/`putCol` 을 insert/update 로 분리. 수정 시 `owner_id` 를 안 보내므로 소유권 이전 문제도 사라짐 |
| **백업 복원이 소유권을 빼앗음** — JSON 가져오기가 모든 항목의 `owner_id` 를 가져온 사람으로 덮어씀 | 기존 항목은 `by`·`ownerId`·`createdAt`·`updatedAt` 유지 |
| **AI 호출 비용 무제한** — 로그인만 하면 횟수·입력 크기 제한 없이 호출 가능 | `ai_take_quota` 함수(하루 40회, 운영자 600회), 본문 32KB·필드별 길이 상한 |
| **AI 응답이 잘려 실패** — `claude-opus-5` 는 thinking 이 기본 켜짐이고 `max_tokens` 는 (thinking + 응답) 합계 상한 | 4096 / 16000 / 16000 으로 상향, taxonomy 는 effort medium |
| `javascript:` 링크가 그대로 href 로 렌더 | `safeUrl()` 로 http(s)·mailto 만 허용 |
| 추천 수를 항목 주인이 REST 로 직접 조작 가능 | `votes` 컬럼 update 권한 회수 (트리거만 변경) |
| 한글 입력 확정 Enter 가 검색창을 벗어나 첫 항목을 여는 오동작 | `isComposing` 확인 |
| 버튼·링크 포커스 상태의 Enter 를 가로챔 | 대상 태그 확인 |
| 종류를 바꿔 URL 칸을 숨겨도 `type=url` 검증이 남아 저장이 조용히 실패 | 숨길 때 `disabled` |
| AI 정리 창을 닫아도 배치 호출이 계속되고 TypeError | 창 존재 확인 후 중단 |
| 조회 실패가 "아직 항목이 없습니다" 로 표시 | 실패 메시지 별도 표시 |
| iOS 에서 입력칸 포커스마다 화면 확대 | 좁은 화면 입력칸 16px |
| 인덱스 부족 (분야 필터, votes 의 RLS 필터) | `items_category_idx`, `votes_user_idx` |

**안 고치고 남긴 것** (todo.md 참고): 전체 재렌더·전체 테이블 재조회 같은 성능 개선, URL 라우팅, 접근성(포커스 트랩·aria-live·명도 대비), `.limit(5000)` 이 Supabase 기본 1000행에 잘리는 문제.

### 분야 주 관리자
- 분야마다 담당자를 지정한다. 지정하지 않으면 운영자가 담당.
- 담당자 권한: **그 분야 자료의 수정·삭제, 그 분야 신고의 검토·닫기**. 다른 분야는 손댈 수 없고, 분야를 만들거나 지우거나 담당자를 지정할 수는 없다.
- 저장 위치: `settings.categories` 의 각 분야에 `owner`(사용자 id) + `ownerName`(닉네임 스냅샷).
  닉네임을 함께 저장하는 이유는 로그인하지 않은 방문자도 담당자를 볼 수 있어야 하는데, 프로필 조회는 막혀 있기 때문이다.
- 권한은 화면이 아니라 DB 가 지킨다: `manages_category(cat)`, `manages_any()`, `manages_item(iid)` 세 함수 + items/reports 정책 확장.
  `items_update` 는 using 에 `manages_category(category)`, with check 에 `manages_any()` 를 쓴다.
  잘못 분류된 자료를 맞는 분야로 **옮길 수 있어야** 하는데 with check 는 바뀐 뒤의 행만 보기 때문이다.
- 지정 화면: 운영자만. ⋯ → 분야 주 관리자. 운영자는 이미 전체 프로필 조회 권한이 있어 **권한 규칙을 열지 않았다**. 목록에는 닉네임만 나온다.
- 담당자 지정이 지워지지 않도록 세 경로를 막았다: `normCats`(보존), `parseCatText`(이름으로 이어 붙임), JSON 가져오기(파일의 owner 는 무시).

### 알게 된 것 — 카카오가 주는 사용자 정보
- Supabase 는 카카오 닉네임을 `name`·`full_name`·`preferred_username`·`user_name` **네 키에 모두 같은 값으로** 넣는다.
  `nickname` 키에는 넣지 않는다. 즉 사이트가 읽는 네 키가 이미 전부이고, 다른 키로 새지 않는다.
  (supabase/auth 의 `internal/api/provider/kakao.go` 매핑 확인. 2023년 도입 이래 바뀐 적 없음)
- 사용자가 **닉네임 동의를 거부하면 그 다섯 키(위 넷 + avatar_url)가 통째로 사라진다.** 빈 문자열이 아니라 키 자체가 없다.
  남는 것은 `email_verified, iss, phone_verified, provider_id, sub` 다섯 개뿐이다.
- 실제로 그런 계정이 하나 생겼다(2026-09-05 가입). 코드 결함이 아니라 카카오가 아무것도 주지 않은 것이다.
  → 해결책은 코드가 아니라 **카카오 콘솔에서 닉네임을 필수 동의로 올리는 것**. todo 에 남김.
- 이메일 미동의 시 `auth.users.email` 은 NULL 이고 가짜 주소는 만들어지지 않는다.

### 개인정보 (공개 확장 대비)
- **카카오 닉네임을 조용히 저장하던 것을 중단**. 카카오 프로필 이름은 본명인 경우가 많은데, 그대로 저장되면 올리는 자료마다 비로그인 방문자에게까지 공개됐다.
  이제 이름 창에 **미리 채워 보여 주기만** 하고, 사용자가 확인·수정한 뒤에 저장된다.
- 이름 창 문구에 "로그인하지 않은 사람에게도 보입니다" 명시, 본명 대신 닉네임 권장.
- **이름을 바꾸면 예전에 올린 자료의 이름도 함께 바뀐다** (`renamePast`). `by` 가 항목마다 복사되는 구조라 이걸 하지 않으면 옛 이름이 영구히 남았다.

### 사이드바
- 종류·분야·모음을 태그처럼 **접히는 섹션**으로 변경 (분야가 늘어나면 목록이 길어지므로).
- 접은 상태에서도 제목줄에 현재 고른 종류·분야가 보인다. 여닫은 상태는 브라우저에 기억된다.
- 기본값: 넓은 화면은 펼침, 좁은 화면은 접힘.
- 선택한 분야 아래에 담당자 한 줄 표시.

### 기타
- `.gitignore` 에 `supabase/톡연계정보.txt` 추가 (카카오 키 파일, 커밋 금지), 화면 캡처 파일도 제외
- AI 호출 한도를 **호출 전에 차감**하던 문제 수정. 키 만료·네트워크 등 우리 쪽 이유로 실패하면 `ai_refund_quota` 로 돌려준다.
  키 만료를 알아보기 쉽게 오류 문구도 "AI 키가 만료되었거나 올바르지 않습니다" 로 변경.

## 2026-09-04

### 배포
- GitHub 저장소 `Imperialpapa/MyWeb` 에 첫 커밋·푸시 (브랜치 `main`, 원격 `origin` 연결)
- Vercel 자동 배포 연결. 공개 주소: https://my-web-imperialpapas-projects.vercel.app
- Vercel **Deployment Protection(Vercel Authentication)** 해제 → 로그인 없이 누구나 접속 가능
- 해시 붙은 주소(`my-xxxx-...vercel.app`)는 특정 시점 배포라 공유용으로 쓰지 않기로 함

### 데이터베이스 (Supabase `csxndscngmkciibarumi`)
- 운영자 지정 트리거 수정: SQL Editor(로그인 컨텍스트 없음)에서 `is_admin` 변경 허용 (`schema.sql`)
- 추가 자료 20개 작성: 개발·도구 10 + 생활·건강·취미 10 (`supabase/seed-2.sql`, `seed-2.json`)
- 사이트 JSON 가져오기로 20개 반영 → 총 38개

### 로그인
- 이메일 매직링크 재전송 제한 시 한글 안내 + 카운트다운 버튼
- 회사 메일 보안 스캐너가 링크를 먼저 열어 `otp_expired` 가 나는 문제 확인 → **6자리 코드 입력** 방식 추가
- 페이지 진입 시 주소의 auth 오류(`#error=...`)를 읽어 안내
- **카카오 로그인** 버튼 추가 (`config.js` `AUTH_PROVIDERS` 로 제어, 이메일 코드는 예비)
- 카카오 개발자 콘솔 설정 완료: REST API 키·클라이언트 시크릿·리다이렉트 URI, 개인 개발자 비즈 앱 전환, 동의항목(닉네임·프로필 사진·이메일 선택 동의)
- Supabase Kakao 제공자 설정 완료 → 카카오 로그인 성공 확인
- 첫 소셜 로그인 시 카카오 닉네임을 이름으로 자동 저장, 이메일 없는 계정도 메뉴 표시 정상

### 화면
- 모바일: 태그 목록을 접히는 섹션(`details`)으로 바꾸고 본문 아래로 이동. 데스크톱은 펼침 유지
- 접힌 상태에서도 태그 수와 선택한 태그가 제목에 표시

### 아이콘
- 앱 아이콘 제작: 선글라스 낀 노장 거북이 번개를 쥔 원작 캐릭터, 애니 셀 채색 스타일 (`icon.png`, 512px)
- 카카오 콘솔 앱 아이콘으로 등록

### 문서
- README: 카카오 설정(개편 콘솔 기준), 이메일 코드 템플릿, 운영자 지정(이메일/이름), 새 파일 설명, 섹션 번호 정리

### 커밋
| 커밋 | 내용 |
|---|---|
| `217a22c` | 초기 커밋 |
| `910cbbf` | 운영자 트리거 수정, 재전송 안내, 자료 20개 |
| `3790823` | 6자리 코드 로그인, 만료 링크 안내 |
| `48d9c32` | 카카오 로그인 버튼 |
| `8acc297` | README 문구 정리 |
| `81bac66` | 모바일 태그 섹션 하단 접힘 |
| `ad11a2c` | README 카카오 개편 콘솔 경로 |
| `8e150f1` | 이메일 없는 계정 지원 |
| `8be655e` | README 비즈 앱 전환 필수 안내 |

### 알게 된 것
- Supabase 는 카카오에 `account_email` 을 항상 요청한다. 카카오 앱에 이메일 동의항목이 없으면 무조건 KOE205 → 비즈 앱 전환이 필수. "Allow users without an email" 옵션은 사용자가 동의 화면에서 이메일 체크를 뺀 경우만 구제한다.
- 개인 개발자도 본인인증 + 카카오비즈니스 약관 동의로 비즈 앱 전환 가능 (사업자등록번호 불필요). 앱 아이콘 등록이 선행 조건.
- 카카오 콘솔 개편 후 클라이언트 시크릿은 **앱 → 플랫폼 키 → REST API 키** 안에 있고 기본 활성화 상태.
- Supabase 이메일 OTP 최소 길이는 6자리 (4자리 불가).
- 푸시 시 Git Credential Manager 창 때문에 멈추면 `gh auth setup-git` 으로 해결.
