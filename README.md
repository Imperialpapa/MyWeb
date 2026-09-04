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
   - 사용자가 동의 화면에서 이메일 체크를 빼면 계정이 만들어지지 않으니, 아래 8번의 **Allow users without an email** 을 켜 두면 그런 경우도 로그인됩니다. 사이트는 이메일 없는 계정도 정상 동작하며, 첫 로그인 때 카카오 닉네임을 이름으로 가져옵니다.

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

## 권한 요약

| 행동 | 비로그인 | 로그인 | 운영자 |
|---|---|---|---|
| 보기·검색 | O | O | O |
| 올리기·모음 만들기 | | O | O |
| 추천 (항목당 1회) | | O | O |
| 신고 | | O | O |
| 수정·삭제 | | 내 것만 | 모두 |
| 신고 검토함, 분야 편집 | | | O |

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
