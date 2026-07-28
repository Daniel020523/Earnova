// Supabase Edge Function: send-email
// Sends contact/support form submissions to support.earnova@gmail.com via SMTP.
// Deploy with: supabase functions deploy send-email

import { SMTPClient } from "https://deno.land/x/denomailer/mod.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { formType, name, email, message, topic, details } = await req.json();

    let subject = "";
    let text = "";

    if (formType === "contact") {
      if (!name || !email || !message) {
        throw new Error("Missing required contact fields");
      }
      subject = `Contact form message from ${name}`;
      text = `Name: ${name}\nEmail: ${email}\n\nMessage:\n${message}`;
    } else if (formType === "support") {
      if (!topic || !details) {
        throw new Error("Missing required support fields");
      }
      subject = `Support request: ${topic}`;
      text = `Topic: ${topic}\n\nDetails:\n${details}`;
    } else {
      throw new Error("Invalid formType");
    }

    const client = new SMTPClient({
      connection: {
        hostname: Deno.env.get("SMTP_HOST")!,
        port: Number(Deno.env.get("SMTP_PORT")!),
        tls: false, // STARTTLS upgrade on port 587
        auth: {
          username: Deno.env.get("SMTP_USER")!,
          password: Deno.env.get("SMTP_PASS")!,
        },
      },
    });

    await client.send({
      from: Deno.env.get("SMTP_FROM")!,
      to: "support.earnova@gmail.com",
      replyTo: formType === "contact" ? email : undefined,
      subject,
      content: text,
    });

    await client.close();

    return new Response(JSON.stringify({ success: true }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error(err);
    return new Response(JSON.stringify({ error: err.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
