-- ============================================================
-- 빠른 연결 데이터베이스 스키마 (Supabase / Postgres)
-- Supabase 대시보드 → SQL Editor 에 전체를 붙여넣고 Run 하세요.
-- 여러 번 실행해도 안전하게 만들어져 있습니다.
-- ============================================================

-- ---------- 사용자 프로필 ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null default '',
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

-- 가입 시 프로필 자동 생성
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id) values (new.id) on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users for each row execute function public.handle_new_user();

-- 운영자 여부 (RLS 정책에서 사용)
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false)
$$;

-- 일반 사용자가 자기 is_admin 을 바꾸지 못하게
-- (SQL Editor 처럼 로그인 컨텍스트가 없는 직접 실행은 허용 → 첫 운영자 지정용)
create or replace function public.protect_admin_flag()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.is_admin is distinct from old.is_admin
     and auth.uid() is not null
     and not public.is_admin() then
    raise exception '운영자 권한은 직접 바꿀 수 없습니다';
  end if;
  return new;
end $$;
drop trigger if exists profiles_protect_admin on public.profiles;
create trigger profiles_protect_admin
  before update on public.profiles for each row execute function public.protect_admin_flag();

-- ---------- 항목 ----------
create table if not exists public.items (
  id text primary key,
  type text not null check (type in ('link','note','snippet','file')),
  title text not null,
  url text not null default '',
  lang text not null default '',
  body text not null default '',
  category text not null default '',
  sub text not null default '',
  tags text[] not null default '{}',
  votes integer not null default 0,
  by text not null default '',
  owner_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz
);
-- checked_at: AI 정리로 마지막으로 살펴본 시각. 고칠 게 없다고 판단한 경우에도 기록한다.
-- 이게 없으면 이미 확인한 자료를 매번 다시 검토해 AI 비용이 계속 나간다.
alter table public.items add column if not exists checked_at timestamptz;

-- category_id: 분야를 잇는 정본. category(이름)는 아래 트리거가 유지하는 표시용 사본이다.
-- null 은 "아직 잇지 못한 것"이고 빈 문자열과 뜻이 다르므로 not null 을 걸지 않는다.
alter table public.items add column if not exists category_id text;
alter table public.items drop constraint if exists items_category_id_fmt;
alter table public.items add  constraint items_category_id_fmt
  check (category_id is null or category_id ~ '^[A-Za-z0-9_-]{1,64}$');
create index if not exists items_category_id_idx on public.items (category_id, sub);

-- ---------- 사진·영상 (2026-10-28) ----------
-- 파일 자체는 Cloudflare R2 에 있고 여기에는 열쇠(media_key)만 둔다. Supabase Storage 를 쓰지 않는 이유는
-- 저장·전송 한도를 DB·로그인과 함께 써서, 넘치면 사이트 전체가 읽기 전용(402)이 되기 때문이다 (todo.md).
-- status: pending 은 운영자 승인 전이다. 올린 사람과 운영자만 보고(items_select), 파일은 비공개 버킷에 있다.
--         승인하면 media 함수가 공개 버킷으로 옮기고 media_approve 로 approved 를 찍는다. 거절은 자료 삭제다.
-- 세 컬럼은 화면이 고칠 수 없다(아래 grant update 목록에 없다). 새 자료의 값은 items_media_guard 트리거가 정한다.
-- **이 컬럼들은 아래 RLS 정책보다 위에 있어야 한다.** 정책이 status 를 읽는다.
alter table public.items add column if not exists status text not null default 'approved';
alter table public.items add column if not exists media_key text;
alter table public.items add column if not exists media_type text;
alter table public.items drop constraint if exists items_type_check;
alter table public.items add  constraint items_type_check check (type in ('link','note','snippet','file','media'));
alter table public.items drop constraint if exists items_status_chk;
alter table public.items add  constraint items_status_chk check (status in ('pending','approved'));
-- 열쇠 모양은 media_begin 이 만드는 것만. 공개 주소에 그대로 붙으므로 계정 id 같은 것은 넣지 않는다
alter table public.items drop constraint if exists items_media_chk;
alter table public.items add  constraint items_media_chk check (
  media_key is null or media_key ~ '^m/[0-9a-f]{32}\.(jpg|png|webp|gif|mp4|webm)$');
-- 사진·영상 자료에는 파일이 꼭 있고, 다른 종류에는 없다. 그래서 사진·영상을 수정에서 다른 종류로 바꿀 수 없다
-- (바꾸면 파일만 남은 링크가 된다). 바꾸려면 지우고 다시 올린다
alter table public.items drop constraint if exists items_media_pair;
alter table public.items add  constraint items_media_pair check ((type = 'media') = (media_key is not null));
create index if not exists items_pending_idx on public.items (status) where status = 'pending';

create index if not exists items_created_idx on public.items (created_at desc);
-- 지금은 브라우저가 items 를 통째로 받아 메모리에서 거르므로 이 인덱스를 타는 질의가 없다.
-- 자료가 많아져 "오래 확인 안 한 것" 을 서버에서 골라 오게 되면 그때 쓰인다.
create index if not exists items_checked_idx on public.items (checked_at nulls first);
create index if not exists items_owner_idx on public.items (owner_id);
create index if not exists items_category_idx on public.items (category, sub);

-- ---------- 모음 ----------
create table if not exists public.collections (
  id text primary key,
  title text not null,
  "desc" text not null default '',
  item_ids text[] not null default '{}',
  by text not null default '',
  owner_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz
);

-- ---------- 신고 ----------
create table if not exists public.reports (
  id text primary key,
  item_id text not null,
  reason text not null default '',
  note text not null default '',
  by text not null default '',
  reporter_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

-- ---------- 추천 (한 사람이 한 항목에 한 번) ----------
create table if not exists public.votes (
  item_id text not null references public.items(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (item_id, user_id)
);
create index if not exists votes_user_idx on public.votes (user_id);   -- RLS 의 user_id = auth.uid() 필터용

-- 추천 수를 items.votes 에 유지
create or replace function public.sync_vote_count()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update public.items set votes = votes + 1 where id = new.item_id;
  elsif tg_op = 'DELETE' then
    update public.items set votes = greatest(votes - 1, 0) where id = old.item_id;
  end if;
  return null;
end $$;
drop trigger if exists votes_sync on public.votes;
create trigger votes_sync
  after insert or delete on public.votes for each row execute function public.sync_vote_count();

-- ---------- 설정 (분야 구조 등) ----------
create table if not exists public.settings (
  key text primary key,
  value jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
insert into public.settings (key, value) values (
  'categories',
  -- id 는 이름에서 만들지 않는다. 만들면 이름이 다시 키가 되어 개명 때 썩는다.
  -- id 와 이름은 index.html 의 DEFAULT_CATS 와 같아야 한다 (설정을 받기 전 첫 화면이 이걸로 그려진다).
  -- subs 는 같지 않아도 된다 — DEFAULT_CATS 는 일부러 비워 둔다. 첫 화면은 분야 이름만 있으면 그려지고,
  -- 하위분야는 설정을 받은 뒤에 채워진다. 여기서 이름이 어긋나면 잠깐 다른 분야가 보였다가 바뀐다.
  '{"v":2,"list":[{"id":"dev","name":"개발·도구","subs":["웹","CLI·스크립트","디자인·문서","학습자료","프로젝트 운영"]},{"id":"life","name":"생활·건강·취미","subs":["운동","식단","정보·공공","책·문화"]},{"id":"ai","name":"AI 에이전트","subs":["에이전트 도구","프레임워크·SDK","MCP·연동","프롬프트·스킬","학습자료"]},{"id":"humor","name":"유머","subs":["만화·웹툰","개발자 유머","밈·인터넷 문화","이스터에그·장난"]}]}'::jsonb
) on conflict (key) do nothing;

-- ---------- 분야 주 관리자 ----------
-- settings.categories 의 각 분야에 owner(사용자 uuid)를 넣어 지정한다.
-- 지정하지 않은 분야는 owner 가 없고, 운영자가 그대로 담당한다.
--
-- 분야를 잇는 키는 **id** 다. 이름이 아니다.
-- 예전에는 이름으로 이어 붙여서 분야 이름을 바꾸면 자료와 담당자 권한이 조용히 끊겼다.
-- 이제 items.category_id 가 정본이고, items.category(이름)는 트리거가 유지하는 표시용 사본이다.
--
-- **이 절은 items·settings 테이블보다 아래에 있어야 한다. 위로 올리지 마라.**
-- language sql 함수는 만드는 시점에 본문의 테이블·컬럼이 실제로 있는지 검사한다.
-- 위에 두면 아직 만들지 않은 items.category_id 를 보고 42703 이 나서 파일 전체가 롤백된다.
-- (2026-09-10 에 실제로 겪었다. plpgsql 은 검사하지 않아 트리거 셋은 아래 어디에 있어도 된다)

-- 내가 이 분야의 주 관리자인가 (id 기준)
create or replace function public.manages_category_id(cid text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select true
      from public.settings s, lateral jsonb_array_elements(coalesce(s.value->'list', '[]'::jsonb)) c
     where s.key = 'categories'
       and c->>'id' = cid
       and c->>'owner' = auth.uid()::text
     limit 1), false)
$$;
-- 이름으로 잇던 옛 함수는 지운다. 남겨 두면 언젠가 다시 쓰이고 같은 사고가 난다.
-- (아래 정책·함수에서 참조를 모두 끊은 뒤라야 지워진다)

-- 내가 아무 분야라도 맡고 있는가 (자료를 다른 분야로 옮길 때 쓴다)
create or replace function public.manages_any()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select true
      from public.settings s, lateral jsonb_array_elements(coalesce(s.value->'list', '[]'::jsonb)) c
     where s.key = 'categories' and c->>'owner' = auth.uid()::text
     limit 1), false)
