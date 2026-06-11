-- v96: 共鳴マップ / 蝋燭への返事 / 夜明けイベント / 再生の殿堂 / 中央保護区
--   1) get_resonance_map: 承認済み過去詳細の「失ったもの」チップを全ビル分返す（ミニマップ共鳴表示用）
--   2) candle_replies: ビルオーナーが蝋燭をくれた人へ定型文で返事。返事を受けた側は従業員+1（1日最大1回）
--   3) city_state + toggle_candle改: 蝋燭の合計が基準に達すると24時間「夜明け」になり、明けたら次の基準へ
--   4) get_monthly_hall: 当月最多蝋燭のビル（再生の殿堂）を返す
--   5) buy_land改: 中央(0,0)から周囲2マス（|x|<=20, |z|<=20）は新規購入不可（既存の所有地はそのまま）

-- ============================================================
-- 1) 共鳴マップ：承認済みの「失ったもの」チップを全ビル分
-- ============================================================
CREATE OR REPLACE FUNCTION get_resonance_map()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'x', building_x,
    'z', building_z,
    'lost', to_jsonb(lost_items)
  )), '[]'::jsonb)
  FROM building_past_details
  WHERE status = 'approved'
    AND lost_items IS NOT NULL
    AND array_length(lost_items, 1) > 0;
$$;
GRANT EXECUTE ON FUNCTION get_resonance_map() TO authenticated;

-- ============================================================
-- 2) 蝋燭への返事（定型文のみ・1本につき1返事）
-- ============================================================
CREATE TABLE IF NOT EXISTS candle_replies (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  building_x integer NOT NULL,
  building_z integer NOT NULL,
  owner_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  giver_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  phrase text NOT NULL,              -- 定型文キー: thanks / not_alone / warmth / keep_going
  seen boolean DEFAULT false,        -- 受け取った側（蝋燭をあげた人）が確認したか
  created_at timestamptz DEFAULT now(),
  UNIQUE(building_x, building_z, giver_id)
);
ALTER TABLE candle_replies ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "replies_select_own" ON candle_replies;
CREATE POLICY "replies_select_own" ON candle_replies
  FOR SELECT TO authenticated USING (auth.uid() = owner_id OR auth.uid() = giver_id);
-- 書き込みはRPC(SECURITY DEFINER)経由のみ

-- オーナーが自分のビルの蝋燭一覧（誰がくれたか＋返事済みか）を見る
CREATE OR REPLACE FUNCTION get_candle_givers(bx integer, bz integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('error','not_authenticated'); END IF;
  IF NOT EXISTS(SELECT 1 FROM lands WHERE grid_x = bx AND grid_z = bz AND owner_id = v_uid) THEN
    RETURN jsonb_build_object('error','not_owner');
  END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'giver_id', c.user_id,
      'x_username', u.x_username,
      'is_subscribed', COALESCE(u.is_subscribed, false),
      'show_x_username', COALESCE(u.show_x_username, true),
      'lit_at', c.created_at,
      'replied', (r.id IS NOT NULL),
      'phrase', r.phrase
    ) ORDER BY c.created_at DESC)
    FROM building_candles c
    LEFT JOIN users u ON u.id = c.user_id
    LEFT JOIN candle_replies r
      ON r.building_x = c.building_x AND r.building_z = c.building_z AND r.giver_id = c.user_id
    WHERE c.building_x = bx AND c.building_z = bz
  ), '[]'::jsonb);
END;
$$;
GRANT EXECUTE ON FUNCTION get_candle_givers(integer, integer) TO authenticated;

-- オーナーが蝋燭に定型文で返事 → 受けた側(giver)に従業員+1（1日最大1回）
CREATE OR REPLACE FUNCTION reply_to_candle(bx integer, bz integer, p_giver uuid, p_phrase text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_today date := (now() AT TIME ZONE 'utc')::date;
  v_got_today boolean;
  v_rewarded boolean := false;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated'); END IF;
  IF p_phrase NOT IN ('thanks','not_alone','warmth','keep_going') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_phrase');
  END IF;
  IF NOT EXISTS(SELECT 1 FROM lands WHERE grid_x = bx AND grid_z = bz AND owner_id = v_uid) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_owner');
  END IF;
  IF NOT EXISTS(SELECT 1 FROM building_candles WHERE building_x = bx AND building_z = bz AND user_id = p_giver) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_candle');
  END IF;
  IF EXISTS(SELECT 1 FROM candle_replies WHERE building_x = bx AND building_z = bz AND giver_id = p_giver) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_replied');
  END IF;

  INSERT INTO candle_replies(building_x, building_z, owner_id, giver_id, phrase)
  VALUES(bx, bz, v_uid, p_giver, p_phrase);

  -- 返事を受けた側の報酬：従業員+1（その日初回のみ。coins台帳のamount=0行で日次判定）
  SELECT EXISTS(
    SELECT 1 FROM coins
    WHERE user_id = p_giver AND reason = 'candle_reply_received'
      AND (created_at AT TIME ZONE 'utc')::date = v_today
  ) INTO v_got_today;
  IF NOT v_got_today THEN
    UPDATE users SET bench_employees = COALESCE(bench_employees, 0) + 1 WHERE id = p_giver;
    INSERT INTO coins(user_id, amount, reason) VALUES(p_giver, 0, 'candle_reply_received');
    v_rewarded := true;
  END IF;

  RETURN jsonb_build_object('ok', true, 'rewarded', v_rewarded);
END;
$$;
GRANT EXECUTE ON FUNCTION reply_to_candle(integer, integer, uuid, text) TO authenticated;

-- 自分（蝋燭をあげた人）宛ての未読返事を取得し、既読にする
CREATE OR REPLACE FUNCTION get_my_candle_replies()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_result jsonb;
BEGIN
  IF v_uid IS NULL THEN RETURN '[]'::jsonb; END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'x', building_x, 'z', building_z, 'phrase', phrase, 'created_at', created_at
  ) ORDER BY created_at DESC), '[]'::jsonb)
  INTO v_result
  FROM candle_replies WHERE giver_id = v_uid AND seen = false;
  UPDATE candle_replies SET seen = true WHERE giver_id = v_uid AND seen = false;
  RETURN v_result;
