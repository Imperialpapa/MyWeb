// ============================================================
// 빠른 연결 사진·영상 (Supabase Edge Function)
// ------------------------------------------------------------
// 파일은 Cloudflare R2 에 둔다. 버킷이 둘이다 — 승인 전(비공개)과 승인 뒤(공개 주소로 읽힘).
// 브라우저는 R2 키를 가질 수 없으므로, R2 에 닿는 일은 모두 이 함수가 서명해 준다.
//   upload  : 열쇠를 받고(media_begin) 비공개 버킷에 올릴 주소를 서명해 준다        — 로그인 사용자
//   view    : 승인 전 파일을 볼 주소를 서명해 준다 (RLS 로 그 자료가 보이는 사람만)   — 올린 사람·운영자
//   approve : 크기·형식을 다시 보고 공개 버킷으로 옮긴 뒤 승인을 찍는다(media_approve)  — 운영자
//   sweep   : 지운 자료의 파일을 R2 에서 지운다 (media_trash)                         — 운영자
// DB 쓰기는 전부 schema.sql 의 함수가 사용자 권한으로 한다. 이 함수는 service_role 키를 쓰지 않는다.
//
// 배포:  npx supabase functions deploy media
// 비밀 값 (대시보드 Edge Functions → Secrets 에서 넣는다. 키를 채팅이나 저장소에 붙이지 않는다):
//   R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY
//   R2_PENDING_BUCKET (기본 quickref-pending), R2_PUBLIC_BUCKET (기본 quickref-media)
// ============================================================
import { createClient } from "npm:@supabase/supabase-js@2.116.0";

// schema.sql 의 media_begin 과 같은 값이어야 한다. 승인 때 R2 에 실제로 올라간 파일을 이것으로 다시 본다
const MEDIA_LIMIT: Record<string, number> = {
  "image/jpeg": 10 * 1024 * 1024, "image/png": 10 * 1024 * 1024, "image/webp": 10 * 1024 * 1024, "image/gif": 10 * 1024 * 1024,
  "video/mp4": 50 * 1024 * 1024, "video/webm": 50 * 1024 * 1024,
};
const KEY_RE = /^m\/[0-9a-f]{32}\.(jpg|png|webp|gif|mp4|webm)$/;   // schema.sql 의 items_media_chk 와 같다
const ID_RE = /^[A-Za-z0-9_-]{1,64}$/;
const SIGN_TTL = 600;          // 서명한 주소의 수명(초). 올리기·미리 보기 모두 10분이면 넉넉하다
const MAX_BODY_BYTES = 4_000;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const fail = (message: string, status = 400) => json({ error: message }, status);
const scrub = (m: unknown) =>
  String(m || "").replace(/eyJ[\w-]*\.[\w-]*\.[\w-]*/g, "[jwt]").replace(/sb_[a-z]+_[\w-]+/gi, "[key]").slice(0, 200);
const logFail = (stage: string, f: Record<string, unknown>) =>
  console.error(JSON.stringify({ mediaFail: stage, ...f, msg: scrub(f.msg) }));

