import { createClient } from "@supabase/supabase-js";

export default async function handler(req, res) {
  // Enable CORS
  res.setHeader("Access-Control-Allow-Credentials", "true");
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET,OPTIONS,PATCH,DELETE,POST,PUT");
  res.setHeader(
    "Access-Control-Allow-Headers",
    "X-CSRF-Token, X-Requested-With, Accept, Accept-Version, Content-Length, Content-MD5, Content-Type, Date, X-Api-Version"
  );

  if (req.method === "OPTIONS") {
    return res.status(200).end();
  }

  if (req.method !== "POST") {
    return res.status(405).json({ ok: false, error: "Method Not Allowed" });
  }

  const { contact, message, phone } = req.body || {};
  if (!contact || !message) {
    return res.status(400).json({ ok: false, error: "Missing contact name or message." });
  }

  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!url || !key) {
    return res.status(500).json({ ok: false, error: "Supabase credentials are not configured on Vercel." });
  }

  try {
    const supabase = createClient(url, key);
    
    // Insert message into scheduled_messages table as 'pending' to be sent immediately by local runner
    const { data, error } = await supabase
      .from("scheduled_messages")
      .insert([
        {
          contact_name: contact,
          phone_number: phone || null,
          message: message,
          send_at: new Date().toISOString(),
          status: "pending"
        }
      ])
      .select();

    if (error) {
      return res.status(500).json({ ok: false, error: error.message });
    }

    return res.status(200).json({ ok: true, deliveryStatus: "pending", data });
  } catch (err) {
    return res.status(500).json({ ok: false, error: err.message });
  }
}
