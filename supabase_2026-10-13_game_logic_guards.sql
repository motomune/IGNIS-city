-- IGNIS CITY：ゲーム進行の抜け穴をふさぐ（2026-10-13）
--
-- 実証した穴（ログインさえすれば誰でもできた。実際に試して成功を確認）
--   (1) 自分の区画でない座標に、何棟でも、32767階までビルを挿入できた（街の荒らし）
--   (2) 格言・過去詳細を自分で status='approved' にでき、審査を通さず街に出せた。
--       さらに他人の座標の行を先に作れるので、持ち主が書けなくなる（UNIQUE(x,z)の乗っ取り）
--   (3) 承認済みの過去詳細（＝有料会員向けの全文）が、ログインさえすれば表から直接読めた
--   (4) 自分のビルの閲覧数（view_count / view_total）を自分で書きかえられた
--   (5) ミニゲームの成績を上限なく申告でき、ランキングを好きな数字にできた
--
-- 直し方：列ごとの権限 ＋ BEFORE トリガー。
-- 運営のRPCは全部 SECURITY DEFINER（実行者は postgres）なので、
-- current_user が 'authenticated'/'anon' のときだけ検査する作りにすれば影響しない。

-- ============================================================
-- (1) ビル：自分の区画・1区画1棟・1〜300階だけ
-- ============================================================
create or replace function public.buildings_guard()
returns trigger language plpgsql as $fn$
declare
  FOUNDER constant uuid := 'afc818cd-d2fa-4c1c-8460-9dbce9e60e37';
begin
  -- 運営のRPC（SECURITY DEFINER=postgres）や管理バッチはそのまま通す
  if current_user not in ('authenticated','anon') then return new; end if;

  if new.floors is null or new.floors < 1 or new.floors > 300 then
    raise exception '階数は1〜300です（受け取った値: %）', new.floors;
  end if;
  if coalesce(new.employees,0) < 0 then
    raise exception '従業員数が不正です';
  end if;

  if tg_op = 'INSERT' then
    if new.owner_id is distinct from auth.uid() then
      raise exception '他人の名義では建てられません';
    end if;
    if new.owner_id <> FOUNDER then
      if not exists (
        select 1 from public.lands l
         where l.grid_x = new.x::int and l.grid_z = new.z::int
           and l.owner_id = new.owner_id
      ) then
        raise exception '自分の区画にだけ建てられます（%, %）', new.x, new.z;
      end if;
      if exists (select 1 from public.buildings b where b.x = new.x and b.z = new.z) then
        raise exception 'この区画にはすでにビルがあります';
      end if;
    end if;
  else
    if new.owner_id is distinct from old.owner_id
       or new.x is distinct from old.x
       or new.z is distinct from old.z then
      raise exception 'ビルの持ち主と位置は変えられません';
    end if;
    -- 閲覧数は record_building_view（サーバー）だけが増やす
    new.view_count := old.view_count;
    new.view_total := old.view_total;
  end if;
  return new;
end $fn$;

drop trigger if exists trg_buildings_guard on public.buildings;
create trigger trg_buildings_guard
  before insert or update on public.buildings
  for each row execute function public.buildings_guard();

-- 列の権限（表ごとの許可は列の拒否より強いので、まず表から外す）
revoke insert, update on table public.buildings from public, anon, authenticated;
grant insert (x, z, floors, style, owner_id, employees) on public.buildings to authenticated;
grant update (floors, style, employees)                 on public.buildings to authenticated;

-- ============================================================
-- (2) 格言（building_profiles）：審査状態は本人に触らせない
-- ============================================================
create or replace function public.building_profiles_guard()
returns trigger language plpgsql as $fn$
declare
  FOUNDER constant uuid := 'afc818cd-d2fa-4c1c-8460-9dbce9e60e37';
begin
  if current_user not in ('authenticated','anon') then return new; end if;
  if auth.uid() = FOUNDER then return new; end if;   -- 運営の審査操作

  new.user_id := auth.uid();
  if not exists (
    select 1 from public.lands l
     where l.grid_x = new.building_x and l.grid_z = new.building_z
       and l.owner_id = auth.uid()
  ) then
    raise exception '自分の区画のビルにだけ書けます';
  end if;

  if tg_op = 'INSERT' then
    new.status        := 'pending';
    new.reviewed_at   := null;
    new.motto_text_en := null;
  else
    new.reviewed_at   := old.reviewed_at;
    new.motto_text_en := old.motto_text_en;
    if old.status = 'approved' then
      -- 承認ずみの格言は差しかえさせない（修正は pending_motto_text を通す）
      new.status     := 'approved';
      new.motto_text := old.motto_text;
      new.notes_text := old.notes_text;
    else
      new.status := 'pending';   -- 再申請は必ず審査待ちへ
    end if;
  end if;
  return new;
end $fn$;

drop trigger if exists trg_building_profiles_guard on public.building_profiles;
create trigger trg_building_profiles_guard
  before insert or update on public.building_profiles
  for each row execute function public.building_profiles_guard();

-- ============================================================
-- (3) 過去詳細（building_past_details）
--     ・自分で承認できない
--     ・承認後に中身を書きかえたら必ず審査待ちに戻る
--     ・他人の承認済み全文を表から直接読めない（有料会員向けはRPCだけ）
-- ============================================================
create or replace function public.building_past_details_guard()
returns trigger language plpgsql as $fn$
declare
  FOUNDER constant uuid := 'afc818cd-d2fa-4c1c-8460-9dbce9e60e37';
  changed boolean;