$$;

-- 이 자료가 속한 분야를 내가 맡고 있는가 (신고 검토용)
create or replace function public.manages_item(iid text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.manages_category_id((select category_id from public.items where id = iid))
$$;

-- ---------- 이미 돌고 있는 DB 를 새 형태로 옮기기 ----------
-- 위 insert 는 이미 분야가 있는 DB 에서는 아무 일도 하지 않는다. 그래서 이관이 따로 필요하다.
-- 아래 네 문장은 여러 번 실행해도 안전하고, 이미 옮겨진 DB 에서는 아무것도 바꾸지 않는다.
-- **이 부분이 없으면** 아래 정책이 category_id 를 보기 시작하는 순간 기존 자료 전부가
-- 분야를 잃은 것으로 취급되어, 분야 주 관리자가 오류 없이 권한만 잃는다.

-- (1) 기존 분야에 id 를 붙인다. owner·ownerName·순서·모르는 키를 전부 보존한다.
--     jsonb_agg 는 순서를 보장하지 않으므로 with ordinality 로 원래 순서를 지킨다.
with cur as (
  select s.key, e.c, e.ord
    from public.settings s,
         lateral jsonb_array_elements(coalesce(s.value->'list', '[]'::jsonb)) with ordinality e(c, ord)
   where s.key = 'categories'
), fixed as (
  select cur.key, cur.ord,
         case when coalesce(cur.c->>'id','') <> '' then cur.c
              else cur.c || jsonb_build_object('id', coalesce(
                     (select m.id from (values ('개발·도구','dev'), ('생활·건강·취미','life'),
                                               ('AI 에이전트','ai'), ('유머','humor')) m(nm, id)
                       where m.nm = cur.c->>'name'),
                     'c' || substr(md5(random()::text || clock_timestamp()::text
                                       || coalesce(cur.c->>'name','')), 1, 12)))
         end as c2
    from cur
), rebuilt as (
  select key, coalesce(jsonb_agg(c2 order by ord), '[]'::jsonb) as list from fixed group by key
)
update public.settings s
   set value = jsonb_set(s.value, '{list}', rebuilt.list),
       updated_at = now()
  from rebuilt
 where s.key = rebuilt.key
   and (s.value->'list') is distinct from rebuilt.list;   -- 재실행 시 무변경 → id 가 새로 생기지 않는다
-- v=2 는 여기서 찍지 않는다. 아래 (2)가 "아직 이관 전인가" 를 v 로 판정하기 때문이다.
-- 맨 마지막 (5)에서 찍는다.

-- (2) 목록에 없는 분야를 쓰는 자료가 있으면 그 분야를 목록에 올린다. 조용히 버리지 않는다.
--     **이관 전인 DB 에서 한 번만 돈다.** 이 조건이 없으면 재실행할 때마다
--     "분야 없음" 자료(이 앱에서 정상적으로 생기는 상태다 — 가져오기가 못 이은 자료)의
--     이름 사본을 정본으로 삼아, 운영자가 만든 적 없는 유령 분야를 되살리고 자료를 그리로 끌고 간다.
--     한번 자료가 들어가면 아래 삭제 방어에 걸려 그 분야를 지울 수도 없다.
with missing as (
  select distinct i.category as name
    from public.items i
   where coalesce(i.category,'') <> ''
     and not exists (select 1 from public.settings s,
                            lateral jsonb_array_elements(coalesce(s.value->'list', '[]'::jsonb)) c
                      where s.key = 'categories' and c->>'name' = i.category)
), add as (
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', 'c' || substr(md5(random()::text || name), 1, 12), 'name', name, 'subs', '[]'::jsonb
         ) order by name), '[]'::jsonb) as arr from missing
)
update public.settings s
   set value = jsonb_set(s.value, '{list}', coalesce(s.value->'list', '[]'::jsonb) || add.arr),
       updated_at = now()
  from add where s.key = 'categories' and add.arr <> '[]'::jsonb
   and coalesce(s.value->>'v','') <> '2';   -- 이관을 마친 DB 에서는 돌지 않는다 (유령 분야 방지)

-- (3) 자료에 id 를 채운다. 이미 채워진 행은 건드리지 않는다.
update public.items i
   set category_id = c.id
  from (select c->>'id' as id, c->>'name' as name
          from public.settings s, lateral jsonb_array_elements(coalesce(s.value->'list', '[]'::jsonb)) c
         where s.key = 'categories') c
 where i.category_id is null and i.category = c.name;

-- (3b) 이름과 id 가 서로 다른 분야를 가리키는 자료를 이름 쪽으로 맞춘다.
--      정상 상태에서는 0행이다 — 트리거가 이름 사본을 id 에 맞춰 두기 때문이다.
--      0행이 아닌 경우는 하나뿐이다: 트리거가 없던 기간(되돌리기)에 옛 화면이 이름만 바꾼 자료.
--      그때는 이름이 사람이 마지막으로 고른 값이므로 이름이 정본이다.
--      이 문장이 없으면 (3)이 'category_id is null' 만 보므로 그 자료들을 건너뛰고,
--      나중에 누가 분야를 한 번 저장하는 순간 sync 트리거가 자료를 옛 분야로 되돌려 놓는다.
update public.items i
   set category_id = c.id
  from (select c->>'id' as id, c->>'name' as name
          from public.settings s, lateral jsonb_array_elements(coalesce(s.value->'list', '[]'::jsonb)) c
         where s.key = 'categories') c
 where i.category = c.name and i.category_id is distinct from c.id;

