-- v99: 中央特別区域を4×4（16マス: x,z とも -20〜+10）に変更し、
--      マップ範囲内の「所有者不明（土地未所有）」ビルを中央付近も含めてDBから削除する。
--      ※ v98 はもう実行不要（このv99がすべて含む・上書きする）

-- ============================================================
-- 1) 所有者不明ビルをDBから削除（マップ全域 ±100。中央付近も含む）
--    所有済みの土地に建つビルは残る。
-- ============================================================
-- 実行前に件数を確認したい場合：
-- SELECT COUNT(*) FROM buildings b
-- WHERE NOT EXISTS (SELECT 1 FROM lands l WHERE l.grid_x = b.x AND l.grid_z = b.z)
--   AND abs(b.x) <= 100 AND abs(b.z) <= 100;

DELETE FROM buildings b
WHERE NOT EXISTS (SELECT 1 FROM lands l WHERE l.grid_x = b.x AND l.grid_z = b.z)
  AND abs(b.x) <= 100 AND abs(b.z) <= 100;

-- ============================================================
-- 2) buy_land 改：特別区域は 4×4（-20〜+10）に変更
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

  -- 中央特別区域（4×4＝16マス、x,z とも -20〜+10）は購入不可
  IF gx BETWEEN -20 AND 10 AND gz BETWEEN -20 AND 10 THEN
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

-- ============================================================
-- 3) lands 直接INSERTにも 4×4 特別区域を強制（ゲームは直接INSERTで土地購入するため）
-- ============================================================
CREATE OR REPLACE FUNCTION lands_block_reserved()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.grid_x BETWEEN -20 AND 10 AND NEW.grid_z BETWEEN -20 AND 10 THEN
    RAISE EXCEPTION 'reserved_zone';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_lands_block_reserved ON lands;
CREATE TRIGGER trg_lands_block_reserved
  BEFORE INSERT ON lands
  FOR EACH ROW EXECUTE FUNCTION lands_block_reserved();
