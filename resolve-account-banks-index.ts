// supabase/functions/resolve-account-banks/index.ts
//
// Deploy with:
//   supabase functions deploy resolve-account-banks
//   supabase secrets set PAYSTACK_SECRET_KEY=sk_live_xxxxxxxx
//
// Called from account.html as:
//   POST {SUPABASE_URL}/functions/v1/resolve-account-banks
//   body: { account_number: "0123456789" }
//
// Unlike guessing the bank from the NUBAN check digit (which has real
// false-positive collisions), this calls Paystack's /bank/resolve for
// every bank and only keeps the ones that genuinely verify — so the
// bank(s) returned are ones NIBSS actually confirms hold this account.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Keep this list in sync with the one in account.html.
const BANKS = [
  { name: "Access Bank", code: "044" },
  { name: "Citibank Nigeria", code: "023" },
  { name: "Ecobank Nigeria", code: "050" },
  { name: "Fidelity Bank", code: "070" },
  { name: "First Bank of Nigeria", code: "011" },
  { name: "First City Monument Bank", code: "214" },
  { name: "Globus Bank", code: "00103" },
  { name: "Guaranty Trust Bank", code: "058" },
  { name: "Heritage Bank", code: "030" },
  { name: "Keystone Bank", code: "082" },
  { name: "Polaris Bank", code: "076" },
  { name: "Providus Bank", code: "101" },
  { name: "Stanbic IBTC Bank", code: "221" },
  { name: "Standard Chartered Bank", code: "068" },
  { name: "Sterling Bank", code: "232" },
  { name: "Suntrust Bank", code: "100" },
  { name: "Union Bank of Nigeria", code: "032" },
  { name: "United Bank For Africa", code: "033" },
  { name: "Unity Bank", code: "215" },
  { name: "Wema Bank", code: "035" },
  { name: "Zenith Bank", code: "057" },
];

async function tryResolve(accountNumber: string, bank: { name: string; code: string }, paystackKey: string) {
  try {
    const resp = await fetch(
      `https://api.paystack.co/bank/resolve?account_number=${encodeURIComponent(accountNumber)}&bank_code=${encodeURIComponent(bank.code)}`,
      { headers: { Authorization: `Bearer ${paystackKey}` } }
    );
    const json = await resp.json();
    if (resp.ok && json.status && json.data?.account_name) {
      return { bank_name: bank.name, bank_code: bank.code, account_name: json.data.account_name };
    }
  } catch (_err) {
    // Ignore individual bank failures — a non-match or timeout for one
    // bank shouldn't fail the whole scan.
  }
  return null;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { account_number } = await req.json();

    if (!account_number || !/^\d{10}$/.test(account_number)) {
      return new Response(
        JSON.stringify({ error: "A valid 10-digit account_number is required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const paystackKey = Deno.env.get("PAYSTACK_SECRET_KEY")!;

    const results = await Promise.all(
      BANKS.map(bank => tryResolve(account_number, bank, paystackKey))
    );

    const matches = results.filter(Boolean);

    if (matches.length === 0) {
      return new Response(
        JSON.stringify({ error: "Couldn't find a bank for this account number." }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({ banks: matches }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (_err) {
    return new Response(
      JSON.stringify({ error: "Unexpected error detecting bank." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
