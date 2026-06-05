-- =====================================================================
-- v81: Enable Row Level Security (RLS) on the remaining public tables
-- 目的: 公開 anon キーだけでデータを読み書き削除できる穴を塞ぐ。
--   方針: 表示に必要な SELECT は今まで通り許可（ゲームを壊さない）、
--          書き込み/削除は「本人のみ」に限定。特権処理は SECURITY DEFINER
--          の RPC が RLS を迂回するのでそのまま動く。
-- 適用: Supabase ダッシュボード → SQL Editor に貼り付けて実行。
-- ロールバック: 末尾のコメント参照（テーブル単位で DISABLE できる）。
-- 何度でも再実行可能（DROP POLICY IF EXISTS で冪等）。
-- =====================================================================

-- 管理者（admin.html でログインする承認担当）の UID
-- afc818cd-d2fa-4c1c-8460-9dbce9e60e37

-- ---------------------------------------------------------------------
-- 0) レガシー（緩い）ポリシーの削除  ★必ず先に実行★
--    RLS ポリシーは OR 結合（permissive）。古い「全員許可」系が1つでも
--    残ると、下の制限ポリシーを無効化して穴が残る。先に必ず消すこと。
--    ↓は実際の適用時に存在した名前（IF EXISTS なので安全に再実行可）。
--    名前は環境依存のため、適用後に pg_policies 監査で
--    「anon の insert/update/delete ポリシーが 0 件」を必ず確認する。
-- ---------------------------------------------------------------------
DROP POLICY IF EXISTS "Allow public insert" ON public.buildings;
DROP POLICY IF EXISTS "Enable read access for all users" ON public.buildings;
DROP POLICY IF EXISTS "Enable read access for all users" ON public.users;
DROP POLICY IF EXISTS "lands_insert" ON public.lands;
DROP POLICY IF EXISTS "lands_select" ON public.lands;
DROP POLICY IF EXISTS "own insert" ON public.building_profiles;
DROP POLICY IF EXISTS "own read" ON public.building_profiles;
DROP POLICY IF EXISTS "own update" ON public.building_profiles;
DROP POLICY IF EXISTS "public read approved" ON public.building_profiles;
DROP POLICY IF EXISTS "admin read all" ON public.building_profiles;
-- daily_tasks / game_invites / game_referrals / staff_employees にも旧ポリシーが
-- あれば削除（旧名は環境依存。適用時に削除済み。残っていれば pg_policies で
-- 確認して `DROP POLICY IF EXISTS "<名前>" ON public.<テーブル>;` で個別削除）。

-- ---------------------------------------------------------------------
-- buildings : 街の表示に必要 → 全員 read 可 / 書き込みは所有者のみ
-- ---------------------------------------------------------------------
ALTER TABLE public.buildings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "buildings_select_public" ON public.buildings;
CREATE POLICY "buildings_select_public" ON public.buildings
  FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "buildings_insert_own" ON public.buildings;
CREATE POLICY "buildings_insert_own" ON public.buildings
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = owner_id);

DROP POLICY IF EXISTS "buildings_update_own" ON public.buildings;
CREATE POLICY "buildings_update_own" ON public.buildings
  FOR UPDATE TO authenticated USING (auth.uid() = owner_id) WITH CHECK (auth.uid() = owner_id);

DROP POLICY IF EXISTS "buildings_delete_own" ON public.buildings;
CREATE POLICY "buildings_delete_own" ON public.buildings
  FOR DELETE TO authenticated USING (auth.uid() = owner_id);

-- ---------------------------------------------------------------------
-- lands : 街の表示に必要 → 全員 read 可 / 書き込みは所有者のみ
-- ---------------------------------------------------------------------
ALTER TABLE public.lands ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "lands_select_public" ON public.lands;
CREATE POLICY "lands_select_public" ON public.lands
  FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "lands_insert_own" ON public.lands;
CREATE POLICY "lands_insert_own" ON public.lands
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = owner_id);

DROP POLICY IF EXISTS "lands_update_own" ON public.lands;
CREATE POLICY "lands_update_own" ON public.lands
  FOR UPDATE TO authenticated USING (auth.uid() = owner_id) WITH CHECK (auth.uid() = owner_id);

DROP POLICY IF EXISTS "lands_delete_own" ON public.lands;
CREATE POLICY "lands_delete_own" ON public.lands
  FOR DELETE TO authenticated USING (auth.uid() = owner_id);

-- ---------------------------------------------------------------------
-- users : ビルの所有者名表示に必要 → read は許可 / 書き込みは本人のみ
--   ※ read を全員許可しているため coins 等の列も公開されます。
--     より厳密にしたい場合は「安全な列だけのビュー」を別途用意推奨（下部メモ）。
-- ---------------------------------------------------------------------
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "users_select_public" ON public.users;
CREATE POLICY "users_select_public" ON public.users
  FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "users_insert_self" ON public.users;
CREATE POLICY "users_insert_self" ON public.users
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = id);

DROP POLICY IF EXISTS "users_update_self" ON public.users;
CREATE POLICY "users_update_self" ON public.users
  FOR UPDATE TO authenticated USING (auth.uid() = id) WITH CHECK (auth.uid() = id);

