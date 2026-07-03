-- v118: Life Game ranking now tracks CURRENT total money (not self-best).
-- Money carries over between plays (board.cash -> gsave.carry), so the value
-- posted at board end already represents the player's current wallet. We
-- therefore OVERWRITE lifegame_money with the latest value (floored at 0 so
-- debt/negative never shows), instead of GREATEST. antgame_coins stays
-- best-ever (GREATEST). Replaces the v115 version of record_minigame_stat.

CREATE OR REPLACE FUNCTION record_minigame_stat(p_kind text, p_value integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_val integer := COALESCE(p_value, 0);
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;
  IF p_kind = 'lifegame' THEN
    -- current total holdings: overwrite with latest (floor 0), can go up or down
    UPDATE users SET lifegame_money = GREATEST(0, v_val) WHERE id = v_uid;
  ELSIF p_kind = 'antgame' THEN
    UPDATE users SET antgame_coins = GREATEST(COALESCE(antgame_coins,0), v_val) WHERE id = v_uid;
  ELSE
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_kind');
  END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

GRANT EXECUTE ON FUNCTION record_minigame_stat(text, integer) TO authenticated;
