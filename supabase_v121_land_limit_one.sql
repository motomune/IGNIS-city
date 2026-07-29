-- v121: 土地は1人1マスまでに制限
--
-- 背景：クライアントの handleLandBuy は buy_land RPC を経由せず lands に直接 INSERT していたため、
-- v52 で buy_land に入れた上限（2面）は実際には効いていなかった。
-- どの経路でも効くように BEFORE INSERT トリガーで強制する。
-- 適用時点で全ユーザーがちょうど1マス所有だったため、既存ユーザーへの影響はなし。
-- 適用済み（Supabase 管理APIで実行済み）。

create or replace function public.lands_enforce_limit() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_cnt int;
begin
  if NEW.owner_id is null then return NEW; end if;
  select count(*) into v_cnt from public.lands where owner_id = NEW.owner_id;
  if v_cnt >= 1 then
    raise exception 'land_limit_reached' using errcode='P0001';
  end if;
  return NEW;
end $$;

drop trigger if exists trg_lands_enforce_limit on public.lands;
create trigger trg_lands_enforce_limit before insert on public.lands
  for each row execute function public.lands_enforce_limit();

-- RPC 側も 2 → 1 に揃える（こちらを使う経路のため）
create or replace function buy_land(gx integer, gz integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_user_id uuid := auth.uid(); v_coins integer; v_land_cost integer := 100;
begin
  if v_user_id is null then return jsonb_build_object('ok', false, 'reason', 'not_authenticated'); end if;
  if (select count(*) from lands where owner_id = v_user_id) >= 1 then
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
