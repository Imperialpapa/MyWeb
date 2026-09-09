// ============================================================
// 빠른 연결 AI 에이전트 (Supabase Edge Function)
// ------------------------------------------------------------
// 브라우저는 API 키를 가질 수 없으므로, AI 호출은 모두 이 함수가 대신한다.
//   suggest  : 새 항목 하나의 분야·하위분야·태그(·제목·설명) 제안   — 로그인 사용자
//   organize : 여러 항목(최대 30개)을 다시 분류해 바꿀 것만 제안     — 운영자
//   taxonomy : 전체 자료를 보고 분야·하위분야 구조 개편안 제안        — 운영자
//   expand   : 고른 분야에 넣을 자료를 새로 제안 (링크 생존·중복·위험 명령은 서버가 검증) — 운영자
//
// 분야는 이름이 아니라 **id** 로 오간다. 화면은 categoryId 를 보내고, 응답은 {categoryId, category} 를 함께 준다.
// settings 의 분야에 id 가 하나라도 없으면 자동으로 옛 이름 방식으로 강등한다(idMode). 배포 순서가 어긋나도 죽지 않게.
// 이 함수는 데이터베이스를 읽기만 한다. 적용(쓰기)은 브라우저가 사용자 권한(RLS)으로 한다.
//
// 배포:  npx supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
//        npx supabase functions deploy ai
// ============================================================
import Anthropic from "npm:@anthropic-ai/sdk@0.71.0";
import { createClient } from "npm:@supabase/supabase-js@2";

const MODEL = "claude-opus-5";
const MAX_ORGANIZE = 30;      // 한 번에 다시 분류할 항목 수 (브라우저가 이 크기로 나눠 부른다)
const MAX_TAXONOMY_ITEMS = 1500;
const MAX_BODY_BYTES = 32_000;   // 요청 본문 상한
const DAILY_LIMIT = { user: 20, admin: 300 };   // 하루 AI 사용량 (아래 ACTION_COST 로 가중)
// 작업마다 비용이 다르다. 가중치는 실제 토큰 비용을 분류 제안 1회 기준으로 나눈 값이다
// (분류 제안 약 25원, 재분류 30개 묶음 약 219원, 분야 구조 약 169원, 자료 채우기 약 371원 — 2026-09-09 추정).
// 이 값이 틀리면 비싼 작업이 싼 작업인 척하며 한도를 빠져나간다. 실제 사용량은 ask() 가 로그로 남기니
// 한 달쯤 쌓인 뒤 대시보드 로그를 보고 다시 맞추는 것이 좋다.
const ACTION_COST: Record<string, number> = { suggest: 1, organize: 9, taxonomy: 7, expand: 15 };
const MAX_EXPAND = 10;           // 한 번에 제안할 자료 수 상한
const LINK_TIMEOUT_MS = 6000;    // 링크 하나를 기다리는 시간
const LINK_CONCURRENCY = 6;      // 동시에 두드릴 링크 수
// 상대 서버가 우리를 알아보고 막거나 허용할 수 있게 신분을 밝힌다 (헤더 값은 ASCII 만 들어간다)
const LINK_UA = "quickref-linkcheck/1.0 (+https://my-web-imperialpapas-projects.vercel.app)";
// 텍스트 필드 상한 (프롬프트 길이 = 비용이므로 서버에서 자른다)
const CAP = { title: 200, url: 500, lang: 40, body: 1200, category: 60, catId: 64, sub: 60, tag: 40, tags: 10, hint: 30, topic: 80 };
const cut = (v: unknown, n: number) => String(v ?? "").slice(0, n);
const cutArr = (v: unknown, n: number, each: number) =>
  (Array.isArray(v) ? v : []).slice(0, n).map((x) => cut(x, each)).filter(Boolean);
