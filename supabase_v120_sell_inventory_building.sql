-- v120: 図鑑の「所有ビル一覧」から、未設置の在庫ビルを本人が売却できるRPC
-- 報酬 = 階数 × 1 + ★ × 5（★は表示と同じく階数ベース：48F=5/40F=4/30F=3/20F=2/他=1）
-- 設置済みビルは従来どおりビル詳細の sell_building（階数×倍率＋土地ごと）を使う。
-- 適用済み（Supabase 管理APIで実行済み）。

create or replace function public.sell_inventory_building(p_inv_id uuid)
returns json language plpgsql security definer set search_path=public as $$
declare v_uid uuid := auth.uid(); v_floors int; v_star int; v_reward int; v_new int;
begin
  if v_uid is null then
    return json_build_object('ok', false, 'reason', 'not_logged_in');
  end if;
  -- 本人所有の在庫ビルのみ
  select floors into v_floors from public.building_inventory where id = p_inv_id and user_id = v_uid;
  if v_floors is null then
    return json_build_object('ok', false, 'reason', 'not_found');
  end if;
  v_star := case
    when v_floors >= 48 then 5
    when v_floors >= 40 then 4
    when v_floors >= 30 then 3
    when v_floors >= 20 then 2
    else 1 end;
  v_reward := v_floors * 1 + v_star * 5;
  delete from public.building_inventory where id = p_inv_id and user_id = v_uid;
  update public.users set coin_column = coalesce(coin_column, 0) + v_reward where id = v_uid returning coin_column into v_new;
  insert into public.coins(user_id, amount, reason) values (v_uid, v_reward, 'inventory_sell');
  return json_build_object('ok', true, 'reward', v_reward, 'coins_remaining', v_new, 'star', v_star, 'floors', v_floors);
end $$;

grant execute on function public.sell_inventory_building(uuid) to anon, authenticated;
