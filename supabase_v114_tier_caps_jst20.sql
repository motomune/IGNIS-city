-- v114: 人生ゲーム/アリゲーム報酬を「会員ティア別の1日上限」＋「日本時間20:00リセット」に変更
--   ・1日の反映上限（各ゲームごと）：無課金30 / サブスク40 / プレミア60
--   ・「1日」の境界は日本時間(JST)の20:00。20:00 JSTで再び獲得できる。
--   ・ゲームデー判定式： ((ts AT TIME ZONE 'Asia/Tokyo') - interval '20 hours')::date
--     → 20:00より前は前日、20:00以降は当日として扱われる。
--   ・ティアは users.is_premium / is_subscribed を参照（SECURITY DEFINER で本人行を読む）。

CREATE OR REPLACE FUNCTION claim_lifegame_reward(p_coins integer, p_ending text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_gameday date := ((now() AT TIME ZONE 'Asia/Tokyo') - interval '20 hours')::date;
  v_cap     integer;
  v_sub     boolean;
  v_prem    boolean;
  v_grant   integer;
  v_capped  boolean;
  v_done    boolean;
  v_total   integer;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  SELECT COALESCE(is_subscribed,false), COALESCE(is_premium,false)
    INTO v_sub, v_prem FROM users WHERE id = v_uid;
  v_cap := CASE WHEN v_prem THEN 60 WHEN v_sub THEN 40 ELSE 30 END;

  -- 当日（JST20時境界）すでに受け取り済みか
  SELECT EXISTS(
    SELECT 1 FROM coins
    WHERE user_id = v_uid
      AND reason LIKE 'lifegame%'
      AND ((created_at AT TIME ZONE 'Asia/Tokyo') - interval '20 hours')::date = v_gameday
  ) INTO v_done;
  IF v_done THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_today');
  END IF;

  -- サーバー側でキャップ（クライアントの coins 値は信用しない）
  v_grant  := LEAST(GREATEST(COALESCE(p_coins, 0), 0), v_cap);
  v_capped := COALESCE(p_coins, 0) > v_cap;

  IF v_grant <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'zero_amount');
  END IF;

  UPDATE users
     SET coin_column = COALESCE(coin_column, 0) + v_grant
   WHERE id = v_uid
   RETURNING coin_column INTO v_total;

  INSERT INTO coins(user_id, amount, reason)
  VALUES (v_uid, v_grant,
          'lifegame' || COALESCE(':' || NULLIF(regexp_replace(COALESCE(p_ending,''), '[^a-z_]', '', 'g'), ''), ''));

  RETURN jsonb_build_object(
    'ok', true, 'granted', v_grant, 'total', v_total,
    'capped', v_capped, 'cap', v_cap, 'ending', p_ending
  );
END $$;

GRANT EXECUTE ON FUNCTION claim_lifegame_reward(integer, text) TO authenticated;


CREATE OR REPLACE FUNCTION claim_antgame_reward(p_today_total integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_gameday date := ((now() AT TIME ZONE 'Asia/Tokyo') - interval '20 hours')::date;
  v_cap     integer;
  v_sub     boolean;
  v_prem    boolean;
  v_target  integer;
  v_already integer;
  v_grant   integer;
  v_total   integer;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  SELECT COALESCE(is_subscribed,false), COALESCE(is_premium,false)
    INTO v_sub, v_prem FROM users WHERE id = v_uid;
  v_cap := CASE WHEN v_prem THEN 60 WHEN v_sub THEN 40 ELSE 30 END;

  -- その日（JST20時境界）の反映目標 = min(獲得累計, ティア上限)
  v_target := LEAST(GREATEST(COALESCE(p_today_total, 0), 0), v_cap);

  -- 今日（JST20時境界）すでにアリゲームで付与済みの合計
  SELECT COALESCE(SUM(amount), 0) INTO v_already
  FROM coins
  WHERE user_id = v_uid AND reason LIKE 'antgame%'
    AND ((created_at AT TIME ZONE 'Asia/Tokyo') - interval '20 hours')::date = v_gameday;

  v_grant := GREATEST(0, v_target - v_already);

  IF v_grant <= 0 THEN
    SELECT coin_column INTO v_total FROM users WHERE id = v_uid;
    RETURN jsonb_build_object('ok', true, 'granted', 0, 'total', v_total, 'claimed_today', v_already, 'cap', v_cap);
  END IF;

  UPDATE users SET coin_column = COALESCE(coin_column, 0) + v_grant
   WHERE id = v_uid RETURNING coin_column INTO v_total;
  INSERT INTO coins(user_id, amount, reason) VALUES (v_uid, v_grant, 'antgame');

  RETURN jsonb_build_object('ok', true, 'granted', v_grant, 'total', v_total,
    'claimed_today', v_already + v_grant, 'cap', v_cap);
END $$;

GRANT EXECUTE ON FUNCTION claim_antgame_reward(integer) TO authenticated;
