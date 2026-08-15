-- v131: 放置ビル一覧に「初めて出てきたビル」か「180日を過ぎて戻ってきたビル」かを持たせる
--
-- 一度「残す」と判断したビルは180日後にまた一覧へ戻る。そのとき、まだ一度も見ていない
-- 新規のビルと混ざると、判断済みのものを何度も読み直すことになり確認が雑になる。
-- カード側で見分けられるよう、状態と前回の判断日を返す。
--
--   review_state = 'new'     … まだ一度も判断していない（目立たせる）
--   review_state = 'recheck' … 以前「残す」と判断し、180日が過ぎて戻ってきた
--
-- 適用済み（2026-08-15 に管理APIで実行）。

create or replace function public.admin_list_idle_buildings(p_days integer default 90)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid := auth.uid(); v_rows jsonb;
begin
  if v_uid is null or v_uid is distinct from 'afc818cd-d2fa-4c1c-8460-9dbce9e60e37'::uuid then
    return jsonb_build_object('ok', false, 'reason', 'forbidden');
  end if;
  select coalesce(jsonb_agg(t order by t->>'review_state' asc, t->>'last_seen_at'), '[]'::jsonb)
    into v_rows from (
    select jsonb_build_object(
             'x', b.x, 'z', b.z, 'floors', b.floors, 'employees', b.employees,
             'owner_id', b.owner_id,
             'last_seen_at', u.last_seen_at,
             'has_motto', exists(select 1 from building_profiles p
                                  where p.building_x=b.x and p.building_z=b.z
                                    and p.status='approved' and p.motto_text is not null),
             'refund_coins', calc_sell_coin_reward(
                               calc_sell_total_floors(coalesce(b.floors,0), coalesce(b.employees,0)),
                               coalesce(b.employees,0)),
             -- 未判断を先頭に出したい。'new' < 'recheck' なので昇順で並べる
             'review_state', case when r.grid_x is null then 'new' else 'recheck' end,
             'last_kept_at', r.kept_at
           ) as t
      from buildings b
      join users u on u.id = b.owner_id
      left join idle_building_reviews r on r.grid_x = b.x and r.grid_z = b.z
     where coalesce(u.last_seen_at, u.created_at) < now() - make_interval(days => p_days)
       -- 過去詳細が入っているビルは対象外（このゲームの本体なので消さない）
       and not exists (
             select 1 from building_past_details d
              where d.building_x = b.x and d.building_z = b.z
                and d.status = 'approved'
                and coalesce(d.background_detail, d.how_handled,
                             d.what_happened_after, d.journey_to_now) is not null)
       -- 「残す」と判断してから180日以内のものは外す
       and (r.grid_x is null or r.kept_at <= now() - interval '180 days')
       and b.owner_id <> 'afc818cd-d2fa-4c1c-8460-9dbce9e60e37'::uuid
  ) s;
  return jsonb_build_object('ok', true, 'days', p_days, 'items', v_rows);
end $$;

grant execute on function public.admin_list_idle_buildings(integer) to authenticated;
