-- =====================================================================
-- v84: building_inventory（未設置ビルの在庫）
-- 目的: ガチャ（スクラッチ）で獲得したビルを「未設置の在庫」として保存し、
--       土地の「設置」ボタンから在庫を選んで配置できるようにする。
-- 適用: Supabase ダッシュボード → SQL Editor に貼り付けて Run（冪等）。
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.building_inventory (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL,
  prism      text NOT NULL,                 -- 'square' | 'triangle' | 'cylinder'
  floors     integer NOT NULL CHECK (floors >= 1 AND floors <= 50),
  star       integer,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_building_inventory_user
  ON public.building_inventory(user_id, created_at DESC);

-- RLS: 本人の在庫だけ read / insert / delete 可能
ALTER TABLE public.building_inventory ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "inv_select_own" ON public.building_inventory;
CREATE POLICY "inv_select_own" ON public.building_inventory
  FOR SELECT TO authenticated USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "inv_insert_own" ON public.building_inventory;
CREATE POLICY "inv_insert_own" ON public.building_inventory
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "inv_delete_own" ON public.building_inventory;
CREATE POLICY "inv_delete_own" ON public.building_inventory
  FOR DELETE TO authenticated USING (auth.uid() = user_id);
