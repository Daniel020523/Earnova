// Deploy with: supabase functions deploy paystack-verify
// Secrets needed (supabase secrets set ...):
//   PAYSTACK_SECRET_KEY   - your Paystack secret key (server-side only, never expose client-side)
// SUPABASE_URL / SUPABASE_ANON_KEY are already available automatically.
// SUPABASE_SERVICE_ROLE_KEY - Project Settings > API. Needed to write is_activated
//   regardless of RLS (the user's own session can't write that column directly).

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const PAYSTACK_SECRET_KEY = Deno.env.get("PAYSTACK_SECRET_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// ₦1,500 in kobo — Paystack amounts are always in the smallest currency unit.
const ACTIVATION_AMOUNT_KOBO = 150000;

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

  if (verifyJson.data.amount !== ACTIVATION_AMOUNT_KOBO) {
    return new Response(JSON.stringify({ error: "Amount mismatch" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const supabaseAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // Idempotency — a reference should only ever activate an account once.
  const { data: existing } = await supabaseAdmin
    .from("activation_payments")
    .select("id")
    .eq("reference", reference)
    .maybeSingle();

  if (!existing) {
    await supabaseAdmin.from("activation_payments").insert({
      user_id: user.id,
      reference,
      amount: verifyJson.data.amount,
      status: "success",
    });
  }

  await supabaseAdmin.from("profiles").update({ is_activated: true }).eq("id", user.id);

  return new Response(JSON.stringify({ activated: true }), {
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
});
