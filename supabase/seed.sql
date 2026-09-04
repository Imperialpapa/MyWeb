-- 초기 자료 18개 (선택). schema.sql 을 실행한 뒤 SQL Editor 에서 실행하세요.
-- owner_id 가 비어 있으므로 운영자만 수정·삭제할 수 있습니다.
insert into public.items (id, type, title, url, lang, body, category, sub, tags, by, created_at) values
('seed-01','link','Excalidraw','https://excalidraw.com','','손그림 느낌의 다이어그램 도구. 회의 중 구조를 빠르게 그려 보여줄 때 좋음. 설치 없이 브라우저에서 바로.','개발·도구','디자인·문서','{다이어그램,무료,협업}','초기 자료','2026-09-04T01:00:00Z'),
('seed-02','link','regex101','https://regex101.com','','정규식을 실시간으로 테스트하고 각 부분이 무엇을 뜻하는지 설명해 줌. JS·Python·Go 방언 선택 가능.','개발·도구','웹','{정규식,테스트}','초기 자료','2026-09-04T01:05:00Z'),
('seed-03','link','Squoosh','https://squoosh.app','','이미지 압축·포맷 변환. 원본과 결과를 나란히 비교하며 품질 조절. 서버 업로드 없이 브라우저에서 처리.','개발·도구','디자인·문서','{이미지,최적화,무료}','초기 자료','2026-09-04T01:10:00Z'),
('seed-04','link','jq play','https://jqplay.org','','JSON 을 붙여넣고 jq 필터를 바로 실험. 복잡한 응답에서 원하는 값만 뽑는 식을 만들 때.','개발·도구','CLI·스크립트','{json,jq,cli}','초기 자료','2026-09-04T01:15:00Z'),
('seed-05','link','MDN Web Docs','https://developer.mozilla.org/ko/','','웹 표준(HTML·CSS·JS·Web API) 공식 레퍼런스. 한국어 번역본 포함.','개발·도구','학습자료','{레퍼런스,웹,문서}','초기 자료','2026-09-04T01:20:00Z'),
('seed-06','snippet','최근 작업한 브랜치 순으로 보기','','bash',E'git branch --sort=-committerdate --format=\'%(committerdate:relative)%09%(refname:short)\' | head -20','개발·도구','CLI·스크립트','{git,브랜치}','초기 자료','2026-09-04T01:25:00Z'),
('seed-07','snippet','멈춘 도커 컨테이너·오래된 이미지 정리','','bash',E'# 멈춘 컨테이너 삭제\ndocker container prune -f\n\n# 일주일 넘게 안 쓴 이미지 삭제\ndocker image prune -a -f --filter "until=168h"\n\n# 남은 용량 확인\ndocker system df','개발·도구','CLI·스크립트','{docker,정리,디스크}','초기 자료','2026-09-04T01:30:00Z'),
('seed-08','snippet','Windows 에서 포트를 잡고 있는 프로세스 찾기','','powershell',E'# 3000 포트를 쓰는 프로세스 ID\nGet-NetTCPConnection -LocalPort 3000 -State Listen | Select-Object OwningProcess\n\n# 그 프로세스가 무엇인지\nGet-Process -Id <PID>\n\n# 종료\nStop-Process -Id <PID> -Force','개발·도구','CLI·스크립트','{windows,powershell,포트}','초기 자료','2026-09-04T01:35:00Z'),
('seed-09','snippet','JSON 을 보기 좋게 정렬해서 저장','','bash',E'# 키 정렬 + 들여쓰기 2칸\npython -m json.tool --sort-keys --indent 2 input.json > pretty.json\n\n# jq 로 같은 작업\njq -S . input.json > pretty.json','개발·도구','CLI·스크립트','{json,cli,python}','초기 자료','2026-09-04T01:40:00Z'),
('seed-10','note','새 프로젝트 시작 체크리스트','','',E'1. README 에 \'이 저장소가 하는 일\' 세 줄 먼저 쓰기\n2. .gitignore, .editorconfig, 포매터 설정\n3. 환경변수는 .env.example 로 키만 공개\n4. 첫 커밋 전에 라이선스 결정\n5. CI 에서 lint + test 만이라도 돌리기\n6. 배포 주소와 담당자를 README 상단에\n\n나중에 합류하는 사람이 30분 안에 실행할 수 있으면 합격.','개발·도구','프로젝트 운영','{체크리스트,프로젝트,온보딩}','초기 자료','2026-09-04T01:45:00Z'),
('seed-11','file','Python 공식 문서 (오프라인 다운로드)','https://docs.python.org/ko/3/download.html','pdf','공식 문서 전체를 PDF·HTML 로 내려받는 페이지. 비행기·오프라인 환경에서 참고용.','개발·도구','학습자료','{python,문서,오프라인}','초기 자료','2026-09-04T01:50:00Z'),
('seed-12','link','식품영양성분 데이터베이스 (식약처)','https://various.foodsafetykorea.go.kr/nutrient/','','국내 식품의 열량·단백질·나트륨 등 공식 영양성분 조회. 식단 기록할 때 기준 자료.','생활·건강·취미','식단','{영양,식단,공공데이터}','초기 자료','2026-09-04T02:00:00Z'),
('seed-13','link','국민체력100','https://nfa.kspo.or.kr','','국민체육진흥공단 무료 체력 측정·운동 처방 서비스. 가까운 체력인증센터 예약 가능.','생활·건강·취미','운동','{운동,체력측정,무료}','초기 자료','2026-09-04T02:05:00Z'),
('seed-14','note','주 3회 근력 루틴','','',E'월: 하체 (스쿼트 5x5, 런지 3x10, 카프레이즈 3x15)\n수: 밀기 (벤치프레스 5x5, 숄더프레스 3x8, 딥스 3x최대)\n금: 당기기 (데드리프트 5x5, 바벨로우 3x10, 턱걸이 3x최대)\n\n- 각 세션 45분 이내, 세트 사이 90초\n- 5x5 를 다 채우면 다음 주 2.5kg 증량\n- 잠 6시간 미만인 날은 무게 20% 낮추기','생활·건강·취미','운동','{운동,루틴,근력}','초기 자료','2026-09-04T02:10:00Z'),
('seed-15','link','기상청 날씨누리','https://www.weather.go.kr','','공식 예보. 주말 야외 활동 계획할 때 동네예보와 특보 확인.','생활·건강·취미','정보·공공','{날씨,야외,공공}','초기 자료','2026-09-04T02:15:00Z'),
('seed-16','link','국립중앙도서관','https://www.nl.go.kr','','소장 자료 검색과 디지털 열람. 절판된 책이나 옛 자료 찾을 때.','생활·건강·취미','책·문화','{도서관,책,자료}','초기 자료','2026-09-04T02:20:00Z'),
('seed-17','note','주간 장보기 기본 목록','','',E'매주 고정: 달걀 30구, 닭가슴살 1kg, 두부 2모, 현미 2kg, 냉동 블루베리, 양파·마늘, 그릭요거트\n\n격주: 올리브유, 견과류 믹스, 김\n\n장보기 전 냉장고 사진 한 장 찍고 가기. 중복 구매가 확 줄어듦.','생활·건강·취미','식단','{장보기,식단,루틴}','초기 자료','2026-09-04T02:25:00Z'),
('seed-18','link','Hevy','https://www.hevyapp.com','','운동 세트·무게 기록 앱. 이전 기록이 바로 보여서 증량 판단이 쉬움. 기본 기능 무료.','생활·건강·취미','운동','{운동,기록,앱}','초기 자료','2026-09-04T02:30:00Z')
on conflict (id) do nothing;
