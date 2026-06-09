-- v92: 蝋燭をサブスク会員限定に戻し、報酬を付与する。
--   - 灯せるのはサブスク会員のみ（自分のビルは不可）
--   - 1棟につき1本（UNIQUE制約）。再押しで取り消し可（報酬は戻さない）
--   - 灯すと「その日初回だけ」コイン+5・従業員(bench)+1（何本配っても1日この上限）
--   - coins台帳に reason='candle_give' で記録し、当日分の有無で日次上限を判定

CREATE OR REPLACE FUNCTION toggle_candle(bx integer, bz integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_subscribed boolean;
  v_count integer;
  v_already boolean;
  v_lit boolean;
  v_reward boolean := false;
  v_today date := (now() AT TIME ZONE 'utc')::date;
  v_got_today boolean;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;
  SELECT is_subscribed INTO v_subscribed FROM users WHERE id = v_uid;
  IF NOT COALESCE(v_subscribed, false) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'subscription_required');
  END IF;
  IF EXISTS(SELECT 1 FROM buildings WHERE x = bx AND z = bz AND owner_id = v_uid) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'own_building');
  END IF;

  SELECT EXISTS(
    SELECT 1 FROM building_candles
    WHERE user_id = v_uid AND building_x = bx AND building_z = bz
  ) INTO v_already;

  IF v_already THEN
    DELETE FROM building_candles WHERE user_id = v_uid AND building_x = bx AND building_z = bz;
    v_lit := false;
  ELSE
    INSERT INTO building_candles(user_id, building_x, building_z) VALUES(v_uid, bx, bz);
    v_lit := true;
    -- 当日まだ蝋燭報酬を受けていなければ コイン+5・従業員+1
    SELECT EXISTS(
      SELECT 1 FROM coins
      WHERE user_id = v_uid AND reason = 'candle_give'
        AND (created_at AT TIME ZONE 'utc')::date = v_today
    ) INTO v_got_today;
    IF NOT v_got_today THEN
      UPDATE users
        SET coin_column = COALESCE(coin_column, 0) + 5,
            bench_employees = COALESCE(bench_employees, 0) + 1
        WHERE id = v_uid;
      INSERT INTO coins(user_id, amount, reason) VALUES(v_uid, 5, 'candle_give');
      v_reward := true;
    END IF;
  END IF;

  SELECT COUNT(*) INTO v_count FROM building_candles WHERE building_x = bx AND building_z = bz;
  RETURN jsonb_build_object('ok', true, 'lit', v_lit, 'count', v_count, 'reward', v_reward);
END;
$$;

GRANT EXECUTE ON FUNCTION toggle_candle(integer, integer) TO authenticated;
