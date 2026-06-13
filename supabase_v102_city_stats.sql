-- v102: 街の広告塔用の公開統計RPC（今月のログイン人数＝同一人物は1カウント）
-- ※ 2026-06-13 にClaude CodeからAPI経由で適用済み。このファイルは記録用。
--    あわせて創設者(soultamash81989)に is_premium=true を設定済み。

CREATE OR REPLACE FUNCTION get_city_stats()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT jsonb_build_object(
    'monthly_logins',
    (SELECT COUNT(DISTINCT user_id) FROM daily_tasks
     WHERE task_type = 'login' AND completed = true
       AND task_date >= date_trunc('month', now())::date)
  );
$fn$;
GRANT EXECUTE ON FUNCTION get_city_stats() TO authenticated;
