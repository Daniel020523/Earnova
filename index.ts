// Deploy with: supabase functions deploy paystack-verify
// Secrets needed (supabase secrets set ...):
//   PAYSTACK_SECRET_KEY   - your Paystack secret key (server-side only, never expose client-side)
// SUPABASE_URL / SUPABASE_ANON_KEY are already available automatically.
// SUPABASE_SERVICE_ROLE_KEY - Project Settings > API. Needed to write paid_until
//   regardless of RLS (the user's own session can't write that column directly).

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const PAYSTACK_SECRET_KEY = Deno.env.get("PAYSTACK_SECRET_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// ₦1,500 in kobo — Paystack amounts are always in the smallest currency unit.
const MONTHLY_FEE_KOBO = 150000;
// How many days one successful payment unlocks access for. Renewal is
// manual — nothing here auto-charges the user again after this expires.
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

  // Idempotency — a reference should only ever extend access once. If Paystack's
  // webhook and the client's onSuccess both call this (or the user retries),
  // we must not stack extra days onto paid_until for the same payment.
  const { data: existing } = await supabaseAdmin
    .from("activation_payments")
    .select("id")
    .eq("reference", reference)
    .maybeSingle();

  if (existing) {
    // Already processed — return the account's current paid_until as-is
    // rather than extending it again.
    const { data: profile } = await supabaseAdmin
      .from("profiles")
      .select("paid_until")
      .eq("id", user.id)
      .single();

    return new Response(JSON.stringify({ paid_until: profile?.paid_until ?? null }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  await supabaseAdmin.from("activation_payments").insert({
    user_id: user.id,
    reference,
    amount: verifyJson.data.amount,
    status: "success",
  });

  // Extend from the later of "now" or the current paid_until, so paying a
  // few days early adds to remaining time instead of resetting it.
  const { data: currentProfile, error: currentProfileError } = await supabaseAdmin
    .from("profiles")
    .select("paid_until")
    .eq("id", user.id)
    .single();

  if (currentProfileError) {
    return new Response(JSON.stringify({ error: "Payment verified but we couldn't update your account. Contact support with your reference: " + reference }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const now = new Date();
  const currentPaidUntil = currentProfile?.paid_until ? new Date(currentProfile.paid_until) : null;
  const extendFrom = currentPaidUntil && currentPaidUntil.getTime() > now.getTime() ? currentPaidUntil : now;
  const newPaidUntil = new Date(extendFrom.getTime() + ACCESS_PERIOD_DAYS * 24 * 60 * 60 * 1000);

  const { error: updateError } = await supabaseAdmin
    .from("profiles")
    .update({ paid_until: newPaidUntil.toISOString() })
    .eq("id", user.id);

  if (updateError) {
    return new Response(JSON.stringify({ error: "Payment verified but we couldn't update your account. Contact support with your reference: " + reference }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  return new Response(JSON.stringify({ paid_until: newPaidUntil.toISOString() }), {
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
});