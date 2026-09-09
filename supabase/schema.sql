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

-- ---------- 분야 주 관리자 ----------
-- settings.categories 의 각 분야에 owner(사용자 uuid)를 넣어 지정한다.
-- 지정하지 않은 분야는 owner 가 없고, 운영자가 그대로 담당한다.

-- 내가 이 분야의 주 관리자인가
create or replace function public.manages_category(cat text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select true
      from public.settings s, lateral jsonb_array_elements(s.value->'list') c
     where s.key = 'categories'
       and c->>'name' = cat
       and c->>'owner' = auth.uid()::text
     limit 1), false)
$$;

-- 내가 아무 분야라도 맡고 있는가 (자료를 다른 분야로 옮길 때 쓴다)
create or replace function public.manages_any()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select true
      from public.settings s, lateral jsonb_array_elements(s.value->'list') c
     where s.key = 'categories' and c->>'owner' = auth.uid()::text
     limit 1), false)
$$;

-- 이 자료가 속한 분야를 내가 맡고 있는가 (신고 검토용)
create or replace function public.manages_item(iid text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.manages_category((select category from public.items where id = iid))
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
  '{"list":[{"name":"개발·도구","subs":["웹","CLI·스크립트","디자인·문서","학습자료","프로젝트 운영"]},{"name":"생활·건강·취미","subs":["운동","식단","정보·공공","책·문화"]},{"name":"AI 에이전트","subs":["에이전트 도구","프레임워크·SDK","MCP·연동","프롬프트·스킬","학습자료"]},{"name":"유머","subs":["만화·웹툰","개발자 유머","밈·인터넷 문화","이스터에그·장난"]}]}'::jsonb
) on conflict (key) do nothing;

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
create policy items_select on public.items for select using (true);
drop policy if exists items_insert on public.items;
create policy items_insert on public.items for insert to authenticated with check (owner_id = auth.uid());
drop policy if exists items_update on public.items;
create policy items_update on public.items for update to authenticated
  -- using 은 고치기 전 행을 본다: 내 글이거나, 운영자이거나, 그 분야의 주 관리자
  using (owner_id = auth.uid() or public.is_admin() or public.manages_category(category))
  -- with check 는 고친 뒤 행을 본다. 주 관리자가 잘못 분류된 자료를 맞는 분야로 옮길 수 있어야 하므로
  -- 여기서는 분야를 따지지 않고 "분야를 하나라도 맡은 사람"인지만 본다.
  with check (owner_id = auth.uid() or public.is_admin() or public.manages_any());
drop policy if exists items_delete on public.items;
create policy items_delete on public.items for delete to authenticated
  using (owner_id = auth.uid() or public.is_admin() or public.manages_category(category));

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
revoke update on public.items from authenticated, anon;
grant  update (type, title, url, lang, body, category, sub, tags, by, owner_id, updated_at)
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
     and (public.is_admin() or public.manages_category(category));
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.mark_checked(text[]) from public, anon;
grant execute on function public.mark_checked(text[]) to authenticated;

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

-- ============================================================
-- 운영자 지정: 본인이 사이트에 한 번 로그인한 뒤, 아래 한 줄을
-- 이메일만 바꿔 실행하세요.
-- ============================================================
-- update public.profiles set is_admin = true
--   where id = (select id from auth.users where email = 'mail@wkac.co.kr');
