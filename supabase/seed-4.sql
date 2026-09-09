-- 유머 분야 + 자료 12개. schema.sql 을 실행한 뒤 SQL Editor 에서 실행하세요.
-- 여러 번 실행해도 중복되지 않습니다. owner_id 가 비어 있으므로 운영자만 수정·삭제할 수 있습니다.

-- ---------- 분야 추가: settings.categories 에 id 'humor' 도 이름 '유머' 도 없을 때만 붙임 ----------
insert into public.settings (key, value) values ('categories', '{"list":[]}'::jsonb) on conflict (key) do nothing;
update public.settings
   set value = jsonb_set(value, '{list}', coalesce(value->'list', '[]'::jsonb) || '[{"id":"humor","name":"유머","subs":["만화·웹툰","개발자 유머","밈·인터넷 문화","이스터에그·장난"]}]'::jsonb),
       updated_at = now()
 where key = 'categories'
   -- 중복 판정은 **id 가 먼저**다. 이름만 보면 분야를 개명한 뒤 이 파일을 다시 돌릴 때
   -- 같은 id 를 한 번 더 붙이게 되고, settings_keep_ids 가 '같은 id 의 분야가 두 개입니다' 로
   -- 이 스크립트 전체를 막아 아래 자료 12건까지 통째로 롤백된다.
   -- 이름도 함께 보는 것은, 화면에서 같은 이름의 분야를 이미 만들어 둔(= 다른 id 를 받은) 경우
   -- '같은 이름의 분야가 두 개입니다' 로 같은 롤백이 나기 때문이다.
   and not exists (select 1 from jsonb_array_elements(coalesce(value->'list', '[]'::jsonb)) c
                    where c->>'id' = 'humor' or c->>'name' = '유머');

-- ---------- 자료 ----------
insert into public.items (id, type, title, url, lang, body, category, sub, tags, by, created_at) values

