-- v101: 中央特別区域を5×5（25マス: x,z とも -20〜+20）に変更（4×4から拡大）
-- ※ 2026-06-13 にClaude CodeからAPI経由で適用済み。このファイルは記録用。

CREATE OR REPLACE FUNCTION buy_land(gx integer, gz integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_user_id uuid := auth.uid();
  v_coins integer;
  v_land_cost integer := 100;
BEGIN
  IF v_user_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated'); END IF;
  IF gx BETWEEN -20 AND 20 AND gz BETWEEN -20 AND 20 THEN
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
  UPDATE users SET coin_column = coin_column - v_land_cost WHERE id = v_user_id RETURNING coin_column INTO v_coins;
  RETURN jsonb_build_object('ok', true, 'coins_remaining', v_coins, 'cost', v_land_cost);
END;
$fn$;
GRANT EXECUTE ON FUNCTION buy_land(integer, integer) TO authenticated;

CREATE OR REPLACE FUNCTION lands_block_reserved()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
  IF NEW.grid_x BETWEEN -20 AND 20 AND NEW.grid_z BETWEEN -20 AND 20 THEN
    RAISE EXCEPTION 'reserved_zone';
  END IF;
  RETURN NEW;
END;
$fn$;
DROP TRIGGER IF EXISTS trg_lands_block_reserved ON lands;
CREATE TRIGGER trg_lands_block_reserved BEFORE INSERT ON lands FOR EACH ROW EXECUTE FUNCTION lands_block_reserved();
