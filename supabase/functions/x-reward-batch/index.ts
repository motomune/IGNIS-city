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
const COOLDOWN_HOURS = 24;

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

/** ツイートをリポストしたユーザー（username→小文字） */
async function getRetweeters(tweetId: string): Promise<string[]> {
  try {
    const data = await xGet(
      `/tweets/${tweetId}/retweeted_by?max_results=100&user.fields=username`
    );
    return (data.data ?? []).map((u: any) => u.username?.toLowerCase() ?? '');
  } catch {
    return [];
  }
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
/** 直近 COOLDOWN_HOURS 以内にそのテーブルで報酬を受け取ったか */
async function hasRecentReward(table: string, userId: string): Promise<boolean> {
  const since = new Date(Date.now() - COOLDOWN_HOURS * 3600_000).toISOString();
  const { data } = await db
    .from(table)
    .select('id')
    .eq('user_id', userId)
    .gte('rewarded_at', since)
    .limit(1);
  return (data ?? []).length > 0;
}

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
      const tweetId  = tweet.id as string;
      const convoId  = (tweet.conversation_id ?? tweetId) as string;

      // ── リポスト処理 ──────────────────────────
      const retweeters = await getRetweeters(tweetId);
      for (const handle of retweeters) {
        const uid = handleToUid[handle];
        if (!uid) continue;

        // 同一ツイートへの重複チェック
        const { data: dup } = await db
          .from('x_repost_rewards')
          .select('id')
          .eq('user_id', uid)
          .eq('founder_tweet_id', tweetId)
          .limit(1);
        if ((dup ?? []).length > 0) continue;

        // 24h クールダウンチェック
        if (await hasRecentReward('x_repost_rewards', uid)) continue;

        await grantReward(
          'x_repost_rewards',
          { founder_tweet_id: tweetId },
          uid, REPOST_COINS, 'x_repost'
        );
        totalRepost++;
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

        // ターンごとに 1 コイン付与（ただし 24h クールダウンと重複スキップ）
        for (let i = 0; i < turns; i++) {
          // 同一スレッド・同一ターンの重複チェック
          const { data: dup } = await db
            .from('x_reply_rewards')
            .select('id')
            .eq('user_id', uid)
            .eq('founder_tweet_id', tweetId)
            .eq('turn_index', i)
            .limit(1);
          if ((dup ?? []).length > 0) continue;

          // 24h クールダウン
          if (await hasRecentReward('x_reply_rewards', uid)) continue;

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