('seed4-01','link','xkcd','https://xkcd.com','','개발자·과학자 사이에서 가장 널리 읽히는 영어 웹툰. 코드, 통계, 보안 이야기를 한 컷으로 웃긴다. 그림 위에 마우스를 올리면 숨은 문구가 뜬다.','유머','만화·웹툰','{웹툰,개발자,영어}','초기 자료','2026-09-07T02:00:00Z'),
('seed4-02','link','CommitStrip','https://www.commitstrip.com','','개발 팀의 일상을 그린 웹툰. 기획·리뷰·배포에서 겪는 장면이 많아 팀 채널에 붙이기 좋다. 영어판과 프랑스어판이 있다.','유머','만화·웹툰','{웹툰,개발자,팀}','초기 자료','2026-09-07T02:05:00Z'),
('seed4-03','link','네이버 웹툰','https://comic.naver.com','','한국에서 가장 많이 보는 웹툰 사이트. 개그·일상 장르에 짧게 읽고 웃을 작품이 많다. 요일별 무료 연재.','유머','만화·웹툰','{웹툰,한국,일상}','초기 자료','2026-09-07T02:10:00Z'),
('seed4-04','link','HTTP Cats','https://http.cat','','HTTP 상태 코드를 고양이 사진 한 장으로 보여 준다. 주소 뒤에 코드를 붙이면(http.cat/404) 바로 그 그림이 나와서 API 오류를 설명할 때 쓰기 좋다.','유머','개발자 유머','{http,상태코드,api}','초기 자료','2026-09-07T02:15:00Z'),
('seed4-05','link','The Daily WTF','https://thedailywtf.com','','현업에서 실제로 나온 황당한 코드와 시스템 이야기를 모으는 곳. 웃다가 우리 코드를 돌아보게 된다. 2004년부터 이어진 아카이브.','유머','개발자 유머','{코드,실화,영어}','초기 자료','2026-09-07T02:20:00Z'),
('seed4-06','snippet','418 I''m a teapot 응답 만들기','','javascript',E'// Express. 만우절 RFC 2324 에 나오는 상태 코드 418 을 그대로 돌려준다.\n// 실서비스 경로에는 두지 말고 내부 데모나 사내 헬스체크 장난용으로만.\napp.get(''/teapot'', (req, res) => {\n  res.status(418).json({ error: "I''m a teapot", rfc: 2324 });\n});\n\n// 확인\n// curl -i http://localhost:3000/teapot\n//   HTTP/1.1 418 I''m a teapot','유머','개발자 유머','{http,418,express}','초기 자료','2026-09-07T02:25:00Z'),
('seed4-07','link','Know Your Meme','https://knowyourmeme.com','','밈이 어디서 나와 어떻게 퍼졌는지 출처를 정리한 백과사전. 뜻을 모른 채 쓰다가 생기는 오해를 줄여 준다.','유머','밈·인터넷 문화','{밈,백과,영어}','초기 자료','2026-09-07T02:30:00Z'),
('seed4-08','link','GIPHY','https://giphy.com','','검색해서 바로 쓰는 GIF 모음. 슬랙·팀즈에 붙여 넣기 좋고, 퍼오는 대신 링크로 걸 수 있어 출처가 남는다.','유머','밈·인터넷 문화','{gif,슬랙,반응}','초기 자료','2026-09-07T02:35:00Z'),
('seed4-09','note','사내 자료함에 유머를 올릴 때 지키는 선','','',E'1. 출처가 분명한 것만. 공식 사이트·위키·아카이브·공개 저장소 링크로 걸고, 밈 이미지 파일을 직접 올리지 않는다\n2. 정치·종교 풍자, 특정 인물·회사 조롱은 올리지 않는다. 편이 갈리는 것은 웃기기 전에 불편하다\n3. 성적·폭력적 표현이나 욕설이 섞인 자료는 제외. 신입도 고객도 이 자료함을 본다\n4. 사내 사람이나 고객이 등장하는 짤은 당사자 동의 없이 올리지 않는다\n5. 링크로 걸 수 있으면 링크로. 퍼온 이미지는 저작권 판단이 어렵다\n6. 애매하면 올리지 않는다. 웃음 하나 얻자고 감수할 위험이 아니다','유머','밈·인터넷 문화','{운영,저작권,규칙}','초기 자료','2026-09-07T02:40:00Z'),
('seed4-10','link','RFC 2324 하이퍼텍스트 커피포트 제어 규약(HTCPCP)','https://www.rfc-editor.org/rfc/rfc2324','','1998년 만우절에 실제로 발행된 RFC. 커피포트를 HTTP 로 제어하자는 농담이며, 여기서 상태 코드 418 (I''m a teapot) 이 나왔다.','유머','이스터에그·장난','{rfc,만우절,http}','초기 자료','2026-09-07T02:45:00Z'),
('seed4-11','link','만우절 (위키백과)','https://ko.wikipedia.org/wiki/만우절','','4월 1일 장난의 유래와 나라별 사례. 사내 만우절 이벤트를 기획하기 전에 선을 어디까지 둘지 참고하기 좋다.','유머','이스터에그·장난','{만우절,문화,위키}','초기 자료','2026-09-07T02:50:00Z'),
('seed4-12','snippet','터미널에서 잠깐 웃기 (sl · cowsay · fortune)','','bash',E'# ls 를 sl 로 잘못 치면 증기기관차가 화면을 가로지른다\nsudo apt install sl fortune-mod cowsay figlet   # 데비안·우분투\nbrew install sl fortune cowsay figlet           # macOS\n\nsl                 # 기차\nfortune | cowsay   # 소가 한마디\nfiglet "DEPLOY OK" # 큰 글자로 공지\n\n# 셸을 켤 때마다 한마디 (~/.bashrc 또는 ~/.zshrc 맨 아래)\n# fortune | cowsay','유머','이스터에그·장난','{cli,터미널,bash}','초기 자료','2026-09-07T02:55:00Z')

on conflict (id) do nothing;

-- ---------- 분야 잇기 ----------
-- 분야를 이름이 아니라 id 로 못 박는다. 위 insert 는 이름만 싣는데,
-- 이 분야를 개명한 DB 에서는 그 이름이 목록에 없어 트리거가 id 를 못 찾고
-- 자료가 오류 하나 없이 전부 "분야 없음" 으로 떨어진다.
-- 이미 다른 분야로 옮겨 둔 자료는 category_id 가 차 있으므로 건드리지 않는다.
update public.items set category_id = 'humor'
 where id like 'seed4-%' and category_id is null
   and exists (select 1 from public.settings s,
                      lateral jsonb_array_elements(coalesce(s.value->'list','[]'::jsonb)) c
                where s.key='categories' and c->>'id' = 'humor');

