import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// ======================================================
// 定数
// ======================================================
const BEARER       = Deno.env.get('X_BEARER_TOKEN')!;
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const FOUNDER_X_ID  = '1996865590414528512';
const REPOST_COINS  = 15;
const REPLY_COINS   = 10;
/** 創設者投稿からこの時間経過後のみリポスト／引用リポスト報酬対象 */
const REPOST_MIN_AGE_HOURS = 24;
/** この時間を超えた投稿は API 読み込み・報酬付与の対象外 */
const TWEET_API_WINDOW_HOURS = 48;

const db = createClient(SUPABASE_URL, SERVICE_KEY);

// ======================================================
// X API ヘルパー
// ======================================================
async function xGet(path: string): Promise<any> {
  const res = await fetch(`https://api.twitter.com/2${path}`, {
    headers: { Authorization: `Bearer ${BEARER}` },
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`X API ${res.status}: ${body}`);
  }
  return res.json();
}

/** 創設者の投稿一覧（ローンチ日以降） */
async function getFounderTweets(launchDate: string): Promise<any[]> {
  const start = new Date(launchDate).toISOString();
  const data = await xGet(
    `/users/${FOUNDER_X_ID}/tweets?max_results=100&start_time=${start}` +
    `&tweet.fields=created_at,conversation_id&exclude=retweets,replies`
  );
  return data.data ?? [];
}

/** 通常リポストしたユーザー（username→小文字） */
async function getRetweeters(tweetId: string): Promise<string[]> {
  try {
    const data = await xGet(
      `/tweets/${tweetId}/retweeted_by?max_results=100&user.fields=username`
    );
    return (data.data ?? []).map((u: any) => u.username?.toLowerCase() ?? '').filter(Boolean);
  } catch {
    return [];
  }
}

/** 引用リポストしたユーザー（username→小文字） */
async function getQuoters(tweetId: string): Promise<string[]> {
  try {
    const data = await xGet(
      `/tweets/${tweetId}/quote_tweets?max_results=100` +
      `&tweet.fields=author_id&expansions=author_id&user.fields=username`
    );
    const idToName: Record<string, string> = {};
    ((data.includes?.users) ?? []).forEach((u: any) => {
      idToName[u.id] = u.username?.toLowerCase() ?? '';
    });
    return (data.data ?? [])
      .map((t: any) => idToName[t.author_id] ?? '')
      .filter(Boolean);
  } catch {
    return [];
  }
}

/** リポスト＋引用リポスト（重複ハンドルは1人1回） */
async function getRepostHandles(tweetId: string): Promise<string[]> {
  const handles = new Set<string>();
  for (const h of [...await getRetweeters(tweetId), ...await getQuoters(tweetId)]) {
    if (h) handles.add(h);
  }
  return [...handles];
}

function tweetAgeHours(tweetCreatedAt: string): number {
  return (Date.now() - new Date(tweetCreatedAt).getTime()) / 3600_000;
}

/** 投稿後48h未満のみバッチ対象（リポスト・リプライとも API を読む） */
function isWithinApiWindow(tweetCreatedAt: string): boolean {
  return tweetAgeHours(tweetCreatedAt) < TWEET_API_WINDOW_HOURS;
}

function isRepostEligible(tweetCreatedAt: string): boolean {
  const h = tweetAgeHours(tweetCreatedAt);
  return h >= REPOST_MIN_AGE_HOURS && h < TWEET_API_WINDOW_HOURS;
}

/**
 * 会話スレッド内のツイートを取得。
 * author_id / username のマッピングも返す。
 */
async function getConversationTweets(
  conversationId: string
): Promise<{ tweets: any[]; idToName: Record<string, string> }> {
  try {
    const data = await xGet(
      `/tweets/search/recent?query=conversation_id:${conversationId}` +
      `&max_results=100&tweet.fields=author_id,created_at` +
      `&expansions=author_id&user.fields=username`
    );
    const tweets: any[] = data.data ?? [];
    const idToName: Record<string, string> = {};
    ((data.includes?.users) ?? []).forEach((u: any) => {
      idToName[u.id] = u.username?.toLowerCase() ?? '';
    });
    return { tweets, idToName };
  } catch {
    return { tweets: [], idToName: {} };
  }
}

// ======================================================
// カウントロジック
// ======================================================
/**
 * ユーザーの「有効ターン数」を数える。
 * ルール：
 *  - 創設者投稿への最初の返信 → +1
 *  - 創設者が返信 → 次のユーザー返信 → +1
 *  - 連続リプライ（創設者返信なしに複数送信）→ 最初の1つだけカウント
 */