// ---------- 호출한 사용자 확인 ----------
// ai/index.ts 와 같은 규칙이다 (그쪽 주석이 이유를 자세히 적고 있다). 한쪽을 고치면 다른 쪽도 본다.
const SERVER_KEY_MSG = "서버에 Supabase 키가 설정되지 않았습니다. 운영자에게 알려 주세요";
function pickSupabaseKey(): { key: string } | { why: string } {
  const anon = (Deno.env.get("SUPABASE_ANON_KEY") || "").trim();
  const sw = (Deno.env.get("KEY_SOURCE") || "").trim().toLowerCase();
  if (sw === "anon") return anon ? { key: anon } : { why: "KEY_SOURCE=anon but SUPABASE_ANON_KEY is empty" };
  if (sw) return { why: "KEY_SOURCE is set but not 'anon'" };
  const isPub = (v: unknown): v is string => typeof v === "string" && v.startsWith("sb_publishable_");
  let pub = "";
  try {
    const m: unknown = JSON.parse(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS") || "{}");
    if (m && typeof m === "object") {
      const d = (m as Record<string, unknown>).default;
      pub = isPub(d) ? d : (Object.values(m).find(isPub) ?? "");
    }
  } catch { /* 깨진 JSON: 아래 대비책으로 */ }
  if (!pub) {
    const one = (Deno.env.get("SUPABASE_PUBLISHABLE_KEY") || "").trim();
    if (isPub(one)) pub = one;
  }
  if (pub) return { key: pub.trim() };
  if (anon) return { key: anon };
  return { why: "no publishable or anon key in env" };
}
function bearerToken(req: Request): string {
  const m = /^bearer\s+(\S+)$/i.exec(req.headers.get("Authorization") || "");
  return m ? m[1] : "";
}
function looksLikeUserJwt(token: string): boolean {
  const parts = token.split(".");
  if (parts.length !== 3 || !parts.every((p) => /^[A-Za-z0-9_-]+$/.test(p))) return false;
  try {
    const claims = JSON.parse(atob(parts[1].replace(/-/g, "+").replace(/_/g, "/")));
    return !!claims && typeof claims.sub === "string" && claims.sub !== "";
  } catch { return false; }
}

// ---------- R2 (S3 호환) 서명: AWS Signature V4 ----------
// 라이브러리(aws4fetch)는 content-length·content-type 을 서명에서 빼 버린다. 그러면 업로드 주소 하나로
// 5GB 까지 올릴 수 있어, 크기 상한이 의미가 없다. 그래서 직접 서명하고 두 머리글을 서명에 넣는다.
const enc = new TextEncoder();
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
const sha256 = async (s: string) => hex(await crypto.subtle.digest("SHA-256", enc.encode(s)));
async function hmac(key: ArrayBuffer | Uint8Array, s: string): Promise<ArrayBuffer> {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return crypto.subtle.sign("HMAC", k, enc.encode(s));
}
// RFC 3986. encodeURIComponent 는 !'()* 를 그대로 둔다
const uri = (s: string) => encodeURIComponent(s).replace(/[!'()*]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());

type R2 = { account: string; akid: string; secret: string; host: string; buckets: { pending: string; approved: string } };
function r2Config(): R2 | null {
  const account = (Deno.env.get("R2_ACCOUNT_ID") || "").trim();
  const akid = (Deno.env.get("R2_ACCESS_KEY_ID") || "").trim();
  const secret = (Deno.env.get("R2_SECRET_ACCESS_KEY") || "").trim();
  if (!account || !akid || !secret) return null;
  return {
    account, akid, secret, host: `${account}.r2.cloudflarestorage.com`,
    buckets: {
      pending: (Deno.env.get("R2_PENDING_BUCKET") || "quickref-pending").trim(),
      approved: (Deno.env.get("R2_PUBLIC_BUCKET") || "quickref-media").trim(),
    },
  };
}

// headers: 서명에 넣을 머리글 (이름은 소문자). host 는 여기서 넣는다.
// query=true 면 서명을 주소에 싣고(브라우저에 건넬 주소), 아니면 Authorization 머리글을 돌려준다.
async function sign(r2: R2, method: string, bucket: string, key: string,
  headers: Record<string, string>, opt: { query: boolean; expires?: number }) {
  const now = new Date();
  const amzDate = now.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");   // 20261028T010203Z
  const day = amzDate.slice(0, 8);
  const scope = `${day}/auto/s3/aws4_request`;
  const path = `/${uri(bucket)}/${key.split("/").map(uri).join("/")}`;
  const h: Record<string, string> = { ...headers, host: r2.host };
  if (!opt.query) { h["x-amz-date"] = amzDate; h["x-amz-content-sha256"] = "UNSIGNED-PAYLOAD"; }
  const names = Object.keys(h).map((n) => n.toLowerCase()).sort();
  const signedHeaders = names.join(";");
  const canonHeaders = names.map((n) => `${n}:${String(h[n]).trim()}\n`).join("");
  const q: Record<string, string> = opt.query ? {
    "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
    "X-Amz-Credential": `${r2.akid}/${scope}`,
    "X-Amz-Date": amzDate,
    "X-Amz-Expires": String(opt.expires || SIGN_TTL),
    "X-Amz-SignedHeaders": signedHeaders,
  } : {};
  const canonQuery = Object.keys(q).sort().map((k) => `${uri(k)}=${uri(q[k])}`).join("&");
  const canonical = [method, path, canonQuery, canonHeaders, signedHeaders, "UNSIGNED-PAYLOAD"].join("\n");
  const toSign = ["AWS4-HMAC-SHA256", amzDate, scope, await sha256(canonical)].join("\n");
  let k = await hmac(enc.encode("AWS4" + r2.secret), day);
  k = await hmac(k, "auto"); k = await hmac(k, "s3"); k = await hmac(k, "aws4_request");
  const sig = hex(await hmac(k, toSign));
  const base = `https://${r2.host}${path}`;
  if (opt.query) return { url: `${base}?${canonQuery}&X-Amz-Signature=${sig}`, headers: {} as Record<string, string> };
  const out: Record<string, string> = { ...headers, "x-amz-date": amzDate, "x-amz-content-sha256": "UNSIGNED-PAYLOAD" };
  out["authorization"] = `AWS4-HMAC-SHA256 Credential=${r2.akid}/${scope}, SignedHeaders=${signedHeaders}, Signature=${sig}`;
  return { url: base, headers: out };
}
async function r2Fetch(r2: R2, method: string, bucket: string, key: string, headers: Record<string, string> = {}) {
  const s = await sign(r2, method, bucket, key, headers, { query: false });
  return fetch(s.url, { method, headers: s.headers });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return fail("POST 만 받습니다", 405);

  const r2 = r2Config();
  if (!r2) return fail("사진·영상 저장소(R2)가 아직 설정되지 않았습니다. 운영자에게 알려 주세요", 503);
  const sbKey = pickSupabaseKey();
  if ("why" in sbKey) { logFail("key", { msg: sbKey.why }); return fail(SERVER_KEY_MSG, 500); }
  const token = bearerToken(req);
  if (!looksLikeUserJwt(token)) return fail("로그인이 필요합니다", 401);

  // 사용자 토큰을 실은 클라이언트. 아래 조회·rpc 에 RLS 가 이 사용자로 걸린다
  const sb = createClient(Deno.env.get("SUPABASE_URL") || "", sbKey.key, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  let userId = "";
  try {
    const { data, error } = await sb.auth.getUser(token);
    if (error) logFail("getUser", { status: (error as { status?: number }).status || 0, msg: error.message });
    userId = data.user?.id || "";
  } catch (e) { logFail("getUser", { msg: String((e as Error)?.message || e) }); }
  if (!userId) return fail("로그인이 필요합니다. 다시 로그인한 뒤 시도해 주세요", 401);

  let body: { action?: string; contentType?: string; size?: number; id?: string };
  try {
    const raw = await req.text();
    if (raw.length > MAX_BODY_BYTES) return fail("요청이 너무 큽니다", 413);
    body = JSON.parse(raw);
  } catch { return fail("요청 본문이 JSON 이 아닙니다"); }
  const action = String(body.action || "");

  const isAdmin = async (): Promise<boolean | Response> => {
    const { data, error } = await sb.from("profiles").select("is_admin").eq("id", userId).maybeSingle();
    if (error) { logFail("profile", { code: error.code, msg: error.message }); return fail("권한을 확인하지 못했습니다. 잠시 후 다시 시도해 주세요", 503); }
    return !!(data && data.is_admin);
  };
  // RLS 로 읽는다. 승인 전 자료는 올린 사람과 운영자에게만 보인다
  const readItem = async (id: unknown) => {
    if (typeof id !== "string" || !ID_RE.test(id)) return { res: fail("자료 id 가 올바르지 않습니다") };
    const { data, error } = await sb.from("items").select("id,type,status,media_key,media_type").eq("id", id).maybeSingle();
    if (error) { logFail("item", { code: error.code, msg: error.message }); return { res: fail("자료를 읽지 못했습니다. schema.sql 을 최신으로 실행했는지 확인해 주세요", 500) }; }
    if (!data || !data.media_key || !KEY_RE.test(data.media_key)) return { res: fail("사진·영상 자료를 찾지 못했습니다", 404) };
    return { item: data as { id: string; status: string; media_key: string; media_type: string } };
  };

  if (action === "upload") {
    const ct = String(body.contentType || "");
    const size = Number(body.size);
    if (!MEDIA_LIMIT[ct]) return fail("사진(jpg·png·webp·gif)이나 영상(mp4·webm)만 올릴 수 있습니다");
    if (!Number.isSafeInteger(size) || size <= 0) return fail("파일 크기가 올바르지 않습니다");
    // 상한·하루 횟수·승인 대기 수는 DB 함수가 본다. 거절 문구는 그쪽 것을 그대로 보여 준다
    const { data: key, error } = await sb.rpc("media_begin", { ct, sz: size });
    if (error) {
      if (error.code === "P0001") return fail(error.message, 400);   // raise exception 의 문구
      logFail("begin", { code: error.code, msg: error.message });
      return fail("올리기를 시작하지 못했습니다. schema.sql 을 최신으로 실행했는지 확인해 주세요", 500);
    }
    if (typeof key !== "string" || !KEY_RE.test(key)) return fail("서버가 이상한 열쇠를 돌려주었습니다", 500);
    // 크기와 형식을 서명에 넣는다. 브라우저가 다른 크기·형식으로 올리면 R2 가 서명 불일치로 거절한다
    const s = await sign(r2, "PUT", r2.buckets.pending, key, { "content-length": String(size), "content-type": ct }, { query: true });
    return json({ key, url: s.url });
  }

  if (action === "view") {
    const r = await readItem(body.id);
    if (r.res) return r.res;
    const it = r.item!;
    if (it.status === "approved") return json({ public: true });
    const s = await sign(r2, "GET", r2.buckets.pending, it.media_key, {}, { query: true });
    return json({ url: s.url });
  }

  if (action === "approve" || action === "sweep") {
    const adm = await isAdmin();
    if (adm instanceof Response) return adm;
    if (!adm) return fail("운영자만 쓸 수 있습니다", 403);
  }

  if (action === "approve") {
    const r = await readItem(body.id);
    if (r.res) return r.res;
    const it = r.item!;
    if (it.status !== "pending") return json({ ok: true, already: true });
    // 실제로 올라간 파일을 본다. 서명이 크기·형식을 묶지만, 그 장치가 R2 에서 정말 먹는지는 여기서 한 번 더 지킨다
    const head = await r2Fetch(r2, "HEAD", r2.buckets.pending, it.media_key);
    if (head.status === 404) return fail("파일이 아직 올라오지 않았거나 지워졌습니다. 거절(삭제)해 주세요", 409);
    if (!head.ok) { logFail("head", { status: head.status }); return fail("저장소에서 파일을 확인하지 못했습니다 (HTTP " + head.status + ")", 502); }
    const len = Number(head.headers.get("content-length") || "0");
    const ct = (head.headers.get("content-type") || "").split(";")[0].trim();
    if (ct !== it.media_type || !MEDIA_LIMIT[ct]) return fail(`파일 형식이 올릴 때와 다릅니다 (${ct || "없음"}). 거절해 주세요`, 409);
    if (!(len > 0) || len > MEDIA_LIMIT[ct]) return fail("파일 크기가 상한을 넘습니다. 거절해 주세요", 409);
    // 공개 버킷으로 복사 → 승인 표시 → 비공개 원본 삭제. 승인을 먼저 찍으면 공개 주소가 한동안 빈 곳을 가리킨다
    const copy = await r2Fetch(r2, "PUT", r2.buckets.approved, it.media_key, {
      "x-amz-copy-source": `/${uri(r2.buckets.pending)}/${it.media_key}`,
    });
    const copyText = await copy.text().catch(() => "");
    // S3 는 복사 도중 실패를 200 + <Error> 본문으로 줄 수 있다
    if (!copy.ok || /<Error>/.test(copyText)) {
      logFail("copy", { status: copy.status, msg: copyText });
      return fail("공개 저장소로 옮기지 못했습니다 (HTTP " + copy.status + ")", 502);
    }
    const { error } = await sb.rpc("media_approve", { iid: it.id });
    if (error) { logFail("approve", { code: error.code, msg: error.message }); return fail("승인을 기록하지 못했습니다: " + error.message, 500); }
    // 원본을 못 지워도 승인은 끝난 것이다. 비공개 버킷의 수명 규칙(8일)이 지운다
    await r2Fetch(r2, "DELETE", r2.buckets.pending, it.media_key).then((x) => x.body?.cancel()).catch(() => {});
    return json({ ok: true });
  }

  if (action === "sweep") {
    const { data, error } = await sb.rpc("media_trash_take", { lim: 50 });
    if (error) { logFail("trash", { code: error.code, msg: error.message }); return fail("지울 파일 목록을 읽지 못했습니다", 500); }
    const rows = (Array.isArray(data) ? data : []) as { bucket: string; key: string }[];
    const done: Record<string, string[]> = { pending: [], approved: [] };
    let failed = 0;
    for (const row of rows) {
      const b = row.bucket === "approved" ? r2.buckets.approved : row.bucket === "pending" ? r2.buckets.pending : "";
      if (!b || !KEY_RE.test(row.key)) { failed++; continue; }
      // 없는 파일을 지워도 R2 는 204 를 준다. 그래서 이미 지워진 것도 목록에서 빠진다
      const res = await r2Fetch(r2, "DELETE", b, row.key).catch(() => null);
      await res?.body?.cancel().catch(() => {});
      if (res && (res.ok || res.status === 404)) done[row.bucket].push(row.key); else failed++;
    }
    let removed = 0;
    for (const b of ["pending", "approved"]) {
      if (!done[b].length) continue;
      const { data: n, error: e2 } = await sb.rpc("media_trash_done", { b, keys: done[b] });
      if (e2) logFail("trashDone", { code: e2.code, msg: e2.message }); else removed += Number(n) || 0;
    }
    if (failed) logFail("sweep", { failed });
    return json({ removed, failed, more: rows.length >= 50 });
  }

  return fail("알 수 없는 action 입니다: " + action);
});
