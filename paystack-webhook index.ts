// Deploy with: supabase functions deploy paystack-webhook --no-verify-jwt
// (--no-verify-jwt is required — Paystack calls this directly with no
// Supabase auth token. Its own security is the signature check below.)
//
// Secrets needed: same as paystack-verify (PAYSTACK_SECRET_KEY,
// SUPABASE_SERVICE_ROLE_KEY). SUPABASE_URL is automatic.
//
// In your Paystack dashboard, set the Live Webhook URL to:
//   https://vrgqbyowlfqrtjumzeqq.supabase.co/functions/v1/paystack-webhook
//
// Requires the process_activation_payment() SQL function — see
// migration_process_activation_payment.sql. This function is a
// server-side backstop for paystack-verify: it fires even if the user
// closes the browser tab before the client-side verify call completes.
// Both paths call the SAME atomic DB function keyed by `reference`, so
// whichever one runs first extends paid_until and the other is a no-op —
// it's never extended twice for one payment, and a partial failure in one
// path can't leave the payment "recorded but not applied" for the other
// to skip past.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { crypto } from "https://deno.land/std@0.224.0/crypto/mod.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const PAYSTACK_SECRET_KEY = Deno.env.get("PAYSTACK_SECRET_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// ₦1,500 in kobo — must match MONTHLY_FEE_KOBO in paystack-verify / activate.html.
const MONTHLY_FEE_KOBO = 150000;
// How many days one successful payment unlocks access for. Must match
// ACCESS_PERIOD_DAYS in paystack-verify.
const ACCESS_PERIOD_DAYS = 30;

function toHex(buf: ArrayBuffer): string {
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function hmacSha512Hex(key: string, message: string): Promise<string> {
  const enc = new TextEncoder();
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    enc.encode(key),
    { name: "HMAC", hash: "SHA-512" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", cryptoKey, enc.encode(message));
  return toHex(sig);
}

serve(async (req) => {
  const rawBody = await req.text();
  const signature = req.headers.get("x-paystack-signature") || "";

  // Paystack signs the raw request body with your secret key (HMAC-SHA512).
  // If this doesn't match, the request didn't actually come from Paystack.
  const expectedSignature = await hmacSha512Hex(PAYSTACK_SECRET_KEY, rawBody);
  if (expectedSignature !== signature) {
    return new Response("invalid signature", { status: 401 });
  }

  let event: any;
  try {
    event = JSON.parse(rawBody);
  } catch {
    return new Response("invalid body", { status: 400 });
  }

  if (event.event !== "charge.success") {
    // Not a payment event we care about — acknowledge so Paystack doesn't retry.
    return new Response("ok");
  }

  const data = event.data;

  if (data.amount !== MONTHLY_FEE_KOBO) {
    // Not our activation/renewal charge — ignore (e.g. some other Paystack use later).
    return new Response("ok");
  }

  const userId = data.metadata?.user_id;
  const reference = data.reference;
  if (!userId || !reference) {
    return new Response("ok");
  }

  const supabaseAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // Records the payment and extends paid_until atomically. If paystack-verify
  // already processed this exact reference, this just returns the current
  // paid_until without extending again.
  const { error: rpcError } = await supabaseAdmin.rpc("process_activation_payment", {
    p_user_id: userId,
    p_reference: reference,
    p_amount: data.amount,
    p_access_period_days: ACCESS_PERIOD_DAYS,
  });

  if (rpcError) {
    console.error("Failed to process activation payment", rpcError);
    // 500 so Paystack retries — better to risk a duplicate attempt (safely
    // absorbed by the RPC's own idempotency) than to silently drop a real
    // payment.
    return new Response("processing failed", { status: 500 });
  }

  return new Response("ok");
});
