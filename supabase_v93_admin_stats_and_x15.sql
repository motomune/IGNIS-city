-- v93: 管理者向け利用者統計RPC ＋ サブスク会員のXリポスト/リプライ報酬1.5倍

-- 1) 管理者だけが取得できる利用者統計
--    total_users  = ユーザー総数
--    mau_30d      = 直近30日に1回でもログイン（daily_tasks行が作られた）した人数（重複なし）
CREATE OR REPLACE FUNCTION get_admin_stats()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_total int;
  v_mau int;
BEGIN
  IF v_uid IS NULL OR v_uid <> 'afc818cd-d2fa-4c1c-8460-9dbce9e60e37'::uuid THEN
    RETURN jsonb_build_object('error', 'forbidden');
  END IF;
  SELECT COUNT(*) INTO v_total FROM users;
  SELECT COUNT(DISTINCT user_id) INTO v_mau
    FROM daily_tasks
    WHERE task_date >= ((now() AT TIME ZONE 'utc')::date - INTERVAL '30 days');
  RETURN jsonb_build_object('total_users', v_total, 'mau_30d', v_mau);
END;
$$;
GRANT EXECUTE ON FUNCTION get_admin_stats() TO authenticated;

-- 2) X報酬（リポスト/リプライ）はサブスク会員のみ 1.5倍。
--    grant_x_reward は x-reward-batch（リポスト/リプライ報酬）専用なので、
--    ここで会員判定して増額すればバッチ側の改修は不要。
--    タスククリア報酬は別経路（completeTask / add_coins_and_record）なので影響なし。
CREATE OR REPLACE FUNCTION grant_x_reward(
  p_user_id uuid,
  p_amount integer,
  p_reason text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_subscribed boolean;
  v_amount integer := p_amount;
BEGIN
  SELECT is_subscribed INTO v_subscribed FROM users WHERE id = p_user_id;
  IF COALESCE(v_subscribed, false) THEN
    v_amount := ROUND(p_amount * 1.5)::int; -- 会員は1.5倍（例: 15→23, 10→15）
  END IF;
  UPDATE users SET coin_column = COALESCE(coin_column, 0) + v_amount WHERE id = p_user_id;
  INSERT INTO coins(user_id, amount, reason) VALUES(p_user_id, v_amount, p_reason);
END;
$$;
REVOKE EXECUTE ON FUNCTION grant_x_reward(uuid, integer, text) FROM authenticated;
