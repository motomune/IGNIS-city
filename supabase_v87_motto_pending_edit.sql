-- v87: 格言の「修正申請」を承認制にする
-- ---------------------------------------------------------------------
-- 目的：
--   すでに承認済みの格言を本人が修正申請したとき、管理者が承認するまでは
--   ・壁（ビル文字）には「元の承認済み格言」を出し続ける
--   ・修正後の文章は pending_motto_text に退避し、承認時に本採用する
--   これにより「未承認の修正がいきなり壁に出る」「却下で元の格言が消える」
--   の両方を防ぐ。
--
-- 仕組み：
--   building_profiles は (building_x, building_z) で 1 行。
--   ・新規格言         … status='pending', motto_text=本文（従来どおり）
--   ・承認済み格言の修正 … status='approved' のまま motto_text は維持し、
--                          pending_motto_text に修正本文を入れる
--   壁表示クエリは status='approved' の motto_text だけを読むので、
--   pending_motto_text は承認されるまで表示されない。
-- ---------------------------------------------------------------------

ALTER TABLE public.building_profiles
  ADD COLUMN IF NOT EXISTS pending_motto_text text,
  ADD COLUMN IF NOT EXISTS pending_submitted_at timestamptz;

-- 既存 RLS（v81）で本人＋管理者は UPDATE 可、承認済み行は全員 SELECT 可。
-- 追加カラムも同じ行に属するため、新たなポリシーは不要。
-- （pending_motto_text は本人が公開申請したテキストなので閲覧されても問題なし。
--   なお壁表示クエリは motto_text のみ select するため一般には露出しない）
