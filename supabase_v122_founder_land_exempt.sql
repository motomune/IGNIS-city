-- v122: 創設者を「土地は1人1マスまで」の制限から除外する
--
-- 適用済み（2026-08-03 に管理APIで実行、founder_exempt=true を確認）。
-- （v121 で入れた lands_enforce_limit トリガーが創設者もブロックしていたため、
--   これを適用しないと創設者は2マス目を購入できなかった）
--
-- 創設者 user id: afc818cd-d2fa-4c1c-8460-9dbce9e60e37

create or replace function public.lands_enforce_limit() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_cnt int;
begin
  if NEW.owner_id is null then return NEW; end if;
  -- 創設者は制限の対象外（運営用に複数区画を持てる）
  if NEW.owner_id = 'afc818cd-d2fa-4c1c-8460-9dbce9e60e37'::uuid then return NEW; end if;
  select count(*) into v_cnt from public.lands where owner_id = NEW.owner_id;
  if v_cnt >= 1 then
    raise exception 'land_limit_reached' using errcode='P0001';
  end if;
  return NEW;
end $$;

-- RPC 側も同様に除外
create or replace function buy_land(gx integer, gz integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_user_id uuid := auth.uid(); v_coins integer; v_land_cost integer := 100;
begin
  if v_user_id is null then return jsonb_build_object('ok', false, 'reason', 'not_authenticated'); end if;
  if v_user_id <> 'afc818cd-d2fa-4c1c-8460-9dbce9e60e37'::uuid
     and (select count(*) from lands where owner_id = v_user_id) >= 1 then
    return jsonb_build_object('ok', false, 'reason', 'land_limit_reached');
  end if;
  if exists (select 1 from lands where grid_x = gx and grid_z = gz) then
    return jsonb_build_object('ok', false, 'reason', 'already_owned');
  end if;
  select coin_column into v_coins from users where id = v_user_id for update;
  if coalesce(v_coins,0) < v_land_cost then
    return jsonb_build_object('ok', false, 'reason', 'insufficient_coins', 'coins', coalesce(v_coins,0), 'need', v_land_cost);
  end if;
  update users set coin_column = coin_column - v_land_cost where id = v_user_id;
  insert into lands(grid_x, grid_z, owner_id) values (gx, gz, v_user_id);
  return jsonb_build_object('ok', true, 'coins_remaining', v_coins - v_land_cost);
end $$;
