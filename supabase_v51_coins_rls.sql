-- v51: RLS policies for coins table
-- coins テーブルに SELECT / INSERT ポリシーを追加する
-- ※ RLS は既に ENABLED のため、POLICY の追加のみ実行する

-- 自分のコイン履歴だけ読める
CREATE POLICY "coins_select_own" ON public.coins
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- 自分のコイン履歴だけ書ける
CREATE POLICY "coins_insert_own" ON public.coins
  FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);
