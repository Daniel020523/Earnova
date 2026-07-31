// supabase/functions/verify-paystack/index.ts
//
// Deploy with:
//   supabase functions deploy verify-paystack
//
// Required secrets (set with `supabase secrets set KEY=value`):
//   PAYSTACK_SECRET_KEY   - your Paystack secret key (sk_...), never exposed to the client
//   SUPABASE_URL          - auto-provided by Supabase at runtime
//   SUPABASE_SERVICE_ROLE_KEY - auto-provided by Supabase at runtime
//
// This function is the only thing allowed to write real affiliate_sales
// rows. It re-checks the payment against Paystack directly rather than
// trusting whatever the browser claims happened, and it uses the service
// role key (bypasses RLS) only after that check passes.
//
// NOTE: assumes products.commission_rate is a PERCENTAGE (e.g. 10 = 10%).
// If it's actually stored as a fraction (0.1 = 10%), delete the "/ 100"
// in the commissionAmount calculation below.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const PAYSTACK_SECRET_KEY = Deno.env.get("PAYSTACK_SECRET_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { reference, product_id, ref_code, buyer_name, buyer_email } = await req.json();

    if (!reference || !product_id || !buyer_email) {
      return json({ verified: false, reason: "missing_params" }, 400);
    }

    const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // 1. Already processed this reference? (prevents replay / double-crediting)
    const { data: existing } = await supabaseAdmin
      .from("affiliate_sales")
      .select("id")
      .eq("paystack_reference", reference)
      .maybeSingle();

    if (existing) {
      return json({ verified: true, already_recorded: true });
    }

    // 2. Look up the product server-side — never trust a price from the client.
    const { data: product, error: productError } = await supabaseAdmin
      .from("products")
      .select("id, price, commission_rate, is_active")
      .eq("id", product_id)
      .single();

    if (productError || !product || !product.is_active) {
      return json({ verified: false, reason: "product_not_found" }, 404);
    }

    // 3. Verify the transaction directly with Paystack.
    const paystackResp = await fetch(
      `https://api.paystack.co/transaction/verify/${encodeURIComponent(reference)}`,
      { headers: { Authorization: `Bearer ${PAYSTACK_SECRET_KEY}` } }
    );
    const paystackData = await paystackResp.json();

    if (!paystackResp.ok || !paystackData.status || !paystackData.data) {
      return json({ verified: false, reason: "paystack_lookup_failed" }, 502);
    }

    const tx = paystackData.data;

    if (tx.status !== "success") {
      return json({ verified: false, reason: "payment_not_successful" });
    }

    // 4. Confirm the amount actually paid matches the product's price (kobo).
    const expectedKobo = Math.round(Number(product.price) * 100);
    if (tx.amount !== expectedKobo) {
      return json({ verified: false, reason: "amount_mismatch" }, 400);
    }

    // 5. Confirm the product referenced in Paystack metadata matches too.
    if (tx.metadata && tx.metadata.product_id && tx.metadata.product_id !== product_id) {
      return json({ verified: false, reason: "product_mismatch" }, 400);
    }

    // 6. Resolve the affiliate link (if any) server-side — never trust the
    //    client's claim about which affiliate should be credited.
    let affiliateLinkId: string | null = null;
    if (ref_code) {
      const { data: link } = await supabaseAdmin
        .from("affiliate_links")
        .select("id, product_id")
        .eq("code", ref_code)
        .maybeSingle();

      if (link && (!link.product_id || link.product_id === product_id)) {
        affiliateLinkId = link.id;
      }
    }

    const saleAmount = Number(product.price);
    const commissionAmount = affiliateLinkId
      ? Math.round(saleAmount * (Number(product.commission_rate) / 100) * 100) / 100
      : 0;

    // 7. Record the sale. Commission starts "pending" for admin review/payout.
    //    This row is only ever written here, never from client-side code.
    const { error: insertError } = await supabaseAdmin.from("affiliate_sales").insert({
      affiliate_link_id: affiliateLinkId,
      buyer_name: buyer_name || null,
      buyer_email: buyer_email,
      sale_amount: saleAmount,
      commission_amount: commissionAmount,
      status: affiliateLinkId ? "pending" : "completed",
      paystack_reference: reference,
    });

    if (insertError) {
      console.error("Insert error:", insertError.message);
      return json({ verified: true, recorded: false, reason: "db_insert_failed" });
    }

    return json({ verified: true, recorded: true });
  } catch (err) {
    console.error(err);
    return json({ verified: false, reason: "server_error" }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
