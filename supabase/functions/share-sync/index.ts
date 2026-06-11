// Supabase Edge Function: share-sync
// 創設者(CREATOR_X_USERNAME)の最新投稿を取得し、各投稿への「リプライ/リポスト」を
// ゲームユーザーと照合して share_engagements に記録する。
//
// コスト対策（再カウント防止）:
//   - リプライは search/recent を since_id 付きで叩き、毎回「新着だけ」読む。
//     取得した最大IDを creator_posts.last_reply_since_id に保存 → 各リプライは生涯1回だけ。
//   - リポストは retweeted_by（ユーザー一覧／Post数枠を消費しない）を upsert（PKで冪等）。
//   - 対象は投稿から 48h 以内のアクティブ投稿のみ。
//
// 認可: x-cron-secret == CRON_SECRET（Cron） もしくは 管理者JWT。
// 必要シークレット: X_BEARER_TOKEN（既存の x-reward-batch と共用） / CRON_SECRET
// 任意: CREATOR_X_USERNAME（既定 soultamash81989）
//
// デプロイ: supabase functions deploy share-sync --no-verify-jwt
// Cron 例（毎6時間）: dashboard の Edge Functions > Cron で share-sync を 0 */6 * * * 等。

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ADMIN_USER_ID = "afc818cd-d2fa-4c1c-8460-9dbce9e60e37";
const ACTIVE_WINDOW_MS = 48 * 60 * 60 * 1000;
const MAX_PAGES = 5; // 1投稿あたりのページ上限（暴走防止）
const X_API = "https://api.x.com/2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

