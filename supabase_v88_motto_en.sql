-- v88: ビル壁の格言の英訳キャッシュ列
-- 承認時に DeepL で1回だけ英訳して保存し、英語モードで壁に表示する。
-- （全員で共有するため翻訳APIの消費は「格言1件につき生涯1回」）

ALTER TABLE public.building_profiles
  ADD COLUMN IF NOT EXISTS motto_text_en text;

-- 既存の RLS で十分:
--   - 公開読み取り: status='approved' の行は誰でも SELECT 可（motto_text_en も読める）
--   - 書き込み: 本人 + 管理者のみ（bprofiles_update_own_or_admin）
-- 追加ポリシーは不要。
