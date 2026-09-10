-- 제휴 사이트. schema.sql 을 실행한 뒤 SQL Editor 에서 실행하세요.
-- 여러 번 실행해도 안전합니다. **이 파일이 정본입니다** — 다시 실행하면 아래 내용으로 되돌립니다.
--   · 제휴 소개 문구나 주소를 바꾸려면 화면이 아니라 이 파일을 고치고 다시 실행하세요
--   · 제휴를 빼려면 이 파일에서 지우고, 화면에서 그 자료를 지우세요. 화면에서만 빼면 다음 실행에 되돌아옵니다
--
-- 새 표를 만들지 않습니다. 제휴 사이트도 결국 자료 하나이고,
-- 모음(collections)이 이미 "주제별로 항목을 묶는" 그릇이라 검색·권한·신고·수정이 그대로 딸려 옵니다.
-- 바닥글은 config.js 의 `PARTNER_COL` 이 가리키는 **모음 id** 를 읽어 그 안의 자료를 링크로 그립니다.
--
-- **모음을 반드시 이 파일로 만들어야 합니다.** 화면에서 만든 모음은 (가) 임의 id 를 받아 config.js 와 안 이어지고
-- (나) 만든 사람이 주인으로 남는데, 바닥글은 **주인 없는 모음만** 그립니다. 아래 "왜" 를 보세요.
--
-- 제휴가 늘면 두 곳에 한 줄씩 더합니다. 코드는 안 고칩니다.
--   1) items 에 자료 한 줄
--   2) 맨 아래 "모음에 담기" 의 배열에 그 자료 id

-- ---------- 먼저: 남이 이 자리를 차지했는지 본다 ----------
-- 모음 id 와 자료 id 는 **선착순**이다. 이 파일을 돌리기 전이거나 운영자가 모음을 지운 뒤라면,
-- 아무 로그인 사용자나 JSON 가져오기로 같은 id 의 모음을 만들어 바닥글을 통째로 가져갈 수 있다.
-- 그런 상태에서 이 파일이 조용히 성공하면 남의 모음에 우리 자료를 담아 주게 되므로 시끄럽게 멈춘다.
do $$
declare who uuid;
begin
  select owner_id into who from public.collections where id = 'partners';
  if who is not null then
    raise exception '모음 "partners" 를 다른 사람이 차지하고 있습니다 (owner_id=%). 운영자로 그 모음을 지운 뒤 이 파일을 다시 실행하세요', who;
  end if;
  select owner_id into who from public.items where id = 'partner-gameant';
  if who is not null then
    raise exception '자료 "partner-gameant" 를 다른 사람이 차지하고 있습니다 (owner_id=%). 운영자로 그 자료를 지운 뒤 다시 실행하세요', who;
  end if;
end $$;

-- ---------- 자료 ----------
-- **분야를 일부러 비운다.** 분야를 주면 그 분야의 주 관리자가 items_update 정책의
-- `manages_category_id(category_id)` 갈래로 이 자료를 고칠 수 있고, 그건 곧 사이트 전면 바닥글의
-- 제목·주소를 담당자가 바꿀 수 있다는 뜻이다. 분야가 없으면 그 갈래가 false 라 실제로 운영자 전용이 된다.
-- (owner_id 를 박아도 소용없다 — 정책이 OR 라 담당자 갈래가 그대로 남는다)
-- 대신 이 자료는 왼쪽 "분야 없음" 에 모인다. 제휴 모음과 검색으로 찾을 수 있다.
insert into public.items (id, type, title, url, lang, body, category, category_id, sub, tags, by, created_at) values

('partner-gameant','link','ant@IT','https://gameant.pages.dev','',
 E'IT 정보·개발 지식·코딩·AI 를 다루는 한국어 사이트.\n기술 아티클과 가이드, 게임 개발 이야기, 자유 게시판이 있다.',
 '', null, '', '{제휴,IT,개발,블로그}','운영','2026-09-10T00:00:00Z')

on conflict (id) do update set
  type = excluded.type, title = excluded.title, url = excluded.url, body = excluded.body,
  category = excluded.category, category_id = excluded.category_id, sub = excluded.sub,
  tags = excluded.tags, updated_at = now()
 where public.items.owner_id is null;   -- 남이 차지한 행은 덮지 않는다 (위에서 이미 막았지만 한 겹 더)

-- ---------- 모음 ----------
-- owner_id 를 비워 둔다. 바닥글이 "주인 없는 모음" 만 그리는 것이 선점 방어의 핵심이다.
insert into public.collections (id, title, "desc", item_ids, by, created_at) values
('partners','제휴 사이트','함께 보면 좋은 곳입니다. 바닥글에도 나옵니다.','{}','운영','2026-09-10T00:00:00Z')
on conflict (id) do update set
  title = excluded.title, "desc" = excluded."desc", by = excluded.by, updated_at = now()
 where public.collections.owner_id is null;

-- ---------- 모음에 담기 ----------
-- 아직 안 담긴 것만 더합니다. 사람이 화면에서 담아 둔 것은 지우지 않습니다.
-- 지워진 자료 id 를 담지 않도록 items 에 실제로 있는 것만 고릅니다.
update public.collections c
   set item_ids = c.item_ids || add.ids, updated_at = now()
  from (
    select coalesce(array_agg(i.id order by i.id), '{}'::text[]) as ids
      from public.items i
     where i.id = any ('{partner-gameant}'::text[])
       and not (select item_ids from public.collections where id = 'partners') @> array[i.id]
  ) add
 where c.id = 'partners' and c.owner_id is null and add.ids <> '{}'::text[];
