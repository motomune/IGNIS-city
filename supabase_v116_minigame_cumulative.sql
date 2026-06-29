-- v116: ランキングのミニゲーム統計を「累計」に変更
--   ・lifegame_money : 人生ゲームの最終所持金を毎回 加算（累計所持金）。負(借金)は加算しない。
--       人生ゲームの結果postMessageは1日1回だけ飛ぶ（firstClaimToday）ので、実質1日1回の加算。
--   ・antgame_coins  : アリの巣の coinCount は単調増加（コインは消費されない・localStorage保持）なので
--       GREATESTで更新すれば「累計獲得コイン数」になる（重複加算を避けるためADDにはしない）。

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
    -- 累計：その回の所持金（負は0扱い）を足し込む
    UPDATE users SET lifegame_money = COALESCE(lifegame_money,0) + GREATEST(v_val, 0) WHERE id = v_uid;
  ELSIF p_kind = 'antgame' THEN
    -- 累計獲得（coinCountは単調増加）：より大きい値で更新
    UPDATE users SET antgame_coins = GREATEST(COALESCE(antgame_coins,0), v_val) WHERE id = v_uid;
  ELSE
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_kind');
  END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

GRANT EXECUTE ON FUNCTION record_minigame_stat(text, integer) TO authenticated;
