require("dotenv").config();
const { createClient } = require("@supabase/supabase-js");

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!url || !key) {
  throw new Error(
    "Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY. Copy .env.example to .env and fill it in."
  );
}

// Service role key is used because this runs as a trusted backend process,
// not in a browser. Never expose this key client-side.
const supabase = createClient(url, key);

module.exports = { supabase };
