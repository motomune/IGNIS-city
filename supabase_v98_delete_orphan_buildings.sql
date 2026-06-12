-- v98: 買える土地の範囲内（保護区を除く）にある「所有者不明（土地未所有）」のビルをDBから削除
--   ゲーム側(v127)は表示から取り除き済み。これを実行するとデータ自体も消えて読み込みも軽くなる。
--   保護区（中央5x5、|x|<=20 かつ |z|<=20）は購入不可エリアなので景観として残す。

-- 実行前に対象件数を確認したい場合：
-- SELECT COUNT(*) FROM buildings b
-- WHERE NOT EXISTS (SELECT 1 FROM lands l WHERE l.grid_x = b.x AND l.grid_z = b.z)
--   AND abs(b.x) <= 100 AND abs(b.z) <= 100
--   AND NOT (abs(b.x) <= 20 AND abs(b.z) <= 20);

DELETE FROM buildings b
WHERE NOT EXISTS (SELECT 1 FROM lands l WHERE l.grid_x = b.x AND l.grid_z = b.z)
  AND abs(b.x) <= 100 AND abs(b.z) <= 100
  AND NOT (abs(b.x) <= 20 AND abs(b.z) <= 20);
