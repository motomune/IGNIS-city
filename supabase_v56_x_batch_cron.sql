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