END;
$$;
GRANT EXECUTE ON FUNCTION get_my_candle_replies() TO authenticated;

-- ============================================================
-- 3) 夜明けイベント：蝋燭の合計が基準に達したら24時間だけ空が朝焼けに
-- ============================================================
CREATE TABLE IF NOT EXISTS city_state (
  id integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  dawn_until timestamptz,                       -- この時刻まで夜明け（NULL=通常の夜）
  dawn_threshold integer NOT NULL DEFAULT 30,   -- 次の夜明けに必要な「増加」本数
  last_dawn_total integer NOT NULL DEFAULT 0    -- 前回夜明け時点の合計本数
);
INSERT INTO city_state(id) VALUES(1) ON CONFLICT DO NOTHING;
ALTER TABLE city_state ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "city_state_read_all" ON city_state;
CREATE POLICY "city_state_read_all" ON city_state FOR SELECT TO authenticated USING (true);

-- 現在の夜明け状態＋進捗
CREATE OR REPLACE FUNCTION get_city_dawn()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_state city_state;
  v_total integer;
BEGIN
  SELECT * INTO v_state FROM city_state WHERE id = 1;
  SELECT COUNT(*) INTO v_total FROM building_candles;
  RETURN jsonb_build_object(
    'dawn_until', v_state.dawn_until,
    'is_dawn', (v_state.dawn_until IS NOT NULL AND v_state.dawn_until > now()),
    'progress', GREATEST(0, v_total - v_state.last_dawn_total),
    'threshold', v_state.dawn_threshold,
    'total', v_total
  );
END;
$$;
GRANT EXECUTE ON FUNCTION get_city_dawn() TO authenticated;

-- toggle_candle 改：v92の内容（サブスク限定・自ビル不可・日次報酬）＋夜明け判定
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

    -- 夜明け判定：合計が「前回夜明け時点＋基準」に達したら24時間の夜明け開始
    SELECT * INTO v_state FROM city_state WHERE id = 1 FOR UPDATE;
    SELECT COUNT(*) INTO v_total FROM building_candles;
    IF (v_state.dawn_until IS NULL OR v_state.dawn_until <= now())
       AND v_total >= v_state.last_dawn_total + v_state.dawn_threshold THEN
      UPDATE city_state
        SET dawn_until = now() + interval '24 hours',
            last_dawn_total = v_total
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
-- 4) 再生の殿堂：当月最多蝋燭のビル（格言＋⑥生まれ変わったら）
-- ============================================================
CREATE OR REPLACE FUNCTION get_monthly_hall()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_x integer; v_z integer; v_cnt integer;
BEGIN
  SELECT building_x, building_z, COUNT(*) INTO v_x, v_z, v_cnt
  FROM building_candles
  WHERE created_at >= date_trunc('month', now())
  GROUP BY building_x, building_z
  ORDER BY COUNT(*) DESC, MIN(created_at) ASC
  LIMIT 1;
  IF v_x IS NULL THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'x', v_x, 'z', v_z, 'candles', v_cnt,
    'motto', (SELECT motto_text FROM building_profiles
              WHERE building_x = v_x AND building_z = v_z AND status = 'approved'),
    'motto_en', (SELECT motto_text_en FROM building_profiles
                 WHERE building_x = v_x AND building_z = v_z AND status = 'approved'),
    'reborn', (SELECT journey_to_now FROM building_past_details
               WHERE building_x = v_x AND building_z = v_z AND status = 'approved'),
    'reborn_en', (SELECT journey_to_now_en FROM building_past_details
                  WHERE building_x = v_x AND building_z = v_z AND status = 'approved')
  );
END;
$$;
GRANT EXECUTE ON FUNCTION get_monthly_hall() TO authenticated;

-- ============================================================
-- 5) buy_land 改：中央保護区（|x|<=20 かつ |z|<=20 ＝中央5x5マス）は新規購入不可
--    ※既に所有されている土地はそのまま（取り上げない）
-- ============================================================
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

  -- 中央保護区（再生の殿堂エリア）は購入不可
  IF abs(gx) <= 20 AND abs(gz) <= 20 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'reserved_zone');
  END IF;

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

-- ゲーム側は lands に直接INSERTしているため、トリガーでも保護区を強制する
CREATE OR REPLACE FUNCTION lands_block_reserved()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF abs(NEW.grid_x) <= 20 AND abs(NEW.grid_z) <= 20 THEN
    RAISE EXCEPTION 'reserved_zone';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_lands_block_reserved ON lands;
CREATE TRIGGER trg_lands_block_reserved
  BEFORE INSERT ON lands
  FOR EACH ROW EXECUTE FUNCTION lands_block_reserved();
