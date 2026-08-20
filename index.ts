// supabase/functions/verify-join/index.ts
// Verifies a Paystack payment reference server-side, then inserts the
// challenge_submissions row. The client-side Paystack callback is not
// trustworthy on its own — this function is the source of truth.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const PAYSTACK_SECRET_KEY = Deno.env.get("PAYSTACK_SECRET_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const JOIN_FEE_NAIRA = 1000;

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  // Identify the caller from their Supabase auth JWT (sent by supabase-js
  // automatically as the Authorization header) — never trust a user_id
  // passed in the request body.
  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(SUPABASE_URL, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData?.user) {
    return json({ error: "Not authenticated" }, 401);
  }
  const userId = userData.user.id;

  const body = await req.json().catch(() => null);
  const { reference, challenge_id, tier, tiktok_account_url, tiktok_url } = body ?? {};
  if (!reference || !challenge_id || !tier || !tiktok_account_url || !tiktok_url) {
    return json({ error: "Missing required fields" }, 400);
  }

  // 1. Verify the transaction with Paystack directly (server-to-server).
  const verifyRes = await fetch(
    `https://api.paystack.co/transaction/verify/${encodeURIComponent(reference)}`,
    { headers: { Authorization: `Bearer ${PAYSTACK_SECRET_KEY}` } },
  );
  const verifyData = await verifyRes.json();

  if (!verifyRes.ok || !verifyData?.status || verifyData.data?.status !== "success") {
    return json({ error: "Payment could not be verified" }, 402);
  }

  const paidKobo = verifyData.data.amount;
  const expectedKobo = JOIN_FEE_NAIRA * 100;
  if (paidKobo !== expectedKobo) {
    return json({ error: "Amount paid does not match the entry fee" }, 402);
  }

  // Metadata was set client-side when initiating payment — cross-check it,
  // but the amount/status check above is what actually matters.
  const meta = verifyData.data.metadata ?? {};
  if (meta.user_id && meta.user_id !== userId) {
    return json({ error: "Payment does not belong to this user" }, 403);
  }
  if (String(meta.challenge_id) !== String(challenge_id)) {
    return json({ error: "Payment does not match this challenge" }, 403);
  }

  // 2. Insert with the service role so RLS can safely require this
  // function as the only path that sets payment_reference / amount_paid.
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  const { error: insertErr } = await admin.from("challenge_submissions").insert({
    challenge_id,
    user_id: userId,
    tier,
    tiktok_account_url,
    tiktok_url,
    payment_reference: reference,
    amount_paid: paidKobo / 100,
  });

  if (insertErr) {
    // Most likely cause: unique index on payment_reference (double-submit)
    // or a duplicate entry for this user/challenge.
    return json({ error: insertErr.message }, 409);
  }

  return json({ ok: true });
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