-- (4) 목록에 없는 하위분야를 쓰는 자료가 있으면 그 이름을 목록에 올린다.
--     (실제로 '건강', '취미·여행' 두 개가 이 경우다. 버리지도 이름을 바꾸지도 않는다)
with cur as (
  select s.key, e.c, e.ord from public.settings s,
         lateral jsonb_array_elements(coalesce(s.value->'list', '[]'::jsonb)) with ordinality e(c, ord)
   where s.key = 'categories'
), old_subs as (
  select cur.ord, t.name, t.sord from cur,
         lateral jsonb_array_elements_text(coalesce(cur.c->'subs', '[]'::jsonb)) with ordinality t(name, sord)
), new_subs as (
  select distinct cur.ord, i.sub as name, 1000000::bigint as sord
    from cur join public.items i on i.category_id = cur.c->>'id'
   where coalesce(i.sub,'') <> ''
     and not exists (select 1 from old_subs o where o.ord = cur.ord and o.name = i.sub)
), packed as (
  select ord, coalesce(jsonb_agg(name order by sord, name), '[]'::jsonb) as subs
    from (select ord, name, sord from old_subs union all select ord, name, sord from new_subs) u
   group by ord
), merged as (
  select cur.key, cur.ord, cur.c || jsonb_build_object('subs', coalesce(p.subs, '[]'::jsonb)) as c2
    from cur left join packed p on p.ord = cur.ord
), rebuilt as (
  select key, jsonb_agg(c2 order by ord) as list from merged group by key
)
update public.settings s set value = jsonb_set(s.value, '{list}', rebuilt.list), updated_at = now()
  from rebuilt where s.key = rebuilt.key and (s.value->'list') is distinct from rebuilt.list;

-- (5) 이관을 마쳤다고 표시한다. 위 (2)가 이 표시를 보고 두 번 돌지 않는다.
--     맨 마지막에 찍어야 한다. (1)에서 찍으면 (2)가 첫 실행에서도 꺼진다.
update public.settings set value = value || '{"v":2}'::jsonb, updated_at = now()
 where key = 'categories' and coalesce(value->>'v','') <> '2';

-- ============================================================
-- 접근 규칙 (RLS)
--   읽기: 누구나 (신고·추천·프로필 제외)
--   쓰기: 로그인한 사람. 수정·삭제는 올린 사람 또는 운영자
-- ============================================================
alter table public.profiles    enable row level security;
alter table public.items       enable row level security;
alter table public.collections enable row level security;
alter table public.reports     enable row level security;
alter table public.votes       enable row level security;
alter table public.settings    enable row level security;

-- profiles: 본인만 읽고 고침 (운영자는 전체 조회)
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select using (id = auth.uid() or public.is_admin());
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update using (id = auth.uid() or public.is_admin());

-- items
drop policy if exists items_select on public.items;
-- 승인 전 사진·영상은 올린 사람과 운영자만 본다. 분야 담당자는 승인하지 않으므로 보지 않는다
create policy items_select on public.items for select
  using (status = 'approved' or owner_id = auth.uid() or public.is_admin());
drop policy if exists items_insert on public.items;
create policy items_insert on public.items for insert to authenticated with check (owner_id = auth.uid());
drop policy if exists items_update on public.items;
create policy items_update on public.items for update to authenticated
  -- using 은 고치기 전 행을 본다: 내 글이거나, 운영자이거나, 그 분야의 주 관리자
  using (owner_id = auth.uid() or public.is_admin() or public.manages_category_id(category_id))
  -- with check 는 고친 뒤 행을 본다. 주 관리자가 잘못 분류된 자료를 맞는 분야로 옮길 수 있어야 하므로
  -- 여기서는 분야를 따지지 않고 "분야를 하나라도 맡은 사람"인지만 본다.
  with check (owner_id = auth.uid() or public.is_admin() or public.manages_any());
drop policy if exists items_delete on public.items;
create policy items_delete on public.items for delete to authenticated
  using (owner_id = auth.uid() or public.is_admin() or public.manages_category_id(category_id));

-- 이름으로 잇던 옛 함수는 여기서 지운다. 위 정책이 참조를 놓은 뒤라야 지울 수 있다.
-- 남겨 두면 언젠가 다시 쓰이고 "이름을 바꾸면 연결이 끊기는" 같은 사고가 난다.
drop function if exists public.manages_category(text);

-- collections
drop policy if exists collections_select on public.collections;
create policy collections_select on public.collections for select using (true);
drop policy if exists collections_insert on public.collections;
create policy collections_insert on public.collections for insert to authenticated with check (owner_id = auth.uid());
drop policy if exists collections_update on public.collections;
create policy collections_update on public.collections for update to authenticated
  using (owner_id = auth.uid() or public.is_admin())
  with check (owner_id = auth.uid() or public.is_admin());
drop policy if exists collections_delete on public.collections;
create policy collections_delete on public.collections for delete to authenticated using (owner_id = auth.uid() or public.is_admin());

-- reports: 신고자는 자기 신고만 보고, 운영자는 전체를 보고 닫음
drop policy if exists reports_select on public.reports;
create policy reports_select on public.reports for select to authenticated
  using (reporter_id = auth.uid() or public.is_admin() or public.manages_item(item_id));
drop policy if exists reports_insert on public.reports;
create policy reports_insert on public.reports for insert to authenticated with check (reporter_id = auth.uid());
drop policy if exists reports_delete on public.reports;
create policy reports_delete on public.reports for delete to authenticated
  using (public.is_admin() or public.manages_item(item_id));

-- votes: 자기 추천만
drop policy if exists votes_select on public.votes;
create policy votes_select on public.votes for select to authenticated using (user_id = auth.uid());
drop policy if exists votes_insert on public.votes;
create policy votes_insert on public.votes for insert to authenticated with check (user_id = auth.uid());
drop policy if exists votes_delete on public.votes;
create policy votes_delete on public.votes for delete to authenticated using (user_id = auth.uid());

-- settings: 읽기 공개, 쓰기 운영자
drop policy if exists settings_select on public.settings;
create policy settings_select on public.settings for select using (true);
drop policy if exists settings_write on public.settings;
create policy settings_write on public.settings for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ---------- AI 사용량 (Edge Function 이 하루 호출 횟수를 센다) ----------
create table if not exists public.ai_usage (
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null default current_date,
  n integer not null default 0,
  primary key (user_id, day)
);
alter table public.ai_usage enable row level security;   -- 정책 없음 = 아무도 직접 못 본다 (아래 함수로만 접근)

-- 아래 함수들의 revoke 에 anon 을 함께 적는 이유:
-- Supabase 는 public 스키마의 새 함수에 anon·authenticated 실행 권한을 기본으로 준다(ALTER DEFAULT PRIVILEGES).
-- 그래서 "from public" 만 걷으면 anon 에게 준 권한은 그대로 남아, 로그인하지 않은 사람도 부를 수 있다.
-- (함수 안에서 auth.uid() 를 먼저 보므로 실제 피해는 없었지만, 막으려던 것이 안 막혀 있었다.)

-- 오늘 사용량을 cost 만큼 늘리고, 한도 안이면 true. Edge Function 이 AI 호출 전에 부른다.
-- cost 는 그 작업이 얼마나 비싼지다. 자료 10개 제안은 분류 제안보다 훨씬 비싸므로 5로 센다.
-- 인자 하나짜리 옛 함수는 반드시 먼저 지운다. 남겨 두면 호출이 모호해져 PGRST203 으로 전부 실패한다.
drop function if exists public.ai_take_quota(integer);
create or replace function public.ai_take_quota(lim integer, cost integer default 1)
returns boolean language plpgsql security definer set search_path = public as $$
declare cur integer; c integer := greatest(coalesce(cost, 1), 1);
begin
  if auth.uid() is null then return false; end if;
  insert into public.ai_usage (user_id, day, n) values (auth.uid(), current_date, c)
    on conflict (user_id, day) do update set n = public.ai_usage.n + c
    returning n into cur;
  -- 한도를 넘었으면 방금 더한 만큼 되돌린다. 안 그러면 한도에 걸린 사람이 다시 누를 때마다
  -- 쓰지도 않은 사용량이 계속 쌓여 숫자가 실제와 멀어진다.
  if cur > lim then
    update public.ai_usage set n = greatest(n - c, 0)
     where user_id = auth.uid() and day = current_date;
    return false;
  end if;
  return true;
