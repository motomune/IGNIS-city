-- v100: Stripe課金の下準備
--   users にStripe顧客IDを追加（Webhookがゲームユーザーと決済を紐づけるために使う）

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS stripe_customer_id text;

CREATE INDEX IF NOT EXISTS idx_users_stripe_customer ON public.users(stripe_customer_id);
