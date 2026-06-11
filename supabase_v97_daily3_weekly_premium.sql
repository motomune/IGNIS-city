-- v97: 蝋燭1日3本 / 週間共同クエスト / 夜明け回数 / 創設者ビルの過去詳細を無課金開放 / プレミアム会員枠
--   ※ v96 (supabase_v96_resonance_reply_dawn_hall.sql) を先に実行してください。

-- ============================================================
-- 1) city_state に「夜明け回数」「週間クエスト目標」を追加
-- ============================================================
ALTER TABLE public.city_state
  ADD COLUMN IF NOT EXISTS dawn_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS weekly_goal integer NOT NULL DEFAULT 20;

-- ============================================================
-- 2) toggle_candle 改：蝋燭は1人1日3本まで（報酬は従来どおり1日1回）
--    夜明け開始時に dawn_count を加算
-- ============================================================
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
  v_given_today integer;
  v_state city_state;
  v_total integer;
  v_dawn_started boolean := false;
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
    -- 1人1日3本まで（今日灯した本数で判定。消すと枠は戻る）
    SELECT COUNT(*) INTO v_given_today
    FROM building_candles
    WHERE user_id = v_uid AND (created_at AT TIME ZONE 'utc')::date = v_today;
    IF v_given_today >= 3 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'daily_limit');
    END IF;

    INSERT INTO building_candles(user_id, building_x, building_z) VALUES(v_uid, bx, bz);
    v_lit := true;
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

    -- 夜明け判定：合計が「前回夜明け時点＋基準」に達したら24時間の夜明け開始（回数も記録）
    SELECT * INTO v_state FROM city_state WHERE id = 1 FOR UPDATE;
    SELECT COUNT(*) INTO v_total FROM building_candles;
    IF (v_state.dawn_until IS NULL OR v_state.dawn_until <= now())
       AND v_total >= v_state.last_dawn_total + v_state.dawn_threshold THEN
      UPDATE city_state
        SET dawn_until = now() + interval '24 hours',
            last_dawn_total = v_total,
            dawn_count = COALESCE(dawn_count, 0) + 1
        WHERE id = 1;
      v_dawn_started := true;
    END IF;
  END IF;

  SELECT COUNT(*) INTO v_count FROM building_candles WHERE building_x = bx AND building_z = bz;
  RETURN jsonb_build_object('ok', true, 'lit', v_lit, 'count', v_count, 'reward', v_reward, 'dawn_started', v_dawn_started);
END;
$$;
GRANT EXECUTE ON FUNCTION toggle_candle(integer, integer) TO authenticated;

-- ============================================================
-- 3) get_city_dawn 改：夜明け回数＋週間クエスト進捗も返す（HUD用）
-- ============================================================
CREATE OR REPLACE FUNCTION get_city_dawn()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_state city_state;
  v_total integer;
  v_week integer;
BEGIN
  SELECT * INTO v_state FROM city_state WHERE id = 1;
  SELECT COUNT(*) INTO v_total FROM building_candles;
  SELECT COUNT(*) INTO v_week FROM building_candles WHERE created_at >= date_trunc('week', now());
  RETURN jsonb_build_object(
    'dawn_until', v_state.dawn_until,
    'is_dawn', (v_state.dawn_until IS NOT NULL AND v_state.dawn_until > now()),
    'progress', GREATEST(0, v_total - v_state.last_dawn_total),
    'threshold', v_state.dawn_threshold,
    'total', v_total,
    'dawn_count', COALESCE(v_state.dawn_count, 0),
    'week_progress', v_week,
    'weekly_goal', COALESCE(v_state.weekly_goal, 20)
  );
END;
$$;
GRANT EXECUTE ON FUNCTION get_city_dawn() TO authenticated;

-- ============================================================
-- 4) 週間共同クエスト：今週の街全体の蝋燭が目標に達したら、
--    今週蝋燭を灯した人に +10コイン（週1回。coins台帳 reason='weekly_quest' で判定）
-- ============================================================
CREATE OR REPLACE FUNCTION claim_weekly_quest()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_goal integer;
  v_week integer;
  v_lit_this_week boolean;
  v_claimed boolean;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('granted', false, 'reason', 'not_authenticated'); END IF;
  SELECT COALESCE(weekly_goal, 20) INTO v_goal FROM city_state WHERE id = 1;
  SELECT COUNT(*) INTO v_week FROM building_candles WHERE created_at >= date_trunc('week', now());
  IF v_week < v_goal THEN
    RETURN jsonb_build_object('granted', false, 'reason', 'not_reached', 'progress', v_week, 'goal', v_goal);
  END IF;
  SELECT EXISTS(
    SELECT 1 FROM building_candles
    WHERE user_id = v_uid AND created_at >= date_trunc('week', now())
  ) INTO v_lit_this_week;
  IF NOT v_lit_this_week THEN
    RETURN jsonb_build_object('granted', false, 'reason', 'not_participant');
  END IF;
  SELECT EXISTS(
    SELECT 1 FROM coins
    WHERE user_id = v_uid AND reason = 'weekly_quest'
      AND created_at >= date_trunc('week', now())
  ) INTO v_claimed;
  IF v_claimed THEN
    RETURN jsonb_build_object('granted', false, 'reason', 'already_claimed');
  END IF;
  UPDATE users SET coin_column = COALESCE(coin_column, 0) + 10 WHERE id = v_uid;
  INSERT INTO coins(user_id, amount, reason) VALUES(v_uid, 10, 'weekly_quest');
  RETURN jsonb_build_object('granted', true, 'amount', 10);
END;
$$;
GRANT EXECUTE ON FUNCTION claim_weekly_quest() TO authenticated;

-- ============================================================
-- 5) 創設者ビルの過去詳細③〜⑥は無課金でも全文閲覧できる
-- ============================================================
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
  v_creator uuid := 'afc818cd-d2fa-4c1c-8460-9dbce9e60e37';  -- 創設者UUID
BEGIN
  SELECT * INTO v_row FROM building_past_details
  WHERE building_x = bx AND building_z = bz AND status = 'approved';
  IF NOT FOUND THEN RETURN NULL; END IF;
  -- 創設者のビルは誰でも全文OK。それ以外はサブスク会員のみ
  IF v_row.user_id <> v_creator THEN
    SELECT is_subscribed INTO v_subscribed FROM users WHERE id = v_uid;
    IF NOT COALESCE(v_subscribed, false) THEN
      RETURN jsonb_build_object('error','subscription_required');
    END IF;
  END IF;
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

-- ============================================================
-- 6) プレミアム会員（上位課金）：X宣伝枠
--    is_premium=true のユーザーのXユーザー名を返す（宣伝バー用）
--    プレミアム付与は管理者がSQLで: UPDATE users SET is_premium=true WHERE x_username='...';
-- ============================================================
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS is_premium boolean DEFAULT false;

CREATE OR REPLACE FUNCTION get_premium_promos()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(jsonb_agg(x_username ORDER BY x_username), '[]'::jsonb)
  FROM users
  WHERE is_premium = true AND x_username IS NOT NULL AND x_username <> '';
$$;
GRANT EXECUTE ON FUNCTION get_premium_promos() TO authenticated;
