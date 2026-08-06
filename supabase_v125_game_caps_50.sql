-- v125: ミニゲームの1日反映上限を引き上げ（無課金30→50 / サブスク40→60 / プレミア60→80）
--
-- 上限を決めているのはサーバー側のこの2関数。クライアントの gameDailyCap() は
-- 表示と ?cap= の受け渡しに使っているだけなので、こちらを変えないと実際の付与は増えない。
-- 無課金だけを50にするとサブスク(40)を追い越してしまうため、上位ティアも同じ幅で引き上げる。
--
-- 変更点は CASE 式の1行のみ。判定ロジック（JST20時境界・1日1回）は元のまま。
--
-- 適用済み（2026-08-04 に管理APIで実行）。

-- 関数本体の中の上限テーブルだけを置き換える（定義の他の部分は触らない）
do $$
declare
  r record;
  v_src text;
  v_new text;
  v_args text;
begin
  for r in
    -- identity_arguments だと DEFAULT が落ちて CREATE OR REPLACE が
    -- 「既存関数から既定値は外せない」と怒られる。既定値込みの arguments を使う。
    select p.oid, p.proname,
           pg_get_function_arguments(p.oid) as args,
           p.prosrc
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('claim_lifegame_reward','claim_antgame_reward')
  loop
    v_src := r.prosrc;
    v_new := replace(v_src,
      'CASE WHEN v_prem THEN 60 WHEN v_sub THEN 40 ELSE 30 END',
      'CASE WHEN v_prem THEN 80 WHEN v_sub THEN 60 ELSE 50 END');
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
