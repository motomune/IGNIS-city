-- v53: building_past_details table + is_subscribed flag

-- ユーザーのサブスク状態フラグを追加
ALTER TABLE users ADD COLUMN IF NOT EXISTS is_subscribed boolean DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS subscribed_until timestamptz;

-- 過去詳細テーブル
CREATE TABLE IF NOT EXISTS building_past_details (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  building_x integer NOT NULL,
  building_z integer NOT NULL,
  -- ① 何を失ったか（複数選択）
  lost_items text[] DEFAULT '{}',
  -- ② 今どうなっているか
  current_positive text,
  current_stage text CHECK (current_stage IN ('recovering','stable','growing','new_challenge')),
  -- ③〜⑥ 課金者のみ閲覧可能
  background_detail text,
  how_handled text,
  what_happened_after text,
  journey_to_now text,
  -- 管理
  status text DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  rejected_reason text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  UNIQUE(building_x, building_z)
);

ALTER TABLE building_past_details ENABLE ROW LEVEL SECURITY;

-- 自分のレコードは全フィールド読み書き可
CREATE POLICY "past_details_select_own" ON building_past_details
  FOR SELECT TO authenticated USING (auth.uid() = user_id);

CREATE POLICY "past_details_insert_own" ON building_past_details
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

CREATE POLICY "past_details_update_own" ON building_past_details
  FOR UPDATE TO authenticated USING (auth.uid() = user_id);

-- 承認済みの①②は全認証ユーザーが読める（③〜⑥はRPCで制御）
CREATE POLICY "past_details_select_approved_public" ON building_past_details
  FOR SELECT TO authenticated
  USING (status = 'approved');

-- 承認済み①②取得RPC（無課金者用）
CREATE OR REPLACE FUNCTION get_past_detail_preview(bx integer, bz integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row building_past_details;
BEGIN
  SELECT * INTO v_row FROM building_past_details
  WHERE building_x = bx AND building_z = bz AND status = 'approved';
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'lost_items', v_row.lost_items,
    'current_positive', v_row.current_positive,
    'current_stage', v_row.current_stage
  );
END;
$$;

-- 承認済み全フィールド取得RPC（課金者用）
CREATE OR REPLACE FUNCTION get_past_detail_full(bx integer, bz integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_row building_past_details;
  v_subscribed boolean;
BEGIN
  -- 課金者確認
  SELECT is_subscribed INTO v_subscribed FROM users WHERE id = v_uid;
  IF NOT COALESCE(v_subscribed, false) THEN
    RETURN jsonb_build_object('error','subscription_required');
  END IF;
  SELECT * INTO v_row FROM building_past_details
  WHERE building_x = bx AND building_z = bz AND status = 'approved';
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'lost_items', v_row.lost_items,
    'current_positive', v_row.current_positive,
    'current_stage', v_row.current_stage,
    'background_detail', v_row.background_detail,
    'how_handled', v_row.how_handled,
    'what_happened_after', v_row.what_happened_after,
    'journey_to_now', v_row.journey_to_now
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_past_detail_preview(integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION get_past_detail_full(integer, integer) TO authenticated;
