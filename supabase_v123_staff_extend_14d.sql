-- v123: 任期延長を「満期2週間前」から使えるようにする ＋ 延長単価をUI表示と一致させる
--
-- 【背景1】延長対象の期間はサーバー側では絞っていない（term_end の昇順に p_count 人ぶん延長する）。
--          つまり「何日前から延長できるか」はクライアントが p_count に何を渡すかで決まる。
--          → 14日以内の人数を渡すようにクライアントを変更すれば足りるので、ここでの変更は不要。
--
-- 【背景2】単価が食い違っていた。サーバー = 8コイン/人、画面表示 = 5コイン/人。
--          画面に出ている金額を請求するのが正しいので、サーバーを 5 に合わせる。
--          （これまで延長した人は表示より3コイン/人多く引かれていた）
--
-- 適用済み（2026-08-04 に管理APIで実行）。

create or replace function public.extend_staff_terms(p_count integer default null)
returns jsonb language plpgsql security definer set search_path = public as $$
DECLARE
  v_user_id uuid := auth.uid();
  v_coins integer;
  v_cost_per integer := 5;   -- ← 画面表示（STAFF_EXTEND_COST_PER）と一致させる
  v_limit integer;
  v_extended integer := 0;
  v_cost integer := 0;
  r record;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;
  SELECT COUNT(*)::int INTO v_limit FROM staff_employees WHERE user_id = v_user_id;
  IF v_limit = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_staff');
  END IF;
  IF p_count IS NOT NULL AND p_count > 0 THEN
    v_limit := LEAST(p_count, v_limit);
  END IF;
  v_cost := v_limit * v_cost_per;
  SELECT coin_column INTO v_coins FROM users WHERE id = v_user_id;
  IF COALESCE(v_coins, 0) < v_cost THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'insufficient_coins', 'coins', COALESCE(v_coins, 0), 'need', v_cost);
  END IF;
  -- 満期が近い順に延長する（クライアントは「2週間以内の人数」を p_count で渡す）
  FOR r IN SELECT id FROM staff_employees WHERE user_id = v_user_id ORDER BY term_end ASC LIMIT v_limit LOOP
    UPDATE staff_employees SET term_end = term_end + interval '3 months' WHERE id = r.id;
    v_extended := v_extended + 1;
  END LOOP;
  v_cost := v_extended * v_cost_per;
  UPDATE users SET coin_column = coin_column - v_cost WHERE id = v_user_id;
  SELECT coin_column INTO v_coins FROM users WHERE id = v_user_id;
  RETURN jsonb_build_object('ok', true, 'extended', v_extended, 'cost', v_cost, 'coins_remaining', v_coins);
END;
$$;
