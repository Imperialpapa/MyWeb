-- AI 에이전트 분야 + 자료 11개. schema.sql 을 실행한 뒤 SQL Editor 에서 실행하세요.
-- 여러 번 실행해도 중복되지 않습니다. owner_id 가 비어 있으므로 운영자만 수정·삭제할 수 있습니다.

-- ---------- 분야 추가: settings.categories 에 'AI 에이전트' 가 없을 때만 붙임 ----------
insert into public.settings (key, value) values ('categories', '{"list":[]}'::jsonb) on conflict (key) do nothing;
update public.settings
   set value = jsonb_set(value, '{list}', coalesce(value->'list', '[]'::jsonb) || '[{"name":"AI 에이전트","subs":["에이전트 도구","프레임워크·SDK","MCP·연동","프롬프트·스킬","학습자료"]}]'::jsonb),
       updated_at = now()
 where key = 'categories'
   and not exists (select 1 from jsonb_array_elements(coalesce(value->'list', '[]'::jsonb)) c where c->>'name' = 'AI 에이전트');

-- ---------- 자료 ----------
insert into public.items (id, type, title, url, lang, body, category, sub, tags, by, created_at) values

('seed3-01','link','Claude Code 문서','https://docs.claude.com/en/docs/claude-code/overview','','터미널에서 코드베이스를 읽고 고치는 에이전트. 설치·슬래시 명령·서브에이전트·MCP 연결 방법이 정리돼 있음.','AI 에이전트','에이전트 도구','{claude-code,cli,문서}','초기 자료','2026-09-07T01:00:00Z'),
('seed3-02','link','Building effective agents (Anthropic)','https://www.anthropic.com/research/building-effective-agents','','에이전트를 만들 때 워크플로와 에이전트를 구분하고, 단순한 구성부터 시작하라는 글. 처음 설계할 때 한 번 읽을 것.','AI 에이전트','학습자료','{설계,패턴,anthropic}','초기 자료','2026-09-07T01:05:00Z'),
('seed3-03','link','Model Context Protocol','https://modelcontextprotocol.io','','에이전트가 외부 도구·데이터에 붙는 표준 규약. 서버 만드는 법과 공개 서버 목록이 있음.','AI 에이전트','MCP·연동','{mcp,연동,표준}','초기 자료','2026-09-07T01:10:00Z'),
('seed3-04','link','Claude Agent SDK','https://docs.claude.com/en/api/agent-sdk/overview','','Claude Code 와 같은 에이전트 루프를 내 프로그램 안에서 쓰는 SDK. Python·TypeScript 지원.','AI 에이전트','프레임워크·SDK','{sdk,python,typescript}','초기 자료','2026-09-07T01:15:00Z'),
('seed3-05','link','LangGraph','https://langchain-ai.github.io/langgraph/','','에이전트 흐름을 그래프(상태 + 노드)로 그려서 만드는 프레임워크. 분기·반복이 많은 작업에 맞음.','AI 에이전트','프레임워크·SDK','{langgraph,python,워크플로}','초기 자료','2026-09-07T01:20:00Z'),
('seed3-06','link','OpenAI Agents SDK','https://openai.github.io/openai-agents-python/','','핸드오프·가드레일 개념으로 여러 에이전트를 잇는 경량 SDK. 예제가 짧아서 개념 잡기에 좋음.','AI 에이전트','프레임워크·SDK','{openai,sdk,python}','초기 자료','2026-09-07T01:25:00Z'),
('seed3-07','link','Smithery (MCP 서버 모음)','https://smithery.ai','','공개 MCP 서버를 검색하고 설치 명령을 바로 복사. 원하는 연동이 이미 있는지 먼저 확인.','AI 에이전트','MCP·연동','{mcp,서버,검색}','초기 자료','2026-09-07T01:30:00Z'),
('seed3-08','snippet','Claude Code 서브에이전트 정의 파일','','markdown',E'# 프로젝트의 .claude/agents/<이름>.md 로 저장\n---\nname: add-category\ndescription: 새 분야를 추가할 때 사용. "분야 추가", "카테고리 추가" 요청에 반드시 이 에이전트를 쓴다.\ntools: Read, Edit, Write, Glob, Grep, Bash\nmodel: inherit\n---\n\n여기부터는 에이전트에게 주는 지시문.\n1. 무엇을 읽고\n2. 무엇을 만들고\n3. 어떻게 검증하는지\n순서대로 적는다. description 은 Claude Code 가 자동 위임을 판단하는 기준이므로 트리거 문구를 넣어 둔다.','AI 에이전트','프롬프트·스킬','{claude-code,서브에이전트,설정}','초기 자료','2026-09-07T01:35:00Z'),
('seed3-09','snippet','Claude Code 에 MCP 서버 붙이기','','bash',E'# 프로젝트 범위로 등록 (.mcp.json 에 저장, 팀과 공유)\nclaude mcp add --scope project github -- npx -y @modelcontextprotocol/server-github\n\n# 등록된 서버 확인\nclaude mcp list\n\n# 제거\nclaude mcp remove github','AI 에이전트','MCP·연동','{claude-code,mcp,cli}','초기 자료','2026-09-07T01:40:00Z'),
('seed3-10','note','에이전트 만들기 전 체크리스트','','',E'1. 이 일이 정말 에이전트가 필요한가. 순서가 정해진 일이면 그냥 스크립트·워크플로\n2. 도구는 최소로. 도구가 많을수록 잘못 고르는 일이 늘어남\n3. 한 번에 한 가지 일만 시키고, 끝났는지 판단할 기준(테스트·빌드·체크리스트)을 준다\n4. 되돌릴 수 없는 동작(삭제·결제·발송)은 사람 확인을 끼운다\n5. 실패 로그를 남겨서 지시문을 고칠 근거로 삼는다\n6. 지시문은 파일로 두고 버전 관리한다\n\n잘 되는 에이전트는 똑똑한 모델보다 좁고 명확한 일 범위에서 나온다.','AI 에이전트','학습자료','{설계,체크리스트}','초기 자료','2026-09-07T01:45:00Z'),
('seed3-11','note','이 사이트에 분야 추가하기 (add-category 에이전트)','','',E'저장소의 .claude/agents/add-category.md 가 분야 추가 전담 에이전트다.\n\n사용법 (저장소 폴더에서 Claude Code 실행 후)\n  "데이터·분석 분야 추가해줘. 하위분야는 시각화, SQL, 통계로"\n\n에이전트가 하는 일\n- supabase/seed-N.sql: 분야를 settings 에 합치는 SQL + 초기 자료\n- supabase/seed-N.json: 같은 내용, 사이트의 JSON 가져오기용\n- schema.sql 기본 분야, index.html DEFAULT_CATS, README 표 갱신\n\n반영 방법 (둘 중 하나)\n- Supabase SQL Editor 에서 seed-N.sql 실행\n- 운영자로 로그인 → ⋯ → 파일로 관리 → JSON 가져오기 → seed-N.json','AI 에이전트','프롬프트·스킬','{운영,분야,claude-code}','초기 자료','2026-09-07T01:50:00Z')

on conflict (id) do nothing;
