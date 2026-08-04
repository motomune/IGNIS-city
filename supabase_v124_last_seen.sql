-- v124: 最終ログイン（last_seen_at）
--
-- ビル詳細に「オーナーが最後にゲームを開いた日時」を出すための列。
-- 更新はクライアントからの直接 update（users_update_self ポリシーで自分の行だけ書ける）、
-- 参照は users_select_public でそのまま読める。専用のRPCは要らない。
--
-- 適用済み（2026-08-04 に管理APIで実行）。

alter table public.users add column if not exists last_seen_at timestamptz;

-- 既存ユーザーは登録日を初期値にしておく（NULL のままだと全員「不明」になってしまうため）
update public.users set last_seen_at = created_at where last_seen_at is null;

-- 「7日以上動いていない土地」を探す運用クエリで使うので索引を張っておく
create index if not exists users_last_seen_at_idx on public.users (last_seen_at desc nulls last);
