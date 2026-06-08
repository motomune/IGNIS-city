// Supabase Edge Function: translate-motto
// 承認済み格言(motto_text)を DeepL で英訳し building_profiles.motto_text_en に保存する。
// - 管理者(ADMIN_USER_ID)のみ実行可能（呼び出し元のJWTを検証）
// - DeepL のキーは Supabase シークレット DEEPL_API_KEY に保存（クライアントには出さない）
//
// デプロイ:
//   supabase functions deploy translate-motto
//   supabase secrets set DEEPL_API_KEY=xxxxxxxx:fx        (Free キーは末尾が :fx)
// 呼び出し（admin.html から）:
//   POST /functions/v1/translate-motto   body: {} = 未翻訳を全件 / {"ids":["..."]} = 指定IDのみ

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ADMIN_USER_ID = "afc818cd-d2fa-4c1c-8460-9dbce9e60e37";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
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
    if (!DEEPL_KEY) return json({ error: "DEEPL_API_KEY not set" }, 500);

    // 呼び出し元が管理者か検証
    const authHeader = req.headers.get("Authorization") || "";
    const userClient = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user } } = await userClient.auth.getUser();
    if (!user || user.id !== ADMIN_USER_ID) return json({ error: "forbidden" }, 403);

    let ids: string[] | undefined;
    try {
      const b = await req.json();
      if (Array.isArray(b?.ids)) ids = b.ids;
    } catch (_) { /* body 無し = 全件 */ }

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    let query = admin
      .from("building_profiles")
      .select("id,motto_text,motto_text_en,status")
      .eq("status", "approved")
      .not("motto_text", "is", null);
    if (ids && ids.length) query = query.in("id", ids);
    else query = query.is("motto_text_en", null); // 全件モードは未翻訳のみ

    const { data: rows, error } = await query;
    if (error) throw error;

    let translated = 0;
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
          if (!upErr) translated++;
        }
      } catch (e) {
        console.warn("translate failed", (r as any).id, String(e));
      }
    }
    return json({ ok: true, translated, total: (rows || []).length });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
