// ============================================================
// 빠른 연결 AI 에이전트 (Supabase Edge Function)
// ------------------------------------------------------------
// 브라우저는 API 키를 가질 수 없으므로, AI 호출은 모두 이 함수가 대신한다.
//   suggest  : 새 항목 하나의 분야·하위분야·태그(·제목·설명) 제안   — 로그인 사용자
//   organize : 여러 항목(최대 30개)을 다시 분류해 바꿀 것만 제안     — 운영자
//   taxonomy : 전체 자료를 보고 분야·하위분야 구조 개편안 제안        — 운영자
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
const DAILY_LIMIT = { user: 40, admin: 600 };   // 하루 AI 호출 횟수 (organize 는 배치 1건 = 1회)
// 텍스트 필드 상한 (프롬프트 길이 = 비용이므로 서버에서 자른다)
const CAP = { title: 200, url: 500, lang: 40, body: 1200, category: 60, sub: 60, tag: 40, tags: 10, hint: 30 };
const cut = (v: unknown, n: number) => String(v ?? "").slice(0, n);
const cutArr = (v: unknown, n: number, each: number) =>
  (Array.isArray(v) ? v : []).slice(0, n).map((x) => cut(x, each)).filter(Boolean);

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const fail = (message: string, status = 400) => json({ error: message }, status);

type Cat = { name: string; subs: string[] };
type Row = {
  id: string; type: string; title: string; url: string; lang: string; body: string;
  category: string; sub: string; tags: string[];
};

const SITE_RULES = `당신은 "빠른 연결"이라는 한국어 공유 자료함의 분류 담당 에이전트다.
사람들이 링크·메모·코드·자료를 올리면 분야(category), 하위분야(sub), 태그(tags)로 정리한다.

분류 규칙:
- category 는 반드시 아래 "분야 목록"에 있는 이름 중 하나를 그대로 쓴다.
- sub 는 그 분야의 기존 하위분야 중 가장 맞는 것을 우선 쓴다. 정말 맞는 것이 없을 때만 새 하위분야를 짧게(2~8자) 제안한다. 여러 단어는 가운뎃점(·)으로 잇는다. 예: "CLI·스크립트".
- tags 는 2~5개. 짧은 명사, 공백과 # 없이. 영어는 소문자(docker, python). 이미 많이 쓰이는 태그가 맞으면 그것을 재사용한다.
- 내용을 지어내지 않는다. URL 과 제목만으로 무엇인지 확실히 알 수 없으면 보수적으로 분류한다.`;