// 프롬프트 안에 넣을 사용자 글은 줄바꿈과 머리글 기호를 없앤다.
// 안 그러면 남이 올린 제목 한 줄로 시스템 프롬프트의 "## 절" 을 위조할 수 있다.
const flat = (v: unknown, n: number) =>
  cut(v, n).replace(/[\r\n\u2028\u2029]+/g, " ").replace(/^[\s#>*\-]+/, "").replace(/\s{2,}/g, " ").trim();
// 태그 모양 맞추기: # 과 공백을 빼고, 영문·숫자만인 태그는 소문자로 (SITE_RULES 와 같은 규칙)
const normTags = (v: unknown) => [...new Set(
  cutArr(v, CAP.tags, CAP.tag)
    .map((t) => t.replace(/^#+/, "").replace(/\s+/g, ""))
    .map((t) => (/^[A-Za-z0-9._+-]+$/.test(t) ? t.toLowerCase() : t))
    .filter(Boolean),
)];

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const fail = (message: string, status = 400) => json({ error: message }, status);

type Cat = { id: string; name: string; subs: string[] };
type Row = {
  id: string; type: string; title: string; url: string; lang: string; body: string;
  category: string; category_id?: string; sub: string; tags: string[];
};

// 분류 규칙의 첫 줄은 모드를 따라가야 한다. 이름 모드(idMode=false)일 때 출력 스키마는
// category(이름)를 요구하는데 프롬프트가 "id 를 돌려준다" 고 시키면 정반대라,
// 모델이 이름 자리에 id 를 적거나 헤매다 엉뚱한 분야를 고른다.
const SITE_RULES = (idMode: boolean) => `당신은 "빠른 연결"이라는 한국어 공유 자료함의 분류 담당 에이전트다.
사람들이 링크·메모·코드·자료를 올리면 분야(category), 하위분야(sub), 태그(tags)로 정리한다.

분류 규칙:
${idMode
  ? `- category_id 는 반드시 아래 "분야 목록"의 대괄호 안에 있는 id 중 하나를 그대로 쓴다. 이름이 아니라 id 를 돌려준다.`
  : `- category 는 반드시 아래 "분야 목록"에 있는 분야 이름 중 하나를 글자 그대로 쓴다. 이름을 새로 지어내지 않는다.`}
- sub 는 그 분야의 기존 하위분야 중 가장 맞는 것을 우선 쓴다. 정말 맞는 것이 없을 때만 새 하위분야를 짧게(2~8자) 제안한다. 여러 단어는 가운뎃점(·)으로 잇는다. 예: "CLI·스크립트".
- tags 는 2~5개. 짧은 명사, 공백과 # 없이. 영어는 소문자(docker, python). 이미 많이 쓰이는 태그가 맞으면 그것을 재사용한다.
- 내용을 지어내지 않는다. URL 과 제목만으로 무엇인지 확실히 알 수 없으면 보수적으로 분류한다.`;

function catsText(cats: Cat[]) {
  // 분야 이름·하위분야도 남이 쓴 글이다. 운영자가 정하지만 AI 가 지은 이름이 taxonomy 적용으로
  // 그대로 저장되는 길이 있어, 시스템 프롬프트에 들어가는 다른 사용자 글과 똑같이 한 줄로 눕힌다.
  // id 는 있을 때만 붙인다. 이름 모드에서는 id 가 비어 있어 그냥 두면 "- [] 이름" 이 나가,
  // "대괄호 안의 id" 를 쓰라는 규칙과 어긋나는 목록을 보여 주게 된다.
  return cats.map((c) => {
    const subs = c.subs.map((s) => flat(s, CAP.sub)).filter(Boolean);
    return `- ${c.id ? `[${c.id}] ` : ""}${flat(c.name, CAP.category)}${subs.length ? ": " + subs.join(", ") : " (하위분야 없음)"}`;
  }).join("\n");
}
function itemText(r: Partial<Row>) {
  const parts = [
    `종류: ${r.type || "link"}`,
    `제목: ${r.title || "(없음)"}`,
    r.url ? `URL: ${r.url}` : "",
    r.lang ? `언어/형식: ${r.lang}` : "",
    r.body ? `내용: ${String(r.body).slice(0, 1200)}` : "",
    r.category ? `현재 분야: ${r.category}${r.sub ? " › " + r.sub : ""}` : "현재 분야: (없음)",
    r.tags && r.tags.length ? `현재 태그: ${r.tags.join(", ")}` : "",
  ];
  return parts.filter(Boolean).join("\n");
}
function topTags(rows: { tags?: string[] }[], n = 40) {
  const c: Record<string, number> = {};
  rows.forEach((r) => (r.tags || []).forEach((t) => (c[t] = (c[t] || 0) + 1)));
  return Object.entries(c).sort((a, b) => b[1] - a[1]).slice(0, n).map(([t]) => t);
}

// ---------- 링크 점검 ----------
// 결과를 세 등급으로만 나눈다. "죽었다" 고 단정해 자동으로 버리지 않는다.
// 멀쩡한 사이트가 자동 접속을 막거나(403) 인증서 문제로 실패하는 경우가 흔하기 때문이다.
type LinkState = "ok" | "dead" | "unknown" | "none";
type LinkCheck = { state: LinkState; status: number; note: string };

// 이 서버가 남의 사내망을 대신 열어 보는 통로가 되면 안 된다.
// 자료의 url 은 로그인한 사람이면 누구나 써 넣을 수 있으므로 두드리기 전에 목적지를 따진다.
// (이름이 부를 때마다 다른 주소로 풀리는 공격까지는 막지 못한다. 이 규모에서 치를 값이 아니다.)
function unsafeTarget(u: URL): string {
  if (!/^https?:$/i.test(u.protocol)) return "웹 주소가 아닙니다";
  if (u.port && u.port !== "80" && u.port !== "443") return "확인하지 않는 포트입니다";
  // 끝점을 붙인 이름(example.com.)도 같은 곳을 가리키므로 떼고 본다
  let h = u.hostname.replace(/^\[|\]$/g, "").toLowerCase().replace(/\.$/, "");
  if (h === "localhost" || /\.(local|internal|localhost)$/.test(h) || /\.home\.arpa$/.test(h)) return "안쪽 망 주소입니다";
  // IPv6 는 같은 주소를 적는 방법이 여러 가지라 위험한 것만 골라 막을 수 없다.
  // ::ffff:7f00:1 처럼 IPv4 를 감싼 것만 되돌려 아래 규칙에 태우고, 나머지 리터럴은 통째로 거절한다.
  if (h.includes(":")) {
    const m6 = h.match(/^::(?:ffff:)?([0-9a-f]{1,4}):([0-9a-f]{1,4})$/);
    if (!m6) return "확인하지 않는 주소입니다";
    const num = parseInt(m6[1], 16) * 65536 + parseInt(m6[2], 16);
    h = [(num >>> 24) & 255, (num >>> 16) & 255, (num >>> 8) & 255, num & 255].join(".");
  }
  const v4 = h.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (v4) {
    const a = Number(v4[1]), b = Number(v4[2]);
    if (a === 0 || a === 10 || a === 127 || a >= 224) return "안쪽 망 주소입니다";
    if (a === 172 && b >= 16 && b <= 31) return "안쪽 망 주소입니다";
    if (a === 192 && b === 168) return "안쪽 망 주소입니다";
    if (a === 169 && b === 254) return "안쪽 망 주소입니다";   // 클라우드 메타데이터
    if (a === 100 && b >= 64 && b <= 127) return "안쪽 망 주소입니다";
  }
  return "";
}

async function checkLink(url: string): Promise<LinkCheck> {
  if (!/^https?:\/\//i.test(url)) return { state: "none", status: 0, note: "" };
  let target: URL;
  try { target = new URL(url); } catch { return { state: "dead", status: 0, note: "주소 형식이 잘못됐습니다" }; }
  // 옮겨 가는 걸음마다 따로 세면 링크 하나가 24초를 쓸 수 있다. 전체 시간에 상한을 둔다.
  const deadline = Date.now() + LINK_TIMEOUT_MS * 2;
  // 옮겨 가는 주소(3xx)는 한 걸음씩 직접 따라간다. redirect:"follow" 로 맡기면
  // 겉보기 멀쩡한 도메인이 안쪽 망 주소로 넘겨도 막을 수 없다.
  for (let hop = 0; hop < 4; hop++) {
    const bad = unsafeTarget(target);
    if (bad) return { state: "unknown", status: 0, note: bad };
    // HEAD 를 막는 사이트가 있어 GET 으로 보내고, 헤더가 오면 본문은 바로 끊는다
    try {
      const left = deadline - Date.now();
      if (left <= 0) return { state: "unknown", status: 0, note: "응답이 없습니다" };
      const res = await fetch(target.toString(), {
        method: "GET", redirect: "manual", signal: AbortSignal.timeout(Math.min(LINK_TIMEOUT_MS, left)),
        headers: { "Accept": "text/html,*/*", "User-Agent": LINK_UA },
      });
      try { await res.body?.cancel(); } catch { /* 본문 취소 실패는 무시 */ }
      if (res.status >= 300 && res.status < 400) {
        const loc = res.headers.get("location");
        if (!loc) return { state: "ok", status: res.status, note: "" };
        try { target = new URL(loc, target); } catch { return { state: "unknown", status: res.status, note: "옮겨 간 주소를 읽지 못했습니다" }; }
        continue;
      }
      if (res.status === 404 || res.status === 410) return { state: "dead", status: res.status, note: "페이지가 없습니다" };
      if (res.ok || res.status < 400) return { state: "ok", status: res.status, note: "" };
      if (res.status === 403 || res.status === 429 || res.status === 405) {
        return { state: "unknown", status: res.status, note: "자동 접속을 막는 사이트입니다" };
      }
      if (res.status >= 500) return { state: "unknown", status: res.status, note: "서버가 응답하지 못했습니다" };
      return { state: "unknown", status: res.status, note: "확인하지 못했습니다" };
    } catch (e) {
      const m = String((e as Error)?.name || "");
      if (m === "TimeoutError") return { state: "unknown", status: 0, note: "응답이 없습니다" };
      // DNS 조회 실패는 주소 자체가 없을 가능성이 높지만, 인증서 오류도 여기로 온다
      const msg = String((e as Error)?.message || "");
      if (/dns error|failed to lookup|name not resolved/i.test(msg)) return { state: "dead", status: 0, note: "없는 주소입니다" };
      return { state: "unknown", status: 0, note: "연결하지 못했습니다" };
    }
  }
  return { state: "unknown", status: 0, note: "옮겨 가는 횟수가 너무 많습니다" };
}

// 여러 링크를 동시에 두드리되 한 번에 너무 많이 열지 않는다
async function checkLinks(urls: string[]): Promise<LinkCheck[]> {
  const out: LinkCheck[] = new Array(urls.length);
  let i = 0;
  const worker = async () => {
    while (i < urls.length) {
      const n = i++;
      out[n] = await checkLink(urls[n]);
    }
  };
  await Promise.all(Array.from({ length: Math.min(LINK_CONCURRENCY, urls.length) }, worker));
  return out;
}

// 중복 판정을 위해 주소를 같은 모양으로 맞춘다 (www, 끝 슬래시, 추적용 파라미터 제거)
function normUrl(u: string): string {
  try {
    const x = new URL(String(u).trim());
    x.hash = "";
    x.hostname = x.hostname.replace(/^www\./i, "").toLowerCase();
    x.protocol = x.protocol.toLowerCase();
    [...x.searchParams.keys()].forEach((k) => { if (/^(utm_|fbclid|gclid|ref$|source$)/i.test(k)) x.searchParams.delete(k); });
    let out = x.toString();
    out = out.replace(/\/$/, "");
    return out;
  } catch { return String(u).trim().toLowerCase().replace(/\/$/, ""); }
}
const normTitle = (t: string) => String(t || "").trim().toLowerCase().replace(/\s+/g, " ");

// 실행하면 되돌릴 수 없는 명령. 좁게 잡는다 — sudo·--force 같은 넓은 낱말은
// 이미 들어 있는 정상 자료(도커 정리, git 되돌리기 등)를 오탐한다.
// 걸렸다고 무조건 막지는 않는다. 코드(snippet)는 그대로 붙여 넣어 실행하는 것이라 막고,
// 메모·링크는 "이 명령은 쓰지 마라" 처럼 설명하는 글이 많아 표시만 하고 운영자가 고르게 둔다.
const DANGER = [
  // rm: 플래그가 어디에 붙든, 지우는 대상이 루트·홈·시스템 디렉터리면 잡는다
  /\brm\s[^\n]*-[a-zA-Z]*[rf][a-zA-Z]*[^\n]*\s(\/(\*|\s|$)|\/(etc|usr|var|bin|boot|home|opt|lib)\b|~\S*|\$HOME\b)/,
  /mkfs(\.|\s)/, /dd\s+[^\n]*of=\/dev\//,
  // 내려받아 그대로 실행: sudo 뒤에 옵션이 끼거나 zsh 로 받는 형태까지
  /(curl|wget)[^\n|]*\|\s*(sudo(\s+-\S+)*\s+)?(ba|z|k|fi|da)?sh\b/,
  /drop\s+(table|database|schema)\s/i, /truncate\s+table\s/i, /delete\s+from\s+\S+\s*;/i,
  // git push: --force, 짧은 플래그 묶음(-uf), refspec 강제(+main)
  /git\s+push[^\n]*(\s--force(?!-with-lease)|\s-[a-zA-Z]*f[a-zA-Z]*(\s|$)|\s\+[A-Za-z0-9_.\/-]+(\s|$))/,
  /:\(\)\s*\{\s*:\|:&\s*\}\s*;:/,
  /chmod\s[^\n]*\b777\b[^\n]*\s\/(\s|$)/, /\b(shutdown|reboot|halt|poweroff)\s+(-f\b|-h\s+now\b|now\b)/i,
];
const dangerHits = (text: string) => DANGER.filter((re) => re.test(text)).map((re) => String(re));

// ---------- Claude 호출 (구조화 출력: 응답이 항상 주어진 JSON 스키마를 따른다) ----------
// call.ok 는 "AI 응답을 끝까지 받았다" 는 표시다. 부르는 쪽이 이걸 보고 하루 사용량을 돌려줄지 정한다.
async function ask(
  client: Anthropic,
  system: string,
  user: string,
  schema: Record<string, unknown>,
  opts: { max_tokens: number; effort: "low" | "medium" | "high"; label: string; timeout_ms: number },
  call: { ok: boolean },
) {
  // 사용자 잘못이 아닌 실패. 던지면 부르는 쪽이 하루 사용량을 돌려준다.
  const ours = (m: string) => Object.assign(new Error(m), { ours: true });
  const t0 = Date.now();
  // claude-opus-5 는 thinking 이 기본으로 켜져 있고 max_tokens 는 (thinking + 응답) 합계 상한이다.
  // 값이 작으면 생각하다가 잘려 stop_reason=max_tokens 로 실패하므로 넉넉히 잡는다.
  //
  // 반드시 스트리밍으로 받는다. max_tokens 가 크면 SDK 가 "10분을 넘길 수 있다" 며
  // 한 번에 받는 요청을 보내기도 전에 거부한다 (자료 채우기의 24000 이 여기에 걸렸다).
  const stream = await client.beta.messages.create({
    model: MODEL,
    max_tokens: opts.max_tokens,
    // 안전 분류기가 요청을 거절하면 서버가 다른 모델로 같은 요청을 다시 시도한다
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    system: [{ type: "text", text: system, cache_control: { type: "ephemeral" } }],
    messages: [{ role: "user", content: user }],
    output_config: { effort: opts.effort, format: { type: "json_schema", schema } },
    stream: true,
    // Supabase 는 응답이 없는 요청을 150초에서 끊는다. 그보다 먼저 우리가 끊어야
    // 아래 catch 가 돌아 하루 사용량이 환불되고, 운영자도 침묵 대신 오류 문구를 받는다.
  }, { timeout: opts.timeout_ms });

  let text = "";
  let stop: string | null = null;
  let done = false;                     // message_stop 을 봤는가
  let tokIn = 0, tokCache = 0, tokOut = 0;
  for await (const ev of stream) {
    const e = ev as {
      type: string;
      delta?: { type?: string; text?: string; stop_reason?: string | null };
      message?: { usage?: { input_tokens?: number; cache_read_input_tokens?: number } };
      usage?: { output_tokens?: number };
    };
    // 생각(thinking_delta)은 버리고 답(text_delta)만 모은다
    if (e.type === "content_block_delta" && e.delta?.type === "text_delta") text += e.delta.text || "";
    else if (e.type === "message_delta") {
      if (e.delta?.stop_reason) stop = e.delta.stop_reason;
      if (e.usage?.output_tokens) tokOut = e.usage.output_tokens;   // 누적값이라 덮어쓴다
    } else if (e.type === "message_start") {
      tokIn = e.message?.usage?.input_tokens || 0;
      tokCache = e.message?.usage?.cache_read_input_tokens || 0;
    } else if (e.type === "message_stop") done = true;
  }

  // 얼마를 썼는지 남긴다. 대시보드 Edge Functions → ai → Logs 에서 볼 수 있다.
  // 이게 없으면 어느 작업이 비싼지 청구서 총액 말고는 알 방법이 없다.
  console.log(JSON.stringify({
    ai: opts.label, model: MODEL, effort: opts.effort,
    in: tokIn, cached: tokCache, out: tokOut, ms: Date.now() - t0, stop: stop || "none",
  }));

  // 끊긴 스트림을 성공으로 오해하면, 반쪽짜리 JSON 을 두고 엉뚱한 오류를 낸다
  if (!done) throw ours("AI 응답이 도중에 끊겼습니다. 잠시 후 다시 시도해 주세요");
  call.ok = true;   // 여기까지 왔으면 응답을 끝까지 받았다

  if (stop === "refusal") throw ours("AI 가 이 요청의 처리를 거절했습니다");
  if (stop === "max_tokens") {
    throw ours(opts.label === "suggest"
      ? "AI 응답이 너무 길어 잘렸습니다. 내용을 조금 줄여 다시 시도해 주세요"
      : "AI 응답이 너무 길어 잘렸습니다. 항목 수를 줄여 다시 시도해 주세요");
  }
  try { return JSON.parse(text); } catch { throw ours("AI 응답을 해석하지 못했습니다"); }
}

const strArr = { type: "array", items: { type: "string" } };
// id 모드면 모델이 id 를 고르게 한다. 구조화 출력의 enum 이 목록 밖의 값을 원천 봉쇄하므로
// "없는 분야" 가 올 수 없고, 나중에 이름을 id 로 옮기다 실패하는 지점도 사라진다.
const classifyProps = (idMode: boolean, catIds: string[], catNames: string[]) => (
  idMode
    ? { category_id: { type: "string", enum: catIds }, sub: { type: "string" }, tags: strArr }
    : { category: { type: "string", enum: catNames }, sub: { type: "string" }, tags: strArr }
);
const classifyKey = (idMode: boolean) => (idMode ? "category_id" : "category");

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return fail("POST 만 받습니다", 405);

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) return fail("서버에 ANTHROPIC_API_KEY 가 설정되지 않았습니다 (README 7단계)", 500);

  // 호출한 사용자 확인: 브라우저가 보낸 로그인 토큰으로 Supabase 에 물어본다
  const auth = req.headers.get("Authorization") || "";
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
  });
  const { data: { user } } = await sb.auth.getUser();
  if (!user) return fail("로그인이 필요합니다", 401);
  const { data: prof } = await sb.from("profiles").select("is_admin").eq("id", user.id).maybeSingle();
  const isAdmin = !!(prof && prof.is_admin);

  let body: { action?: string; item?: Partial<Row>; ids?: string[]; tagsHint?: string[];
    category?: string; topic?: string; count?: number; mix?: string; subs?: string[] };
  let rawBody: string;
  try { rawBody = await req.text(); } catch { return fail("요청을 읽지 못했습니다"); }
  if (rawBody.length > MAX_BODY_BYTES) return fail("요청이 너무 큽니다", 413);
  try { body = JSON.parse(rawBody); } catch { return fail("요청 본문이 JSON 이 아닙니다"); }

  // 하루 사용량 제한. 작업마다 비용이 달라 가중치를 곱해 센다.
  // 차감은 AI 를 실제로 부르기 직전(takeQuota)에 한다. 권한·입력이 틀려 되돌아가는 요청까지
  // 깎으면, 운영자가 아닌 사람이 expand 를 한 번 눌러 보는 것만으로 15회분이 날아간다.
  const action = String(body.action || "");
  const cost = ACTION_COST[action];
  if (cost === undefined) return fail("알 수 없는 action 입니다: " + action);
  if (action !== "suggest" && !isAdmin) return fail("운영자만 쓸 수 있습니다", 403);
  let charged = 0;
  const call = { ok: false };   // ask() 가 응답을 끝까지 받으면 true
  const takeQuota = async (): Promise<Response | null> => {
    const { data: ok, error } = await sb.rpc("ai_take_quota", { lim: isAdmin ? DAILY_LIMIT.admin : DAILY_LIMIT.user, cost });
    if (error) return fail("사용량을 확인하지 못했습니다. schema.sql 을 최신으로 다시 실행했는지 확인해 주세요", 500);
    if (ok === false) return fail("오늘 쓸 수 있는 AI 사용량을 모두 썼습니다. 내일 다시 시도해 주세요", 429);
    charged = cost;
    return null;
  };

  // 분야 목록 (settings.categories)
  // 조회 오류를 버리면 안 된다. 못 읽은 것과 정말로 비어 있는 것은 다른 일인데,
  // 한데 뭉치면 분야가 멀쩡히 있는 운영자에게 "분야를 먼저 만들어 주세요" 가 나가 원인을 짚을 수 없다.
  const { data: setting, error: setErr } = await sb.from("settings").select("value").eq("key", "categories").maybeSingle();
  if (setErr) return fail("분야 목록을 읽지 못했습니다. 잠시 후 다시 시도해 주세요", 500);
  const cats: Cat[] = (((setting?.value as { list?: unknown })?.list as Cat[]) || [])
    .map((c) => ({
      id: cut(c.id, CAP.catId),
      name: String(c.name || ""),
      subs: Array.isArray(c.subs) ? c.subs.map(String) : [],
    }))
    .filter((c) => c.name);
  if (!cats.length) return fail("분야 목록이 비어 있습니다. 운영자가 분야를 먼저 만들어 주세요");
  const catNames = cats.map((c) => c.name);
  const catIds = cats.map((c) => c.id);
  // id 가 하나라도 비었거나 겹치면 이름으로 답하게 되돌린다.
  // 빈 enum 은 무효라서, 이 강등이 없으면 스키마가 깨져 AI 기능 전체가 죽는다.
  const idMode = catIds.every(Boolean) && new Set(catIds).size === catIds.length;
  // 빈 id 를 넣으면 안 된다. 키 "" 하나에 마지막 분야만 남아, get("") 이 그것을 돌려준다.
  const catById = new Map(cats.filter((c) => c.id).map((c) => [c.id, c]));
  const catByName = new Map(cats.map((c) => [c.name, c]));
  // 분류 결과를 {categoryId, category} 한 쌍으로 정규화한다. 화면은 둘 다 받는다.
  const pickCat = (out: { category_id?: string; category?: string }) => {
    const c = idMode ? catById.get(String(out.category_id || "")) : catByName.get(String(out.category || ""));
    return { categoryId: c ? c.id : "", category: c ? c.name : "", cat: c };
  };
  const client = new Anthropic({ apiKey });

  try {
    // ---------- 1) 항목 하나 분류 제안 ----------
    if (action === "suggest") {
      const src = body.item || {};
      // 프롬프트에 들어갈 값은 전부 서버에서 자른다 (길이 = 비용)
      const srcCatId = cut((src as { categoryId?: string }).categoryId, CAP.catId);
      const it: Partial<Row> = {
        type: cut(src.type, 20), title: cut(src.title, CAP.title), url: cut(src.url, CAP.url),
        lang: cut(src.lang, CAP.lang), body: cut(src.body, CAP.body),
        // 화면이 categoryId 를 보내면 그것으로 이름을 찾는다. 이름만 오면 이름을 그대로 쓴다(옛 화면).
        // 빈 id 로는 조회하지 않는다. 조회하면 "현재 분야" 가 엉뚱한 분야로 바뀌어 프롬프트에 실린다.
        category: (srcCatId && catById.get(srcCatId)?.name) || cut(src.category, CAP.category),
        sub: cut(src.sub, CAP.sub),
        tags: cutArr(src.tags, CAP.tags, CAP.tag),
      };
      if (!(it.title || it.url || it.body)) return fail("제목, 주소, 내용 중 하나는 있어야 합니다");
      const system = `${SITE_RULES(idMode)}

분야 목록:
${catsText(cats)}

자주 쓰는 태그: ${cutArr(body.tagsHint, 40, CAP.hint).join(", ") || "(아직 없음)"}

추가 규칙:
- title: 제목이 비어 있거나 도메인 이름(example.com)뿐이면 한눈에 알아볼 짧은 한국어 제목을 제안한다. 이미 괜찮은 제목이면 그대로 돌려준다.
- body: 링크인데 설명이 비어 있고, 그 서비스·문서가 무엇인지 확실히 알 때만 한 줄(40자 이내) 설명을 쓴다. 모르면 빈 문자열.
- reason: 왜 그렇게 분류했는지 30자 이내.`;
      const schema = {
        type: "object",
        properties: { ...classifyProps(idMode, catIds, catNames), title: { type: "string" }, body: { type: "string" }, reason: { type: "string" } },
        required: [classifyKey(idMode), "sub", "tags", "title", "body", "reason"],
        additionalProperties: false,
      };
      const gate = await takeQuota(); if (gate) return gate;
      const out = await ask(client, system, `다음 항목을 분류해 주세요.\n\n${itemText(it)}`, schema, { max_tokens: 8000, effort: "low", label: "suggest", timeout_ms: 60_000 }, call);
      // 화면에는 id 와 이름을 함께 준다. 옛 화면은 이름만 읽고, 새 화면은 id 로 잇는다.
      const got = pickCat(out);
      return json({
        ...out, categoryId: got.categoryId, category: got.category,
        newSub: !!(got.cat && out.sub && !got.cat.subs.includes(out.sub)),
      });
    }

    // ---------- 2) 여러 항목 다시 분류 (운영자) ----------
    if (action === "organize") {
      const ids = (Array.isArray(body.ids) ? body.ids : []).map(String).filter((x) => /^[A-Za-z0-9_-]{1,64}$/.test(x)).slice(0, MAX_ORGANIZE);
      if (!ids.length) return fail("다시 분류할 항목 id 가 없습니다");
      const [rowsRes, allRes] = await Promise.all([
        sb.from("items").select("id,type,title,url,lang,body,category,category_id,sub,tags").in("id", ids),
        sb.from("items").select("tags").limit(5000),
      ]);
      // 오류를 버리면 안 된다. category_id 컬럼이 아직 없으면 data 가 null 로 와서
      // "항목을 찾지 못했습니다" 가 나가고, 항목이 멀쩡히 보이는 운영자는 원인을 짐작할 수 없다.
      if (rowsRes.error || allRes.error) {
        return fail("자료를 읽지 못했습니다. schema.sql 을 최신으로 다시 실행했는지 확인해 주세요", 500);
      }
      const rows = rowsRes.data, allRows = allRes.data;
      if (!rows || !rows.length) return fail("항목을 찾지 못했습니다", 422);   // 404 는 브라우저가 '함수 미배포' 로 오해한다
      const system = `${SITE_RULES(idMode)}

분야 목록:
${catsText(cats)}

자주 쓰는 태그: ${topTags(allRows || []).join(", ") || "(아직 없음)"}

추가 규칙:
- 항목마다 하나의 proposal 을 낸다. id 는 주어진 그대로.
- 지금 분류가 이미 적절하면 그대로 두고 changed=false 로 표시한다. 분명히 더 나은 자리가 있을 때만 바꾼다(changed=true).
- 태그는 기존 태그를 최대한 유지하고, 빠진 핵심 태그를 더하거나 명백히 틀린 태그만 뺀다.
- reason 은 30자 이내. changed=false 면 빈 문자열.`;
      const schema = {
        type: "object",
        properties: {
          proposals: {
            type: "array",
            items: {
              type: "object",
              properties: { id: { type: "string" }, ...classifyProps(idMode, catIds, catNames), changed: { type: "boolean" }, reason: { type: "string" } },
              required: ["id", classifyKey(idMode), "sub", "tags", "changed", "reason"],
              additionalProperties: false,
            },
          },
        },
        required: ["proposals"],
        additionalProperties: false,
      };
      const user = `다음 ${rows.length}개 항목을 검토해 주세요.\n\n` +
        rows.map((r: Row, i: number) => `[${i + 1}] id=${r.id}\n${itemText(r)}`).join("\n\n");
      // 분류 제안과 함께 링크가 살아 있는지도 확인한다. AI 와 무관한 일이라 나란히 돌린다.
      // (뒤에 직렬로 붙이면 30초를 더 기다리고, 링크 점검이 터질 때 이미 값을 치른 AI 결과까지 날아간다.)
      const linkRows = rows.filter((r: Row) => /^https?:\/\//i.test(r.url || ""));
      const gate = await takeQuota(); if (gate) return gate;
      const [out, checks] = await Promise.all([
        ask(client, system, user, schema, { max_tokens: 16000, effort: "low", label: "organize", timeout_ms: 110_000 }, call),
        checkLinks(linkRows.map((r: Row) => r.url)).catch(() => [] as LinkCheck[]),
      ]);
      const linkBy = new Map<string, LinkCheck>(
        linkRows.map((r: Row, i: number) => [r.id, checks[i]] as [string, LinkCheck]).filter((e) => !!e[1]),
      );
      const byId = new Map<string, Row>(rows.map((r: Row) => [r.id, r]));
      const proposals = (out.proposals || [])
        .filter((p: { id: string }) => byId.has(p.id))
        .map((p: Row & { category_id?: string; changed: boolean; reason: string }) => {
          const cur = byId.get(p.id)!;
          const got = pickCat(p);
          // 같은 분야인지는 id 로 본다. 이름으로 비교하면 과도기에 30개가 전부 "바뀜" 으로 뜨고,
          // 운영자가 그대로 적용하면 필요 없는 대량 쓰기가 된다.
          const sameCat = idMode ? (cur.category_id || "") === got.categoryId : cur.category === got.category;
          const same = sameCat && (cur.sub || "") === (p.sub || "") &&
            JSON.stringify((cur.tags || []).slice().sort()) === JSON.stringify((p.tags || []).slice().sort());
          const link = linkBy.get(p.id) || { state: "none" as LinkState, status: 0, note: "" };
          return {
            ...p, categoryId: got.categoryId, category: got.category,
            changed: p.changed && !same,
            newSub: !!(got.cat && p.sub && !got.cat.subs.includes(p.sub)), link,
          };
        });
      // 실제로 판단이 돌아온 항목의 id 만 돌려준다. 브라우저가 이걸로 checked_at 을 찍는다.
      // 고칠 게 없다고 한 항목도 "봤다" 고 남기되, 모델이 응답에서 빠뜨린 항목까지 찍으면
      // 한 번도 검토되지 않은 자료가 조용히 "확인함" 이 되어 다음 차례에서 빠진다.
      return json({ proposals, checkedIds: proposals.map((p: { id: string }) => p.id) });
    }

    // ---------- 3) 분야 구조 개편안 (운영자) ----------
    if (action === "taxonomy") {
      const { data: rows } = await sb.from("items").select("type,title,category,sub,tags").order("created_at", { ascending: false }).limit(MAX_TAXONOMY_ITEMS);
      const list = (rows || []) as Pick<Row, "type" | "title" | "category" | "sub" | "tags">[];
      const system = `${SITE_RULES(idMode)}

당신의 일: 현재 분야 구조와 전체 자료 목록을 보고, 더 찾기 쉬운 분야·하위분야 구조를 제안한다.

원칙:
${idMode
  ? `- 분야 이름은 자유롭게 바꿔도 된다. 자료와 담당자는 이름이 아니라 id 로 이어져 있어 개명을 따라온다.
- 대신 비싼 것은 **삭제와 병합**이다. 자료가 든 분야를 없애려면 그 자료를 먼저 다른 분야로 옮겨야 한다. 꼭 필요하면 notes 에 "○○ 를 없애려면 자료 N개를 △△ 로 옮겨야 함" 처럼 적는다.
- 기존 분야는 id 를 그대로 돌려준다. 새로 만들자는 분야만 id 를 빈 문자열("")로 둔다. id 를 지어내지 마라.
- 한 분야를 둘로 나눌 때는 **자료가 더 많이 남는 쪽**에 기존 id 를 주고, 새로 갈라져 나오는 쪽은 id 를 빈 문자열("")로 둔다. id 가 붙은 줄의 이름을 바꾸면 그 분야에 든 자료 전부의 분야 표기가 따라 바뀌기 때문이다.
- 같은 id 를 두 줄에 쓰지 않는다. 한 id 는 한 줄에만.`
  : `- 기존 분야 이름은 그대로 둔다. 지금은 이름이 자료를 잇는 키라서, 이름을 바꾸면 이미 올라간 자료의 분야 표기가 어긋난다. 꼭 바꿔야 하면 notes 에만 적는다.
- 자료가 든 분야를 없애려면 그 자료를 먼저 다른 분야로 옮겨야 한다. 꼭 필요하면 notes 에 "○○ 를 없애려면 자료 N개를 △△ 로 옮겨야 함" 처럼 적는다.
- id 는 전부 빈 문자열("")로 둔다.`}
- 하위분야는 항목이 실제로 모이는 곳에만 둔다. 자료가 3개 이상 몰리는데 하위분야가 없으면 새로 만들고, 항목이 하나도 없고 앞으로도 쓰일 것 같지 않은 하위분야는 뺀다.
- 분야당 하위분야 3~7개가 적당하다. 이름은 2~8자, 여러 단어는 가운뎃점(·)으로.
- notes 에는 바꾼 이유를 한 줄씩(각 60자 이내) 쓴다. 바꿀 것이 없으면 그렇게 적는다.`;
      const user = `현재 분야 구조:\n${catsText(cats)}\n\n전체 자료 ${list.length}개 (종류 | 제목 | 분야 › 하위분야 | 태그):\n` +
        // 이 표는 한 줄이 자료 하나다. 제목·태그·분야 이름·하위분야 어디든 줄바꿈이 있으면
        // 없는 자료가 몇 줄 더 생긴 것처럼 보인다. 제목은 로그인한 누구나 넣을 수 있는 값이라 특히 그렇다.
        // 위의 "현재 분야 구조" 도 catsText 가 눕혀서 넣으므로 여기서도 같은 모양으로 맞춰야 두 목록이 서로 맞는다.
        list.map((r) => `${r.type} | ${flat(r.title, 60)} | ${flat(r.category, CAP.category) || "-"}${r.sub ? " › " + flat(r.sub, CAP.sub) : ""} | ${(r.tags || []).map((t) => flat(t, CAP.tag)).filter(Boolean).join(",")}`).join("\n");
      const schema = {
        type: "object",
        properties: {
          list: {
            type: "array",
            items: {
              type: "object",
              // 기존 분야면 그 id, 새로 만들자는 분야면 "". 모델이 id 를 발급하지 못하게 enum 으로 가둔다.
              properties: { id: { type: "string", enum: [...catIds.filter(Boolean), ""] }, name: { type: "string" }, subs: strArr },
              required: ["id", "name", "subs"],
              additionalProperties: false,
            },
          },
          notes: strArr,
        },
        required: ["list", "notes"],
        additionalProperties: false,
      };
      const gate = await takeQuota(); if (gate) return gate;
      const out = await ask(client, system, user, schema, { max_tokens: 16000, effort: "medium", label: "taxonomy", timeout_ms: 100_000 }, call);
      // id 가 정본이 된 뒤로, id 가 붙은 줄의 이름을 바꾸는 것은 그 분야에 든 자료 전부의
      // 표시 이름을 바꾸는 일이다. 스키마의 enum 은 "목록 밖 id" 만 막을 뿐 어느 id 가 어느 이름에
      // 붙었는지는 보지 않는다. 모델이 분야를 쪼개며 같은 id 를 양쪽에 붙이기만 해도
      // 자료 수십 개가 오류 하나 없이 남의 이름 밑으로 들어가므로, 서버가 한 번 훑어 막는다.
      const usedIds = new Set<string>();
      const outList = (Array.isArray(out.list) ? out.list : []).map((row: { id?: string; name?: string; subs?: string[] }) => {
        // 이름은 여기서 길이만 자른다. flat() 으로 다듬지는 않는다 — 운영자가 고칠 제안 문구를
        // 서버가 말없이 바꾸는 것이 되고, 아래 개명 판정(now !== name)도 흔들린다.
        // 자르지 않으면 60자를 넘는 이름이 화면을 지나 저장할 때 트리거에 걸린다.
        const name = cut(row?.name, CAP.category);
        let id = cut(row?.id, CAP.catId).trim();
        // 목록에 없는 id 와 앞줄이 이미 가져간 id 는 새 분야로 강등한다(id 를 "" 로).
        // 강등된 줄은 화면에서 새로 만드는 분야가 되므로 남의 자료를 끌고 가지 않는다.
        if (id && (!catById.has(id) || usedIds.has(id))) id = "";
        if (id) usedIds.add(id);
        // id→지금 이름 대응은 서버만 확실히 안다. 화면이 "개명: A → B · 자료 N개가 따라갑니다" 를
        // 보여 줄 수 있게 지금 이름을 실어 준다. 이름이 그대로거나 새 분야면 빈 문자열.
        const now = id ? (catById.get(id)?.name || "") : "";
        return { ...row, id, name, renamedFrom: now && now !== name ? now : "" };
      });
      return json({ list: outList, notes: out.notes || [], itemCount: list.length });
    }

    // ---------- 4) 분야에 자료 제안 (운영자) ----------
    if (action === "expand") {
      // 기존 분야는 id 로 받는다. 이름으로 흐릿하게 맞춰 보던 코드는 없앴다 — 정체성은 id 가 정한다.
      // 새 분야를 만들 때만 이름을 받는다.
      const wantId = cut((body as { categoryId?: string }).categoryId, CAP.catId).trim();
      // 이름으로 맞춰 볼 때는 양쪽을 똑같이 눕혀서 본다. 들어온 이름만 flat() 을 거치면
      // 저장된 이름에 이중 공백·머리 기호가 하나만 있어도 못 알아보고 "새 분야" 가 되어,
      // 이미 있는 자료를 중복 검사 없이 그대로 다시 제안하고 화면은 중복 이름을 만들려 든다.
      const wantName = flat(body.category, CAP.category);
      const match = wantId
        ? catById.get(wantId)
        : (wantName ? cats.find((c) => flat(c.name, CAP.category) === wantName) : undefined);
      const newName = flat((body as { newCategoryName?: string }).newCategoryName ?? body.category, CAP.category).trim();
      if (!match && !newName) return fail("분야를 골라 주세요");
      const catId = match ? match.id : "";
      const catName = match ? match.name : newName;
      const isNew = !match;
      const topic = flat(body.topic, CAP.topic);
      const want = Math.min(Math.max(Math.floor(Number(body.count)) || MAX_EXPAND, 3), MAX_EXPAND);
      const mix = ["link", "even", "text"].includes(String(body.mix)) ? String(body.mix) : "even";
      const subs = (match ? match.subs : cutArr(body.subs, 12, CAP.sub)).map((x) => flat(x, CAP.sub)).filter(Boolean);

      // 이미 있는 자료를 알려 줘야 같은 것을 또 제안하지 않는다.
      // 자료가 늘어도 프롬프트가 커지지 않도록 세 가지만 넣는다: 그 분야 전체, 자주 쓰는 태그, 전체 호스트 목록.
      // "새 분야" 와 "기존 분야인데 아직 id 를 못 이었다" 는 다른 상태다. 뒤엣것을 빈 목록으로
      // 다루면 프롬프트가 "이 분야에는 자료가 없다" 고 거짓말하고, 제목 기준 중복 검사가 통째로 죽는다.
      const [sameCatRes, allRes] = await Promise.all([
        isNew
          ? Promise.resolve({ data: [], error: null })
          : (catId
              ? sb.from("items").select("type,title,url").eq("category_id", catId).limit(400)
              : sb.from("items").select("type,title,url").eq("category", catName).limit(400)),
        sb.from("items").select("url,tags").limit(2000),
      ]);
      // 오류를 버리면 안 된다. 컬럼이 아직 없을 때 data 가 null 로 와서
      // "이 분야에는 아직 자료가 없다" 고 말한 뒤 이미 있는 것을 그대로 다시 제안하게 된다.
      if (sameCatRes.error || allRes.error) {
        return fail("자료를 읽지 못했습니다. schema.sql 을 최신으로 다시 실행했는지 확인해 주세요", 500);
      }
      const sameCat = sameCatRes.data, allRows = allRes.data;
      const host = (u: string) => { try { return new URL(u).hostname.replace(/^www\./, ""); } catch { return ""; } };
      // 아래 목록은 전부 남이 써 넣은 글이다. 시스템 프롬프트에 들어가므로 한 줄로 눕혀서 넣는다.
      const hosts = [...new Set((allRows || []).map((r: { url?: string }) => host(r.url || "")).filter(Boolean))];
      const existing = (sameCat || []) as { type: string; title: string; url: string }[];

      // 종류 배합. 기존 자료가 링크 위주라 그 결을 따르되, 운영자가 고를 수 있게 한다.
      // 반올림하면 합이 want 와 어긋나(예: 10분의 7·2·1 을 3개로 줄이면 2+1+1=4) 프롬프트가 스스로 모순된다.
      // 내림한 뒤 남는 자리를 소수부가 큰 종류에 하나씩 준다.
      const MIX: Record<string, { link: number; note: number; snippet: number }> =
        { link: { link: 7, note: 2, snippet: 1 }, even: { link: 6, note: 2, snippet: 2 }, text: { link: 4, note: 3, snippet: 3 } };
      const base = MIX[mix];
      const kinds = ["link", "note", "snippet"] as const;
      const exact = kinds.map((k) => (base[k] * want) / 10);
      const plan = { link: 0, note: 0, snippet: 0 } as Record<string, number>;
      kinds.forEach((k, i) => (plan[k] = Math.floor(exact[i])));
      let left = want - kinds.reduce((a, k) => a + plan[k], 0);
      kinds.map((k, i) => ({ k, frac: exact[i] - Math.floor(exact[i]) }))
        .sort((a, b) => b.frac - a.frac)
        .forEach((x) => { if (left > 0) { plan[x.k]++; left--; } });

      const system = `${SITE_RULES(idMode)}

분야 목록:
${catsText(cats)}${isNew ? `\n- ${catName} (이번에 새로 만드는 분야)` : ""}

당신의 일: "${catName}" 분야에 넣을 자료 ${want}개를 제안한다.${topic ? `\n운영자가 준 주제 힌트: ${topic}` : ""}
${subs.length ? `이 분야의 하위분야: ${subs.join(", ")}` : "이 분야에는 아직 하위분야가 없다. 필요하면 짧게 제안한다."}

## 종류와 개수
- link ${plan.link}개, note ${plan.note}개, snippet ${plan.snippet}개. 합계 ${want}개를 정확히 지킨다.
- link: 외부 사이트. url 필수, body 는 왜 쓸모 있는지 한 줄(40~90자).
- note: 정리 메모. url 없음. body 는 번호 붙인 항목 5~8개, 200~300자.
- snippet: 코드. url 없음. lang 에 언어(bash, python, sql 등). body 는 8줄 이내, 각 줄에 한국어 주석.

## link 규칙 — 지어낸 주소는 절대 안 된다
- **확실히 아는 사이트의 도메인 최상단 주소만 쓴다.** 예: https://excalidraw.com
- 하위 경로(/docs/guide/intro 같은 깊은 주소)는 **확신이 없으면 쓰지 마라.** 경로가 바뀌어 사라지는 일이 흔하다.
- 주소가 확실하지 않으면 그 항목을 link 대신 **note 로 바꿔서** 낸다.
- 접속을 확인할 수 없는 사이트, 로그인이 필요한 곳, 광고성 사이트는 넣지 않는다.

## note·snippet 규칙 — 확인할 방법이 없으므로 더 조심한다
- snippet 은 널리 쓰이는 표준 명령만. 버전이나 배포판에 따라 달라지는 것은 쓰지 않는다.
- 되돌릴 수 없는 명령(파일 삭제, 디스크 포맷, 원격 강제 덮어쓰기)은 절대 넣지 않는다.
- note 에 연도·수치·고유명사는 확실할 때만 쓴다. 애매하면 그 문장을 빼라.
- 코드가 정확한지 확신이 없으면 snippet 대신 note 로 낸다.

## 게시 기준
정치·종교 풍자, 특정 인물이나 회사 조롱, 성적·폭력적 표현은 넣지 않는다. 애매하면 넣지 않는다.

## 이미 있는 자료 (같은 것을 또 내지 마라)
${existing.length ? existing.map((r) => `- [${flat(r.type, 12)}] ${flat(r.title, 60)}${r.url ? " (" + host(r.url) + ")" : ""}`).join("\n") : "(이 분야에는 아직 자료가 없다)"}

## 자료함 전체에 이미 있는 사이트 (이 호스트는 피한다)
${hosts.slice(0, 120).join(", ") || "(없음)"}

## 자주 쓰는 태그 (맞으면 재사용한다)
${topTags(allRows || []).map((t) => flat(t, CAP.tag)).filter(Boolean).join(", ") || "(아직 없음)"}

각 항목의 reason 에는 왜 이 분야에 필요한지 30자 이내로 쓴다.`;

      const schema = {
        type: "object",
        properties: {
          items: {
            type: "array",
            items: {
              type: "object",
              properties: {
                type: { type: "string", enum: ["link", "note", "snippet"] },
                title: { type: "string" },
                url: { type: "string" },
                lang: { type: "string" },
                body: { type: "string" },
                sub: { type: "string" },
                tags: strArr,
                reason: { type: "string" },
              },
              required: ["type", "title", "url", "lang", "body", "sub", "tags", "reason"],
              additionalProperties: false,
            },
          },
        },
        required: ["items"],
        additionalProperties: false,
      };

      const gate = await takeQuota(); if (gate) return gate;
      const out = await ask(client, system, `"${catName}" 분야에 넣을 자료 ${want}개를 제안해 주세요.`, schema,
        { max_tokens: 24000, effort: "medium", label: "expand", timeout_ms: 100_000 }, call);

      // ----- 서버 검증. 모델 말을 그대로 믿지 않는다 -----
      const raw = (out.items || []).slice(0, want);
      let items = raw.map((r: Record<string, unknown>) => ({
        type: ["link", "note", "snippet"].includes(String(r.type)) ? String(r.type) : "note",
        title: cut(r.title, CAP.title).trim(),
        url: cut(r.url, CAP.url).trim(),
        lang: cut(r.lang, CAP.lang).trim(),
        body: cut(r.body, 4000).trim(),
        sub: cut(r.sub, CAP.sub).replace(/[:：,，\n]/g, " ").trim(),   // 분야 편집 형식을 깨뜨리지 않게
        tags: normTags(r.tags),
        reason: cut(r.reason, 120).trim(),
      })).filter((r: { title: string }) => r.title);

      // 종류별로 있어야 할 것과 없어야 할 것을 정리한다.
      // 주소 없는 link, 내용 없는 메모·코드는 화면에서 고를 수 없는 항목이 되므로 여기서 뺀다.
      items = items.filter((r: { type: string; url: string; body: string }) =>
        !(r.type === "link" && !/^https?:\/\//i.test(r.url)) && !(r.type !== "link" && !r.body));
      items.forEach((r: { type: string; url: string; lang: string }) => {
        if (r.type !== "link") r.url = "";          // 메모·코드는 주소가 없다
        if (r.type !== "snippet") r.lang = "";
      });
      const dropped = raw.length - items.length;    // 버린 개수를 화면이 설명할 수 있게 알려 준다

      // 링크가 실제로 열리는지 확인한다
      const linkIdx = items.map((r: { type: string }, i: number) => (r.type === "link" ? i : -1)).filter((i: number) => i >= 0);
      const results = await checkLinks(linkIdx.map((i: number) => items[i].url)).catch(() => [] as LinkCheck[]);
      const checkOf = new Map<number, LinkCheck>(
        linkIdx.map((i: number, n: number) => [i, results[n]] as [number, LinkCheck]).filter((e) => !!e[1]),
      );

      // 이미 있는 자료와 겹치는지 본다
      const seenUrl = new Map<string, string>();
      const seenTitle = new Map<string, string>();
      (allRows || []).forEach((r: { url?: string }) => { if (r.url) seenUrl.set(normUrl(r.url), "1"); });
      existing.forEach((r) => { seenTitle.set(normTitle(r.title), r.title); if (r.url) seenUrl.set(normUrl(r.url), r.title); });

      // 위 표본(limit)은 자료가 늘면 잘린다. 제안된 주소만 따로 한 번 더 조회해 확실히 본다.
      const askUrls = items.map((r: { url: string }) => r.url).filter(Boolean).slice(0, 50);
      if (askUrls.length) {
        const { data: hitRows } = await sb.from("items").select("url").in("url", askUrls);
        (hitRows || []).forEach((r: { url?: string }) => { if (r.url) seenUrl.set(normUrl(r.url), "1"); });
      }

      const withinBatch = new Set<string>();
      const finalItems = items.map((r: Record<string, string> & { tags: string[] }, i: number) => {
        const link = checkOf.get(i) || { state: "none" as LinkState, status: 0, note: "" };
        const key = r.url ? normUrl(r.url) : "t:" + normTitle(r.title);
        let dup = "none";
        if (withinBatch.has(key) || withinBatch.has("t:" + normTitle(r.title))) dup = "batch";
        else if (r.url && seenUrl.has(normUrl(r.url))) dup = "url";
        else if (seenTitle.has(normTitle(r.title))) dup = "title";
        withinBatch.add(key);
        withinBatch.add("t:" + normTitle(r.title));   // 주소가 달라도 제목이 같으면 같은 것으로 본다
        const hits = dangerHits(r.body + "\n" + r.title);
        const risk = hits.length ? (r.type === "snippet" ? "block" : "warn") : "none";
        return { ...r, link, dup, risk };
      });

      const got = { link: 0, note: 0, snippet: 0 } as Record<string, number>;
      finalItems.forEach((r: { type: string }) => { got[r.type] = (got[r.type] || 0) + 1; });
      return json({ categoryId: catId, category: catName, isNew, items: finalItems, mixWanted: plan, mixGot: got, count: finalItems.length, want, dropped });
    }

    return fail("알 수 없는 action 입니다: " + String(body.action || ""));
  } catch (e) {
    // 하루 사용량을 돌려주는 경우는 둘이다.
    //   ① AI 응답을 끝까지 받지 못했다 (키·연결·서버, SDK 가 아예 안 보낸 경우 포함) → 값을 치르지 않았다
    //   ② 받긴 했는데 쓸 수 없었다 (거절·응답 잘림·해석 실패) → 사용자 잘못이 아니다
    // 받고 난 뒤 우리 코드가 터진 경우만 돌려주지 않는다. 요금은 이미 나갔고, 그건 고쳐야 할 버그다.
    const refundable = !call.ok || !!(e as { ours?: boolean })?.ours;
    if (charged && refundable) { try { await sb.rpc("ai_refund_quota", { cost: charged }); } catch { /* 환불 실패는 무시 */ } }

    if (e instanceof Anthropic.AuthenticationError) {
      return fail("AI 키가 만료되었거나 올바르지 않습니다. 운영자에게 알려 주세요 (README 7단계)", 500);
    }
    if (e instanceof Anthropic.RateLimitError) return fail("AI 호출이 몰리고 있습니다. 잠시 후 다시 시도해 주세요", 429);
    if (e instanceof Anthropic.APIConnectionError) return fail("AI 서버에 연결하지 못했습니다. 잠시 후 다시 시도해 주세요", 504);
    if (e instanceof Anthropic.APIError) return fail(`AI 서비스 오류 (${e.status ?? "연결"}): ${e.message}`, 502);
    return fail((e as Error).message || "알 수 없는 오류", 500);
  }
});
