// Supabase Edge Function: translate-motto
// 承認済みの「格言(building_profiles.motto_text)」と「過去詳細の自由記述
// (building_past_details.background_detail / current_positive)」を DeepL で英訳し、
// それぞれ *_en 列に保存する。DeepL で翻訳できなかった分（枠超過など）は次回以降に
// 自動でリトライされる（未翻訳=NULL の行だけ拾うため）。
//
// 実行できるのは:
//   - 管理者(ADMIN_USER_ID) の JWT を持つ呼び出し（admin.html から）
//   - もしくは x-cron-secret ヘッダが CRON_SECRET と一致する呼び出し（毎日のCron）
//
// 入力(body):
//   {}                         … 未翻訳を全件（格言＋過去詳細）。Cron/一括ボタン用
//   {"ids":["..."]}            … 指定IDの格言を翻訳（承認直後）
//   {"pastIds":["..."]}        … 指定IDの過去詳細を翻訳（承認直後）
//
// デプロイ:
//   supabase functions deploy translate-motto
//   supabase secrets set DEEPL_API_KEY=xxxxxxxx:fx     (Free キーは末尾が :fx)
//   supabase secrets set CRON_SECRET=任意の長い文字列    (Cronからの実行用)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ADMIN_USER_ID = "afc818cd-d2fa-4c1c-8460-9dbce9e60e37";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

async function deeplTranslate(key: string, text: string, target = "EN-US"): Promise<string> {
  const endpoint = key.endsWith(":fx")
    ? "https://api-free.deepl.com/v2/translate"
    : "https://api.deepl.com/v2/translate";
  const body = new URLSearchParams();
  body.append("text", text);
  body.append("source_lang", "JA");
  body.append("target_lang", target);
  const res = await fetch(endpoint, {
    method: "POST",
    headers: {
      "Authorization": `DeepL-Auth-Key ${key}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body,
  });
  if (!res.ok) throw new Error(`DeepL ${res.status}: ${await res.text()}`);
  const j = await res.json();
  return j?.translations?.[0]?.text || "";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
    const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
    const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const DEEPL_KEY = Deno.env.get("DEEPL_API_KEY");
    const CRON_SECRET = Deno.env.get("CRON_SECRET");
    if (!DEEPL_KEY) return json({ error: "DEEPL_API_KEY not set" }, 500);

    // 認可: Cronシークレット一致 か、管理者JWT のどちらか
    const cronHeader = req.headers.get("x-cron-secret");
    let authorized = false;
    if (CRON_SECRET && cronHeader && cronHeader === CRON_SECRET) {
      authorized = true;
    } else {
      const authHeader = req.headers.get("Authorization") || "";
      const userClient = createClient(SUPABASE_URL, ANON_KEY, {
        global: { headers: { Authorization: authHeader } },
      });
      const { data: { user } } = await userClient.auth.getUser();
      if (user && user.id === ADMIN_USER_ID) authorized = true;
    }
    if (!authorized) return json({ error: "forbidden" }, 403);

    let ids: string[] | undefined;
    let pastIds: string[] | undefined;
    try {
      const b = await req.json();
      if (Array.isArray(b?.ids)) ids = b.ids;
      if (Array.isArray(b?.pastIds)) pastIds = b.pastIds;
    } catch (_) { /* body 無し = 全件 */ }

    const all = !ids && !pastIds; // 何も指定が無ければ未翻訳を全件

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    let mottoCount = 0;
    let pastCount = 0;

    // ---- 格言 (building_profiles.motto_text -> motto_text_en) ----
    if (all || ids) {
      let q = admin
        .from("building_profiles")
        .select("id,motto_text,motto_text_en,status")
        .eq("status", "approved")
        .not("motto_text", "is", null);
      if (ids && ids.length) q = q.in("id", ids);
      else q = q.is("motto_text_en", null);
      const { data: rows, error } = await q;
      if (error) throw error;
      for (const r of rows || []) {
        const src = (r as any).motto_text as string;
        if (!src) continue;
        try {
          const en = await deeplTranslate(DEEPL_KEY, src);
          if (en) {
            const { error: upErr } = await admin
              .from("building_profiles")
              .update({ motto_text_en: en })
              .eq("id", (r as any).id);
            if (!upErr) mottoCount++;
          }
        } catch (e) {
          console.warn("motto translate failed", (r as any).id, String(e));
        }
      }
    }

    // ---- 過去詳細 (background_detail / current_positive -> *_en) ----
    if (all || pastIds) {
      let q = admin
        .from("building_past_details")
        .select("id,background_detail,background_detail_en,current_positive,current_positive_en,status")
        .eq("status", "approved");
      if (pastIds && pastIds.length) q = q.in("id", pastIds);
      const { data: rows, error } = await q;
      if (error) throw error;
      for (const r of rows || []) {
        const row = r as any;
        const patch: Record<string, string> = {};
        try {
          // 指定IDモードは（再申請で内容が変わり得るため）常に翻訳し直す。
          // 全件モードは未翻訳(NULL)のみ。
          if (row.background_detail && (pastIds ? true : !row.background_detail_en)) {
            const en = await deeplTranslate(DEEPL_KEY, row.background_detail);
            if (en) patch.background_detail_en = en;
          }
          if (row.current_positive && (pastIds ? true : !row.current_positive_en)) {
            const en = await deeplTranslate(DEEPL_KEY, row.current_positive);
            if (en) patch.current_positive_en = en;
          }
          if (Object.keys(patch).length) {
            const { error: upErr } = await admin
              .from("building_past_details")
              .update(patch)
              .eq("id", row.id);
            if (!upErr) pastCount++;
          }
        } catch (e) {
          console.warn("past translate failed", row.id, String(e));
        }
      }
    }

    return json({ ok: true, motto: mottoCount, past: pastCount });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
