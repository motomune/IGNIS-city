-- v117: Invite coin rewards bumped to send 20 + register 50 (was 10 + 30).
-- Rewards remain granted at REGISTRATION time and are deduped per referred
-- account (UNIQUE(inviter_id, referred_user_id)), so the same person can
-- never be counted twice and raw share-button spam earns nothing.
-- Replaces the v47/v50 versions of these two functions.

-- Send bonus: 20 coins, once per unique referred user.
CREATE OR REPLACE FUNCTION grant_invite_send_bonus_for_referral(p_inviter uuid, p_referred uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_coins integer;
  v_rows integer;
BEGIN
  INSERT INTO game_invite_send_rewards (inviter_id, referred_user_id, coins)
  VALUES (p_inviter, p_referred, 20)
  ON CONFLICT (inviter_id, referred_user_id) DO NOTHING;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RETURN jsonb_build_object('ok', true, 'awarded', false);
  END IF;
  UPDATE users SET coin_column = COALESCE(coin_column, 0) + 20
  WHERE id = p_inviter
  RETURNING coin_column INTO v_coins;
  RETURN jsonb_build_object('ok', true, 'awarded', true, 'coins_awarded', 20, 'inviter_coins', v_coins);
END;
$$;

-- Registration: 50 coins + the 20 send bonus, once per unique referred user.
CREATE OR REPLACE FUNCTION register_referral(p_inviter uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_inserted boolean := false;
  v_coins integer;
  v_send jsonb;
  v_send_awarded integer := 0;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;
  IF p_inviter IS NULL OR p_inviter = v_uid THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_inviter');
  END IF;
  INSERT INTO game_referrals (inviter_id, referred_user_id)
  VALUES (p_inviter, v_uid)
  ON CONFLICT (referred_user_id) DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  IF NOT v_inserted THEN
    RETURN jsonb_build_object('ok', true, 'registered', false);
  END IF;
  UPDATE users SET coin_column = COALESCE(coin_column, 0) + 50
  WHERE id = p_inviter
  RETURNING coin_column INTO v_coins;
  -- Record coin history for inviter (registration bonus)
  INSERT INTO coins (user_id, amount, reason) VALUES (p_inviter, 50, 'invite_register');
  v_send := grant_invite_send_bonus_for_referral(p_inviter, v_uid);
  IF COALESCE((v_send->>'awarded')::boolean, false) THEN
    v_send_awarded := 20;
    v_coins := COALESCE((v_send->>'inviter_coins')::integer, v_coins);
    -- Record coin history for invite send bonus
    INSERT INTO coins (user_id, amount, reason) VALUES (p_inviter, 20, 'invite_send');
  END IF;
  RETURN jsonb_build_object(
    'ok', true,
    'registered', true,
    'coins_awarded', 50 + v_send_awarded,
    'register_coins', 50,
    'send_coins', v_send_awarded,
    'inviter_coins', v_coins
  );
END;
$$;

GRANT EXECUTE ON FUNCTION grant_invite_send_bonus_for_referral(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION register_referral(uuid) TO authenticated;