async function xGet(path: string, token: string): Promise<any> {
  const res = await fetch(`${X_API}${path}`, { headers: { Authorization: `Bearer ${token}` } });
  if (res.status === 429) throw new Error("rate_limited");
  if (!res.ok) throw new Error(`X ${res.status}: ${await res.text()}`);
  return res.json();
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
    const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
    const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const TOKEN = Deno.env.get("X_BEARER_TOKEN");
    const CRON_SECRET = Deno.env.get("CRON_SECRET");
    const CREATOR = (Deno.env.get("CREATOR_X_USERNAME") || "soultamash81989").replace(/^@/, "");
    if (!TOKEN) return json({ error: "X_BEARER_TOKEN not set" }, 500);

    // ---- 認可 ----
    const cronHeader = req.headers.get("x-cron-secret");
    let authorized = false;
    if (CRON_SECRET && cronHeader && cronHeader === CRON_SECRET) authorized = true;
    else {
      const userClient = createClient(SUPABASE_URL, ANON_KEY, {
        global: { headers: { Authorization: req.headers.get("Authorization") || "" } },
      });
      const { data: { user } } = await userClient.auth.getUser();
      if (user && user.id === ADMIN_USER_ID) authorized = true;
    }
    if (!authorized) return json({ error: "forbidden" }, 403);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    // ---- 1) 創設者の最新投稿を取得して creator_posts に upsert ----
    const u = await xGet(`/users/by/username/${CREATOR}`, TOKEN);
    const creatorId = u?.data?.id;
    if (!creatorId) return json({ error: "creator not found" }, 500);

    // 既存の最大tweet_id以降だけ取得（since_id）
    const { data: latestRow } = await admin
      .from("creator_posts").select("tweet_id").order("tweet_id", { ascending: false }).limit(1);
    const sinceId = latestRow && latestRow[0] ? latestRow[0].tweet_id : null;
    let tlPath = `/users/${creatorId}/tweets?max_results=10&exclude=replies,retweets&tweet.fields=created_at`;
    if (sinceId) tlPath += `&since_id=${sinceId}`;
    const tl = await xGet(tlPath, TOKEN);
    let newPosts = 0;
    for (const t of (tl?.data || [])) {
      const { error } = await admin.from("creator_posts").upsert({
        tweet_id: t.id,
        author_username: CREATOR,
        text: t.text,
        url: `https://x.com/${CREATOR}/status/${t.id}`,
        posted_at: t.created_at,
      }, { onConflict: "tweet_id" });
      if (!error) newPosts++;
    }

    // ---- 2) アクティブ投稿（48h以内）を取得 ----
    const cutoff = new Date(Date.now() - ACTIVE_WINDOW_MS).toISOString();
    const { data: active } = await admin
      .from("creator_posts").select("*").gte("posted_at", cutoff).order("posted_at", { ascending: false });

    // ゲームユーザーの x_username → user_id マップ（小文字・@除去で照合）
    const { data: users } = await admin
      .from("users").select("id,x_username").not("x_username", "is", null);
    const userByHandle = new Map<string, string>();
    for (const us of (users || [])) {
      const h = String((us as any).x_username || "").replace(/^@/, "").toLowerCase();
      if (h) userByHandle.set(h, (us as any).id);
    }

    let engRecorded = 0;
    const recordEngagement = async (handle: string, xUserId: string | null, tweetId: string, kind: "reply" | "repost") => {
      const uid = userByHandle.get(String(handle || "").replace(/^@/, "").toLowerCase());
      if (!uid) return;
      const { error } = await admin.from("share_engagements").upsert({
        user_id: uid, tweet_id: tweetId, kind, x_user_id: xUserId,
      }, { onConflict: "user_id,tweet_id,kind", ignoreDuplicates: true });
      if (!error) engRecorded++;
    };

    for (const post of (active || [])) {
      const tweetId = (post as any).tweet_id as string;

      // ---- 2a) リポスト（retweeted_by） ----
      try {
        let pageToken: string | undefined;
        for (let i = 0; i < MAX_PAGES; i++) {
          let p = `/tweets/${tweetId}/retweeted_by?max_results=100&user.fields=username`;
          if (pageToken) p += `&pagination_token=${pageToken}`;
          const r = await xGet(p, TOKEN);
          for (const usr of (r?.data || [])) await recordEngagement(usr.username, usr.id, tweetId, "repost");
          pageToken = r?.meta?.next_token;
          if (!pageToken) break;
        }
        await admin.from("creator_posts").update({ reposts_synced_at: new Date().toISOString() }).eq("tweet_id", tweetId);
      } catch (e) { console.warn("reposts", tweetId, String(e)); }

      // ---- 2a') 引用リポスト（quote_tweets）も「リポスト」として記録 ----
      try {
        let pageToken: string | undefined;
        for (let i = 0; i < MAX_PAGES; i++) {
          let p = `/tweets/${tweetId}/quote_tweets?max_results=100&expansions=author_id&user.fields=username`;
          if (pageToken) p += `&pagination_token=${pageToken}`;
          const r = await xGet(p, TOKEN);
          const usersById = new Map<string, string>();
          for (const us of (r?.includes?.users || [])) usersById.set(us.id, us.username);
          for (const tw of (r?.data || [])) {
            if (tw.author_id === creatorId) continue; // 本人の自己引用は除外
            const uname = usersById.get(tw.author_id);
            if (uname) await recordEngagement(uname, tw.author_id, tweetId, "repost");
          }
          pageToken = r?.meta?.next_token;
          if (!pageToken) break;
        }
      } catch (e) { console.warn("quotes", tweetId, String(e)); }

      // ---- 2b) リプライ（search/recent + since_id で新着のみ） ----
      try {
        const prevSince = (post as any).last_reply_since_id as string | null;
        let pageToken: string | undefined;
        let maxId = prevSince || null;
        for (let i = 0; i < MAX_PAGES; i++) {
          let p = `/tweets/search/recent?query=${encodeURIComponent(`conversation_id:${tweetId}`)}` +
            `&max_results=100&expansions=author_id&user.fields=username&tweet.fields=author_id`;
          if (prevSince) p += `&since_id=${prevSince}`;
          if (pageToken) p += `&next_token=${pageToken}`;
          const r = await xGet(p, TOKEN);
          const usersById = new Map<string, string>();
          for (const us of (r?.includes?.users || [])) usersById.set(us.id, us.username);
          for (const tw of (r?.data || [])) {
            if (tw.author_id === creatorId) continue; // 本人の自己リプは除外
            const uname = usersById.get(tw.author_id);
            if (uname) await recordEngagement(uname, tw.author_id, tweetId, "reply");
            if (!maxId || BigInt(tw.id) > BigInt(maxId)) maxId = tw.id;
          }
          pageToken = r?.meta?.next_token;
          if (!pageToken) break;
        }
        // 次回はこの maxId 以降だけ読む（再カウント防止）
        if (maxId && maxId !== prevSince) {
          await admin.from("creator_posts")
            .update({ last_reply_since_id: maxId, replies_synced_at: new Date().toISOString() })
            .eq("tweet_id", tweetId);
        }
      } catch (e) { console.warn("replies", tweetId, String(e)); }
    }

    return json({ ok: true, newPosts, activePosts: (active || []).length, engagements: engRecorded });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
