// Supabase Edge Function: verify-paystack
//
// Called by product.html after Paystack's client-side popup reports a
// successful charge. This function is the ONLY place that:
//   1. Holds the Paystack secret key (never sent to the browser)
//   2. Re-verifies the transaction directly with Paystack's server
//   3. Writes to affiliate_sales / credits balances (via record_sale)
//   4. Generates the buyer's signed download link for the product file
//   5. Emails that link to the buyer via Gmail SMTP, so they can find
//      it later even if they close the tab
//
// Deploy with:
//   supabase functions deploy verify-paystack
//   supabase secrets set PAYSTACK_SECRET_KEY=sk_live_xxx
//   supabase secrets set GMAIL_ADDRESS=you@gmail.com
//   supabase secrets set GMAIL_APP_PASSWORD=xxxxxxxxxxxxxxxx
//
// GMAIL_APP_PASSWORD is a Google App Password (not your regular Gmail
// password) — the same kind used for the OTP email flow. Generate one at
// https://myaccount.google.com/apppasswords (requires 2-Step Verification
// on the Gmail account). You can reuse the same Gmail address/app password
// already set up for OTP, or use a separate one — either works.
//
// Env vars available automatically in every Edge Function:
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

const PAYSTACK_SECRET_KEY = Deno.env.get("PAYSTACK_SECRET_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GMAIL_ADDRESS = Deno.env.get("GMAIL_ADDRESS")!;
const GMAIL_APP_PASSWORD = Deno.env.get("GMAIL_APP_PASSWORD")!;

const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

const PRODUCT_FILE_BUCKET = "product-files";
const FILE_URL_TTL_SECONDS = 60 * 60 * 24; // 24 hours

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

async function sendDownloadEmail(
  buyerName: string,
  buyerEmail: string,
  productName: string,
  fileUrl: string
) {
  const client = new SMTPClient({
    connection: {
      hostname: "smtp.gmail.com",
      port: 465,
      tls: true,
      auth: {
        username: GMAIL_ADDRESS,
        password: GMAIL_APP_PASSWORD,
      },
    },
  });

  try {
    await client.send({
      from: `EarnOva <${GMAIL_ADDRESS}>`,
      to: buyerEmail,
      subject: `Your download: ${productName}`,
      content: `Hi ${buyerName},\n\nThanks for your purchase of "${productName}" on EarnOva.\n\nYour download link (valid for 24 hours):\n${fileUrl}\n\nIf the link expires, contact support with your payment reference and we'll issue a new one.\n\n— EarnOva`,
      html: `
        <div style="font-family: Arial, sans-serif; line-height:1.6; color:#111;">
          <p>Hi ${buyerName},</p>
          <p>Thanks for your purchase of <strong>${productName}</strong> on EarnOva.</p>
          <p>
            <a href="${fileUrl}" style="display:inline-block; padding:12px 24px; background:#111; color:#fff; text-decoration:none; border-radius:6px;">
              Download your file
            </a>
          </p>
          <p style="font-size:13px; color:#666;">This link is valid for 24 hours. If it expires, contact support with your payment reference and we'll issue a new one.</p>
          <p>— EarnOva</p>
        </div>
      `,
    });
  } finally {
    await client.close();
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ verified: false, error: "Method not allowed" }, 405);

  let body: {
    reference?: string;
    product_id?: string;
    ref_code?: string | null;
    buyer_name?: string;
    buyer_email?: string;
  };

  try {
    body = await req.json();
  } catch {
    return json({ verified: false, error: "Invalid JSON body" }, 400);
  }

  const { reference, product_id, ref_code, buyer_name, buyer_email } = body;

  if (!reference || !product_id || !buyer_name || !buyer_email) {
    return json({ verified: false, error: "Missing required fields" }, 400);
  }

  // --- 1. Verify the transaction with Paystack's server (source of truth) ---
  let paystackData: any;
  try {
    const psResp = await fetch(
      `https://api.paystack.co/transaction/verify/${encodeURIComponent(reference)}`,
      { headers: { Authorization: `Bearer ${PAYSTACK_SECRET_KEY}` } }
    );
    const psJson = await psResp.json();
    if (!psResp.ok || !psJson?.status) {
      return json({ verified: false, error: "Paystack verification request failed" }, 502);
    }
    paystackData = psJson.data;
  } catch (err) {
    console.error("Paystack verify error:", err);
    return json({ verified: false, error: "Could not reach Paystack" }, 502);
  }

  if (!paystackData || paystackData.status !== "success") {
    return json({ verified: false, error: "Payment not successful" }, 200);
  }

  if (paystackData.currency !== "NGN") {
    return json({ verified: false, error: "Unexpected currency" }, 200);
  }

  // Cross-check the reference actually belongs to this product / matches
  // what the metadata says, so a verified-but-unrelated reference can't be
  // replayed against a different product.
  const metaProductId = paystackData.metadata?.product_id;
  if (metaProductId && metaProductId !== product_id) {
    return json({ verified: false, error: "Reference does not match product" }, 200);
  }

  const paidKobo: number = paystackData.amount; // integer, kobo

  // --- 2. Hand off to the DB function that does the atomic commission split ---
  const { data, error } = await supabaseAdmin.rpc("record_sale", {
    p_paystack_reference: reference,
    p_product_id: product_id,
    p_ref_code: ref_code || null,
    p_buyer_name: buyer_name,
    p_buyer_email: buyer_email,
    p_paid_kobo: paidKobo,
  });

  if (error) {
    console.error("record_sale error:", error);
    return json({ verified: false, error: "Could not record sale" }, 500);
  }

  const result = Array.isArray(data) ? data[0] : data;

  // --- 3. Payment is confirmed and recorded — now generate the buyer's
  // download link. product-files is a private bucket, so only this
  // service-role client can read it; the signed URL is what lets the
  // buyer's browser download without any Storage RLS access of its own. ---
  let fileUrl: string | null = null;
  let productName = "your product";

  const { data: product, error: productError } = await supabaseAdmin
    .from("products")
    .select("name, file_path")
    .eq("id", product_id)
    .single();

  if (productError) {
    console.warn("Could not look up product:", productError.message);
  } else if (product) {
    productName = product.name || productName;

    if (product.file_path) {
      const downloadName = product.file_path.split("/").pop()?.replace(/^\d+-/, "") || "download";
      const { data: signed, error: signError } = await supabaseAdmin.storage
        .from(PRODUCT_FILE_BUCKET)
        .createSignedUrl(product.file_path, FILE_URL_TTL_SECONDS);

      if (signError) {
        console.warn("Could not create signed URL:", signError.message);
      } else if (signed?.signedUrl) {
        // Proxy through download-file so we control the Content-Disposition
        // header ourselves — guarantees a real download for any file type,
        // regardless of whether Storage's own `download` option is honored.
        fileUrl = `${SUPABASE_URL}/functions/v1/download-file?src=${encodeURIComponent(
          signed.signedUrl
        )}&filename=${encodeURIComponent(downloadName)}`;
      }
    }
  }

  // --- 4. Best-effort email so the buyer has the link even after they
  // close this tab. A failed email should never fail the whole request —
  // the buyer already sees the link on-page if this doesn't go through. ---
  if (fileUrl) {
    try {
      await sendDownloadEmail(buyer_name, buyer_email, productName, fileUrl);
    } catch (emailErr) {
      console.error("Download email send error:", emailErr);
    }
  }

  return json({
    verified: true,
    already_processed: result?.already_processed ?? false,
    commission_amount: result?.commission_amount,
    partner_amount: result?.partner_amount,
    site_amount: result?.site_amount,
    file_url: fileUrl,
  });
});