end $$;
revoke all on function public.ai_take_quota(integer, integer) from public, anon;
grant execute on function public.ai_take_quota(integer, integer) to authenticated;

-- 호출이 우리 쪽(키 만료·네트워크·서버) 이유로 실패하면 차감한 횟수를 돌려준다.
-- 이게 없으면 키가 죽어 있는 동안 실패한 호출까지 사용자의 하루 한도를 깎는다.
drop function if exists public.ai_refund_quota();
create or replace function public.ai_refund_quota(cost integer default 1)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  update public.ai_usage set n = greatest(n - greatest(coalesce(cost, 1), 1), 0)
   where user_id = auth.uid() and day = current_date;
end $$;
revoke all on function public.ai_refund_quota(integer) from public, anon;
grant execute on function public.ai_refund_quota(integer) to authenticated;

-- ---------- 자주 쓰는 태그 (AI 분류 제안의 힌트) ----------
-- 분류 제안(suggest)의 system 프롬프트에 넣는 "자주 쓰는 태그" 를 서버가 센다 (2026-09-15).
-- 예전에는 브라우저가 세어 tagsHint 로 보냈고 Edge Function 이 받은 그대로 system 에 넣었다.
-- 그래서 로그인한 누구나 REST 로 함수를 직접 불러 40개×30자까지 자기 글을 system 자리(사용자 메시지보다 모델이 더 믿는 자리)에 넣을 수 있었다.
-- 이제 함수는 tagsHint 를 읽지 않고 이것을 부른다.
-- 저장된 태그도 로그인한 누구나 REST 로 넣는 글이라 셀 때부터 좁힌다.
--   * 태그 수가 아니라 **자료 수**로 센다. 한 자료에 같은 태그를 20번 넣어 20표를 받지 못하게 (화면은 저장할 때 겹친 태그를 하나로 줄인다).
--   * 사이트가 만드는 모양만 센다: 40자 이하, 공백·제어문자·쉼표 없음, 첫 글자가 # > * - 아님 (화면은 쉼표·공백으로 태그를 가른다).
--     안 그러면 줄바꿈으로 시작하는 태그가 바이트 순 동점에서 늘 앞서고, 함수가 눕히면 빈 글자가 되는 태그(#, 탭)가 40자리를 먹는다.
--     공백 판정은 DB 로캘마다 달라 유니코드 공백은 직접 적었다.
--   * 그래도 자료를 올려 태그를 달면 순위에 오른다 (동점이 많은 작은 게시판이면 자료 하나로도). 공개되고 작성자가 남는 글이며,
--     함수가 한 줄 30자로 눕혀 넣는다 (todo.md "프롬프트 인젝션").
--     동점을 "먼저 쓴 태그" 로 가르지 않는 것은 created_at 을 글쓴이가 넣을 수 있어서다 (가져오기가 날짜를 살린다).
-- 순서를 "많이 쓴 순, 같으면 태그 글자 순" 으로 못 박는다. 같은 자료면 매번 같은 목록이 나와야 system 앞부분이 그대로라 프롬프트 캐시가 맞는다.
-- 글자 순은 collate "C"(바이트 순)다. DB 기본 정렬 규칙은 설치마다 달라 로컬 시험과 운영의 순서가 어긋날 수 있다.
-- security invoker: 부른 사람의 RLS 로 센다. items 는 누구나 읽으므로(items_select) 새로 드러나는 것이 없어 anon 에게도 연다.
-- 돌려주는 모양은 text[] 하나다. PostgREST 는 스칼라(배열 포함)를 돌려주는 함수의 결과를 그 JSON 값 그대로 주므로
-- supabase-js 의 rpc("top_tags", { lim }) 는 data 로 ["docker","python",…] 을 받는다. 자료가 없으면 빈 배열이다 (null 이 아니다).
-- **language sql 이라 items 표보다 아래에 있어야 한다** (위 "분야 주 관리자" 절의 42703 함정과 같다).
-- 이 함수가 아직 없어도(schema.sql 을 안 돌리고 함수만 배포) 분류 제안은 멈추지 않는다. 함수가 readFail 한 줄을 남기고 힌트 없이 계속한다.
create or replace function public.top_tags(lim integer default 40)
returns text[] language sql stable security invoker set search_path = public as $$
  select coalesce(array_agg(s.tag order by s.n desc, s.tag collate "C"), '{}')
    from (select t.tag, count(distinct i.id) as n
            from public.items i, unnest(i.tags) t(tag)
           where length(t.tag) <= 40   -- null 은 여기서 빠진다
             and t.tag ~ '^[^#>*-]'     -- 빈 태그도 여기서 빠진다
             and t.tag !~ '[,[:space:][:cntrl:]\u0080-\u00a0\u1680\u2000-\u200b\u2028\u2029\u202f\u205f\u3000\ufeff]'
           group by t.tag
           order by count(distinct i.id) desc, t.tag collate "C"
           limit greatest(1, least(coalesce(lim, 40), 100))) s   -- 1~100 으로 가둔다. 크게 부르면 함수가 한 번에 모든 태그를 셀 수 있다
$$;
grant execute on function public.top_tags(integer) to anon, authenticated;

-- ---------- id 형식 제약 (id 가 화면 HTML 속성에 들어가므로 서버에서 막는다) ----------
-- 이미 운영 중인 DB 라면 먼저 아래로 어긋나는 행이 없는지 확인하세요. 있으면 그 행을 고친 뒤 실행합니다.
--   select id from public.items where id !~ '^[A-Za-z0-9_-]{1,64}$';
alter table public.items       drop constraint if exists items_id_fmt;
alter table public.items       add  constraint items_id_fmt       check (id ~ '^[A-Za-z0-9_-]{1,64}$');
alter table public.collections drop constraint if exists collections_id_fmt;
alter table public.collections add  constraint collections_id_fmt check (id ~ '^[A-Za-z0-9_-]{1,64}$');
alter table public.reports     drop constraint if exists reports_id_fmt;
alter table public.reports     add  constraint reports_id_fmt     check (id ~ '^[A-Za-z0-9_-]{1,64}$');
alter table public.reports     drop constraint if exists reports_item_id_fmt;
alter table public.reports     add  constraint reports_item_id_fmt check (item_id ~ '^[A-Za-z0-9_-]{1,64}$');

-- ---------- 신고: 고아와 중복을 막는다 ----------
-- 지금까지 `reports.item_id` 에 외래키가 없었다. 그래서 자료를 지워도 신고가 남고,
-- 검토함에 "이미 삭제된 항목" 줄로 쌓였다. 게다가 자료가 없으면 `manages_item` 이 분야를 알 수 없어
-- **분야 담당자에게는 보이지도 않는 신고**가 된다. 운영자만 치울 수 있고, 아무도 안 치우면 영영 남는다.
-- 같은 사람이 같은 자료를 몇 번이든 신고할 수도 있었다. 화면은 버튼을 "신고됨" 으로 막지만
-- 새로고침하거나 다른 창을 쓰면 그대로 뚫린다 — 규칙이 화면에만 있었다.
--
-- **제약을 걸기 전에 이미 쌓인 것을 먼저 치운다.** 순서를 바꾸면 제약이 안 붙고 그 자리에서 실패한다.
delete from public.reports r
 where not exists (select 1 from public.items i where i.id = r.item_id);
-- 같은 사람·같은 자료가 여럿이면 **가장 먼저 낸 것**만 남긴다 (그게 실제로 신고한 시점이다)
delete from public.reports r using public.reports k
 where r.reporter_id is not null and r.reporter_id = k.reporter_id and r.item_id = k.item_id
   and (r.created_at, r.id) > (k.created_at, k.id);

alter table public.reports drop constraint if exists reports_item_fk;
alter table public.reports add  constraint reports_item_fk
  foreign key (item_id) references public.items(id) on delete cascade;
-- 한 사람이 한 자료에 한 번. 계정이 지워져 `reporter_id` 가 비워진 옛 신고는 이 제한을 받지 않는다
-- (그 신고들끼리는 서로 누구인지 알 수 없으므로 하나로 합칠 근거가 없다).
create unique index if not exists reports_one_per_person
  on public.reports (item_id, reporter_id) where reporter_id is not null;

-- 길이 제한: 한 사람이 DB·전송량을 부풀리지 못하게 (모든 방문자가 items 전체를 받아 간다)
alter table public.items drop constraint if exists items_len;
alter table public.items add  constraint items_len check (
  length(title) <= 300 and length(url) <= 2000 and length(lang) <= 40 and length(body) <= 20000
  and length(category) <= 60 and length(sub) <= 60 and length(by) <= 40
  and (array_length(tags, 1) is null or array_length(tags, 1) <= 20)
);

-- 추천 수(votes)는 votes 표의 트리거가 관리하는 파생 값이다. 사용자가 REST 로 직접 고치지 못하게
-- 표 단위 update 권한을 걷고 votes 를 뺀 나머지 컬럼만 다시 준다.
-- (컬럼만 revoke 하면 표 단위 권한이 남아 효과가 없다. 동기화 트리거는 security definer 라 영향받지 않는다.)
-- owner_id 도 뺀다 (2026-09-14). 넣어 두면 분야 담당자가 자기 분야 자료의 주인을 아무 계정으로, 또는 null 로
-- 바꿀 수 있었다. items_update 의 with check 가 "분야를 하나라도 맡은 사람" 이면 통과시키기 때문이고,
-- 넘겨줄 계정 UUID 는 공개로 내려가는 owner_id 에서 얼마든지 얻는다.
-- 화면은 고칠 때 owner_id 를 보내지 않는다(put·putCol 이 빼고, patch 는 고를 컬럼만 보낸다). 새 글은 insert 라 이 권한과 무관하다.
-- 표 단위 revoke 는 예전에 준 컬럼 권한(owner_id 포함)까지 함께 걷으므로, 이 파일을 다시 돌리면 정리된다.
revoke update on public.items from authenticated, anon;
grant  update (type, title, url, lang, body, category, category_id, sub, tags, by, updated_at)
  on public.items to authenticated;

-- checked_at 은 운영자·주 관리자가 "살펴봤다" 고 남기는 부기 값이다. 컬럼 쓰기 권한을 주면
-- 누구나 자기 자료의 점검 시각을 미래로 찍어 검토 대기열에서 스스로 빠질 수 있으므로 함수로만 찍는다.
create or replace function public.mark_checked(ids text[])
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if auth.uid() is null then return 0; end if;
  if ids is null or array_length(ids, 1) is null then return 0; end if;
  if array_length(ids, 1) > 500 then raise exception '한 번에 500개까지만 표시할 수 있습니다'; end if;
  update public.items set checked_at = now()
   where id = any(ids)
     and (public.is_admin() or public.manages_category_id(category_id));
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.mark_checked(text[]) from public, anon;
grant execute on function public.mark_checked(text[]) to authenticated;

-- ---------- 분야 id 를 지키는 트리거 셋 ----------
-- 이 셋이 있어야 스키마·함수·화면의 배포 순서가 어긋나도 자료가 상하지 않는다.
-- 특히 옛 화면이 열려 있는 탭에서 분야를 저장하면 id 가 통째로 지워질 수 있는데, 첫 번째가 그것을 막는다.

-- (1) settings 쓰기 방어: id 없이 들어온 저장에 이름으로 옛 id 를 되붙이고,
--     자료가 든 분야를 목록에서 없애는 저장은 거부한다.
create or replace function public.keep_category_ids()
returns trigger language plpgsql security definer set search_path = public as $$
declare old_list jsonb; res jsonb;
begin
  if new.key <> 'categories' then return new; end if;
  -- `on conflict (key) do nothing` 으로 버려질 INSERT 도 BEFORE 트리거는 먼저 탄다.
  -- 그 '버려질 값' 으로 아래 검사를 하면 seed-*.sql 과 이 파일의 재실행이 통째로 실패한다
  -- (seed 파일 첫 문장이 '{"list":[]}' 이라 "모든 분야를 없애는 저장" 으로 보인다).
  -- upsert 는 뒤따르는 UPDATE 패스에서 그대로 검사받으므로 방어력은 줄지 않는다.
  if tg_op = 'INSERT' and exists (select 1 from public.settings where key = 'categories') then
    return new;
  end if;
  old_list := coalesce((select value->'list' from public.settings where key = 'categories'), '[]'::jsonb);

  -- id 가 없이 들어온 줄은 이름으로 옛 줄을 찾아 id 를, 그리고 담당자 지정도 함께 되붙인다.
  -- id 를 되붙이면서 owner 를 두고 오면 담당자 지정만 오류 없이 사라진다.
  -- (id 를 들고 온 줄은 손대지 않는다. 그쪽에서 owner 가 없는 것은 "담당자 해제" 라는 뜻이다)
  select coalesce(jsonb_agg(
           case when coalesce(e.c->>'id','') <> '' then e.c
                else e.c
                     || jsonb_build_object('id', coalesce(m.o->>'id',
                          'c' || substr(md5(random()::text || clock_timestamp()::text), 1, 12)))
                     || case when (e.c ? 'owner') or not (coalesce(m.o,'{}'::jsonb) ? 'owner') then '{}'::jsonb
                             else jsonb_build_object('owner', m.o->'owner',
                                                     'ownerName', coalesce(m.o->'ownerName', '""'::jsonb))
                        end
           end order by e.ord), '[]'::jsonb)
    into res
    from jsonb_array_elements(coalesce(new.value->'list', '[]'::jsonb)) with ordinality e(c, ord)
    left join lateral (
      select o from jsonb_array_elements(old_list) o
       where o->>'name' = e.c->>'name' and coalesce(o->>'id','') <> ''
         -- 이번 목록의 다른 줄이 이미 그 id 를 들고 있으면 되붙이지 않는다.
         -- 안 그러면 "A 를 개명하고 A 의 옛 이름으로 새 분야 만들기" 가
         -- '같은 id 의 분야가 두 개입니다' 로 막혀 손쓸 방법이 없어진다.
         and not exists (select 1 from jsonb_array_elements(coalesce(new.value->'list', '[]'::jsonb)) y
                          where y->>'id' = o->>'id')
       limit 1
    ) m on true;

  -- 자료가 들어 있는 분야는 목록에서 없앨 수 없다.
  -- 이 한 검사가 (1) 옛 화면의 개명 저장 (2) 자료 든 분야 삭제 를 둘 다 시끄럽게 실패시킨다.
  if exists (
    select 1 from jsonb_array_elements(old_list) o
     where coalesce(o->>'id','') <> ''
       and not exists (select 1 from jsonb_array_elements(res) x where x->>'id' = o->>'id')
       and exists (select 1 from public.items i where i.category_id = o->>'id')
  ) then
    -- 사라진 분야가 있는데 처음 보는 id 도 함께 들어왔다면 삭제가 아니라 개명이다.
    -- 문구를 가르지 않으면 이름을 바꾸려던 사람에게 "자료를 먼저 옮기라" 고 시키게 된다.
    -- 백업이 없는 DB 에서 그건 실제 유실 경로다.
    -- 사라진 분야 수와 처음 보는 분야 수가 같을 때만 개명으로 본다.
    -- 그냥 "처음 보는 것이 있는가" 로 보면 '분야 하나를 지우면서 다른 분야를 추가' 까지 개명으로 오진해,
    -- 최신 화면을 쓰는 사람에게 "화면을 새로 고치라" 는 막다른 안내를 하게 된다.
    if (select count(*) from jsonb_array_elements(res) x
         where not exists (select 1 from jsonb_array_elements(old_list) o where o->>'id' = x->>'id'))
      = (select count(*) from jsonb_array_elements(old_list) o
          where coalesce(o->>'id','') <> ''
            and not exists (select 1 from jsonb_array_elements(res) x where x->>'id' = o->>'id')) then
      raise exception '옛 화면에서는 분야 이름을 바꿀 수 없습니다. 화면을 새로 고친 뒤 다시 시도해 주세요';
    end if;
    raise exception '자료가 들어 있는 분야를 목록에서 없앨 수 없습니다. 자료를 먼저 다른 분야로 옮겨 주세요';
  end if;

  -- 이름이 같은 분야가 둘이면 이름으로 id 를 찾는 과도기 경로가 아무거나 고른다. 여기서 막는다.
  if exists (select 1 from jsonb_array_elements(res) c group by c->>'name' having count(*) > 1) then
    raise exception '같은 이름의 분야가 두 개입니다. 이름을 다르게 해 주세요';
  end if;
  if exists (select 1 from jsonb_array_elements(res) c group by c->>'id' having count(*) > 1) then
    raise exception '같은 id 의 분야가 두 개입니다';
  end if;
  -- 이름 길이를 여기서 막지 않으면 아래 (2)의 items 갱신이 items_len 에 걸려
  -- "분야 저장" 이 알 수 없는 이유로 실패한다.
  if exists (select 1 from jsonb_array_elements(res) c where length(coalesce(c->>'name','')) > 60) then
    raise exception '분야 이름은 60자까지입니다';
  end if;
  if exists (select 1 from jsonb_array_elements(res) c where c->>'id' !~ '^[A-Za-z0-9_-]{1,64}$') then
    raise exception '분야 id 형식이 올바르지 않습니다';
  end if;

  new.value := jsonb_set(new.value, '{list}', res);
  return new;
end $$;
drop trigger if exists settings_keep_ids on public.settings;
create trigger settings_keep_ids
  before insert or update on public.settings for each row execute function public.keep_category_ids();

-- (2) 분야 이름을 바꾸면 자료의 이름 사본이 같은 트랜잭션에서 따라간다.
--     updated_at 은 건드리지 않는다. 개명 때문에 자료가 "수정됨" 이 되면 안 된다.
create or replace function public.sync_item_category_names()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.key <> 'categories' then return null; end if;
  update public.items i set category = c.name
    from (select x->>'id' as id, x->>'name' as name
            from jsonb_array_elements(coalesce(new.value->'list', '[]'::jsonb)) x) c
   where i.category_id = c.id and i.category is distinct from c.name;
  -- 고아 회수: 이름은 맞는데 아직 id 를 못 이은 자료를 분야 저장 때마다 주워 온다.
  -- 자료를 먼저 넣고 분야를 나중에 만드는 경로(자료 채우기의 새 분야, JSON 가져오기)가
  -- 이것 없이는 영영 이어지지 않는다. 화면 쪽 순서도 함께 고치지만 이건 그 바깥의 그물이다.
  update public.items i set category_id = c.id
    from (select x->>'id' as id, x->>'name' as name
            from jsonb_array_elements(coalesce(new.value->'list', '[]'::jsonb)) x) c
   where i.category_id is null and i.category = c.name;
  return null;
end $$;
drop trigger if exists settings_sync_cat_names on public.settings;
create trigger settings_sync_cat_names
  after insert or update on public.settings for each row execute function public.sync_item_category_names();

-- (3) 자료 쓰기: id 가 있으면 id 가 이기고, 이름만 들어오면 이름으로 id 를 찾아 채운다.
--     옛 화면, seed-*.sql, 옛 백업 가져오기가 전부 이 경로로 구제된다.
create or replace function public.resolve_item_category()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_id text; v_name text;
begin
  -- 이름만 바꿔 보냈다(id 는 그대로) → 이름으로 id 를 찾는다.
  --
  -- 여기서 이름을 그대로 믿어 **자료를 다른 분야로 옮기면 안 된다.**
  -- "사람이 이름으로 분야를 바꿨다" 와 "낡은 탭이 옛 이름을 실어 보냈다" 는
  -- 행만 보아서는 구별할 방법이 없다 (둘 다 이름만 다르다).
  -- 그래서 이 가지는 분야가 **없던** 자료에 이름으로 분야를 주는 것까지만 한다.
  -- 이미 분야가 있는 자료를 옮기려면 화면이 id 를 보내야 하고, 그러면 이 가지는 아예 안 탄다.
  if tg_op = 'UPDATE'
     and new.category is distinct from old.category
     and new.category_id is not distinct from old.category_id then
    select c->>'id' into v_id from public.settings s,
           lateral jsonb_array_elements(coalesce(s.value->'list', '[]'::jsonb)) c
     where s.key = 'categories' and c->>'name' = new.category limit 1;
    -- 못 찾았을 때 지우면 안 된다. 옛 탭이 낡은 이름을 실어 보내는 것만으로
    -- 이미 이어진 id 가 사라져, 담당자가 이유 없이 그 자료의 권한을 잃는다.
    -- 그냥 두면 아래 세 번째 가지가 이름을 정본으로 되돌려 무해한 헛일이 된다.
    if v_id is not null and coalesce(old.category_id,'') = '' then
      new.category_id := v_id;
    elsif v_id is not null and v_id is distinct from old.category_id then
      -- 분야를 개명하고 그 옛 이름을 새 분야에 다시 쓴 뒤라야 여기에 온다.
      -- 조용히 옮기면 옛 분야 담당자가 이유 없이 그 자료의 권한을 잃으므로 시끄럽게 막는다.
      raise exception '분야 목록이 그 사이에 바뀌었습니다. 화면을 새로 고친 뒤 다시 저장해 주세요';
    end if;
  end if;
  -- 이름만 있고 id 가 비었다 → 이름으로 채운다
  if coalesce(new.category_id,'') = '' and coalesce(new.category,'') <> '' then
    select c->>'id' into v_id from public.settings s,
           lateral jsonb_array_elements(coalesce(s.value->'list', '[]'::jsonb)) c
     where s.key = 'categories' and c->>'name' = new.category limit 1;
    new.category_id := v_id;
  end if;
  -- id 가 있으면 이름 사본을 정본으로 덮어쓴다 (목록에 없는 id 면 손대지 않는다)
  if coalesce(new.category_id,'') <> '' then
    select c->>'name' into v_name from public.settings s,
           lateral jsonb_array_elements(coalesce(s.value->'list', '[]'::jsonb)) c
     where s.key = 'categories' and c->>'id' = new.category_id limit 1;
    if v_name is not null then
      new.category := v_name;
    else
      -- 목록에 없는 id 는 통과시키지 않는다. 통과시키면 화면에는 원래 분야로 보이면서
      -- 담당자 권한·신고 검토·점검 대상에서만 빠지는 자료를 누구나 만들 수 있다
      -- (category_id 는 사용자가 쓸 수 있는 컬럼이다).
      select c->>'id' into v_id from public.settings s,
             lateral jsonb_array_elements(coalesce(s.value->'list', '[]'::jsonb)) c
       where s.key = 'categories' and c->>'name' = new.category limit 1;
      new.category_id := v_id;
    end if;
  end if;
  if coalesce(new.category_id,'') = '' then new.category_id := null; end if;   -- '' 는 제약 위반
  return new;
end $$;
drop trigger if exists items_resolve_category on public.items;
create trigger items_resolve_category
  before insert or update on public.items for each row execute function public.resolve_item_category();

-- ---------- 자료를 지우면 모음에서도 뺀다 ----------
-- 안 빼면 모음에 id 만 남는다. 화면에는 안 보이지만 그 자리는 **예약돼 있다.**
-- 자료 id 는 선착순이고 JSON 가져오기가 파일에 적힌 id 를 그대로 쓰므로,
-- 아무 로그인 사용자나 그 id 로 자료를 새로 만들어 남의 모음에 들어앉을 수 있다.
-- 바닥글에 나가는 제휴 모음에서는 그게 곧 사이트 전면 링크 탈취가 된다.
create or replace function public.strip_deleted_from_collections()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.collections
     set item_ids = array_remove(item_ids, old.id), updated_at = now()
   where item_ids @> array[old.id];
  return old;
end $$;
drop trigger if exists items_strip_from_collections on public.items;
create trigger items_strip_from_collections
  after delete on public.items for each row execute function public.strip_deleted_from_collections();

-- ---------- 작성자 이름(by)은 서버가 정한다 ----------
-- by 는 브라우저가 보내는 값이라, 로그인한 누구나 REST 로 남의 이름을 달고 자료·모음·신고를 올릴 수 있었다.
-- JSON 가져오기도 파일의 by 를 새 id 에 그대로 써서, 지운 글이 원작성자 이름을 달고 되살아날 수 있었다.
--   새 행: 올린 사람의 프로필 이름으로 덮는다. 운영자가 올리는 자료·모음은 예외다 — 백업을 복원할 때 원래 이름을 지켜야 한다.
--   고친 행: by 는 **주인 본인이 자기 현재 이름으로** 바꾸는 것만 받는다("예전 자료의 이름도 바꾸기" 가 이 경로다).
--     나머지는 옛 값을 지킨다. 낡은 탭의 운영자·담당자 저장이 남의 개명을 옛 이름으로 되돌리던 것도 이걸로 막힌다.
--     오류로 막지 않는 이유: 화면은 고칠 때 들고 있던 by 를 늘 함께 보낸다. 그게 낡았다고 저장을 통째로 실패시키면 본문 수정까지 잃는다.
--   로그인 맥락이 없으면(SQL Editor, auth.uid() 가 null) 손대지 않는다. delete-user.sql 의 이름 가리기, seed, partners.sql 이 이 경로다.
-- 주인 컬럼은 to_jsonb 로 읽는다. reports 에는 owner_id 가 없어서 old.owner_id 를 직접 쓰면 실행 중에 오류가 난다.
-- **`by` 는 SQL 예약어라 식 안에서는 반드시 new."by" 로 따옴표를 친다.** 안 치면 `record "new" has no field "by"` 로
-- 자료·모음의 **모든 수정이 실패한다**(대입문 new.by := 는 통과해서 insert 만 시험하면 모른다. 실제로 겪었다).
create or replace function public.enforce_author_name()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_name text;
begin
  if v_me is null then return new; end if;
  v_name := coalesce((select name from public.profiles where id = v_me), '');
  if tg_op = 'INSERT' then
    if tg_table_name = 'reports' or not public.is_admin() then
      new."by" := v_name;
    end if;
  elsif new."by" is distinct from old."by"
        and ((to_jsonb(old)->>'owner_id') is distinct from v_me::text or new."by" is distinct from v_name) then
    new."by" := old."by";
  end if;
  return new;
end $$;
drop trigger if exists items_author_name on public.items;
create trigger items_author_name
  before insert or update on public.items for each row execute function public.enforce_author_name();
drop trigger if exists collections_author_name on public.collections;
create trigger collections_author_name
  before insert or update on public.collections for each row execute function public.enforce_author_name();
drop trigger if exists reports_author_name on public.reports;
create trigger reports_author_name
  before insert on public.reports for each row execute function public.enforce_author_name();
-- 프로필 이름이 items.by 상한(40자)보다 길면 위 트리거가 넣은 이름 때문에 글쓰기가 items_len 으로 실패한다.
-- 화면은 24자로 막지만 REST 로는 길게 저장할 수 있으므로 여기서도 막는다.
-- not valid: 이미 있는 행은 검사하지 않는다. 혹시 긴 이름이 있어도 이 파일 전체가 롤백되지 않게.
alter table public.profiles drop constraint if exists profiles_name_len;
alter table public.profiles add  constraint profiles_name_len check (length(name) <= 40) not valid;

-- ---------- 사진·영상 올리기와 승인 ----------
-- 순서: media 함수가 media_begin 으로 열쇠를 받아 R2 업로드 주소를 서명해 준다 → 브라우저가 R2 에 바로 올린다
--       → 브라우저가 그 열쇠를 실어 자료를 insert 한다 → items_media_guard 가 "내가 받은 열쇠인가" 를 보고 pending 을 찍는다
--       → 운영자가 승인하면 media 함수가 파일 크기·형식을 다시 보고 공개 버킷으로 옮긴 뒤 media_approve 를 부른다.
-- 크기·형식 상한은 여기(media_begin)가 정본이다. R2 서명에 정확한 크기가 들어가 그보다 큰 파일은 R2 가 거절한다.
-- media 함수의 MEDIA_LIMIT 도 같은 값이어야 한다 (승인 때 다시 본다).
create table if not exists public.media_uploads (
  key text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  content_type text not null,
  size bigint not null,
  used boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists media_uploads_user_idx on public.media_uploads (user_id, created_at);
alter table public.media_uploads enable row level security;   -- 정책 없음 = 아래 함수로만 다룬다

-- 열쇠 하나를 발급한다. 하루 올리기 횟수와 승인 대기 수를 여기서 막는다
-- (R2 에 올라간 파일은 우리 돈이다. 막지 않으면 로그인한 누구나 10GB 무료 한도를 하루에 채울 수 있다).
create or replace function public.media_begin(ct text, sz bigint)
returns text language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_ext text; v_max bigint; v_key text; v_admin boolean := public.is_admin();
begin
  if v_me is null then raise exception '로그인이 필요합니다'; end if;
  v_ext := case ct when 'image/jpeg' then 'jpg' when 'image/png' then 'png' when 'image/webp' then 'webp' when 'image/gif' then 'gif'
                   when 'video/mp4' then 'mp4' when 'video/webm' then 'webm' end;
  if v_ext is null then raise exception '사진(jpg·png·webp·gif)이나 영상(mp4·webm)만 올릴 수 있습니다'; end if;
  v_max := case when ct like 'video/%' then 50 * 1024 * 1024 else 10 * 1024 * 1024 end;
  if sz is null or sz <= 0 then raise exception '빈 파일입니다'; end if;
  if sz > v_max then raise exception '파일이 너무 큽니다 (사진 10MB, 영상 50MB 까지)'; end if;
  -- case 를 괄호로 감싸야 한다. plpgsql 의 if 는 조건을 **처음 나오는 then** 까지로 잘라 읽어서,
  -- 감싸지 않으면 case 안의 then 에서 조건이 끝나 42601 "syntax error at end of input" 이 난다 (2026-10-28 실제로 겪었다)
  if (select count(*) from public.media_uploads where user_id = v_me and created_at > now() - interval '1 day')
     >= (case when v_admin then 200 else 20 end) then
    raise exception '오늘은 더 올릴 수 없습니다. 내일 다시 시도해 주세요';
  end if;
  if not v_admin and (select count(*) from public.items where owner_id = v_me and status = 'pending') >= 10 then
    raise exception '승인을 기다리는 사진·영상이 10개입니다. 운영자가 확인한 뒤에 더 올려 주세요';
  end if;
  v_key := 'm/' || replace(gen_random_uuid()::text, '-', '') || '.' || v_ext;
  insert into public.media_uploads (key, user_id, content_type, size) values (v_key, v_me, ct, sz);
  return v_key;
end $$;
revoke all on function public.media_begin(text, bigint) from public, anon;
grant execute on function public.media_begin(text, bigint) to authenticated;

-- 새 자료의 status·media_* 는 서버가 정한다. 화면이 approved 를 실어 보내도, 남의 열쇠를 실어 보내도 통하지 않는다.
-- 운영자가 올린 것도 pending 으로 들어간다 — 승인(파일 크기·형식 확인, 공개 버킷으로 옮기기)을 거쳐야 공개 주소가 생긴다.
-- 화면은 운영자가 올리면 곧바로 승인을 부른다.
-- 로그인 맥락이 없으면(SQL Editor, seed) 손대지 않는다. 고칠 때는 컬럼 권한이 막으므로 insert 만 본다.
create or replace function public.guard_item_media()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_ct text;
begin
  if auth.uid() is null then return new; end if;
  if new.media_key is null then
    new.status := 'approved'; new.media_type := null;
    return new;
  end if;
  update public.media_uploads set used = true
   where key = new.media_key and user_id = auth.uid() and not used
   returning content_type into v_ct;
  if v_ct is null then raise exception '올린 파일을 찾지 못했습니다. 파일을 다시 골라 주세요'; end if;
  new.status := 'pending'; new.media_type := v_ct;
  return new;
end $$;
drop trigger if exists items_media_guard on public.items;
create trigger items_media_guard
  before insert on public.items for each row execute function public.guard_item_media();

-- 승인. media 함수가 파일을 공개 버킷으로 옮긴 **뒤에** 부른다 (먼저 찍으면 공개 주소가 한동안 빈 파일을 가리킨다)
create or replace function public.media_approve(iid text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '운영자만 승인할 수 있습니다'; end if;
  update public.items set status = 'approved' where id = iid and status = 'pending' and media_key is not null;
  return found;
end $$;
revoke all on function public.media_approve(text) from public, anon;
grant execute on function public.media_approve(text) to authenticated;

-- 지운 자료의 파일은 여기 쌓였다가 media 함수(sweep)가 R2 에서 지운다. DB 는 R2 를 직접 부를 수 없다.
-- 자료를 지우는 길이 여럿(화면, 검토함, delete-user.sql, 매일 정리)이라 트리거로 받는다.
-- sweep 은 운영자만 돈다(운영자가 검토함을 열 때, 승인·삭제할 때). 그래서 올린 사람이 지운 공개 파일은 그때까지 주소로 열린다.
create table if not exists public.media_trash (
  bucket text not null check (bucket in ('pending','approved')),
  key text not null,
  created_at timestamptz not null default now(),
  primary key (bucket, key)
);
alter table public.media_trash enable row level security;
create or replace function public.trash_item_media()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.media_key is not null then
    insert into public.media_trash (bucket, key) values (old.status, old.media_key) on conflict do nothing;
  end if;
  return old;
end $$;
drop trigger if exists items_media_trash on public.items;
create trigger items_media_trash
  after delete on public.items for each row execute function public.trash_item_media();

create or replace function public.media_trash_take(lim integer default 50)
returns table (bucket text, key text) language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '운영자만 쓸 수 있습니다'; end if;
  return query select t.bucket, t.key from public.media_trash t order by t.created_at
    limit greatest(1, least(coalesce(lim, 50), 200));
end $$;
revoke all on function public.media_trash_take(integer) from public, anon;
grant execute on function public.media_trash_take(integer) to authenticated;
-- R2 에서 지운 것만 부른다. 지우지 못한 것을 여기서 빼면 그 파일은 영영 남는다
create or replace function public.media_trash_done(b text, keys text[])
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not public.is_admin() then raise exception '운영자만 쓸 수 있습니다'; end if;
  delete from public.media_trash where bucket = b and key = any(keys);
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.media_trash_done(text, text[]) from public, anon;
grant execute on function public.media_trash_done(text, text[]) to authenticated;

-- ---------- 실시간 반영 ----------
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;
do $$
declare t text;
begin
  foreach t in array array['items','collections','reports','settings'] loop
    if not exists (
      select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ---------- 매일 정리 (pg_cron) ----------
-- 개인정보 처리방침에 "지난 기록은 지운다" 고 쓰려면 실제로 지워야 한다. 작업 없이 문장만 있으면 처리방침이 거짓이 된다.
--   (1) ai_usage: 목적이 "하루 사용 한도" 하나뿐이라 날이 지나면 보관할 근거가 없다.
--       어제 것까지는 남긴다 — 자정을 넘긴 요청이 실패하면 환불(ai_refund_quota)이 날짜를 넘겨 들어올 수 있다.
--   (2) 한 번도 로그인하지 않은 계정: 이메일 코드를 요청하는 순간(코드를 확인하기 전에) 계정 행이 생긴다. 남의 주소를 적었을 수도 있다.
--       코드는 1시간 유효하므로 1일이 지나도 로그인한 적이 없으면 지운다.
--       로그인 없이는 글·추천·신고를 못 해서 딸린 것이 있을 수 없지만, 무엇이든 딸려 있으면 손대지 않는다.
--   (3) 7일 동안 승인되지 않은 사진·영상은 자료째 지운다 (파일은 items_media_trash 가 받아 sweep 이 지운다).
--       기준 시각은 media_uploads.created_at 이다. items.created_at 은 화면이 보내는 값이라 미래로 적어 버틸 수 있다.
--       R2 비공개 버킷의 수명 규칙(8일)이 그 뒤에 남은 파일을 지운다 — 열쇠만 받고 자료를 안 만든 업로드도 거기서 지워진다.
--   (4) 올리기 기록은 하루 횟수를 세는 데만 쓴다. 승인 대기 중인 것만 빼고 30일이 지나면 지운다.
-- 같은 이름으로 다시 등록하면 덮어쓴다(재실행 안전). pg_cron 시각은 UTC — 19:07 은 한국 시간 새벽 4시 7분.
-- 확인: select jobname, schedule, active from cron.job;   실행 기록: select * from cron.job_run_details order by start_time desc limit 5;
create extension if not exists pg_cron;
select cron.schedule('daily-privacy-cleanup', '7 19 * * *', $job$
  delete from public.ai_usage where day < current_date - 1;
  delete from auth.users u
   where u.last_sign_in_at is null
     and u.created_at < now() - interval '1 day'
     and not exists (select 1 from public.items       where owner_id    = u.id)
     and not exists (select 1 from public.collections where owner_id    = u.id)
     and not exists (select 1 from public.reports     where reporter_id = u.id)
     and not exists (select 1 from public.votes       where user_id     = u.id)
     and not exists (select 1 from public.profiles p  where p.id = u.id and (p.is_admin or p.name <> ''));
  delete from public.items i
   where i.status = 'pending'
     -- 기록이 아예 없는 것(올린 사람이 탈퇴해 cascade 로 지워짐)도 함께 지운다
     and not exists (select 1 from public.media_uploads m where m.key = i.media_key and m.created_at >= now() - interval '7 days');
  delete from public.media_uploads m
   where m.created_at < now() - interval '30 days'
     and not exists (select 1 from public.items i where i.media_key = m.key and i.status = 'pending');
$job$);

-- 인증 감사 기록(auth.audit_log_entries) 30일 정리. 처리방침 3장이 "30일이 지난 기록은 매일 지운다" 고 적는다.
-- 대시보드 Authentication › Audit Logs 의 "Write audit logs to the database" 가 켜져 있으면 로그인·코드 요청마다
-- IP·이메일이 담긴 행이 쌓인다 (꺼져 있으면 지울 것이 없을 뿐이다). 탈퇴 때는 delete-user.sql 이 그 사람 것을 바로 지운다.
-- 위 작업과 따로 둔다 — auth 스키마 권한 문제로 이 줄이 실패해도 위 정리까지 함께 롤백되지 않게. 시각은 위보다 10분 뒤.
select cron.schedule('daily-audit-log-cleanup', '17 19 * * *', $job$
  delete from auth.audit_log_entries where created_at < now() - interval '30 days';
$job$);

-- ============================================================
-- 운영자 지정: 본인이 사이트에 한 번 로그인한 뒤, 아래 한 줄을
-- 이메일만 바꿔 실행하세요.
-- ============================================================
-- update public.profiles set is_admin = true
--   where id = (select id from auth.users where email = 'mail@wkac.co.kr');
