// Supabase Edge Function: stripe-billing
// ゲーム内からの「サブスク登録（Checkout）」と「解約・プラン変更（カスタマーポータル）」の入口。
//
// 入力(body):
//   {"action":"checkout","plan":"sub"}      … 月980円サブスクの決済ページURLを返す
//   {"action":"checkout","plan":"premium"}  … 月1980円プレミアムの決済ページURLを返す
//   {"action":"portal"}                     … 解約/プラン変更用ポータルURLを返す
//
// 必要シークレット:
//   STRIPE_SECRET_KEY   … sk_test_/sk_live_
//   PRICE_SUB           … 980円プランの価格ID (price_...)
//   PRICE_PREMIUM       … 1980円プランの価格ID (price_...)
//   SITE_URL            … 例 https://motomune.github.io/IGNIS-city （省略時はこのURL）
//
// デプロイ: supabase functions deploy stripe-billing

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14.25.0?target=denonext";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
    const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
    const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const STRIPE_KEY = Deno.env.get("STRIPE_SECRET_KEY");
    const PRICE_SUB = Deno.env.get("PRICE_SUB");
    const PRICE_PREMIUM = Deno.env.get("PRICE_PREMIUM");
    const SITE_URL = (Deno.env.get("SITE_URL") || "https://motomune.github.io/IGNIS-city").replace(/\/$/, "");
    if (!STRIPE_KEY) return json({ error: "STRIPE_SECRET_KEY not set" }, 500);

    // 呼び出したユーザーをJWTで特定
    const authHeader = req.headers.get("Authorization") || "";
    const userClient = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authHeader } } });
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) return json({ error: "not_authenticated" }, 401);

    const stripe = new Stripe(STRIPE_KEY, {
      apiVersion: "2024-04-10",
      httpClient: Stripe.createFetchHttpClient(),
    });
    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    const body = await req.json().catch(() => ({}));
    const action = body?.action;

    // 既存のStripe顧客ID（あれば）
    const { data: urow } = await admin.from("users")
      .select("stripe_customer_id, x_username, is_subscribed, is_premium")
      .eq("id", user.id).single();
    const customerId: string | null = (urow as any)?.stripe_customer_id || null;

    if (action === "portal") {
      if (!customerId) return json({ error: "no_customer" }, 400);
      const session = await stripe.billingPortal.sessions.create({
        customer: customerId,
        return_url: `${SITE_URL}/index.html`,
      });
      return json({ url: session.url });
    }

    if (action === "checkout") {
      const plan = body?.plan === "premium" ? "premium" : "sub";
      const price = plan === "premium" ? PRICE_PREMIUM : PRICE_SUB;
      if (!price) return json({ error: `price not set (${plan})` }, 500);

      // すでに有効なサブスクがある場合は二重課金を防ぎ、ポータル（プラン変更/解約）へ誘導
      if (customerId) {
        const subs = await stripe.subscriptions.list({ customer: customerId, status: "active", limit: 1 });
        if (subs.data.length > 0) {
          const portal = await stripe.billingPortal.sessions.create({
            customer: customerId,
            return_url: `${SITE_URL}/index.html`,
          });
          return json({ url: portal.url, portal: true });
        }
      }

      const session = await stripe.checkout.sessions.create({
        mode: "subscription",
        line_items: [{ price, quantity: 1 }],
        automatic_tax: { enabled: true },     // Stripe Tax（海外税の自動計算）
        ...(customerId
          ? { customer: customerId, customer_update: { address: "auto" } }
          : { customer_email: user.email || undefined }),
        client_reference_id: user.id,         // Webhookでゲームユーザーと紐づける
        success_url: `${SITE_URL}/index.html?sub=success`,
        cancel_url: `${SITE_URL}/index.html?sub=cancel`,
        metadata: { user_id: user.id, plan },
        subscription_data: { metadata: { user_id: user.id, plan } },
      });
      return json({ url: session.url });
    }

    return json({ error: "unknown_action" }, 400);
  } catch (e) {
    console.error("stripe-billing", e);
    return json({ error: String((e as any)?.message || e) }, 500);
  }
});
