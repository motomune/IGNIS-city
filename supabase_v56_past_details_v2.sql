-- v56: building_past_details に gained_items カラム追加
-- ②「現在何を得たか/得ようとしているか」の複数選択用

ALTER TABLE building_past_details
  ADD COLUMN IF NOT EXISTS gained_items text[] DEFAULT '{}';

-- ③ background_detail を 300 文字詳細として再利用
-- ④ current_positive を「読者に伝えたいこと」50文字として再利用
-- （カラム名はそのまま、UI 側で意味を付け直す）

-- 既存の get_past_detail_preview / get_past_detail_full を gained_items 対応に更新

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
    'lost_items',       v_row.lost_items,
    'gained_items',     v_row.gained_items,
    'background_detail',v_row.background_detail,
    'current_positive', v_row.current_positive
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_past_detail_preview(integer, integer) TO authenticated;

-- get_past_detail_full も gained_items 対応
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
  SELECT is_subscribed INTO v_subscribed FROM users WHERE id = v_uid;
  IF NOT COALESCE(v_subscribed, false) THEN
    RETURN jsonb_build_object('error','subscription_required');
  END IF;
  SELECT * INTO v_row FROM building_past_details
  WHERE building_x = bx AND building_z = bz AND status = 'approved';
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'lost_items', v_row.lost_items,
    'gained_items', v_row.gained_items,
    'current_positive', v_row.current_positive,
    'current_stage', v_row.current_stage,
    'background_detail', v_row.background_detail,
    'how_handled', v_row.how_handled,
    'what_happened_after', v_row.what_happened_after,
    'journey_to_now', v_row.journey_to_now
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_past_detail_full(integer, integer) TO authenticated;

-- 管理者が過去詳細を承認できるよう RLS（既に適用済みの場合はスキップ可）
DO $$ BEGIN
  CREATE POLICY "past_details_admin_read_all" ON building_past_details
    FOR SELECT TO authenticated
    USING (auth.uid() = 'afc818cd-d2fa-4c1c-8460-9dbce9e60e37'::uuid);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "past_details_admin_update_all" ON building_past_details
    FOR UPDATE TO authenticated
    USING (auth.uid() = 'afc818cd-d2fa-4c1c-8460-9dbce9e60e37'::uuid);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
