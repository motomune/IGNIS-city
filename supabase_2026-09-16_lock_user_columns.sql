-- 2026-09-16 サーバー安全点検で見つけた穴を閉じる
--
-- ログイン中のプレイヤーが、ブラウザから自分の users 行の「どの列でも」書きかえられた。
-- is_premium / is_subscribed を true にすれば無料で有料会員になれた（実証済み・ロールバック）。
-- ゲーム本体（index.html）が実際に書いている列だけを許可し、会員フラグ・決済情報は
-- サーバー（Stripe Webhook = service_role）しか書けないようにする。
--
-- 注意：index.html で users に新しい列を書くようにしたら、ここの grant update に足すこと。
--       足さないと「permission denied for column」で保存が失敗する。

-- 1) 書きこみ：列単位で許可しなおす（表全体の権限が残っていると列の剥奪は効かない）
revoke insert, update on table public.users from public, anon, authenticated;
grant update (id, username, x_username, rank, coin_column, bench_employees,
              is_guest, last_seen_at, show_x_username)
  on public.users to authenticated;
grant insert (id, username, x_username, rank, coin_column, is_guest)
  on public.users to authenticated;

-- 2) 読みとり：他人に見せる必要のない列を外す（Stripe顧客ID・X内部ID・削除予約日など）
revoke select on table public.users from public, anon, authenticated;
grant select (id, created_at, username, rank, coin_column, x_username, bench_employees,
              total_views, is_subscribed, show_x_username, is_premium, is_guest, last_seen_at)
  on public.users to anon, authenticated;

-- 3) 使われていない「好きな額のコインを自分に足せる」関数を閉じる
--    （anon から剥奪しても PUBLIC 経由で呼べてしまうので PUBLIC からも剥奪する）
revoke execute on function public.add_coins_and_record(integer, text) from public, anon, authenticated;

-- 4) search_path が固定されていない関数を固定（Supabase アドバイザーの警告）
alter function public.calc_sell_reward(integer)                 set search_path = public;
alter function public.calc_sell_coin_multiplier(integer)        set search_path = public;
alter function public.calc_sell_coin_reward(integer, integer)   set search_path = public;
alter function public.calc_sell_total_floors(integer, integer)  set search_path = public;
alter function public.lands_block_reserved()                    set search_path = public;
