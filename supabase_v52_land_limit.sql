-- v52: Enforce 2-land limit per user in buy_land RPC

CREATE OR REPLACE FUNCTION buy_land(gx integer, gz integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_coins integer;
  v_land_cost integer := 100;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  -- 1人あたり最大2面まで
  IF (SELECT COUNT(*) FROM lands WHERE owner_id = v_user_id) >= 2 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'land_limit_reached');
  END IF;

  IF EXISTS (SELECT 1 FROM lands WHERE grid_x = gx AND grid_z = gz) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_owned');
  END IF;

  SELECT coin_column INTO v_coins FROM users WHERE id = v_user_id FOR UPDATE;
  IF COALESCE(v_coins, 0) < v_land_cost THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'insufficient_coins', 'coins', COALESCE(v_coins, 0), 'need', v_land_cost);
  END IF;

  -- ロック後の再チェック（二重購入防止）
  IF EXISTS (SELECT 1 FROM lands WHERE grid_x = gx AND grid_z = gz) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_owned');
  END IF;
  IF (SELECT COUNT(*) FROM lands WHERE owner_id = v_user_id) >= 2 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'land_limit_reached');
  END IF;

  INSERT INTO lands (grid_x, grid_z, owner_id) VALUES (gx, gz, v_user_id);
  UPDATE users SET coin_column = coin_column - v_land_cost WHERE id = v_user_id
  RETURNING coin_column INTO v_coins;

  RETURN jsonb_build_object('ok', true, 'coins_remaining', v_coins, 'cost', v_land_cost);
END;
$$;

GRANT EXECUTE ON FUNCTION buy_land(integer, integer) TO authenticated;
