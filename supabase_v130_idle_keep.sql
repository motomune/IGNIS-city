-- v130: 放置ビル一覧に「残す」判断を記録できるようにする
--
-- 一覧を見て「これは消さない」と判断したビルが毎回並び続けると、
-- 未判断のものが埋もれて確認作業が回らなくなる。判断済みを一覧から外す。
--
-- ただし永久に消さない扱いにはしない。街が本当に埋まったときに再検討できるよう、
-- 記録から 180日 経ったら再び一覧に戻る（そのときまだ放置されていれば）。
--
-- 適用済み（2026-08-15 に管理APIで実行）。

create table if not exists public.idle_building_reviews (
  grid_x  integer     not null,
  grid_z  integer     not null,
  kept_at timestamptz not null default now(),
  note    text,
  primary key (grid_x, grid_z)
);

-- 利用者からは触れない。SECURITY DEFINER の関数経由でのみ読み書きする。
alter table public.idle_building_reviews enable row level security;

-- 「残す」と記録する（創設者のみ）
create or replace function public.admin_keep_building(bx integer, bz integer, p_note text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null or v_uid is distinct from 'afc818cd-d2fa-4c1c-8460-9dbce9e60e37'::uuid then
    return jsonb_build_object('ok', false, 'reason', 'forbidden');
  end if;
  insert into idle_building_reviews(grid_x, grid_z, kept_at, note)
  values (bx, bz, now(), p_note)
  on conflict (grid_x, grid_z) do update set kept_at = now(), note = excluded.note;
  return jsonb_build_object('ok', true, 'x', bx, 'z', bz, 'recheck_after', now() + interval '180 days');
end $$;

-- 一覧：判断済み（180日以内に「残す」としたもの）を除外する
create or replace function public.admin_list_idle_buildings(p_days integer default 90)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid := auth.uid(); v_rows jsonb;
begin
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
       -- 過去詳細が入っているビルは対象外（このゲームの本体なので消さない）
       and not exists (
             select 1 from building_past_details d
              where d.building_x = b.x and d.building_z = b.z
                and d.status = 'approved'
                and coalesce(d.background_detail, d.how_handled,
                             d.what_happened_after, d.journey_to_now) is not null)
       -- 「残す」と判断済みのものは外す（180日で再び戻る）
       and not exists (
             select 1 from idle_building_reviews r
              where r.grid_x = b.x and r.grid_z = b.z
                and r.kept_at > now() - interval '180 days')
       and b.owner_id <> 'afc818cd-d2fa-4c1c-8460-9dbce9e60e37'::uuid
  ) s;
  return jsonb_build_object('ok', true, 'days', p_days, 'items', v_rows);
end $$;

grant execute on function public.admin_keep_building(integer, integer, text) to authenticated;
grant execute on function public.admin_list_idle_buildings(integer) to authenticated;
