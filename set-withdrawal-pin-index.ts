// supabase/functions/set-withdrawal-pin/index.ts
//
// Deploy with:
//   supabase functions deploy set-withdrawal-pin
//   supabase secrets set SUPABASE_SERVICE_ROLE_KEY=eyJ...   (from Project Settings > API)
//
// Called from settings.html as:
//   POST {SUPABASE_URL}/functions/v1/set-withdrawal-pin
//   headers: { Authorization: `Bearer ${session.access_token}` }
//   body: { pin: "1234" }
//
// The PIN is never stored in plain text — it's hashed with bcrypt before
// being saved, the same way a password would be.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import * as bcrypt from "https://deno.land/x/bcrypt@v0.4.1/mod.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.replace("Bearer ", "");

    if (!token) {
      return new Response(
        JSON.stringify({ error: "Missing authorization token." }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Verify the caller's identity using their own access token.
    const authClient = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user }, error: userError } = await authClient.auth.getUser(token);

    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: "Invalid session." }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { pin } = await req.json();

    if (!pin || !/^\d{4,6}$/.test(pin)) {
      return new Response(
        JSON.stringify({ error: "PIN must be 4-6 digits." }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const pinHash = await bcrypt.hash(pin);

    // Use the service role client to write the hash — this bypasses RLS,
    // which is fine here since we've already verified the user's identity.
    const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { error: updateError } = await adminClient
      .from("profiles")
      .update({ withdrawal_pin_hash: pinHash, has_withdrawal_pin: true })
      .eq("id", user.id);

    if (updateError) {
      return new Response(
        JSON.stringify({ error: "Couldn't save your PIN. Please try again." }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({ success: true }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (_err) {
    return new Response(
      JSON.stringify({ error: "Unexpected error setting PIN." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
