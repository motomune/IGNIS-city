-- v127: ミニゲームの1日反映上限を サブスク100 / プレミア200 に（無課金は50のまま）
--
-- v125 で 50/60/80 にしたが、有料ティアの差をもっと大きくする方針に変更。
-- 上限を実際に効かせているのはサーバー側のこの2関数なので、ここを変えないと反映されない。
-- クライアント側 gameDailyCap() も同じ値にしてある（表示と ?cap= の受け渡し用）。
--
-- 適用済み（2026-08-06 に管理APIで実行）。

do $$
declare
  r record;
  v_src text;
  v_new text;
begin
  for r in
    -- identity_arguments だと DEFAULT が落ちるので、既定値込みの arguments を使う
    select p.proname, pg_get_function_arguments(p.oid) as args, p.prosrc
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('claim_lifegame_reward','claim_antgame_reward')
  loop
    v_src := r.prosrc;
    v_new := replace(v_src,
      'CASE WHEN v_prem THEN 80 WHEN v_sub THEN 60 ELSE 50 END',
      'CASE WHEN v_prem THEN 200 WHEN v_sub THEN 100 ELSE 50 END');
    if v_new = v_src then
      raise notice 'cap pattern not found in %', r.proname;
      continue;
    end if;
    execute format(
      'CREATE OR REPLACE FUNCTION public.%I(%s) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS %L',
      r.proname, r.args, v_new);
    raise notice 'updated %', r.proname;
  end loop;
end $$;
