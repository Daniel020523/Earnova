// supabase/functions/resolve-account-name/index.ts
//
// Deploy with:
//   supabase functions deploy resolve-account-name
//   supabase secrets set PAYSTACK_SECRET_KEY=sk_live_xxxxxxxx
//
// Called from account.html as:
//   POST {SUPABASE_URL}/functions/v1/resolve-account-name
//   body: { account_number: "0123456789", bank_code: "058" }

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { account_number, bank_code } = await req.json();

    if (!account_number || !bank_code) {
      return new Response(
        JSON.stringify({ error: "account_number and bank_code are required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const paystackKey = Deno.env.get("PAYSTACK_SECRET_KEY");

    const resp = await fetch(
      `https://api.paystack.co/bank/resolve?account_number=${encodeURIComponent(account_number)}&bank_code=${encodeURIComponent(bank_code)}`,
      {
        headers: {
          Authorization: `Bearer ${paystackKey}`,
        },
      }
    );

    const json = await resp.json();

    if (!resp.ok || !json.status) {
      return new Response(
        JSON.stringify({ error: json.message || "Couldn't verify this account." }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({ account_name: json.data.account_name }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ error: "Unexpected error resolving account." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
