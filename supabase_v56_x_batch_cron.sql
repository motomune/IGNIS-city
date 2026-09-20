-- ⚠️ 2026-09-20：このファイルは今は実行しないこと。実行しても動かない。
--
--   理由1（動かない）: x-reward-batch は認可を要求するようになった（2026-09-16）。
--     下の http_post は anon キーしか送っていないので 403 で弾かれ、
--     cron は「成功したように見えて何も起きない」状態になる。
--     再開するなら headers に 'x-cron-secret' を足す（値は Edge Functions の Secrets にある
--     CRON_SECRET。ここにも他のファイルにも書かないこと）。translate-pending-daily の
--     ジョブ定義が正しい書き方の見本になっている。
--
--   理由2（そもそも止めている）: リポスト・リプライを確認してコインを配るのは、
--     Xの規約でいう「反応を買う行為」に読める（凍結リスク）。2026-09-20に
--     「X連携は止めたままにする」と決めた。再開は、その判断をやり直してから。
--
-- v56: X報酬バッチを8:00 JST と 20:00 JST に自動実行
-- 日本時間 = UTC+9
-- 8:00 JST  = 23:00 UTC（前日）→ cron: '0 23 * * *'
-- 20:00 JST = 11:00 UTC         → cron: '0 11 * * *'

-- SupabaseプロジェクトURLとAnon Keyを自分のものに置き換えてください
-- Dashboard > Settings > API から取得できます

SELECT cron.schedule(
  'x-reward-batch-morning',
  '0 23 * * *',
  $$
  SELECT net.http_post(
    url     := 'https://xssjhgosxyhknonlrjrq.supabase.co/functions/v1/x-reward-batch',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhzc2poZ29zeHloa25vbmxyanJxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzcxMDE5OTYsImV4cCI6MjA5MjY3Nzk5Nn0.mK-w9uRuOEFkY4XBGervejqmuxiC4yiHHG20OQPOUjU'
    ),
    body    := '{}'::jsonb
  );
  $$
);

SELECT cron.schedule(
  'x-reward-batch-evening',
  '0 11 * * *',
  $$
  SELECT net.http_post(
    url     := 'https://xssjhgosxyhknonlrjrq.supabase.co/functions/v1/x-reward-batch',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhzc2poZ29zeHloa25vbmxyanJxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzcxMDE5OTYsImV4cCI6MjA5MjY3Nzk5Nn0.mK-w9uRuOEFkY4XBGervejqmuxiC4yiHHG20OQPOUjU'
    ),
    body    := '{}'::jsonb
  );
  $$
);

-- 設定確認
SELECT jobname, schedule, command FROM cron.job WHERE jobname LIKE 'x-reward%';
