# 빠른 연결

링크, 메모, 코드, 자료를 누구나 올리고 검색으로 바로 찾는 공유 자료함.
읽기는 누구나, 올리기·추천·신고는 카카오 또는 이메일 로그인 후 가능합니다.

## 구성

| 파일 | 역할 |
|---|---|
| `index.html` | 사이트 전체 (화면 + 동작). 서버 코드 없음 |
| `config.js` | Supabase 주소·키, 사이트 이름 |
| `supabase/schema.sql` | 데이터베이스 표, 권한 규칙(RLS), 실시간 설정 |
| `supabase/seed.sql` | 초기 자료 18개 (선택) |
| `supabase/seed-2.sql` | 추가 자료 20개 (개발·도구 10, 생활·건강·취미 10). SQL Editor 용 |
| `supabase/seed-2.json` | 위와 같은 20개. 사이트의 ⋯ → 파일로 관리 → JSON 가져오기 용 |
| `supabase/seed-3.sql` | **AI 에이전트** 분야 추가 + 자료 11개. SQL Editor 용 |
| `supabase/seed-3.json` | 위와 같은 내용. JSON 가져오기 용 (운영자로 실행하면 분야도 함께 추가) |
| `supabase/seed-4.sql` | **유머** 분야 추가 + 자료 12개. SQL Editor 용 |
| `supabase/seed-4.json` | 위와 같은 내용. JSON 가져오기 용 (운영자로 실행하면 분야도 함께 추가) |
| `supabase/functions/ai/index.ts` | **서비스 안 AI 에이전트** (Supabase Edge Function). 올릴 때 분류 제안, 운영자용 재분류·분야 구조 제안. Claude API 키는 여기서만 쓰임 |
| `supabase/config.toml` | Supabase CLI 설정 (Edge Function 배포용) |
| `.claude/agents/add-category.md` | Claude Code 서브에이전트. "○○ 분야 추가해줘" 하면 seed 파일과 기본 분야를 만들어 줌 |

`config.js`가 비어 있으면 **미리보기 모드**로 동작합니다. 브라우저에만 저장되고, 운영자 화면을 미리 볼 수 있습니다. `index.html`을 더블클릭해 열어 보세요.

## 배포 순서 (약 20분)

### 1. Supabase 프로젝트 만들기

1. https://supabase.com/dashboard 에서 **New project**. 이름은 아무거나, Region 은 **Northeast Asia (Seoul)** 권장.
2. 왼쪽 메뉴 **SQL Editor** → **New query** → `supabase/schema.sql` 내용 전체를 붙여넣고 **Run**.
3. 초기 자료를 넣으려면 같은 방법으로 `supabase/seed.sql` 도 실행.
4. **Settings → API** 에서 두 값을 복사해 `config.js`에 넣기:
   - `Project URL` → `SUPABASE_URL`
   - `anon public` 키 → `SUPABASE_ANON_KEY`

### 2. 카카오 로그인 설정 (기본 로그인 방식)

`config.js`의 `AUTH_PROVIDERS`에 적힌 제공자만 로그인 창에 버튼으로 나옵니다. 기본값은 `["kakao"]` 입니다.
Supabase 쪽에서 아직 켜지 않은 상태로 버튼을 누르면 "아직 켜져 있지 않습니다" 안내가 뜹니다.

