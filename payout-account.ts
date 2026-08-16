// Supabase Edge Function: payout-account
//
// Handles everything needed to set up a partner's payout bank account,
// multiplexed by `action` so we only need one function:
//   - action: "list_banks"  -> returns Nigerian banks from Paystack
//   - action: "resolve"     -> verifies bank_code + account_number with
//                              Paystack, returns the real account_name
//   - action: "save"        -> creates a Paystack transfer recipient and
//                              stores bank + recipient details on the
//                              partner's profile row
//
// The Paystack secret key never reaches the browser — every Paystack call
// happens here.
//
// Deploy with:
//   supabase functions deploy payout-account
//   supabase secrets set PAYSTACK_SECRET_KEY=sk_live_xxx   (same secret
//   already used by verify-paystack — no need to set it twice)
//
// Requires the `partner_payouts` table + profile columns from the
// accompanying SQL migration.

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

async function paystackFetch(path: string, options: RequestInit = {}) {
  const resp = await fetch(`https://api.paystack.co${path}`, {
    ...options,
    headers: {
      Authorization: `Bearer ${PAYSTACK_SECRET_KEY}`,
      "Content-Type": "application/json",
      ...(options.headers || {}),
    },
  });
  const data = await resp.json();
  return { ok: resp.ok && data?.status, data };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, error: "Method not allowed" }, 405);

  const user = await getAuthedUser(req);
  if (!user) return json({ ok: false, error: "Not authenticated" }, 401);

  let body: {
    action?: string;
    bank_code?: string;
    account_number?: string;
    account_name?: string;
  };

  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "Invalid JSON body" }, 400);
  }

  // ---- List Nigerian banks ----
  if (body.action === "list_banks") {
    const { ok, data } = await paystackFetch("/bank?country=nigeria&currency=NGN&perPage=100");
    if (!ok) return json({ ok: false, error: "Could not load banks" }, 502);
    const banks = (data.data || []).map((b: any) => ({ code: b.code, name: b.name }));
    return json({ ok: true, banks });
  }

  // ---- Resolve / verify account number ----
  if (body.action === "resolve") {
    const { bank_code, account_number } = body;
    if (!bank_code || !account_number || account_number.length !== 10) {
      return json({ ok: false, error: "Missing or invalid bank/account number" }, 400);
    }

    const { ok, data } = await paystackFetch(
      `/bank/resolve?account_number=${encodeURIComponent(account_number)}&bank_code=${encodeURIComponent(bank_code)}`
    );

    if (!ok) {
      return json({ ok: false, error: data?.message || "Could not verify that account" }, 200);
    }

    return json({ ok: true, account_name: data.data.account_name });
  }

  // ---- Save account: create Paystack recipient + persist to profile ----
  if (body.action === "save") {
    const { bank_code, account_number, account_name } = body;
    if (!bank_code || !account_number || !account_name) {
      return json({ ok: false, error: "Missing account details" }, 400);
    }

    // Re-verify server-side — never trust the account_name the client sends
    // without an independent check, since that name is what money gets
    // attached to.
    const verify = await paystackFetch(
      `/bank/resolve?account_number=${encodeURIComponent(account_number)}&bank_code=${encodeURIComponent(bank_code)}`
    );
    if (!verify.ok || verify.data.data.account_name !== account_name) {
      return json({ ok: false, error: "Account could not be re-verified — try verifying again" }, 200);
    }

    const bankListResp = await paystackFetch("/bank?country=nigeria&currency=NGN&perPage=100");
    const bankMeta = (bankListResp.data?.data || []).find((b: any) => b.code === bank_code);
    const bankName = bankMeta?.name || bank_code;

    const recipientResp = await paystackFetch("/transferrecipient", {
      method: "POST",
      body: JSON.stringify({
        type: "nuban",
        name: account_name,
        account_number,
        bank_code,
        currency: "NGN",
      }),
    });

    if (!recipientResp.ok) {
      return json({ ok: false, error: recipientResp.data?.message || "Could not register payout account with Paystack" }, 502);
    }

    const recipientCode = recipientResp.data.data.recipient_code;

    const { error: updateError } = await supabaseAdmin
      .from("profiles")
      .update({
        payout_bank_code: bank_code,
        payout_bank_name: bankName,
        payout_account_number: account_number,
        payout_account_name: account_name,
        paystack_recipient_code: recipientCode,
      })
      .eq("id", user.id);

    if (updateError) {
      console.error("Save payout account error:", updateError);
      return json({ ok: false, error: "Could not save payout account" }, 500);
    }

    return json({ ok: true });
  }

  return json({ ok: false, error: "Unknown action" }, 400);
});
