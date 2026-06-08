-- v90: シェアタスク（創設者の最新投稿へのリプライ/リポストで達成）用テーブル
-- 既存の x-reward-batch（リポスト+15/リプライ+10・全投稿スキャン）とは別系統。
-- 同期 Edge Function (share-sync) が since_id + 既読IDで二度読み＝再カウントを防ぐ。

-- 創設者の追跡対象ツイート（最新投稿の表示元・エンゲージ照合の対象）
create table if not exists public.creator_posts (
  tweet_id            text primary key,
  author_username     text,
  text                text,
  url                 text,
  posted_at           timestamptz,
  last_reply_since_id text,          -- リプライ取得の since_id（次回は新着のみ取得）
  replies_synced_at   timestamptz,
  reposts_synced_at   timestamptz,
  created_at          timestamptz default now()
);
alter table public.creator_posts enable row level security;
-- 表示用に全員読み取り可。書き込みは service role のみ（RLSはバイパスされる）。
drop policy if exists creator_posts_public_read on public.creator_posts;
create policy creator_posts_public_read on public.creator_posts
  for select to anon, authenticated using (true);

-- どのゲームユーザーが、どの投稿に、どう反応したか（達成判定の根拠）
create table if not exists public.share_engagements (
  user_id    uuid not null references public.users(id) on delete cascade,
  tweet_id   text not null references public.creator_posts(tweet_id) on delete cascade,
  kind       text not null check (kind in ('reply','repost')),
  x_user_id  text,
  engaged_at timestamptz default now(),
  primary key (user_id, tweet_id, kind)
);
alter table public.share_engagements enable row level security;
-- 本人だけ自分のエンゲージを読める（フロントの達成判定用）。書き込みは service role のみ。
drop policy if exists share_engagements_own_read on public.share_engagements;
create policy share_engagements_own_read on public.share_engagements
  for select to authenticated using (auth.uid() = user_id);

-- マッチング高速化＆将来用に X の数値IDをキャッシュ（任意）
alter table public.users add column if not exists x_user_id text;

create index if not exists idx_creator_posts_posted_at on public.creator_posts(posted_at desc);
create index if not exists idx_share_engagements_tweet on public.share_engagements(tweet_id);
