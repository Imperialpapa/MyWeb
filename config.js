// 빠른 연결 설정
// Supabase 프로젝트 → Settings → API Keys 에서 복사해 넣으세요.
// publishable 키와 anon key 는 공개되어도 되는 키입니다 (권한은 데이터베이스의 RLS 규칙이 지킵니다).
// secret 키(sb_secret_…)나 service_role 키는 절대 여기에 넣지 마세요. 이 파일은 누구나 받아 봅니다.
window.TOOLBOX_CONFIG = {
  SUPABASE_URL: "https://csxndscngmkciibarumi.supabase.co",        // 예: https://abcdefghijk.supabase.co
  // 새 publishable 키(sb_publishable_…). 채우면 아래 anon key 대신 이것을 씁니다.
  // 옛 anon key 는 Supabase 가 2026년 말까지 폐지합니다. 옮기는 순서는 todo.md 참고.
  // **SUPABASE_ANON_KEY 줄은 옮기기가 끝날 때까지 지우지 마세요.** 화면과 keepalive 가 둘 중 하나라도 있어야 동작합니다.
  SUPABASE_PUBLISHABLE_KEY: "",
  SUPABASE_ANON_KEY: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNzeG5kc2NuZ21rY2lpYmFydW1pIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODg1MTg4OTEsImV4cCI6MjEwNDA5NDg5MX0.ifU2XWIfHE8kXFGGcS0q08nTuOCI9VT6c8UeAPEaeaA",   // 예: eyJhbGciOi...
  // 소셜 로그인 버튼. Supabase → Authentication → Providers 에서 켠 것만 적으세요. 예: ["kakao", "google"]
  AUTH_PROVIDERS: ["kakao"],
  // AI 기능 (올릴 때 분류 제안, 운영자용 자동 정리·분야 구조 제안).
  // supabase/functions/ai 를 배포하고 ANTHROPIC_API_KEY 를 등록해야 동작합니다 (README 7단계). 끄려면 false.
  AI: true,
  SITE_NAME: "빠른 연결",
  SITE_TAGLINE: "누구나 올리고, 누구나 찾는 자료함",
  // 제휴 사이트를 담아 둔 **모음의 id**. 그 모음에 든 자료가 바닥글에 링크로 나옵니다.
  // 이름이 아니라 id 로 가리킵니다 — 이름으로 가리키면 모음 이름을 바꾸는 순간 바닥글이 조용히 빕니다.
  // 만드는 법은 supabase/partners.sql 참고. 바닥글에서 빼려면 "" 로 두세요.
  PARTNER_COL: "partners",
  // 권리 침해(저작권·불법촬영물·사생활) 신고를 받을 이메일. 바닥글의 "권리 침해 신고" 안내에 **공개**됩니다.
  // 비워 두면 사이트 안 [신고] 버튼만 안내합니다 (로그인해야 쓸 수 있어 회원이 아닌 권리자는 못 씁니다).
  // 회사·개인 메일 말고 이 용도로 따로 만든 주소를 넣으세요. 예: "report@example.com"
  // 채우기 **전에** privacy.html 의 2장 2·3장 "권리 침해 신고 메일" 줄을 확정하세요 (메일로 이름·연락처·근거 자료를 받게 됩니다).
  REPORT_EMAIL: "",
  // 사진·영상 직접 올리기. Cloudflare R2 **공개 버킷의 주소**를 넣으면 켜집니다. 예: "https://pub-xxxx.r2.dev"
  // supabase/functions/media 를 배포하고 R2 비밀 값을 등록해야 동작합니다 (README "사진·영상"). 비워 두면 꺼집니다.
  // 올린 사진·영상은 운영자가 승인해야 공개됩니다.
  MEDIA_BASE: "https://pub-56e18436352746019b20fd2be46dbfe7.r2.dev",
};
