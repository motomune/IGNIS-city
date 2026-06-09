-- v95: 過去詳細を6項目化（③背景と経緯/④自身の対応/⑤どうなったか/⑥生まれ変わったら）
--   ③ background_detail / ④ how_handled / ⑤ what_happened_after / ⑥ journey_to_now（既存列を流用）
--   英訳キャッシュ列 *_en を追加し、get_past_detail_full を6項目対応に更新。

ALTER TABLE public.building_past_details
  ADD COLUMN IF NOT EXISTS how_handled_en text,
  ADD COLUMN IF NOT EXISTS what_happened_after_en text,
  ADD COLUMN IF NOT EXISTS journey_to_now_en text;
-- background_detail_en は v89 で追加済み。current_positive は未使用に。

-- 課金者のみ閲覧できる本文（③〜⑥）＋英訳を返す
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
    'lost_items',                v_row.lost_items,
    'gained_items',              v_row.gained_items,
    'background_detail',         v_row.background_detail,
    'background_detail_en',      v_row.background_detail_en,
    'how_handled',               v_row.how_handled,
    'how_handled_en',            v_row.how_handled_en,
    'what_happened_after',       v_row.what_happened_after,
    'what_happened_after_en',    v_row.what_happened_after_en,
    'journey_to_now',            v_row.journey_to_now,
    'journey_to_now_en',         v_row.journey_to_now_en
  );
END;
$$;
GRANT EXECUTE ON FUNCTION get_past_detail_full(integer, integer) TO authenticated;
