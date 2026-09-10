// 빠른 연결 설정
// Supabase 프로젝트 → Settings → API 에서 복사해 넣으세요.
// anon key 는 공개되어도 되는 키입니다 (권한은 데이터베이스의 RLS 규칙이 지킵니다).
window.TOOLBOX_CONFIG = {
  SUPABASE_URL: "https://csxndscngmkciibarumi.supabase.co",        // 예: https://abcdefghijk.supabase.co
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
};
