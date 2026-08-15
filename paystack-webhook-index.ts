// Deploy with: supabase functions deploy paystack-webhook --no-verify-jwt
// (--no-verify-jwt is required — Paystack calls this directly with no
// Supabase auth token. Its own security is the signature check below.)
//
// Secrets needed: same as paystack-verify (PAYSTACK_SECRET_KEY,
// SUPABASE_SERVICE_ROLE_KEY). SUPABASE_URL is automatic.
//
// In your Paystack dashboard, set the webhook URL to:
//   https://<your-project-ref>.supabase.co/functions/v1/paystack-webhook

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { crypto } from "https://deno.land/std@0.224.0/crypto/mod.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const PAYSTACK_SECRET_KEY = Deno.env.get("PAYSTACK_SECRET_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ACTIVATION_AMOUNT_KOBO = 150000;

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

  const event = JSON.parse(rawBody);

  if (event.event === "charge.success") {
    const data = event.data;

    if (data.amount !== ACTIVATION_AMOUNT_KOBO) {
      // Not our activation charge — ignore (e.g. some other Paystack use later).
      return new Response("ok");
    }

    const userId = data.metadata?.user_id;
    if (!userId) {
      return new Response("ok");
    }

    const supabaseAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: existing } = await supabaseAdmin
      .from("activation_payments")
      .select("id")
      .eq("reference", data.reference)
      .maybeSingle();

    if (!existing) {
      await supabaseAdmin.from("activation_payments").insert({
        user_id: userId,
        reference: data.reference,
        amount: data.amount,
        status: "success",
      });
      await supabaseAdmin.from("profiles").update({ is_activated: true }).eq("id", userId);
    }
  }

  return new Response("ok");
});
