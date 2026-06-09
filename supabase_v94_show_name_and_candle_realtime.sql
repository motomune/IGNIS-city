-- v94: Xユーザー名の表示ON/OFF設定 ＋ 蝋燭(building_candles)のリアルタイム配信

-- 1) 各ユーザーの「ビル詳細/ランキングでXユーザー名を表示するか」（既定: 表示）
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS show_x_username boolean DEFAULT true;

-- 2) 蝋燭のリアルタイム更新（HUDの受け取り本数をその場で増減）
--    DELETE時に building_x/z を受け取れるよう REPLICA IDENTITY FULL に。
ALTER TABLE public.building_candles REPLICA IDENTITY FULL;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.building_candles;
EXCEPTION
  WHEN duplicate_object THEN NULL;  -- 既に追加済みならスキップ
  WHEN undefined_object THEN NULL;  -- publicationが無い環境はスキップ（ダッシュボードで有効化）
END $$;
