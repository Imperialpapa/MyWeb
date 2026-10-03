-- ============================================================
-- 탈퇴(계정 삭제) 요청 처리 — Supabase 대시보드 → SQL Editor 에서 실행
-- 맨 아래 "여기만 고친다" 두 줄만 바꿔 넣고 전체를 Run 한다.
-- ============================================================
--
-- **대시보드 Authentication → Users 에서 사용자를 바로 지우면 안 된다.**
-- 그러면 items·collections·reports 의 owner_id·reporter_id 가 null 이 되어(on delete set null)
-- 그 사람이 올린 자료와 신고를 **더는 찾을 수 없다.** 표시 이름(by)은 글마다 복사된 스냅샷이라
-- 이름은 공개로 남는데 누구 것인지는 모르게 되고, 분야 담당자 지정(settings 안의 UUID)도 그대로 남는다.
-- 이 파일은 그 순서를 지킨다: 흔적을 먼저 정리하고 → 마지막에 계정을 지운다.
--
-- 계정 찾기 (표시 이름으로):
--   select p.id, p.name, u.email, u.created_at, u.last_sign_in_at
--     from public.profiles p join auth.users u on u.id = p.id
--    where p.name = '표시 이름';
--
-- 한 트랜잭션으로 돈다(SQL Editor 가 전체를 한 번에 실행한다). 중간에 실패하면 아무것도 바뀌지 않는다.
-- 카카오 계정의 "연결된 서비스" 목록에서는 이 SQL 로 빠지지 않는다. 요청자에게
-- 카카오톡 → 설정 → 카카오계정 → 연결된 서비스 관리 에서 직접 끊으면 된다고 안내한다.

create temp table if not exists delete_user_result (step text, n integer) on commit drop;
truncate delete_user_result;

do $$
declare
  -- ---------- 여기만 고친다 ----------
  v_email        text    := '';      -- 이메일로 찾기. 카카오에서 이메일 동의를 안 한 계정은 이메일이 없으니 아래 id 를 쓴다
  v_uid          uuid    := null;    -- 또는 계정 id (위 "계정 찾기" 쿼리의 id)
  v_delete_posts boolean := false;   -- false: 올린 자료·모음은 남기고 작성자 이름만 '탈퇴한 사용자' 로 / true: 자료·모음도 지운다
  -- -----------------------------------
  v_label constant text := '탈퇴한 사용자';
  v_n integer;
begin
  if v_uid is null then
    if coalesce(v_email, '') = '' then
      raise exception 'v_email 이나 v_uid 중 하나를 채워 주세요';
    end if;
    if (select count(*) from auth.users where lower(email) = lower(v_email)) > 1 then
      raise exception '같은 이메일의 계정이 여럿입니다. v_uid 로 지정해 주세요: %', v_email;
    end if;
    select id into v_uid from auth.users where lower(email) = lower(v_email);
  end if;
  if v_uid is null or not exists (select 1 from auth.users where id = v_uid) then
    raise exception '그 계정이 없습니다 (email=%, id=%)', v_email, v_uid;
  end if;
  -- 운영자를 지우면 운영 메뉴를 쓸 사람이 없어질 수 있다. 권한을 먼저 거두고 다시 실행한다
  if exists (select 1 from public.profiles where id = v_uid and is_admin) then
    raise exception '운영자 계정입니다. 먼저 update public.profiles set is_admin = false where id = ''%''; 를 실행한 뒤 다시 돌려 주세요', v_uid;
  end if;

  -- (1) 분야 담당자 지정 해제. settings 안의 UUID 는 외래키가 없어 계정을 지워도 남는다.
  --     id 를 든 줄에서 owner 를 빼면 keep_category_ids 트리거가 "담당자 해제" 로 받아들인다
  update public.settings s
     set value = jsonb_set(s.value, '{list}', (
           select coalesce(jsonb_agg(case when e.c->>'owner' = v_uid::text then e.c - 'owner' - 'ownerName' else e.c end
                                     order by e.ord), '[]'::jsonb)
             from jsonb_array_elements(s.value->'list') with ordinality e(c, ord)))
   where s.key = 'categories'
     and exists (select 1 from jsonb_array_elements(s.value->'list') c where c->>'owner' = v_uid::text);
  get diagnostics v_n = row_count;
  insert into delete_user_result values ('분야 담당자 지정 해제 (settings 행)', v_n);

  -- (1-2) 운영자 소개(settings.about)의 owner. "최근 올린 자료" 를 보여 줄 계정의 UUID 이고, 이것도 외래키가 없다.
  --       지우지 않으면 탈퇴한 계정의 UUID 가 누구나 읽는 settings 에 남는다. 빼 두면 다음에 소개를 저장한 운영자로 채워진다
  update public.settings set value = value - 'owner', updated_at = now()
   where key = 'about' and value->>'owner' = v_uid::text;
  get diagnostics v_n = row_count;
  insert into delete_user_result values ('운영자 소개 owner 해제 (settings 행)', v_n);

  -- (2) 올린 자료·모음. updated_at 은 건드리지 않는다 — 이름을 가린 것이 "수정" 은 아니다
  if v_delete_posts then
    delete from public.collections where owner_id = v_uid;
    get diagnostics v_n = row_count;
    insert into delete_user_result values ('모음 삭제', v_n);
    -- 자료를 지우면 그 자료의 추천·신고도 지워지고(cascade), 남의 모음에서도 빠진다(트리거)
    delete from public.items where owner_id = v_uid;
    get diagnostics v_n = row_count;
    insert into delete_user_result values ('자료 삭제', v_n);
  else
    update public.collections set by = v_label where owner_id = v_uid and by is distinct from v_label;
    get diagnostics v_n = row_count;
    insert into delete_user_result values ('모음 작성자 이름 가림', v_n);
    update public.items set by = v_label where owner_id = v_uid and by is distinct from v_label;
    get diagnostics v_n = row_count;
    insert into delete_user_result values ('자료 작성자 이름 가림', v_n);
  end if;

  -- (3) 그 사람이 낸 신고. 신고 내용은 검토 기록이라 남기고, 신고자 이름만 가린다
  update public.reports set by = v_label where reporter_id = v_uid and by is distinct from v_label;
  get diagnostics v_n = row_count;
  insert into delete_user_result values ('신고자 이름 가림', v_n);

  -- (4) 인증 감사 기록. 로그인·로그아웃마다 이메일과 IP 가 담긴 행이 쌓이는데, 계정과 외래키가 없어 계정을 지워도 남는다
  delete from auth.audit_log_entries where payload->>'actor_id' = v_uid::text;
  get diagnostics v_n = row_count;
  insert into delete_user_result values ('인증 감사 기록 삭제', v_n);

  -- (5) 마지막에 계정. profiles·추천(votes, 추천 수도 함께 줄어든다)·AI 사용량(ai_usage)은 cascade 로 지워지고,
  --     남긴 자료·모음·신고의 owner_id·reporter_id 는 null 이 된다
  select count(*) into v_n from public.votes where user_id = v_uid;
  insert into delete_user_result values ('추천 기록 삭제', v_n);
  delete from auth.users where id = v_uid;
  get diagnostics v_n = row_count;
  insert into delete_user_result values ('계정 삭제', v_n);
end $$;

select * from delete_user_result;
