-- v128: 本人によるアカウント削除（30日の猶予つき）
--
-- 方針
--  ・消せるのは本人がボタンを押したときだけ。運営が勝手にアカウントを消すことはしない。
--  ・押した瞬間は消さず「削除予定」を立てる。30日以内に再ログインすれば自動で取り消される。
--    （このゲームの性質上、感情が動いているときに押してしまう人が出るため）
--  ・30日を過ぎた分を purge_deleted_accounts() が実際に消す。
--    メールアドレスとパスワードごと消えるよう auth.users まで削除する。
--
-- 適用済み（2026-08-15 に管理APIで実行）。

alter table public.users add column if not exists deletion_requested_at timestamptz;
create index if not exists users_deletion_requested_idx
  on public.users (deletion_requested_at) where deletion_requested_at is not null;

-- 削除を予約する（本人のみ）
create or replace function public.request_account_deletion()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid := auth.uid(); v_at timestamptz;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'reason', 'not_authenticated'); end if;
  update public.users set deletion_requested_at = now()
   where id = v_uid returning deletion_requested_at into v_at;
  if v_at is null then return jsonb_build_object('ok', false, 'reason', 'user_not_found'); end if;
  return jsonb_build_object('ok', true, 'requested_at', v_at, 'purge_after', v_at + interval '30 days');
end $$;

-- 予約を取り消す（本人のみ）。ログイン時にも自動で呼ばれる。
create or replace function public.cancel_account_deletion()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid := auth.uid(); v_had boolean;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'reason', 'not_authenticated'); end if;
  select deletion_requested_at is not null into v_had from public.users where id = v_uid;
  update public.users set deletion_requested_at = null where id = v_uid;
  return jsonb_build_object('ok', true, 'was_scheduled', coalesce(v_had,false));
end $$;

-- 予約の状態を返す（画面に「あと何日で削除されます」を出すため）
create or replace function public.get_account_deletion_state()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid := auth.uid(); v_at timestamptz;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'reason', 'not_authenticated'); end if;
  select deletion_requested_at into v_at from public.users where id = v_uid;
  if v_at is null then return jsonb_build_object('ok', true, 'scheduled', false); end if;
  return jsonb_build_object('ok', true, 'scheduled', true, 'requested_at', v_at,
    'purge_after', v_at + interval '30 days',
    'days_left', greatest(0, ceil(extract(epoch from (v_at + interval '30 days' - now()))/86400))::int);
end $$;

-- 1人ぶんを完全に消す。ユーザー行に紐づくものを全部落としてから auth.users を消す。
-- （auth.users を消すとメールアドレスとパスワードのハッシュも消える）
create or replace function public.purge_one_account(p_uid uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  delete from public.building_past_details where user_id = p_uid;
  delete from public.building_profiles     where user_id = p_uid;
  delete from public.building_candles      where user_id = p_uid;
  delete from public.candle_replies        where owner_id = p_uid or giver_id = p_uid;
  delete from public.building_inventory    where user_id = p_uid;
  delete from public.buildings             where owner_id = p_uid;
  delete from public.lands                 where owner_id = p_uid;
  delete from public.staff_employees       where user_id = p_uid;
  delete from public.user_plushies         where user_id = p_uid;
  delete from public.daily_tasks           where user_id = p_uid;
  delete from public.coins                 where user_id = p_uid;
  delete from public.gacha_results         where user_id = p_uid;
  delete from public.exchange_requests     where user_id = p_uid;
  delete from public.share_engagements     where user_id = p_uid;
  delete from public.x_reply_rewards       where user_id = p_uid;
  delete from public.x_repost_rewards      where user_id = p_uid;
  delete from public.ad_impressions        where user_id = p_uid;
  delete from public.users                 where id = p_uid;
  delete from auth.users                   where id = p_uid;
end $$;

-- 30日を過ぎた予約を実際に消す（Cronから呼ぶ）
create or replace function public.purge_deleted_accounts()
returns jsonb language plpgsql security definer set search_path=public as $$
declare r record; v_n int := 0;
begin
  for r in select id from public.users
            where deletion_requested_at is not null
              and deletion_requested_at < now() - interval '30 days'
  loop
    perform public.purge_one_account(r.id);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'purged', v_n);
end $$;

grant execute on function public.request_account_deletion()   to authenticated;
grant execute on function public.cancel_account_deletion()    to authenticated;
grant execute on function public.get_account_deletion_state() to authenticated;
-- purge 系は利用者から呼べないようにする（Cron / 管理者のみ）
revoke execute on function public.purge_one_account(uuid)     from authenticated, anon;
revoke execute on function public.purge_deleted_accounts()    from authenticated, anon;
