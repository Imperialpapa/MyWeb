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
create or replace function public.protect_admin_flag()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.is_admin is distinct from old.is_admin and not public.is_admin() then
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
create index if not exists items_created_idx on public.items (created_at desc);
create index if not exists items_owner_idx on public.items (owner_id);

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
  '{"list":[{"name":"개발·도구","subs":["웹","CLI·스크립트","디자인·문서","학습자료","프로젝트 운영"]},{"name":"생활·건강·취미","subs":["운동","식단","정보·공공","책·문화"]}]}'::jsonb
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
  using (owner_id = auth.uid() or public.is_admin())
  with check (owner_id = auth.uid() or public.is_admin());
drop policy if exists items_delete on public.items;
create policy items_delete on public.items for delete to authenticated using (owner_id = auth.uid() or public.is_admin());

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
create policy reports_select on public.reports for select to authenticated using (reporter_id = auth.uid() or public.is_admin());
drop policy if exists reports_insert on public.reports;
create policy reports_insert on public.reports for insert to authenticated with check (reporter_id = auth.uid());
drop policy if exists reports_delete on public.reports;
create policy reports_delete on public.reports for delete to authenticated using (public.is_admin());

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
