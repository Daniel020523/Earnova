// Deploy with: supabase functions deploy cpx-entry
// Secrets needed (supabase secrets set ...):
//   CPX_APP_ID          - your CPX Research App ID
//   CPX_SECURE_HASH      - your CPX Research app "secure hash" key (kept secret, server-side only)
// SUPABASE_URL / SUPABASE_ANON_KEY are already available automatically in the function's env.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { crypto } from "https://deno.land/std@0.224.0/crypto/mod.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CPX_APP_ID = Deno.env.get("CPX_APP_ID")!;
const CPX_SECURE_HASH = Deno.env.get("CPX_SECURE_HASH")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

function toHex(buf: ArrayBuffer): string {
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function md5(text: string): Promise<string> {
  const buf = await crypto.subtle.digest("MD5", new TextEncoder().encode(text));
  return toHex(buf);
}

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

  // Verify the caller is a logged-in EarnOva user before handing out an
  // entry hash — this is what stops a stranger from generating hashes
  // for arbitrary user IDs.
  const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: { user }, error } = await supabase.auth.getUser();
  if (error || !user) {
    return new Response(JSON.stringify({ error: "Invalid session" }), {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const secureHash = await md5(`${user.id}-${CPX_SECURE_HASH}`);

  return new Response(
    JSON.stringify({
      app_id: CPX_APP_ID,
      ext_user_id: user.id,
      secure_hash: secureHash,
    }),
    { headers: { ...corsHeaders, "Content-Type": "application/json" } },
  );
});
