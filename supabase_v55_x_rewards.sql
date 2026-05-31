-- v55: X API reward tracking tables

-- リポスト報酬（1投稿につき1ユーザー1回のみ）
CREATE TABLE IF NOT EXISTS x_repost_rewards (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  founder_tweet_id text NOT NULL,
  rewarded_at timestamptz DEFAULT now(),
  UNIQUE(user_id, founder_tweet_id)
);

-- リプライ報酬（会話ターン＝話者切替ごとに1カウント・24h制限）
CREATE TABLE IF NOT EXISTS x_reply_rewards (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  founder_tweet_id text NOT NULL,
  turn_index integer NOT NULL,        -- 同一スレッド内のターン番号
  rewarded_at timestamptz DEFAULT now(),
  UNIQUE(user_id, founder_tweet_id, turn_index)
);

-- バッチ処理の設定・ログ
CREATE TABLE IF NOT EXISTS x_batch_config (
  key text PRIMARY KEY,
  value text
);

INSERT INTO x_batch_config(key, value) VALUES
  ('launch_date', '2026-06-01'),       -- ローンチ日（対象投稿の開始日）
  ('founder_x_id', ''),                -- 創設者のX user ID（APIで取得した数字ID）
  ('last_batch_at', '2000-01-01T00:00:00Z')
ON CONFLICT(key) DO NOTHING;

-- RLS
ALTER TABLE x_repost_rewards ENABLE ROW LEVEL SECURITY;
ALTER TABLE x_reply_rewards ENABLE ROW LEVEL SECURITY;

CREATE POLICY "x_repost_select_own" ON x_repost_rewards
  FOR SELECT TO authenticated USING (auth.uid() = user_id);

CREATE POLICY "x_reply_select_own" ON x_reply_rewards
  FOR SELECT TO authenticated USING (auth.uid() = user_id);

-- コイン付与RPC（バッチ処理から呼ばれる）
CREATE OR REPLACE FUNCTION grant_x_reward(
  p_user_id uuid,
  p_amount integer,
  p_reason text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE users SET coin_column = COALESCE(coin_column, 0) + p_amount WHERE id = p_user_id;
  INSERT INTO coins(user_id, amount, reason) VALUES(p_user_id, p_amount, p_reason);
END;
$$;

-- service_role のみ実行可（バッチ処理用）
REVOKE EXECUTE ON FUNCTION grant_x_reward(uuid, integer, text) FROM authenticated;
