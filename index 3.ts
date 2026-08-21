// Supabase Edge Function: download-file
//
// A thin proxy in front of a Storage signed URL. verify-paystack still
// does all the real work (auth, generating the short-lived signed URL to
// the private product-files bucket) — this function just re-serves those
// bytes with an explicit Content-Disposition: attachment header that WE
// set ourselves, instead of relying on Storage/its CDN to forward the
// `download` option correctly. This guarantees every file type (video,
// pdf, zip, etc.) triggers a real "Save to device" instead of playing or
// opening inline in the browser.
//
// verify-paystack builds file_url as:
//   {SUPABASE_URL}/functions/v1/download-file?src=<encoded signed url>&filename=<encoded name>
//
// No separate auth check needed here — the security boundary is the
// Storage signed URL itself (src), which is already short-lived and was
// only ever handed out after a confirmed payment.

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const url = new URL(req.url);
  const src = url.searchParams.get("src");
  const filename = url.searchParams.get("filename") || "download";

  if (!src) {
    return new Response("Missing src", { status: 400, headers: corsHeaders });
  }

  let upstream: Response;
  try {
    upstream = await fetch(src);
  } catch (err) {
    console.error("download-file fetch error:", err);
    return new Response("Could not reach file storage", { status: 502, headers: corsHeaders });
  }

  if (!upstream.ok || !upstream.body) {
    return new Response("File not found or link expired", {
      status: upstream.status || 404,
      headers: corsHeaders,
    });
  }

  const headers = new Headers(corsHeaders);
  headers.set(
    "Content-Type",
    upstream.headers.get("content-type") || "application/octet-stream"
  );
  const contentLength = upstream.headers.get("content-length");
  if (contentLength) headers.set("Content-Length", contentLength);

  // The header that actually forces a download, regardless of file type.
  headers.set("Content-Disposition", `attachment; filename="${filename.replace(/"/g, "")}"`);

  return new Response(upstream.body, { status: 200, headers });
});
