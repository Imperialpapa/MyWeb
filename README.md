# 빠른 연결

링크, 메모, 코드, 자료를 누구나 올리고 검색으로 바로 찾는 공유 자료함.
읽기는 누구나, 올리기·추천·신고는 이메일 로그인 후 가능합니다.

## 구성

| 파일 | 역할 |
|---|---|
| `index.html` | 사이트 전체 (화면 + 동작). 서버 코드 없음 |
| `config.js` | Supabase 주소·키, 사이트 이름 |
| `supabase/schema.sql` | 데이터베이스 표, 권한 규칙(RLS), 실시간 설정 |
| `supabase/seed.sql` | 초기 자료 18개 (선택) |

`config.js`가 비어 있으면 **미리보기 모드**로 동작합니다. 브라우저에만 저장되고, 운영자 화면을 미리 볼 수 있습니다. `index.html`을 더블클릭해 열어 보세요.

## 배포 순서 (약 20분)

### 1. Supabase 프로젝트 만들기

1. https://supabase.com/dashboard 에서 **New project**. 이름은 아무거나, Region 은 **Northeast Asia (Seoul)** 권장.
2. 왼쪽 메뉴 **SQL Editor** → **New query** → `supabase/schema.sql` 내용 전체를 붙여넣고 **Run**.
3. 초기 자료를 넣으려면 같은 방법으로 `supabase/seed.sql` 도 실행.
4. **Settings → API** 에서 두 값을 복사해 `config.js`에 넣기:
   - `Project URL` → `SUPABASE_URL`
   - `anon public` 키 → `SUPABASE_ANON_KEY`

### 2. 로그인 메일 설정

1. **Authentication → Providers → Email**: 켜져 있는지 확인. **Confirm email** 은 꺼도 됩니다 (링크 클릭 자체가 확인).
2. **Authentication → URL Configuration**:
   - `Site URL`: 배포 주소 (예: `https://빠른연결.vercel.app`). 아직 없으면 배포 후에 채우세요.
   - `Redirect URLs`: 같은 주소와 `http://localhost:*` 추가.
3. 기본 메일은 Supabase 가 시간당 몇 통만 보냅니다. 사용자가 늘면 **Authentication → SMTP Settings** 에서 Resend, Gmail 등 실제 메일 발송 서비스를 연결하세요 (무료 티어로 충분).

### 3. GitHub 에 올리기

```bash
git init
git add .
git commit -m "빠른 연결 첫 버전"
git branch -M main
git remote add origin https://github.com/<계정>/<저장소>.git
git push -u origin main
```

### 4. Vercel 로 배포

1. https://vercel.com/new 에서 방금 올린 저장소 **Import**.
2. Framework Preset 은 **Other**, 나머지는 기본값 그대로 **Deploy**.
3. 배포 주소가 나오면 2단계의 `Site URL` 과 `Redirect URLs` 를 그 주소로 바꿉니다.

Netlify 도 같습니다. 저장소를 연결하고 빌드 명령 없이 배포하면 됩니다.

### 5. 운영자 지정

1. 배포된 사이트에서 본인 이메일로 한 번 로그인합니다.
2. Supabase **SQL Editor** 에서 실행 (이메일만 바꾸세요):

```sql
update public.profiles set is_admin = true
  where id = (select id from auth.users where email = 'mail@wkac.co.kr');
```

3. 사이트를 새로고침하면 이름 옆에 **운영자** 표시와 상단에 **검토함** 버튼이 생깁니다.

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
