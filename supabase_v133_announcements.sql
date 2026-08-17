-- v133: 全ユーザーへのお知らせ（規約変更の周知用）
--
-- 民法548条の4により、規約を変更するときは「変更後の内容」と「効力発生時期」を
-- あらかじめ周知しなければ効力が生じない。口頭やSNSではなく、サービス内で
-- 全員に届く経路が要る。ゲーム内の🔔通知パネルへ流し込むための土台。
--
-- ・announcements … 運営が出すお知らせ。誰でも読める（ログイン前でも見える）。
-- ・作成・更新・削除は創設者のみ。
-- ・kind='terms' は規約変更の周知。effective_at に効力発生日を入れる。
--
-- 適用済み（2026-08-15 に管理APIで実行）。

create table if not exists public.announcements (
  id           uuid primary key default gen_random_uuid(),
  kind         text        not null default 'info',   -- 'terms' | 'maintenance' | 'event' | 'info'
  title_ja     text        not null,
  title_en     text,
  body_ja      text        not null,
  body_en      text,
  effective_at timestamptz,                            -- 規約変更の効力発生日
  published_at timestamptz not null default now(),
  created_at   timestamptz not null default now()
);

create index if not exists announcements_published_idx
  on public.announcements (published_at desc);

alter table public.announcements enable row level security;

-- 読むのは誰でも（未ログインの人にも規約変更は届くべき）
drop policy if exists announcements_select_all on public.announcements;
create policy announcements_select_all on public.announcements
  for select using (true);

-- 書けるのは創設者だけ
drop policy if exists announcements_write_founder on public.announcements;
create policy announcements_write_founder on public.announcements
  for all
  using (auth.uid() = 'afc818cd-d2fa-4c1c-8460-9dbce9e60e37'::uuid)
  with check (auth.uid() = 'afc818cd-d2fa-4c1c-8460-9dbce9e60e37'::uuid);

grant select on public.announcements to anon, authenticated;
grant insert, update, delete on public.announcements to authenticated;
