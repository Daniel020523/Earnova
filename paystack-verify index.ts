// Deploy with: supabase functions deploy paystack-verify
// Secrets needed (supabase secrets set ...):
//   PAYSTACK_SECRET_KEY   - your Paystack secret key (server-side only, never expose client-side)
// SUPABASE_URL / SUPABASE_ANON_KEY are already available automatically.
// SUPABASE_SERVICE_ROLE_KEY - Project Settings > API. Needed to call
//   process_activation_payment() regardless of RLS (the user's own
//   session can't write profiles.paid_until directly).
//
// Requires the process_activation_payment() SQL function — see
// migration_process_activation_payment.sql. Recording the payment and
// extending paid_until happen as one atomic DB transaction, shared with
// paystack-webhook via the same `reference` row, so whichever of the two
// paths runs first "wins" and the other is a safe no-op.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const PAYSTACK_SECRET_KEY = Deno.env.get("PAYSTACK_SECRET_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// ₦1,500 in kobo — Paystack amounts are always in the smallest currency unit.
// Must match MONTHLY_FEE_KOBO in activate.html and paystack-webhook.
const MONTHLY_FEE_KOBO = 150000;
// How many days one successful payment unlocks access for. Renewal is
// manual — nothing here auto-charges the user again after this expires.
// Must match ACCESS_PERIOD_DAYS in paystack-webhook.
const ACCESS_PERIOD_DAYS = 30;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return new Response(JSON.stringify({ error: "Missing auth" }), {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const supabaseUser = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: { user }, error: userError } = await supabaseUser.auth.getUser();
  if (userError || !user) {
    return new Response(JSON.stringify({ error: "Invalid session" }), {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  let body: { reference?: string };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid body" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const reference = body.reference;
  if (!reference) {
    return new Response(JSON.stringify({ error: "Missing reference" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  // Verify directly with Paystack — never trust the client's own claim that
  // payment succeeded. This is a server-to-server call using the secret key.
  const verifyRes = await fetch(
    `https://api.paystack.co/transaction/verify/${encodeURIComponent(reference)}`,
    { headers: { Authorization: `Bearer ${PAYSTACK_SECRET_KEY}` } },
  );
  const verifyJson = await verifyRes.json();

  if (!verifyJson.status || verifyJson.data?.status !== "success") {
    return new Response(JSON.stringify({ error: "Payment not successful" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  if (verifyJson.data.amount !== MONTHLY_FEE_KOBO) {
    return new Response(JSON.stringify({ error: "Amount mismatch" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const supabaseAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // Records the payment and extends paid_until atomically. If this exact
  // reference was already processed (e.g. the webhook beat us to it), the
  // function just returns the current paid_until without extending again.
  const { data: newPaidUntil, error: rpcError } = await supabaseAdmin.rpc(
    "process_activation_payment",
    {
      p_user_id: user.id,
      p_reference: reference,
      p_amount: verifyJson.data.amount,
      p_access_period_days: ACCESS_PERIOD_DAYS,
    },
  );

  if (rpcError) {
    return new Response(
      JSON.stringify({
        error: "Payment verified but we couldn't update your account. Contact support with your reference: " + reference,
      }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }

  return new Response(JSON.stringify({ paid_until: newPaidUntil }), {
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
});
