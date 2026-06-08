-- v89: 過去詳細の英訳列 + RPC更新 + 毎日の自動英訳(Cron)
-- 格言(v88: building_profiles.motto_text_en)に加えて、過去詳細の自由記述も DeepL 英訳する。
-- DeepL で翻訳できなかった分（枠超過など）は、未翻訳(NULL)の行だけ拾う設計なので
-- 毎日のCronで枠が復活し次第まとめて自動翻訳される。

-- 1) 英訳キャッシュ列（自由記述の2項目）
ALTER TABLE public.building_past_details
  ADD COLUMN IF NOT EXISTS background_detail_en text,
  ADD COLUMN IF NOT EXISTS current_positive_en  text;

-- 2) get_past_detail_full が英訳列も返すように更新（英語モードで表示するため）
CREATE OR REPLACE FUNCTION get_past_detail_full(bx integer, bz integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_row building_past_details;
  v_subscribed boolean;
BEGIN
  SELECT is_subscribed INTO v_subscribed FROM users WHERE id = v_uid;
  IF NOT COALESCE(v_subscribed, false) THEN
    RETURN jsonb_build_object('error','subscription_required');
  END IF;
  SELECT * INTO v_row FROM building_past_details
  WHERE building_x = bx AND building_z = bz AND status = 'approved';
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'lost_items', v_row.lost_items,
    'gained_items', v_row.gained_items,
    'current_positive', v_row.current_positive,
    'current_positive_en', v_row.current_positive_en,
    'current_stage', v_row.current_stage,
    'background_detail', v_row.background_detail,
    'background_detail_en', v_row.background_detail_en,
    'how_handled', v_row.how_handled,
    'what_happened_after', v_row.what_happened_after,
    'journey_to_now', v_row.journey_to_now
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_past_detail_full(integer, integer) TO authenticated;

-- 3) 毎日の自動英訳（未翻訳をまとめて拾う）。pg_cron + pg_net で Edge Function を呼ぶ。
--    ※ 下の <...> を自分の値に置き換えてから実行してください。
--    ※ pg_cron / pg_net が未有効ならダッシュボード(Database > Extensions)で有効化。
--    ※ ダッシュボードの Edge Functions > Cron からスケジュールしてもOK（その場合は下は不要）。
--
-- 【重要】関数の JWT 検証が既定(ON)のままだと、Authorization 無しの呼び出しは
--   ゲートウェイで 401 になる。対策は次のどちらか:
--     (A) 関数を JWT 検証なしで再デプロイ:  supabase functions deploy translate-motto --no-verify-jwt
--         → その場合、下の Authorization/apikey ヘッダは無くてもよい（x-cron-secret だけで可）。
--     (B) 下のように匿名キーを Authorization/apikey に付ける（再デプロイ不要）。
--   いずれにせよ x-cron-secret は CRON_SECRET と完全一致させること。
--
-- create extension if not exists pg_cron;
-- create extension if not exists pg_net;
--
-- select cron.schedule(
--   'translate-pending-daily',
--   '17 3 * * *',                       -- 毎日 03:17 UTC（=日本 12:17）に実行
--   $$
--   select net.http_post(
--     url     := 'https://<PROJECT_REF>.supabase.co/functions/v1/translate-motto',
--     headers := jsonb_build_object(
--                  'Content-Type','application/json',
--                  'Authorization','Bearer <SUPABASE_ANON_KEY>',  -- 方法(A)で再デプロイ済みなら不要
--                  'apikey','<SUPABASE_ANON_KEY>',                -- 方法(A)で再デプロイ済みなら不要
--                  'x-cron-secret','<CRON_SECRET>'
--                ),
--     body    := '{}'::jsonb
--   );
--   $$
-- );
--
-- 解除する場合: select cron.unschedule('translate-pending-daily');
