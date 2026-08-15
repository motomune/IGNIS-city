-- v129: 放置ビルの整理（運営の裁量で1棟ずつ削除。自動削除はしない）
--
-- 目的は「街が埋まって重くなる」ことへの備え。ただし機械的には消さない。
--  ・対象になるのは「90日ログインが無く」かつ「過去詳細が承認済みで入っていない」ビルだけ。
--    過去詳細＝このゲームの本体なので、書いてあるビルは何があっても対象外。
--  ・格言だけ書いてあるビルは一覧に出すが、消すかどうかは創設者が1件ずつ判断する。
--  ・消すときはオーナーに不利益が出ないよう、売却と同じ計算でコインを返し、
--    配属していた従業員は休職プールへ戻す（アカウント自体は消さない）。
--
-- 適用済み（2026-08-15 に管理APIで実行）。

-- 削除候補の一覧（創設者のみ）
create or replace function public.admin_list_idle_buildings(p_days integer default 90)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid := auth.uid(); v_rows jsonb;
begin
  -- v_uid が NULL だと <> の結果が NULL になり IF が素通りしてしまう。
  -- is distinct from + 明示的な null 判定で必ず弾く。
  if v_uid is null or v_uid is distinct from 'afc818cd-d2fa-4c1c-8460-9dbce9e60e37'::uuid then
    return jsonb_build_object('ok', false, 'reason', 'forbidden');
  end if;
  select coalesce(jsonb_agg(t order by t->>'last_seen_at'), '[]'::jsonb) into v_rows from (
    select jsonb_build_object(
             'x', b.x, 'z', b.z, 'floors', b.floors, 'employees', b.employees,
             'owner_id', b.owner_id,
             'last_seen_at', u.last_seen_at,
             'has_motto', exists(select 1 from building_profiles p
                                  where p.building_x=b.x and p.building_z=b.z
                                    and p.status='approved' and p.motto_text is not null),
             'refund_coins', calc_sell_coin_reward(
                               calc_sell_total_floors(coalesce(b.floors,0), coalesce(b.employees,0)),
                               coalesce(b.employees,0))
           ) as t
      from buildings b
      join users u on u.id = b.owner_id
     where coalesce(u.last_seen_at, u.created_at) < now() - make_interval(days => p_days)
       -- 過去詳細が承認済みで入っているビルは対象外（本体なので消さない）
       and not exists (
             select 1 from building_past_details d
              where d.building_x = b.x and d.building_z = b.z
                and d.status = 'approved'
                and coalesce(d.background_detail, d.how_handled,
                             d.what_happened_after, d.journey_to_now) is not null)
       -- 創設者のビルは対象外
       and b.owner_id <> 'afc818cd-d2fa-4c1c-8460-9dbce9e60e37'::uuid
  ) s;
  return jsonb_build_object('ok', true, 'days', p_days, 'items', v_rows);
end $$;

-- 1棟を削除して、オーナーへコインを返し従業員を休職プールへ戻す（創設者のみ）
create or replace function public.admin_delete_building(bx integer, bz integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_uid uuid := auth.uid();
  v_owner uuid; v_base int; v_emp int; v_total int; v_refund int;
begin
  -- v_uid が NULL だと <> の結果が NULL になり IF が素通りしてしまう。
  -- is distinct from + 明示的な null 判定で必ず弾く。
  if v_uid is null or v_uid is distinct from 'afc818cd-d2fa-4c1c-8460-9dbce9e60e37'::uuid then
    return jsonb_build_object('ok', false, 'reason', 'forbidden');
  end if;
  select owner_id, coalesce(floors,0), coalesce(employees,0)
    into v_owner, v_base, v_emp
    from buildings where x = bx and z = bz limit 1;
  if v_owner is null then return jsonb_build_object('ok', false, 'reason', 'building_not_found'); end if;
  -- 過去詳細が入っているビルはここでも弾く（一覧から漏れても消えないように二重で守る）
  if exists (select 1 from building_past_details d
              where d.building_x = bx and d.building_z = bz and d.status='approved'
                and coalesce(d.background_detail, d.how_handled,
                             d.what_happened_after, d.journey_to_now) is not null) then
    return jsonb_build_object('ok', false, 'reason', 'has_past_detail');
  end if;

  v_total  := calc_sell_total_floors(v_base, v_emp);
  v_refund := calc_sell_coin_reward(v_total, v_emp);   -- 売却と同じ計算で返す

  delete from buildings        where x = bx and z = bz;
  delete from lands            where grid_x = bx and grid_z = bz;
  delete from building_profiles where building_x = bx and building_z = bz;
  delete from building_candles  where building_x = bx and building_z = bz;

  update users
     set coin_column     = coalesce(coin_column,0) + v_refund,
         bench_employees = coalesce(bench_employees,0) + v_emp
   where id = v_owner;
  insert into coins(user_id, amount, reason) values (v_owner, v_refund, 'idle_building_refund');

  return jsonb_build_object('ok', true, 'x', bx, 'z', bz,
    'owner_id', v_owner, 'refund_coins', v_refund, 'staff_returned', v_emp, 'floors', v_total);
end $$;

grant execute on function public.admin_list_idle_buildings(integer) to authenticated;
grant execute on function public.admin_delete_building(integer, integer) to authenticated;
