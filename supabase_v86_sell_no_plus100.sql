-- =====================================================================
-- v86: 売却報酬から +100 を撤廃
-- 変更前: floors × multiplier + 100
-- 変更後: floors × multiplier
-- sell_building RPC はこの関数を呼ぶので、関数を差し替えるだけで反映される。
-- 適用: Supabase ダッシュボード → SQL Editor に貼り付けて Run（冪等）。
-- =====================================================================

CREATE OR REPLACE FUNCTION calc_sell_coin_reward(floors integer, emp integer)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT GREATEST(0, ROUND(COALESCE(floors, 0) * calc_sell_coin_multiplier(emp))::integer);
$$;
