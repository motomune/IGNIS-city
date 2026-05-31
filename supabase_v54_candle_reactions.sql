-- v54: 🕯️ building candle reactions (subscribers only)

CREATE TABLE IF NOT EXISTS building_candles (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  building_x integer NOT NULL,
  building_z integer NOT NULL,
  created_at timestamptz DEFAULT now(),
  UNIQUE(user_id, building_x, building_z)
);

ALTER TABLE building_candles ENABLE ROW LEVEL SECURITY;

-- カウントは全員が読める
CREATE POLICY "candles_select_all" ON building_candles
  FOR SELECT TO authenticated USING (true);

-- 押せるのはサブスク会員のみ（RPCで制御）
CREATE POLICY "candles_insert_own" ON building_candles
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

CREATE POLICY "candles_delete_own" ON building_candles
  FOR DELETE TO authenticated USING (auth.uid() = user_id);

-- 🕯️ を押す（サブスク確認付き）
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
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;
  SELECT is_subscribed INTO v_subscribed FROM users WHERE id = v_uid;
  IF NOT COALESCE(v_subscribed, false) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'subscription_required');
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
