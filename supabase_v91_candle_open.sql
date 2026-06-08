-- v91: 蝋燭(candle)を全ログインユーザーが灯せるように（サブスク限定を解除）。
-- 自分のビルには灯せない（own_building を返す）。building_candles / RLS は v54 のまま。

CREATE OR REPLACE FUNCTION toggle_candle(bx integer, bz integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_count integer;
  v_already boolean;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;
  -- 自分が所有するビルには灯せない
  IF EXISTS(SELECT 1 FROM buildings WHERE x = bx AND z = bz AND owner_id = v_uid) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'own_building');
  END IF;
  SELECT EXISTS(
    SELECT 1 FROM building_candles
    WHERE user_id = v_uid AND building_x = bx AND building_z = bz
  ) INTO v_already;
  IF v_already THEN
    DELETE FROM building_candles WHERE user_id = v_uid AND building_x = bx AND building_z = bz;
  ELSE
    INSERT INTO building_candles(user_id, building_x, building_z) VALUES(v_uid, bx, bz);
  END IF;
  SELECT COUNT(*) INTO v_count FROM building_candles WHERE building_x = bx AND building_z = bz;
  RETURN jsonb_build_object('ok', true, 'lit', NOT v_already, 'count', v_count);
END;
$$;

GRANT EXECUTE ON FUNCTION toggle_candle(integer, integer) TO authenticated;
