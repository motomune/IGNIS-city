-- v103: 全会員（サブスク＋プレミアム）の user_id を返す安全なRPC（屋上ランプを全員に付けるため）
--   会員フラグ自体は露出せず、idの集合だけ返す。RLSで他人のusers行が読めない環境でも全員分を取得できる。
-- ※ 2026-06-14 にClaude CodeからAPI経由で適用済み。このファイルは記録用。

CREATE OR REPLACE FUNCTION get_member_ids()
RETURNS SETOF uuid
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT id FROM users WHERE is_subscribed = true OR is_premium = true;
$$;
GRANT EXECUTE ON FUNCTION get_member_ids() TO authenticated;
