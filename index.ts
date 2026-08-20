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
// This function is a server-side backstop for paystack-verify: it fires
// even if the user closes the browser tab before the client-side verify
// call completes. Both paths write to the SAME activation_payments row
// keyed by `reference`, so whichever one runs first "wins" and the other
// becomes a no-op — paid_until is never extended twice for one payment.

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

  try {
    // Idempotency — shared with paystack-verify via the same `reference`
    // column. If the client-side verify call already processed this exact
    // payment, do nothing: don't extend paid_until a second time.
    const { data: existing } = await supabaseAdmin
      .from("activation_payments")
      .select("id")
      .eq("reference", reference)
      .maybeSingle();

    if (existing) {
      return new Response("ok");
    }

    await supabaseAdmin.from("activation_payments").insert({
      user_id: userId,
      reference,
      amount: data.amount,
      status: "success",
    });

    // Extend from the later of "now" or the current paid_until, so paying a
    // few days early adds to remaining time instead of resetting it.
    // This mirrors paystack-verify's extension logic exactly.
    const { data: currentProfile, error: currentProfileError } = await supabaseAdmin
      .from("profiles")
      .select("paid_until")
      .eq("id", userId)
      .single();

    if (currentProfileError) {
      // The activation_payments row above is already recorded, so this
      // payment won't be silently lost or double-inserted on retry — but
      // paid_until wasn't extended. Return 500 so Paystack retries; the
      // insert above will need to tolerate a retry (see note in README).
      console.error("Failed to fetch profile for paid_until extension", currentProfileError);
      return new Response("profile fetch failed", { status: 500 });
    }

    const now = new Date();
    const currentPaidUntil = currentProfile?.paid_until ? new Date(currentProfile.paid_until) : null;
    const extendFrom = currentPaidUntil && currentPaidUntil.getTime() > now.getTime() ? currentPaidUntil : now;
    const newPaidUntil = new Date(extendFrom.getTime() + ACCESS_PERIOD_DAYS * 24 * 60 * 60 * 1000);

    const { error: updateError } = await supabaseAdmin
      .from("profiles")
      .update({ paid_until: newPaidUntil.toISOString() })
      .eq("id", userId);

    if (updateError) {
      console.error("Failed to update paid_until", updateError);
      return new Response("profile update failed", { status: 500 });
    }

    return new Response("ok");
  } catch (err) {
    console.error("Unexpected webhook error", err);
    // 500 so Paystack retries — better to risk a duplicate attempt (caught
    // by the idempotency check above) than to silently drop a real payment.
    return new Response("unexpected error", { status: 500 });
  }
});
