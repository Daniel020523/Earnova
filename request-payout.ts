// Supabase Edge Function: request-payout
//
// Called from partnerdashboard.html's "Request payout" form. This is the
// ONLY place that actually moves money out to a partner:
//   1. Confirms the amount doesn't exceed the partner's available balance
//      (earned via affiliate_sales, minus anything already paid/pending)
//      by calling the request_partner_payout() Postgres function, which
//      locks per-partner to prevent double-spend from concurrent requests.
//   2. Calls Paystack's Transfer API using the partner's saved recipient.
//   3. Records the outcome on the partner_payouts row.
//
// IMPORTANT — read before relying on this being fully automatic:
// Paystack requires OTP confirmation for transfers by default. With OTP
// enabled, a transfer this function initiates will sit in Paystack as
// "otp"/pending until someone approves it from the Paystack dashboard —
// it will NOT complete automatically. To get true one-click automated
// payouts, contact Paystack support and ask them to disable OTP for
// transfers on your account (they'll typically ask for extra verification
// first). Until that's done, treat payouts as "queued for you to approve
// in Paystack," not fully hands-off.
//
// Also: transfers pay out of your live Paystack account balance (money
// that has already settled to you from card payments), not from the
// buyer's payment directly. Make sure that balance covers payouts.
//
// Deploy with:
//   supabase functions deploy request-payout
//   (reuses PAYSTACK_SECRET_KEY already set for verify-paystack / payout-account)
//
// Requires the SQL migration: partner_payouts table + request_partner_payout()
// and finalize_partner_payout() functions (service_role only).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const PAYSTACK_SECRET_KEY = Deno.env.get("PAYSTACK_SECRET_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

const MIN_PAYOUT_NAIRA = 100;

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

  let body: { amount?: number };
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "Invalid JSON body" }, 400);
  }

  const amount = Number(body.amount);
  if (!amount || amount < MIN_PAYOUT_NAIRA) {
    return json({ ok: false, error: `Minimum payout is ₦${MIN_PAYOUT_NAIRA}` }, 400);
  }

  // --- 1. Fetch the partner's saved payout account ---
  const { data: profile, error: profileError } = await supabaseAdmin
    .from("profiles")
    .select("paystack_recipient_code, payout_account_name")
    .eq("id", user.id)
    .single();

  if (profileError || !profile?.paystack_recipient_code) {
    return json({ ok: false, error: "Add and verify a payout account first" }, 400);
  }

  // --- 2. Reserve the amount against available balance (locked, atomic) ---
  const { data: payout, error: reserveError } = await supabaseAdmin.rpc(
    "request_partner_payout",
    { p_partner_id: user.id, p_amount: amount }
  );

  if (reserveError) {
    console.error("request_partner_payout error:", reserveError);
    const msg = reserveError.message?.includes("exceeds")
      ? "That amount exceeds your available balance"
      : "Could not reserve that payout amount";
    return json({ ok: false, error: msg }, 400);
  }

  const payoutRow = Array.isArray(payout) ? payout[0] : payout;

  // --- 3. Initiate the Paystack transfer ---
  let transferData: any = null;
  let transferOk = false;
  try {
    const resp = await fetch("https://api.paystack.co/transfer", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${PAYSTACK_SECRET_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        source: "balance",
        amount: Math.round(amount * 100), // kobo
        recipient: profile.paystack_recipient_code,
        reason: "EarnOva partner payout",
        reference: `payout_${payoutRow.id}`,
      }),
    });
    transferData = await resp.json();
    transferOk = resp.ok && transferData?.status;
  } catch (err) {
    console.error("Paystack transfer error:", err);
  }

  // Paystack transfer statuses: "success" (done), "otp"/"pending" (needs
  // approval — see note at top of file), or the call simply failing.
  const paystackStatus = transferData?.data?.status;
  let finalStatus: "success" | "pending" | "failed";
  let failureReason: string | null = null;

  if (transferOk && paystackStatus === "success") {
    finalStatus = "success";
  } else if (transferOk && (paystackStatus === "otp" || paystackStatus === "pending")) {
    finalStatus = "pending";
    failureReason = "Awaiting OTP approval in the Paystack dashboard";
  } else {
    finalStatus = "failed";
    failureReason = transferData?.message || "Transfer could not be initiated";
  }

  const { error: finalizeError } = await supabaseAdmin.rpc("finalize_partner_payout", {
    p_payout_id: payoutRow.id,
    p_status: finalStatus,
    p_transfer_code: transferData?.data?.transfer_code || null,
    p_reference: transferData?.data?.reference || `payout_${payoutRow.id}`,
    p_failure_reason: failureReason,
  });

  if (finalizeError) {
    console.error("finalize_partner_payout error:", finalizeError);
  }

  return json({
    ok: true,
    status: finalStatus,
    failure_reason: failureReason,
  });
});