function catsText(cats: Cat[]) {
  return cats.map((c) => `- ${c.name}${c.subs.length ? ": " + c.subs.join(", ") : " (하위분야 없음)"}`).join("\n");
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

// ---------- Claude 호출 (구조화 출력: 응답이 항상 주어진 JSON 스키마를 따른다) ----------
async function ask(
  client: Anthropic,
  system: string,
  user: string,
  schema: Record<string, unknown>,
  opts: { max_tokens: number; effort: "low" | "medium" | "high" },
) {
  // claude-opus-5 는 thinking 이 기본으로 켜져 있고 max_tokens 는 (thinking + 응답) 합계 상한이다.
  // 값이 작으면 생각하다가 잘려 stop_reason=max_tokens 로 실패하므로 넉넉히 잡는다.
  const res = await client.beta.messages.create({
    model: MODEL,
    max_tokens: opts.max_tokens,
    // 안전 분류기가 요청을 거절하면 서버가 다른 모델로 같은 요청을 다시 시도한다
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    system: [{ type: "text", text: system, cache_control: { type: "ephemeral" } }],
    messages: [{ role: "user", content: user }],
    output_config: { effort: opts.effort, format: { type: "json_schema", schema } },
  });
  if (res.stop_reason === "refusal") throw new Error("AI 가 이 요청의 처리를 거절했습니다");
  if (res.stop_reason === "max_tokens") throw new Error("AI 응답이 너무 길어 잘렸습니다. 항목 수를 줄여 다시 시도해 주세요");
  const text = res.content.filter((b) => b.type === "text").map((b) => (b as { text: string }).text).join("");
  try { return JSON.parse(text); } catch { throw new Error("AI 응답을 해석하지 못했습니다"); }
}

const strArr = { type: "array", items: { type: "string" } };
const classifyProps = (catNames: string[]) => ({
  category: { type: "string", enum: catNames },
  sub: { type: "string" },
  tags: strArr,
});

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

  let body: { action?: string; item?: Partial<Row>; ids?: string[]; tagsHint?: string[] };
  let rawBody: string;
  try { rawBody = await req.text(); } catch { return fail("요청을 읽지 못했습니다"); }
  if (rawBody.length > MAX_BODY_BYTES) return fail("요청이 너무 큽니다", 413);
  try { body = JSON.parse(rawBody); } catch { return fail("요청 본문이 JSON 이 아닙니다"); }

  // 하루 호출 횟수 제한 (로그인만 하면 누구나 부를 수 있으므로 비용 방어선이 필요하다)
  const { data: quotaOk, error: quotaErr } = await sb.rpc("ai_take_quota", { lim: isAdmin ? DAILY_LIMIT.admin : DAILY_LIMIT.user });
  if (quotaErr) return fail("사용량을 확인하지 못했습니다. schema.sql 의 ai_usage 부분을 실행했는지 확인해 주세요", 500);
  if (quotaOk === false) return fail("오늘 쓸 수 있는 AI 횟수를 모두 썼습니다. 내일 다시 시도해 주세요", 429);

  // 분야 목록 (settings.categories)
  const { data: setting } = await sb.from("settings").select("value").eq("key", "categories").maybeSingle();
  const cats: Cat[] = (((setting?.value as { list?: unknown })?.list as Cat[]) || [])
    .map((c) => ({ name: String(c.name || ""), subs: Array.isArray(c.subs) ? c.subs.map(String) : [] }))
    .filter((c) => c.name);
  if (!cats.length) return fail("분야 목록이 비어 있습니다. 운영자가 분야를 먼저 만들어 주세요");
  const catNames = cats.map((c) => c.name);
  const client = new Anthropic({ apiKey });

  try {
    // ---------- 1) 항목 하나 분류 제안 ----------
    if (body.action === "suggest") {
      const src = body.item || {};
      // 프롬프트에 들어갈 값은 전부 서버에서 자른다 (길이 = 비용)
      const it: Partial<Row> = {
        type: cut(src.type, 20), title: cut(src.title, CAP.title), url: cut(src.url, CAP.url),
        lang: cut(src.lang, CAP.lang), body: cut(src.body, CAP.body),
        category: cut(src.category, CAP.category), sub: cut(src.sub, CAP.sub),
        tags: cutArr(src.tags, CAP.tags, CAP.tag),
      };
      if (!(it.title || it.url || it.body)) return fail("제목, 주소, 내용 중 하나는 있어야 합니다");
      const system = `${SITE_RULES}

분야 목록:
${catsText(cats)}

자주 쓰는 태그: ${cutArr(body.tagsHint, 40, CAP.hint).join(", ") || "(아직 없음)"}

추가 규칙:
- title: 제목이 비어 있거나 도메인 이름(example.com)뿐이면 한눈에 알아볼 짧은 한국어 제목을 제안한다. 이미 괜찮은 제목이면 그대로 돌려준다.
- body: 링크인데 설명이 비어 있고, 그 서비스·문서가 무엇인지 확실히 알 때만 한 줄(40자 이내) 설명을 쓴다. 모르면 빈 문자열.
- reason: 왜 그렇게 분류했는지 30자 이내.`;
      const schema = {
        type: "object",
        properties: { ...classifyProps(catNames), title: { type: "string" }, body: { type: "string" }, reason: { type: "string" } },
        required: ["category", "sub", "tags", "title", "body", "reason"],
        additionalProperties: false,
      };
      const out = await ask(client, system, `다음 항목을 분류해 주세요.\n\n${itemText(it)}`, schema, { max_tokens: 4096, effort: "low" });
      const cat = cats.find((c) => c.name === out.category);
      return json({ ...out, newSub: !!(cat && out.sub && !cat.subs.includes(out.sub)) });
    }

    // ---------- 2) 여러 항목 다시 분류 (운영자) ----------
    if (body.action === "organize") {
      if (!isAdmin) return fail("운영자만 쓸 수 있습니다", 403);
      const ids = (Array.isArray(body.ids) ? body.ids : []).map(String).filter((x) => /^[A-Za-z0-9_-]{1,64}$/.test(x)).slice(0, MAX_ORGANIZE);
      if (!ids.length) return fail("다시 분류할 항목 id 가 없습니다");
      const [{ data: rows }, { data: allRows }] = await Promise.all([
        sb.from("items").select("id,type,title,url,lang,body,category,sub,tags").in("id", ids),
        sb.from("items").select("tags").limit(5000),
      ]);
      if (!rows || !rows.length) return fail("항목을 찾지 못했습니다", 422);   // 404 는 브라우저가 '함수 미배포' 로 오해한다
      const system = `${SITE_RULES}

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
              properties: { id: { type: "string" }, ...classifyProps(catNames), changed: { type: "boolean" }, reason: { type: "string" } },
              required: ["id", "category", "sub", "tags", "changed", "reason"],
              additionalProperties: false,
            },
          },
        },
        required: ["proposals"],
        additionalProperties: false,
      };
      const user = `다음 ${rows.length}개 항목을 검토해 주세요.\n\n` +
        rows.map((r: Row, i: number) => `[${i + 1}] id=${r.id}\n${itemText(r)}`).join("\n\n");
      const out = await ask(client, system, user, schema, { max_tokens: 16000, effort: "low" });
      const byId = new Map<string, Row>(rows.map((r: Row) => [r.id, r]));
      const proposals = (out.proposals || [])
        .filter((p: { id: string }) => byId.has(p.id))
        .map((p: Row & { changed: boolean; reason: string }) => {
          const cur = byId.get(p.id)!;
          const same = cur.category === p.category && (cur.sub || "") === (p.sub || "") &&
            JSON.stringify((cur.tags || []).slice().sort()) === JSON.stringify((p.tags || []).slice().sort());
          const cat = cats.find((c) => c.name === p.category);
          return { ...p, changed: p.changed && !same, newSub: !!(cat && p.sub && !cat.subs.includes(p.sub)) };
        });
      return json({ proposals });
    }

    // ---------- 3) 분야 구조 개편안 (운영자) ----------
    if (body.action === "taxonomy") {
      if (!isAdmin) return fail("운영자만 쓸 수 있습니다", 403);
      const { data: rows } = await sb.from("items").select("type,title,category,sub,tags").order("created_at", { ascending: false }).limit(MAX_TAXONOMY_ITEMS);
      const list = (rows || []) as Pick<Row, "type" | "title" | "category" | "sub" | "tags">[];
      const system = `${SITE_RULES}

당신의 일: 현재 분야 구조와 전체 자료 목록을 보고, 더 찾기 쉬운 분야·하위분야 구조를 제안한다.

원칙:
- 기존 분야 이름은 가능하면 그대로 둔다. 이름을 바꾸면 이미 올라간 항목의 분야 표기가 어긋난다. 꼭 바꿔야 하면 notes 에 "○○ → △△ 로 바꾸면 항목 N개를 수정해야 함" 처럼 적는다.
- 하위분야는 항목이 실제로 모이는 곳에만 둔다. 자료가 3개 이상 몰리는데 하위분야가 없으면 새로 만들고, 항목이 하나도 없고 앞으로도 쓰일 것 같지 않은 하위분야는 뺀다.
- 분야당 하위분야 3~7개가 적당하다. 이름은 2~8자, 여러 단어는 가운뎃점(·)으로.
- notes 에는 바꾼 이유를 한 줄씩(각 60자 이내) 쓴다. 바꿀 것이 없으면 그렇게 적는다.`;
      const user = `현재 분야 구조:\n${catsText(cats)}\n\n전체 자료 ${list.length}개 (종류 | 제목 | 분야 › 하위분야 | 태그):\n` +
        list.map((r) => `${r.type} | ${String(r.title || "").slice(0, 60)} | ${r.category || "-"}${r.sub ? " › " + r.sub : ""} | ${(r.tags || []).join(",")}`).join("\n");
      const schema = {
        type: "object",
        properties: {
          list: { type: "array", items: { type: "object", properties: { name: { type: "string" }, subs: strArr }, required: ["name", "subs"], additionalProperties: false } },
          notes: strArr,
        },
        required: ["list", "notes"],
        additionalProperties: false,
      };
      const out = await ask(client, system, user, schema, { max_tokens: 16000, effort: "medium" });
      return json({ list: out.list || [], notes: out.notes || [], itemCount: list.length });
    }

    return fail("알 수 없는 action 입니다: " + String(body.action || ""));
  } catch (e) {
    // 우리 쪽 문제로 실패했으면 차감한 하루 한도를 돌려준다 (사용자 잘못이 아니다)
    const ours = e instanceof Anthropic.AuthenticationError || e instanceof Anthropic.APIConnectionError ||
      e instanceof Anthropic.RateLimitError || (e instanceof Anthropic.APIError && (!e.status || e.status >= 500));
    if (ours) { try { await sb.rpc("ai_refund_quota"); } catch { /* 환불 실패는 무시 */ } }

    if (e instanceof Anthropic.AuthenticationError) {
      return fail("AI 키가 만료되었거나 올바르지 않습니다. 운영자에게 알려 주세요 (README 7단계)", 500);
    }
    if (e instanceof Anthropic.RateLimitError) return fail("AI 호출이 몰리고 있습니다. 잠시 후 다시 시도해 주세요", 429);
    if (e instanceof Anthropic.APIConnectionError) return fail("AI 서버에 연결하지 못했습니다. 잠시 후 다시 시도해 주세요", 504);
    if (e instanceof Anthropic.APIError) return fail(`AI 서비스 오류 (${e.status ?? "연결"}): ${e.message}`, 502);
    return fail((e as Error).message || "알 수 없는 오류", 500);
  }
});