begin
  if current_user not in ('authenticated','anon') then return new; end if;
  if auth.uid() = FOUNDER then return new; end if;

  new.user_id := auth.uid();
  if not exists (
    select 1 from public.lands l
     where l.grid_x = new.building_x and l.grid_z = new.building_z
       and l.owner_id = auth.uid()
  ) then
    raise exception '自分の区画のビルにだけ書けます';
  end if;

  if tg_op = 'INSERT' then
    new.status := 'pending';
    new.background_detail_en    := null;
    new.how_handled_en          := null;
    new.what_happened_after_en  := null;
    new.journey_to_now_en       := null;
    new.current_positive_en     := null;
    new.rejected_reason         := null;
  else
    changed := (new.lost_items, new.gained_items, new.background_detail,
                new.how_handled, new.what_happened_after, new.journey_to_now,
                new.current_positive, new.current_stage)
            is distinct from
               (old.lost_items, old.gained_items, old.background_detail,
                old.how_handled, old.what_happened_after, old.journey_to_now,
                old.current_positive, old.current_stage);
    if changed then
      -- 中身を直したら、承認ずみでも必ず審査からやり直す（承認後のすり替え防止）
      new.status := 'pending';
      new.background_detail_en   := null;
      new.how_handled_en         := null;
      new.what_happened_after_en := null;
      new.journey_to_now_en      := null;
      new.current_positive_en    := null;
    else
      new.status := old.status;
      new.background_detail_en   := old.background_detail_en;
      new.how_handled_en         := old.how_handled_en;
      new.what_happened_after_en := old.what_happened_after_en;
      new.journey_to_now_en      := old.journey_to_now_en;
      new.current_positive_en    := old.current_positive_en;
    end if;
    new.rejected_reason := old.rejected_reason;
  end if;
  return new;
end $fn$;

drop trigger if exists trg_building_past_details_guard on public.building_past_details;
create trigger trg_building_past_details_guard
  before insert or update on public.building_past_details
  for each row execute function public.building_past_details_guard();

-- 有料会員向けの全文が「ログインすれば表から読める」状態だったのを閉じる。
-- 読み方は get_past_detail_preview / get_past_detail_full（SECURITY DEFINER）だけに戻す。
-- 自分の行を読む past_details_select_own と、運営の past_details_admin_read_all は残す。
-- 方針を元に戻したいときは using (status = 'approved') に書き換える。
alter policy past_details_select_approved_public
  on public.building_past_details
  using (false);

-- ============================================================
-- (4) ミニゲームの成績：申告できる上限を決める
-- ============================================================
create or replace function public.record_minigame_stat(p_kind text, p_value integer)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
DECLARE
  v_uid uuid := auth.uid();
  v_max constant integer := 10000000;   -- 1000万。実際の到達域をはるかに超える天井
  v_val integer := LEAST(GREATEST(COALESCE(p_value, 0), 0), v_max);
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;
  IF p_kind = 'lifegame' THEN
    UPDATE users SET lifegame_money = v_val WHERE id = v_uid;
  ELSIF p_kind = 'antgame' THEN
    UPDATE users SET antgame_coins = GREATEST(COALESCE(antgame_coins,0), v_val) WHERE id = v_uid;
  ELSE
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_kind');
  END IF;
  RETURN jsonb_build_object('ok', true);
END $fn$;

revoke execute on function public.record_minigame_stat(text, integer) from public, anon;
grant  execute on function public.record_minigame_stat(text, integer) to authenticated;

-- ============================================================
-- (5) 1人が1日に作れる行数の天井（在庫切れDoS対策）
--     coins / building_inventory / game_invites は本人名義でいくらでも挿入でき、
--     無料枠500MBを埋めてデータベースを読み取り専用に落とせる
--     （＝全員がゲームを続けられなくなる）。通常の遊びでは1日数十行。
-- ============================================================
alter function public.buildings_guard()             set search_path = public;
alter function public.building_profiles_guard()     set search_path = public;
alter function public.building_past_details_guard() set search_path = public;

create or replace function public.throttle_daily_rows()
returns trigger language plpgsql set search_path = public as $fn$
declare
  lim  int  := coalesce(nullif(tg_argv[0],'')::int, 1000);
  ucol text := tg_argv[1];
  uid  uuid;
  n    int;
begin
  if current_user not in ('authenticated','anon') then return new; end if;
  uid := (to_jsonb(new) ->> ucol)::uuid;
  if uid is null then return new; end if;
  execute format(
    'select count(*) from public.%I where %I = $1 and created_at > now() - interval ''1 day''',
    tg_table_name, ucol
  ) into n using uid;
  if n >= lim then
    raise exception '1日に作れる % の件数（%件）を超えました', tg_table_name, lim;
  end if;
  return new;
end $fn$;

create index if not exists coins_user_created_idx on public.coins(user_id, created_at);

create trigger trg_coins_throttle before insert on public.coins
  for each row execute function public.throttle_daily_rows('2000','user_id');
create trigger trg_inventory_throttle before insert on public.building_inventory
  for each row execute function public.throttle_daily_rows('500','user_id');
create trigger trg_invites_throttle before insert on public.game_invites
  for each row execute function public.throttle_daily_rows('200','inviter_id');

-- ============================================================
-- 適用の記録：2026-10-13 に本番へ反映ずみ（MCP apply_migration）。
--   game_logic_guard_triggers / buildings_column_grants /
--   past_details_close_paywall_read / minigame_stat_clamp /
--   throttle_fn_and_search_path
-- 反映後に、巻き戻す前提のDOブロックで実際に攻撃を再現して確認した：
--   遠い座標30000階=拒否 / 他人の区画=拒否 / 自分でapproved=pendingに矯正 /
--   閲覧数の書きかえ=拒否 / 他人の承認済み全文の直読み=0件 /
--   正常系（自分の区画への申請・自分のビル更新・コイン台帳1件）=すべて成功
-- ============================================================
