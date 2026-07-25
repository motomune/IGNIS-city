-- v119: 本人が自分のビルの書き込み（格言・過去の記録）を削除できるRPC
-- 削除権（GDPR/APPI的な「本人による削除」）の担保。
-- 土地の所有者（lands.owner_id = auth.uid()）のみ、そのビルの
-- building_profiles / building_past_details を削除できる。
-- 適用済み（Supabase 管理APIで実行済み）。

create or replace function public.delete_building_writing(p_x int, p_z int)
returns json language plpgsql security definer set search_path=public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return json_build_object('ok', false, 'reason', 'not_logged_in');
  end if;
  -- そのビルの土地の所有者本人のみ削除可能
  if not exists (
    select 1 from public.lands
    where grid_x = p_x and grid_z = p_z and owner_id = v_uid
  ) then
    return json_build_object('ok', false, 'reason', 'not_owner');
  end if;
  delete from public.building_past_details where building_x = p_x and building_z = p_z;
  delete from public.building_profiles     where building_x = p_x and building_z = p_z;
  return json_build_object('ok', true);
end $$;

grant execute on function public.delete_building_writing(int, int) to anon, authenticated;
