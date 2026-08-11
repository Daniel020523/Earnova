// Deploy with: supabase functions deploy cpx-postback --no-verify-jwt
// (--no-verify-jwt is required — CPX's servers call this directly, with no
// Supabase auth token, so Supabase's default JWT check must be disabled
// for this function. Its own security is the secure_hash check below.)
//
// Secrets needed (supabase secrets set ...):
//   CPX_SECURE_HASH             - same key used in cpx-entry
//   SUPABASE_URL                 - already available automatically
//   SUPABASE_SERVICE_ROLE_KEY    - service role key (Project Settings > API).
//                                   NEVER expose this key client-side; it
//                                   bypasses RLS, which is required here
//                                   since the postback comes from CPX's
//                                   servers, not a logged-in user.
//
// In your CPX Research dashboard, set the postback URL to:
//   https://<your-project-ref>.supabase.co/functions/v1/cpx-postback
//     ?status={status}&trans_id={trans_id}&user_id={user_id}
//     &amount_local={amount_local}&amount_usd={amount_usd}
//     &secure_hash={secure_hash}
// Confirm the exact placeholder syntax CPX expects for these params in
// your dashboard — some networks use {token} braces, others use $token.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { crypto } from "https://deno.land/std@0.224.0/crypto/mod.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CPX_SECURE_HASH = Deno.env.get("CPX_SECURE_HASH")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

function toHex(buf: ArrayBuffer): string {
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function md5(text: string): Promise<string> {
  const buf = await crypto.subtle.digest("MD5", new TextEncoder().encode(text));
  return toHex(buf);
}

serve(async (req) => {
  const url = new URL(req.url);
  const status = url.searchParams.get("status");
  const transId = url.searchParams.get("trans_id");
  const userId = url.searchParams.get("user_id");
  const amountLocal = url.searchParams.get("amount_local");
  const secureHash = url.searchParams.get("secure_hash");

  if (!transId || !userId || !secureHash) {
    return new Response("missing params", { status: 400 });
  }

  // Verify this request actually came from CPX and wasn't forged.
  const expectedHash = await md5(`${transId}-${CPX_SECURE_HASH}`);
  if (expectedHash !== secureHash) {
    return new Response("invalid hash", { status: 403 });
  }

  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // Idempotency: CPX may retry postbacks, so only credit each trans_id once.
  const { data: existing } = await supabase
    .from("cpx_transactions")
    .select("id")
    .eq("trans_id", transId)
    .maybeSingle();

  if (existing) {
    return new Response("already processed");
  }

  await supabase.from("cpx_transactions").insert({
    trans_id: transId,
    user_id: userId,
    status: status || "unknown",
  });

  // status 1 = completed, 2 = canceled (per CPX convention) — only credit on completion.
  if (status === "1") {
    const { error: insertError } = await supabase.from("transactions").insert({
      user_id: userId,
      type: "survey",
      status: "completed",
      amount: Number(amountLocal || 0),
      verification_status: "verified",
    });

    if (insertError) {
      return new Response("credit failed: " + insertError.message, { status: 500 });
    }
  }

  return new Response("ok");
});