-- ---------------------------------------------------------------------
-- building_profiles : 承認済みは全員に表示 / 申請中は本人だけ /
--                     書き込みは本人 + 管理者（承認のため）
-- ---------------------------------------------------------------------
ALTER TABLE public.building_profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "bprofiles_select_approved_or_own" ON public.building_profiles;
CREATE POLICY "bprofiles_select_approved_or_own" ON public.building_profiles
  FOR SELECT TO anon, authenticated
  USING (status = 'approved'
         OR auth.uid() = user_id
         OR auth.uid() = 'afc818cd-d2fa-4c1c-8460-9dbce9e60e37');

DROP POLICY IF EXISTS "bprofiles_insert_own" ON public.building_profiles;
CREATE POLICY "bprofiles_insert_own" ON public.building_profiles
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "bprofiles_update_own_or_admin" ON public.building_profiles;
CREATE POLICY "bprofiles_update_own_or_admin" ON public.building_profiles
  FOR UPDATE TO authenticated
  USING (auth.uid() = user_id OR auth.uid() = 'afc818cd-d2fa-4c1c-8460-9dbce9e60e37')
  WITH CHECK (auth.uid() = user_id OR auth.uid() = 'afc818cd-d2fa-4c1c-8460-9dbce9e60e37');

-- ---------------------------------------------------------------------
-- daily_tasks : 本人の進捗のみ
-- ---------------------------------------------------------------------
ALTER TABLE public.daily_tasks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tasks_select_own" ON public.daily_tasks;
CREATE POLICY "tasks_select_own" ON public.daily_tasks
  FOR SELECT TO authenticated USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "tasks_insert_own" ON public.daily_tasks;
CREATE POLICY "tasks_insert_own" ON public.daily_tasks
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "tasks_update_own" ON public.daily_tasks;
CREATE POLICY "tasks_update_own" ON public.daily_tasks
  FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- ---------------------------------------------------------------------
-- game_invites : 本人（招待主）のみ read / insert
-- ---------------------------------------------------------------------
ALTER TABLE public.game_invites ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "invites_select_own" ON public.game_invites;
CREATE POLICY "invites_select_own" ON public.game_invites
  FOR SELECT TO authenticated USING (auth.uid() = inviter_id);

DROP POLICY IF EXISTS "invites_insert_own" ON public.game_invites;
CREATE POLICY "invites_insert_own" ON public.game_invites
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = inviter_id);

-- ---------------------------------------------------------------------
-- 以下は直接の書き込みが無く RPC（SECURITY DEFINER）経由で更新される表。
-- RLS を有効化し、read だけ本人に許可。書き込みポリシーは付けない
-- （= 直接の anon 書き込みは拒否、RPC は RLS を迂回するので動作継続）。
-- ---------------------------------------------------------------------

-- staff_employees : 本人の従業員のみ read
ALTER TABLE public.staff_employees ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "staff_select_own" ON public.staff_employees;
CREATE POLICY "staff_select_own" ON public.staff_employees
  FOR SELECT TO authenticated USING (auth.uid() = user_id);

-- game_referrals : 本人（招待主）のみ read
ALTER TABLE public.game_referrals ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "referrals_select_own" ON public.game_referrals;
CREATE POLICY "referrals_select_own" ON public.game_referrals
  FOR SELECT TO authenticated USING (auth.uid() = inviter_id);

-- game_invite_send_rewards : 本人（招待主）のみ read
ALTER TABLE public.game_invite_send_rewards ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "invite_rewards_select_own" ON public.game_invite_send_rewards;
CREATE POLICY "invite_rewards_select_own" ON public.game_invite_send_rewards
  FOR SELECT TO authenticated USING (auth.uid() = inviter_id);

-- building_views : 本人の閲覧記録のみ read（表示用カウントは buildings.view_count）
ALTER TABLE public.building_views ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "bviews_select_own" ON public.building_views;
CREATE POLICY "bviews_select_own" ON public.building_views
  FOR SELECT TO authenticated USING (auth.uid() = viewer_id);

-- ---------------------------------------------------------------------
-- x_batch_config : バッチ設定（launch_date, founder_x_id, last_batch_at 等）。
--   アプリ(index.html/admin.html)からは参照していない → Edge Function 専用。
--   RLS 有効化 + ポリシー無し = anon/authenticated とも直接アクセス不可。
--   Edge Function は service_role なので RLS を迂回してバッチは動作継続。
--   （監査で判明: このテーブルだけ RLS 無効で設定値が anon に見えていた）
-- ---------------------------------------------------------------------
ALTER TABLE public.x_batch_config ENABLE ROW LEVEL SECURITY;

-- =====================================================================
-- ロールバック（もし特定の機能が動かなくなったら、その表だけ戻す）:
--   ALTER TABLE public.<table> DISABLE ROW LEVEL SECURITY;
--
-- もし RPC 経由の処理（採用・売却・閲覧記録・紹介付与）が失敗する場合、
-- その RPC 関数が SECURITY DEFINER になっているか確認してください。
-- なっていれば RLS を迂回するので問題なく動作します。
-- =====================================================================
