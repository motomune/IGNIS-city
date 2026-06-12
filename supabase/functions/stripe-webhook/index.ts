// Supabase Edge Function: stripe-webhook
// Stripeからの通知を受けて users.is_subscribed / is_premium を自動で更新する。
//   - 決済完了           → ON（980円=サブスク / 1980円=プレミアム＋サブスク扱い）
//   - 解約・支払い失敗   → OFF
//
// 必要シークレット:
//   STRIPE_SECRET_KEY      … sk_test_/sk_live_
//   STRIPE_WEBHOOK_SECRET  … whsec_...（StripeのWebhook設定画面で発行）
//   PRICE_SUB / PRICE_PREMIUM … 各プランの価格ID
//
// デプロイ（Stripeが呼ぶのでJWT検証は無効に）:
//   supabase functions deploy stripe-webhook --no-verify-jwt
//
// Stripe側の設定（ダッシュボード → 開発者 → Webhook → エンドポイントを追加）:
//   URL: https://xssjhgosxyhknonlrjrq.supabase.co/functions/v1/stripe-webhook
//   イベント: checkout.session.completed / customer.subscription.updated / customer.subscription.deleted

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14.25.0?target=denonext";

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  try {
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
    const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const STRIPE_KEY = Deno.env.get("STRIPE_SECRET_KEY");
    const WEBHOOK_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET");
    const PRICE_SUB = Deno.env.get("PRICE_SUB") || "";
    const PRICE_PREMIUM = Deno.env.get("PRICE_PREMIUM") || "";
    if (!STRIPE_KEY || !WEBHOOK_SECRET) return json({ error: "stripe secrets not set" }, 500);

    const stripe = new Stripe(STRIPE_KEY, {
      apiVersion: "2024-04-10",
      httpClient: Stripe.createFetchHttpClient(),
    });
    const cryptoProvider = Stripe.createSubtleCryptoProvider();

    // 署名検証（Stripe以外からの偽リクエストを拒否）
    const sig = req.headers.get("stripe-signature");
    const rawBody = await req.text();
    let event: Stripe.Event;
    try {
      event = await stripe.webhooks.constructEventAsync(rawBody, sig!, WEBHOOK_SECRET, undefined, cryptoProvider);
    } catch (e) {
      console.warn("signature verification failed", String(e));
      return json({ error: "bad_signature" }, 400);
    }

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    // 価格IDからプランを判定して users のフラグを更新
    const applyPlan = async (userId: string, priceId: string | null, active: boolean, customerId?: string | null) => {
      const isPremium = active && priceId === PRICE_PREMIUM;
      const isSub = active && (priceId === PRICE_SUB || isPremium); // プレミアムはサブスク特典も含む
      const patch: Record<string, unknown> = { is_subscribed: isSub, is_premium: isPremium };
      if (customerId) patch.stripe_customer_id = customerId;
      const { error } = await admin.from("users").update(patch).eq("id", userId);
      if (error) console.error("users update failed", userId, error.message);
      else console.log("plan applied", userId, { isSub, isPremium, priceId, active });
    };

    // customer_id からゲームユーザーを引く（subscription系イベント用）
    const findUserByCustomer = async (customerId: string): Promise<string | null> => {
      const { data } = await admin.from("users").select("id").eq("stripe_customer_id", customerId).limit(1);
      return data && data[0] ? (data[0] as any).id : null;
    };

    if (event.type === "checkout.session.completed") {
      const session = event.data.object as Stripe.Checkout.Session;
      const userId = session.client_reference_id || (session.metadata as any)?.user_id;
      const customerId = typeof session.customer === "string" ? session.customer : session.customer?.id;
      if (userId && session.subscription) {
        const subId = typeof session.subscription === "string" ? session.subscription : session.subscription.id;
        const sub = await stripe.subscriptions.retrieve(subId);
        const priceId = sub.items.data[0]?.price?.id || null;
        const active = sub.status === "active" || sub.status === "trialing";
        await applyPlan(userId, priceId, active, customerId);
      }
    } else if (event.type === "customer.subscription.updated" || event.type === "customer.subscription.deleted") {
      const sub = event.data.object as Stripe.Subscription;
      const customerId = typeof sub.customer === "string" ? sub.customer : sub.customer.id;
      const userId = (sub.metadata as any)?.user_id || await findUserByCustomer(customerId);
      if (userId) {
        const priceId = sub.items.data[0]?.price?.id || null;
        const active = event.type !== "customer.subscription.deleted" &&
          (sub.status === "active" || sub.status === "trialing");
        await applyPlan(userId, priceId, active, customerId);
      }
    }

    return json({ received: true });
  } catch (e) {
    console.error("stripe-webhook", e);
    return json({ error: String((e as any)?.message || e) }, 500);
  }
});
