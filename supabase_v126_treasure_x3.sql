-- v126: デイリー宝探しを「1日1個」から「1日3個」に
--
-- ・毎日3か所に出現し、1つずつ拾える（コイン2枚 × 3か所）。
-- ・ぬいぐるみのレア度は据え置き（1日あたり 約1/30で金・約1/300で虹）。
--   3個それぞれで抽選すると出現率が3倍になってしまうので、
--   「その日にぬいぐるみが出るか」を1回だけ判定し、当たった日は3個のうち1つだけが
--   ぬいぐるみになる。ルール表記（約1/30・約1/300）はそのまま正しい。
-- ・拾ったかどうかは coins 台帳の reason 'daily_treasure_0/1/2' で個別に管理する。
--   旧 'daily_treasure' の行は「0番を拾い済み」とみなして互換をとる。
--
-- 適用済み（2026-08-06 に管理APIで実行）。

CREATE OR REPLACE FUNCTION get_daily_treasure()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_today date := (now() AT TIME ZONE 'utc')::date;
  v_hk    bigint;
  v_special_kind text; v_special_amt integer; v_special_idx integer;
  v_items jsonb := '[]'::jsonb;
  v_hx bigint; v_hz bigint; v_hy bigint;
  v_kind text; v_amount integer; v_done boolean;
  i integer;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated'); END IF;

  -- その日ぬいぐるみが出るか（1日1回だけの抽選＝レア度は従来どおり）
  v_hk := ('x'||substr(md5(v_uid::text||v_today::text||'K'),1,8))::bit(32)::bigint;
  IF (v_hk % 300 = 0) THEN v_special_kind := 'rainbow'; v_special_amt := 100;
  ELSIF (v_hk % 30 = 0) THEN v_special_kind := 'gold';  v_special_amt := 10;
  ELSE v_special_kind := NULL; v_special_amt := NULL;
  END IF;
  v_special_idx := (v_hk % 3);   -- 当たった日、3個のうちどれがぬいぐるみか

  FOR i IN 0..2 LOOP
    v_hx := ('x'||substr(md5(v_uid::text||v_today::text||'X'||i::text),1,8))::bit(32)::bigint;
    v_hz := ('x'||substr(md5(v_uid::text||v_today::text||'Z'||i::text),1,8))::bit(32)::bigint;
    v_hy := ('x'||substr(md5(v_uid::text||v_today::text||'Y'||i::text),1,8))::bit(32)::bigint;
    IF v_special_kind IS NOT NULL AND i = v_special_idx THEN
      v_kind := v_special_kind; v_amount := v_special_amt;
    ELSE
      v_kind := 'coins'; v_amount := 2;
    END IF;
    SELECT EXISTS(
      SELECT 1 FROM coins
       WHERE user_id = v_uid
         AND (reason = 'daily_treasure_'||i::text OR (i = 0 AND reason = 'daily_treasure'))
         AND (created_at AT TIME ZONE 'utc')::date = v_today
    ) INTO v_done;
    v_items := v_items || jsonb_build_object(
      'i', i,
      'x', (v_hx % 181) - 90,
      'z', (v_hz % 181) - 90,
      'y', 6 + (v_hy % 12),
      'kind', v_kind,
      'plushie', (v_kind <> 'coins'),
      'amount', v_amount,
      'collected', v_done);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'items', v_items);
END $$;

CREATE OR REPLACE FUNCTION collect_daily_treasure(p_index integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_today date := (now() AT TIME ZONE 'utc')::date;
  v_i     integer := GREATEST(0, LEAST(2, COALESCE(p_index, 0)));
  v_hk    bigint;
  v_kind  text; v_amount integer;
  v_collected boolean; v_new_coins integer; v_count integer := 0;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated'); END IF;

  SELECT EXISTS(
    SELECT 1 FROM coins
     WHERE user_id = v_uid
       AND (reason = 'daily_treasure_'||v_i::text OR (v_i = 0 AND reason = 'daily_treasure'))
       AND (created_at AT TIME ZONE 'utc')::date = v_today
  ) INTO v_collected;
  IF v_collected THEN RETURN jsonb_build_object('ok', false, 'reason', 'already'); END IF;

  -- 種類は get_daily_treasure と完全に同じ式で決める（クライアントの申告は使わない）
  v_hk := ('x'||substr(md5(v_uid::text||v_today::text||'K'),1,8))::bit(32)::bigint;
  IF (v_hk % 300 = 0) AND (v_hk % 3) = v_i THEN v_kind := 'rainbow'; v_amount := 100;
  ELSIF (v_hk % 30 = 0) AND (v_hk % 3) = v_i THEN v_kind := 'gold'; v_amount := 10;
  ELSE v_kind := 'coins'; v_amount := 2;
  END IF;

  UPDATE users SET coin_column = COALESCE(coin_column,0) + v_amount
   WHERE id = v_uid RETURNING coin_column INTO v_new_coins;
  INSERT INTO coins(user_id, amount, reason) VALUES(v_uid, v_amount, 'daily_treasure_'||v_i::text);

  IF v_kind <> 'coins' THEN
    INSERT INTO user_plushies(user_id, plushie_key, count) VALUES(v_uid, v_kind, 1)
      ON CONFLICT (user_id, plushie_key) DO UPDATE SET count = user_plushies.count + 1;
    SELECT count INTO v_count FROM user_plushies WHERE user_id = v_uid AND plushie_key = v_kind;
  END IF;

  RETURN jsonb_build_object('ok', true, 'index', v_i, 'kind', v_kind, 'plushie', (v_kind <> 'coins'),
    'amount', v_amount, 'coins', v_new_coins, 'plushie_count', v_count);
END $$;

GRANT EXECUTE ON FUNCTION get_daily_treasure() TO authenticated;
GRANT EXECUTE ON FUNCTION collect_daily_treasure(integer) TO authenticated;

-- 旧・引数なし版を残すと、引数を省いた呼び出しがどちらか決まらず PostgREST がエラーになる。
-- 新しい方は p_index に既定値があるので、旧版は落として一本化する。
DROP FUNCTION IF EXISTS collect_daily_treasure();
