-- v50: Atomic land purchase and employee assignment RPCs
-- Run in Supabase SQL editor to fix race conditions in handleLandBuy() and assignEmployeesToCurrentBuilding()

-- ----------------------------------------------------------------
-- buy_land: atomically checks coins, inserts land, deducts coins
-- ----------------------------------------------------------------
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
  IF EXISTS (SELECT 1 FROM lands WHERE grid_x = gx AND grid_z = gz) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_owned');
  END IF;
  SELECT coin_column INTO v_coins FROM users WHERE id = v_user_id FOR UPDATE;
  IF COALESCE(v_coins, 0) < v_land_cost THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'insufficient_coins', 'coins', COALESCE(v_coins, 0), 'need', v_land_cost);
  END IF;
  -- Re-check land availability after row lock (prevent double-buy race)
  IF EXISTS (SELECT 1 FROM lands WHERE grid_x = gx AND grid_z = gz) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_owned');
  END IF;
  INSERT INTO lands (grid_x, grid_z, owner_id) VALUES (gx, gz, v_user_id);
  UPDATE users SET coin_column = coin_column - v_land_cost WHERE id = v_user_id
  RETURNING coin_column INTO v_coins;
  RETURN jsonb_build_object('ok', true, 'coins_remaining', v_coins, 'cost', v_land_cost);
END;
$$;

GRANT EXECUTE ON FUNCTION buy_land(integer, integer) TO authenticated;

-- ----------------------------------------------------------------
-- assign_employees: atomically moves employees from bench to building
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION assign_employees(bx integer, bz integer, p_count integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_bench integer;
  v_current_emp integer;
  v_new_bench integer;
  v_new_emp integer;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;
  IF p_count <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_count');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM lands WHERE grid_x = bx AND grid_z = bz AND owner_id = v_user_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_land_owner');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM buildings WHERE x = bx AND z = bz AND owner_id = v_user_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_building_owner');
  END IF;
  SELECT bench_employees INTO v_bench FROM users WHERE id = v_user_id FOR UPDATE;
  IF COALESCE(v_bench, 0) < p_count THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'insufficient_bench', 'bench', COALESCE(v_bench, 0), 'need', p_count);
  END IF;
  SELECT COALESCE(employees, 0) INTO v_current_emp FROM buildings WHERE x = bx AND z = bz FOR UPDATE;
  v_new_bench := COALESCE(v_bench, 0) - p_count;
  v_new_emp := v_current_emp + p_count;
  UPDATE users SET bench_employees = v_new_bench WHERE id = v_user_id;
  UPDATE buildings SET employees = v_new_emp WHERE x = bx AND z = bz AND owner_id = v_user_id;
  RETURN jsonb_build_object('ok', true, 'bench_employees', v_new_bench, 'building_employees', v_new_emp);
END;
$$;

GRANT EXECUTE ON FUNCTION assign_employees(integer, integer, integer) TO authenticated;

-- ----------------------------------------------------------------
-- add_coins_and_record: atomically adds coins and records history
-- Used by completeTask() to avoid read-then-write race conditions
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION add_coins_and_record(p_amount integer, p_reason text)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_new_coins integer;
BEGIN
  IF v_user_id IS NULL THEN RETURN NULL; END IF;
  UPDATE users SET coin_column = COALESCE(coin_column, 0) + p_amount
  WHERE id = v_user_id RETURNING coin_column INTO v_new_coins;
  INSERT INTO coins (user_id, amount, reason) VALUES (v_user_id, p_amount, p_reason);
  RETURN v_new_coins;
END;
$$;

GRANT EXECUTE ON FUNCTION add_coins_and_record(integer, text) TO authenticated;

-- ----------------------------------------------------------------
-- Updated register_referral: also records coins in history table
-- Replaces v47 version
-- ----------------------------------------------------------------
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
  UPDATE users SET coin_column = COALESCE(coin_column, 0) + 30
  WHERE id = p_inviter
  RETURNING coin_column INTO v_coins;
  -- Record coin history for inviter (registration bonus)
  INSERT INTO coins (user_id, amount, reason) VALUES (p_inviter, 30, 'invite_register');
  v_send := grant_invite_send_bonus_for_referral(p_inviter, v_uid);
  IF COALESCE((v_send->>'awarded')::boolean, false) THEN
    v_send_awarded := 10;
    v_coins := COALESCE((v_send->>'inviter_coins')::integer, v_coins);
    -- Record coin history for invite send bonus
    INSERT INTO coins (user_id, amount, reason) VALUES (p_inviter, 10, 'invite_send');
  END IF;
  RETURN jsonb_build_object(
    'ok', true,
    'registered', true,
    'coins_awarded', 30 + v_send_awarded,
    'register_coins', 30,
    'send_coins', v_send_awarded,
    'inviter_coins', v_coins
  );
END;
$$;

GRANT EXECUTE ON FUNCTION register_referral(uuid) TO authenticated;
