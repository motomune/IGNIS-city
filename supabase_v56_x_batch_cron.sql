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
    url     := 'https://YOUR_PROJECT_REF.supabase.co/functions/v1/x-reward-batch',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer YOUR_ANON_KEY'
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
    url     := 'https://YOUR_PROJECT_REF.supabase.co/functions/v1/x-reward-batch',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer YOUR_ANON_KEY'
    ),
    body    := '{}'::jsonb
  );
  $$
);

-- 設定確認
SELECT jobname, schedule, command FROM cron.job WHERE jobname LIKE 'x-reward%';
