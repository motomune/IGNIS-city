// Supabase Edge Function: stripe-billing
// ゲーム内からの「サブスク登録（Checkout）」と「解約・プラン変更（カスタマーポータル）」の入口。
//
// 入力(body):
//   {"action":"checkout","plan":"sub"}      … 月980円サブスクの決済ページURLを返す
//   {"action":"checkout","plan":"premium"}  … 月1980円プレミアムの決済ページURLを返す
//   {"action":"portal"}                     … 解約/プラン変更用ポータルURLを返す
//
// 必要シークレット:
//   STRIPE_SECRET_KEY   … 本番は制限付きキー rk_live_（標準キー sk_live_ は使わない・2026-11-12）
//     権限：書き込み＝Checkout Sessions・Customer portal・Customers／読み取り＝Subscriptions・Products・Prices
//   ゲスト（仮アカウント）は checkout できない（guest_not_allowed）
//
// 価格IDと戻り先URLは、シークレットではなく下の定数に直書きしている。
// 理由：どちらも公開情報（決済画面のURLにも出る）で、隠す必要がない。
// シークレットに入れると画面上でハッシュしか見えず、どの商品・どのサイトを
// 指しているか二度と確認できなくなる。ここに書いてあれば見て分かる。
// 商品を作り直したりドメインを変えたら、この定数を書きかえて再デプロイする。
// （SITE_URL シークレットがあればそちらが優先されるが、通常は設定しない）
//
// デプロイ: supabase functions deploy stripe-billing

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14.25.0?target=denonext";

// 月980円「サブスク会員」    商品 prod_Ui0ZBSRif40aDu
const PRICE_SUB = "price_1TiaYKQxFv0hb0XVKTWuNfJi";
// 月1980円「プレミアム会員」 商品 prod_Ui13kz4WfMtQTV
const PRICE_PREMIUM = "price_1Tib1oQxFv0hb0XVENmkcCKT";

// 決済のあとに戻ってくるサイト。末尾に / を付けない。
const DEFAULT_SITE_URL = "https://ignis-city.motomune.com";

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
    const SITE_URL = (Deno.env.get("SITE_URL") || DEFAULT_SITE_URL).replace(/\/$/, "");
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
      .select("stripe_customer_id, x_username, is_subscribed, is_premium, is_guest")
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

      // 仮アカウント（ゲスト）は申し込めない（2026-11-12）。
      // ゲストは別のブラウザ・別の端末から入れないので、払ったあとに会員の権利ごと失ってしまう。
      // 先に本登録（メールアドレス）をしてもらう。本登録は同じIDのまま昇格するので土地やコインは引き継がれる。
      if ((user as any).is_anonymous || (urow as any)?.is_guest === true) {
        return json({ error: "guest_not_allowed" }, 403);
      }

      // すでに続いているサブスクがある場合は二重課金を防ぎ、ポータル（プラン変更/解約）へ誘導。
      // 「支払いが遅れている（past_due/unpaid）」も続いている扱い（以前は active だけ見ていた＝2重に申し込めた）。
      if (customerId) {
        const subs = await stripe.subscriptions.list({ customer: customerId, status: "all", limit: 10 });
        const live = subs.data.filter((s) => ["active", "trialing", "past_due", "unpaid"].includes(s.status));
        if (live.length > 0) {
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
