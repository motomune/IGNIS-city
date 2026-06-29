-- v115: ミニゲームのランキング用統計を users に保持
--   ・lifegame_money : 人生ゲームの「自己ベスト所持金」（GREATESTで更新＝下がらない）
--   ・antgame_coins  : アリの巣で集めた「最高コイン数」（GREATESTで更新）
--   ・無課金/課金者の区別なくランキング表示する（フロント側で全員対象）。
--   ・record_minigame_stat: 本人(auth.uid())の該当列を、より大きい値のときだけ更新。

ALTER TABLE users ADD COLUMN IF NOT EXISTS lifegame_money integer NOT NULL DEFAULT 0;
ALTER TABLE users ADD COLUMN IF NOT EXISTS antgame_coins integer NOT NULL DEFAULT 0;

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
    UPDATE users SET lifegame_money = GREATEST(COALESCE(lifegame_money,0), v_val) WHERE id = v_uid;
  ELSIF p_kind = 'antgame' THEN
    UPDATE users SET antgame_coins = GREATEST(COALESCE(antgame_coins,0), v_val) WHERE id = v_uid;
  ELSE
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_kind');
  END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

GRANT EXECUTE ON FUNCTION record_minigame_stat(text, integer) TO authenticated;
