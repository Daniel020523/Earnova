// Supabase Edge Function: verify-topup
//
// Called by partnerdashboard.html after Paystack's popup reports a
// successful wallet top-up charge. Re-verifies the transaction directly
// with Paystack (source of truth) and credits the partner's wallet
// balance atomically — the client never writes to profiles.balance or
// wallet_topups directly.
//
// Idempotent: wallet_topups.reference has a unique constraint, so if this
// function is somehow called twice for the same Paystack reference (e.g.
// a retried request), the second call is a no-op rather than double
// crediting the wallet.
//
// Deploy with:
//   supabase functions deploy verify-topup
//   (reuses PAYSTACK_SECRET_KEY already set for your other functions)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const PAYSTACK_SECRET_KEY = Deno.env.get("PAYSTACK_SECRET_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function getAuthedUser(req: Request) {
  const authHeader = req.headers.get("Authorization") || "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (!token) return null;
  const { data, error } = await supabaseAdmin.auth.getUser(token);
  if (error || !data?.user) return null;
  return data.user;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, error: "Method not allowed" }, 405);

  const user = await getAuthedUser(req);
  if (!user) return json({ ok: false, error: "Not authenticated" }, 401);

  let body: { reference?: string };
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "Invalid JSON body" }, 400);
  }

  const { reference } = body;
  if (!reference) return json({ ok: false, error: "Missing reference" }, 400);

  // --- 1. Verify with Paystack's server ---
  let paystackData: any;
  try {
    const psResp = await fetch(
      `https://api.paystack.co/transaction/verify/${encodeURIComponent(reference)}`,
      { headers: { Authorization: `Bearer ${PAYSTACK_SECRET_KEY}` } }
    );
    const psJson = await psResp.json();
    if (!psResp.ok || !psJson?.status) {
      return json({ ok: false, error: "Paystack verification request failed" }, 502);
    }
    paystackData = psJson.data;
  } catch (err) {
    console.error("Paystack verify error:", err);
    return json({ ok: false, error: "Could not reach Paystack" }, 502);
  }

  if (!paystackData || paystackData.status !== "success") {
    return json({ ok: false, error: "Payment not successful" }, 200);
  }

  if (paystackData.currency !== "NGN") {
    return json({ ok: false, error: "Unexpected currency" }, 200);
  }

  // Only credit the wallet if this reference belongs to this partner —
  // stops one partner's reference being replayed against another account.
  if (paystackData.metadata?.partner_id && paystackData.metadata.partner_id !== user.id) {
    return json({ ok: false, error: "Reference does not match this account" }, 200);
  }

  const amountNaira = paystackData.amount / 100;

  // --- 2. Atomic, idempotent credit ---
  const { data, error } = await supabaseAdmin.rpc("credit_wallet_topup", {
    p_partner_id: user.id,
    p_amount: amountNaira,
    p_reference: reference,
  });

  if (error) {
    console.error("credit_wallet_topup error:", error);
    return json({ ok: false, error: "Could not credit wallet" }, 500);
  }

  return json({ ok: true, already_processed: data?.already_processed ?? false });
});