**카카오 개발자 콘솔** (https://developers.kakao.com)

(2025년 개편된 콘솔 기준. 옛 콘솔의 "앱 설정 → 앱 키", "제품 설정 → 보안" 메뉴는 없어졌습니다.)

1. **내 애플리케이션 → 애플리케이션 추가하기**. 앱 이름·회사명은 아무거나.
2. 왼쪽 메뉴 **앱 → 플랫폼 키** → **REST API 키** 복사. (JavaScript 키가 아닙니다.)
3. 같은 **REST API 키** 항목 안의 **클라이언트 시크릿** 코드 복사. 기본으로 "사용함" 상태이며 따로 생성할 필요 없습니다.
4. 같은 **REST API 키** 항목 안의 **리다이렉트 URI** 에 아래 주소 등록 (프로젝트 주소는 본인 것으로):
   ```
   https://csxndscngmkciibarumi.supabase.co/auth/v1/callback
   ```
5. 왼쪽 메뉴 **카카오 로그인**: 활성화 **ON**.
6. **비즈 앱 전환** (필수). Supabase 는 카카오에 항상 **이메일** 동의항목을 요청하는데, 이 항목은 비즈 앱에서만 설정할 수 있습니다. 전환하지 않으면 로그인 시 **KOE205** 오류가 납니다.
   - 먼저 **앱 → 일반** 에서 **앱 아이콘** 을 등록합니다 (전환 조건).
   - **앱 → 일반 → 비즈니스 정보 → 사업자 정보 등록**. 사업자등록번호가 있으면 입력하고, 없으면 **개인 개발자 본인인증 + 카카오비즈니스 약관 동의** 로도 전환됩니다. 앱 소유자(Owner) 계정으로만 가능합니다.
7. **카카오 로그인 → 동의항목**: **닉네임**, **프로필 사진**, **카카오계정(이메일)** 셋을 모두 설정합니다 (선택 동의로 충분). 하나라도 "미설정"이면 **KOE205** 가 납니다.
   - 사용자가 동의 화면에서 이메일 체크를 빼면 계정이 만들어지지 않으니, 아래 8번의 **Allow users without an email** 을 켜 두면 그런 경우도 로그인됩니다. 사이트는 이메일 없는 계정도 정상 동작합니다.
   - **닉네임은 필수 동의로 올리시길 권합니다.** 선택 동의로 두면 사용자가 체크를 뺄 수 있고, 그러면 카카오가 이름을 하나도 주지 않아 **표시 이름 없는 계정**이 생깁니다.
     이름이 없으면 주 관리자로 지정할 수 없고 누가 올렸는지도 알 수 없습니다. 닉네임은 민감도가 낮아 필수로 두어도 이탈이 크지 않습니다.
     (닉네임 미동의 시 카카오는 `name`·`full_name`·`preferred_username`·`user_name`·`avatar_url` 다섯 개를 통째로 빼고 식별자만 보냅니다. 사이트가 읽을 이름 자체가 없습니다.)

**Supabase 대시보드**

8. **Authentication → Providers → Kakao**: **Enabled** ON. 위에서 복사한 **REST API 키**를 `Client ID`에, **Client Secret** 을 `Client Secret`에 넣고, 이메일 동의항목을 못 켠 경우 **Allow users without an email** 도 ON 으로 한 뒤 Save.
9. **Authentication → URL Configuration**: `Site URL` 과 `Redirect URLs` 에 사이트 주소가 있는지 확인 (아래 3번 참고).

Google 도 붙이려면 Google Cloud Console → API 및 서비스 → 사용자 인증 정보 → **OAuth 클라이언트 ID (웹)** 를 만들고, 승인된 리디렉션 URI 에 같은 콜백 주소를 넣은 뒤 Supabase **Providers → Google** 에 ID·Secret 을 넣습니다. 그리고 `config.js`의 `AUTH_PROVIDERS`를 `["kakao", "google"]` 로 바꾸면 버튼이 생깁니다.

### 3. 로그인 메일 설정 (이메일 코드, 예비 방식)

1. **Authentication → Providers → Email**: 켜져 있는지 확인. **Confirm email** 은 꺼도 됩니다 (링크 클릭 자체가 확인).
2. **Authentication → URL Configuration**:
   - `Site URL`: 배포 주소 (예: `https://빠른연결.vercel.app`). 아직 없으면 배포 후에 채우세요.
   - `Redirect URLs`: 같은 주소와 `http://localhost:*` 추가.
3. **Authentication → Email Templates → Magic Link**: 본문에 6자리 코드가 함께 나가도록 아래처럼 바꿉니다. (회사 메일 보안 프로그램이 링크를 미리 열어 버려 "만료" 가 뜨는 경우, 코드로 로그인할 수 있습니다.)

   ```html
   <h2>빠른 연결 로그인</h2>
   <p>아래 6자리 코드를 사이트 로그인 창에 입력하세요.</p>
   <p style="font-size:28px;letter-spacing:6px"><b>{{ .Token }}</b></p>
   <p>또는 이 링크를 눌러도 로그인됩니다: <a href="{{ .ConfirmationURL }}">로그인</a></p>
   <p style="color:#888">본인이 요청하지 않았다면 이 메일은 무시하세요. 코드는 1시간 동안 유효합니다.</p>
   ```

   코드 길이는 **Authentication → Providers → Email → Email OTP Length** 에서 6~10자리로 조정할 수 있습니다 (4자리는 불가).
4. 기본 메일은 Supabase 가 시간당 몇 통만 보냅니다. 사용자가 늘면 **Authentication → SMTP Settings** 에서 Resend, Gmail 등 실제 메일 발송 서비스를 연결하세요 (무료 티어로 충분).

### 4. GitHub 에 올리기

```bash
git init
git add .
git commit -m "빠른 연결 첫 버전"
git branch -M main
git remote add origin https://github.com/<계정>/<저장소>.git
git push -u origin main
```

### 5. Vercel 로 배포

1. https://vercel.com/new 에서 방금 올린 저장소 **Import**.
2. Framework Preset 은 **Other**, 나머지는 기본값 그대로 **Deploy**.
3. 배포 주소가 나오면 3단계의 `Site URL` 과 `Redirect URLs` 를 그 주소로 바꿉니다.

Netlify 도 같습니다. 저장소를 연결하고 빌드 명령 없이 배포하면 됩니다.

### 6. 운영자 지정

1. 배포된 사이트에서 본인 계정(카카오 또는 이메일)으로 한 번 로그인합니다.
2. Supabase **SQL Editor** 에서 실행 (이메일만 바꾸세요):

```sql
update public.profiles set is_admin = true
  where id = (select id from auth.users where email = 'mail@wkac.co.kr');
```

카카오처럼 이메일이 없는 계정이면 사이트에서 정한 **이름**으로 지정합니다 (같은 이름이 여럿이면 가장 먼저 가입한 사람):

```sql
update public.profiles set is_admin = true
  where id = (select id from public.profiles where name = '내 이름' order by created_at limit 1);
```

3. 사이트를 새로고침하면 이름 옆에 **운영자** 표시와 상단에 **검토함** 버튼이 생깁니다.

> `운영자 권한은 직접 바꿀 수 없습니다` 오류가 나면 예전 `schema.sql` 이 적용된 상태입니다.
> 최신 `schema.sql` 을 SQL Editor 에서 다시 한 번 실행한 뒤 위 쿼리를 재실행하세요.

### 7. AI 기능 켜기 (선택, 약 10분)

사이트 안에 **분류 담당 AI 에이전트**가 들어 있습니다. 세 가지 일을 합니다.

| 어디서 | 누가 | 무엇을 |
|---|---|---|
| 새 항목 창 → **✦ AI 분류 제안** | 로그인한 사람 | 제목·주소를 보고 분야·하위분야·태그를 채움. 제목이 비었으면 제목도, 링크 설명이 비었으면 한 줄 설명도 제안 |
| 분야 옆 **✦ AI 정리** → 항목 다시 분류 | 운영자 | 분야가 빈 항목·보이는 목록·전체를 30개씩 검토해 바꿀 것만 표로 제안. 체크한 것만 적용 |
| **✦ AI 정리** → 분야 구조 개편안 | 운영자 | 전체 자료를 보고 하위분야를 더하고 빼는 안을 제안. 고쳐서 저장 |

브라우저는 AI 키를 가질 수 없으므로, 호출은 Supabase **Edge Function** (`supabase/functions/ai`) 이 대신합니다. 이 함수는 데이터를 읽기만 하고, 실제 변경은 브라우저가 로그인한 사람의 권한(RLS)으로 합니다.

1. https://console.anthropic.com 에서 API 키를 만듭니다 (`sk-ant-...`). 결제 수단 등록이 필요합니다. 비용은 항목 하나 분류에 1원 안팎, 50개 재분류에 50원 안팎입니다.
   비용 방어선으로 한 사람이 하루에 쓸 수 있는 횟수를 **40회**(운영자 600회)로 제한해 두었습니다. 바꾸려면 `supabase/functions/ai/index.ts` 의 `DAILY_LIMIT` 을 고치고 다시 배포하세요.
   이 한도는 `schema.sql` 의 `ai_take_quota` 함수가 셉니다. **schema.sql 을 최신으로 한 번 더 실행해야** AI 기능이 동작합니다.
2. 이 폴더에서 터미널을 열고 (Node 가 설치되어 있으면 됩니다):
   ```bash
   npx supabase login                                     # 브라우저가 열리고 Supabase 로그인
   npx supabase link --project-ref csxndscngmkciibarumi   # 프로젝트 ref 는 Supabase URL 의 앞부분. DB 비밀번호는 Enter 로 건너뛰어도 됨
   npx supabase secrets set ANTHROPIC_API_KEY=sk-ant-...  # 키는 Supabase 에만 저장됨 (저장소에 넣지 않음)
   npx supabase functions deploy ai
   ```
3. `config.js` 의 `AI` 가 `true` 인지 확인 (기본값). 사이트를 새로고침하면 새 항목 창에 **✦ AI 분류 제안** 버튼이 보입니다. 끄려면 `AI: false`.

함수 코드를 고친 뒤에는 `npx supabase functions deploy ai` 만 다시 실행하면 됩니다. 로그는 Supabase 대시보드 **Edge Functions → ai → Logs** 에서 봅니다.

## 분야 주 관리자

분야마다 담당자를 정할 수 있습니다. **⋯ → 분야 주 관리자** 에서 운영자가 지정합니다. 지정하지 않으면 운영자가 담당합니다.

담당자는 **맡은 분야에서만** 자료를 수정·삭제하고 신고를 검토할 수 있습니다. 다른 분야는 손댈 수 없고, 분야를 만들거나 지우거나 다른 담당자를 지정할 수는 없습니다. 이 경계는 화면이 아니라 데이터베이스 규칙(RLS)이 지킵니다.

지정 목록에는 **이름을 정한 사람의 닉네임만** 나옵니다. 이메일 등 계정 정보는 화면에 나오지 않습니다.

> 분야 이름을 바꾸면 담당자 지정이 풀립니다. 이름을 바꾼 뒤에는 담당자를 다시 지정해 주세요.

## 권한 요약

| 행동 | 비로그인 | 로그인 | 운영자 |
|---|---|---|---|
| 보기·검색 | O | O | O |
| 올리기·모음 만들기 | | O | O |
| 추천 (항목당 1회) | | O | O |
| 신고 | | O | O |
| 수정·삭제 | | 내 것만 | 모두 |
| AI 분류 제안 (새 항목 창) | | O | O |
| **맡은 분야**의 자료 수정·삭제, 신고 검토 | | 주 관리자만 | O |
| 신고 검토함 전체, 분야 편집, 주 관리자 지정, AI 정리 | | | O |

이 규칙은 화면이 아니라 데이터베이스(RLS)가 지키므로, 페이지를 고쳐도 우회할 수 없습니다.

## 도메인 연결

Vercel 프로젝트 **Settings → Domains** 에서 도메인을 추가하고, 안내대로 DNS 레코드를 넣으면 됩니다. 연결 후 Supabase 의 `Site URL` 도 새 도메인으로 바꾸세요.

## 사이트 이름·문구 바꾸기

`config.js`의 `SITE_NAME`, `SITE_TAGLINE` 만 고치면 됩니다.

## 자주 겪는 문제

- **로그인 링크를 눌렀는데 로그인이 안 됨**: Supabase `Site URL`/`Redirect URLs` 가 실제 주소와 다릅니다.
- **메일이 안 옴**: 스팸함 확인. 짧은 시간에 여러 번 보내면 Supabase 기본 메일 한도에 걸립니다.
- **"실시간 연결 끊김"**: 새로고침하면 최신 내용을 다시 불러옵니다. 계속되면 `schema.sql` 의 실시간 설정 부분을 다시 실행하세요.
- **올리기가 "저장하지 못했습니다"**: 로그인 후 이름을 정했는지, `schema.sql` 을 끝까지 실행했는지 확인.
- **AI 버튼이 "아직 배포되지 않았습니다"**: 7단계의 `functions deploy ai` 를 아직 안 한 상태. **"ANTHROPIC_API_KEY 가 설정되지 않았습니다"** 는 `secrets set` 을 빠뜨린 것.
- **"ANTHROPIC_API_KEY 가 올바르지 않습니다"**: 키가 틀렸습니다. 안내문의 `sk-ant-...` 를 그대로 복사해 넣은 경우가 가장 흔합니다.
  `npx supabase secrets list` 는 값을 해시로만 보여 주지만, 예시 문구가 들어갔는지는 해시를 비교하면 알 수 있습니다
  (`sk-ant-...` 의 SHA-256 은 `dda59792fb6824cc0ee170a9202eb02bd83dacac5ccfa96ba0e8954c5b9246a6`).
  실제 키로 다시 `secrets set` 하면 함수를 재배포하지 않아도 바로 반영됩니다.
- **`npx supabase login` 이 "non-TTY environments" 오류**: Claude Code 같은 도구 안이 아니라 **직접 연 PowerShell 창**에서 실행해야 합니다.
- **카카오로 로그인했는데 이름이 "이름 없음"**: 그 사람이 동의 화면에서 닉네임 체크를 뺀 경우입니다. 카카오가 이름을 하나도 보내지 않아 사이트가 채울 수 없습니다.
  본인이 **이름 정하기** 로 직접 정하면 되고, 근본적으로는 2단계에서 닉네임을 필수 동의로 올리세요.
  어느 쪽인지 확인하려면 SQL Editor 에서 `select id, raw_user_meta_data from auth.users;` 를 실행해 `name` 키가 있는지 봅니다.
- **AI 버튼이 안 보임**: `config.js` 의 `AI` 가 `false` 이거나 미리보기 모드. 운영자용 **✦ AI 정리** 는 운영자 지정(6단계) 후에 나타남.