function countTurns(
  tweets: any[],
  founderXId: string,
  userXId: string
): number {
  const sorted = [...tweets].sort(
    (a, b) => new Date(a.created_at).getTime() - new Date(b.created_at).getTime()
  );
  let count = 0;
  let lastSpeaker = founderXId; // 創設者がスレッドを開始

  for (const t of sorted) {
    const spk = t.author_id;
    if (spk === userXId && lastSpeaker !== userXId) {
      count++;
      lastSpeaker = userXId;
    } else if (spk === founderXId) {
      lastSpeaker = founderXId;
    }
    // spk === userXId && lastSpeaker === userXId → 連続リプライ、スキップ
  }
  return count;
}

// ======================================================
// DB ヘルパー
// ======================================================
/** コイン付与 + テーブルへの記録 */
async function grantReward(
  table: string,
  extra: Record<string, unknown>,
  userId: string,
  amount: number,
  reason: string
): Promise<void> {
  await db.rpc('grant_x_reward', {
    p_user_id: userId,
    p_amount: amount,
    p_reason: reason,
  });
  await db.from(table).insert({ user_id: userId, ...extra });
}

// ======================================================
// メイン処理
// ======================================================
Deno.serve(async () => {
  try {
    // --- 設定取得 ---
    const { data: cfgRows } = await db.from('x_batch_config').select('key,value');
    const cfg: Record<string, string> = {};
    (cfgRows ?? []).forEach((r: any) => (cfg[r.key] = r.value));
    const launchDate = cfg.launch_date ?? '2026-06-01';

    // --- ゲームユーザー（x_username 登録済み）を取得 ---
    const { data: gameUsers } = await db
      .from('users')
      .select('id,x_username')
      .not('x_username', 'is', null);

    // ハンドル（小文字）→ user_id マップ
    const handleToUid: Record<string, string> = {};
    (gameUsers ?? []).forEach((u: any) => {
      if (u.x_username) {
        handleToUid[u.x_username.replace(/^@/, '').toLowerCase()] = u.id;
      }
    });

    // --- 創設者のツイート一覧 ---
    const founderTweets = await getFounderTweets(launchDate);

    let totalRepost = 0;
    let totalReply  = 0;

    for (const tweet of founderTweets) {
      if (!tweet.created_at || !isWithinApiWindow(tweet.created_at)) continue;

      const tweetId  = tweet.id as string;
      const convoId  = (tweet.conversation_id ?? tweetId) as string;

      // ── リポスト／引用リポスト（投稿24h〜48hの窓内のみ）──
      if (isRepostEligible(tweet.created_at)) {
        const repostHandles = await getRepostHandles(tweetId);
        for (const handle of repostHandles) {
          const uid = handleToUid[handle];
          if (!uid) continue;

          // 同一投稿への重複（削除→再リポストも1回のみ）
          const { data: dup } = await db
            .from('x_repost_rewards')
            .select('id')
            .eq('user_id', uid)
            .eq('founder_tweet_id', tweetId)
            .limit(1);
          if ((dup ?? []).length > 0) continue;

          await grantReward(
            'x_repost_rewards',
            { founder_tweet_id: tweetId },
            uid, REPOST_COINS, 'x_repost'
          );
          totalRepost++;
        }
      }

      // ── リプライ処理 ──────────────────────────
      const { tweets: convoTweets, idToName } = await getConversationTweets(convoId);

      // 会話に登場するユーザー（創設者以外）の X user ID 一覧
      const userXIds = [...new Set(
        convoTweets
          .map((t: any) => t.author_id as string)
          .filter((id) => id !== FOUNDER_X_ID)
      )];

      for (const userXId of userXIds) {
        const handle = idToName[userXId];
        if (!handle) continue;
        const uid = handleToUid[handle];
        if (!uid) continue;

        // このスレッドでのターン数を計算
        const turns = countTurns(convoTweets, FOUNDER_X_ID, userXId);
        if (turns === 0) continue;

        // ターンごとに付与（重複スキップのみ、クールダウンなし）
        for (let i = 0; i < turns; i++) {
          const { data: dup } = await db
            .from('x_reply_rewards')
            .select('id')
            .eq('user_id', uid)
            .eq('founder_tweet_id', tweetId)
            .eq('turn_index', i)
            .limit(1);
          if ((dup ?? []).length > 0) continue;

          await grantReward(
            'x_reply_rewards',
            { founder_tweet_id: tweetId, turn_index: i },
            uid, REPLY_COINS, 'x_reply'
          );
          totalReply++;
        }
      }
    }

    // --- バッチ完了時刻を記録 ---
    await db.from('x_batch_config').upsert({
      key: 'last_batch_at',
      value: new Date().toISOString(),
    });

    return new Response(
      JSON.stringify({ ok: true, totalRepost, totalReply }),
      { headers: { 'Content-Type': 'application/json' } }
    );
  } catch (e: any) {
    console.error('[x-reward-batch]', e.message);
    return new Response(
      JSON.stringify({ ok: false, error: e.message }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    );
  }
});
