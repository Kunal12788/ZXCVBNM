require("dotenv").config();
const readline = require("readline");
const { supabase } = require("./supabaseClient");

// Supports two ways of using this:
//
// 1. Flags (fast, scriptable):
//    node add-message.js --contact "Mom" --message "Happy birthday!" --at "2026-07-15T10:00:00" [--phone "+91..."]
//
// 2. No flags -> interactive prompts (easier if you don't remember the flags)

function parseFlags(argv) {
  const flags = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith("--")) {
      const key = argv[i].slice(2);
      const value = argv[i + 1];
      flags[key] = value;
      i++;
    }
  }
  return flags;
}

function ask(rl, question) {
  return new Promise((resolve) => rl.question(question, resolve));
}

// Accepts either a full ISO timestamp, or shorthand like "+10m", "+2h", "+1d"
function resolveSendAt(input) {
  const shorthand = input.trim().match(/^\+(\d+)(m|h|d)$/i);
  if (shorthand) {
    const amount = Number(shorthand[1]);
    const unit = shorthand[2].toLowerCase();
    const msPerUnit = { m: 60000, h: 3600000, d: 86400000 };
    return new Date(Date.now() + amount * msPerUnit[unit]).toISOString();
  }
  const parsed = new Date(input);
  if (isNaN(parsed.getTime())) {
    throw new Error(
      `Couldn't understand send time "${input}". Use an ISO timestamp (2026-07-15T10:00:00) ` +
        `or shorthand like +10m, +2h, +1d.`
    );
  }
  return parsed.toISOString();
}

async function main() {
  const flags = parseFlags(process.argv.slice(2));
  let { contact, message, at, phone } = flags;

  if (!contact || !message || !at) {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    console.log("Queue a new WhatsApp message (leave phone blank if the name is unique):\n");
    contact = contact || (await ask(rl, "Contact name (exact, as saved in WhatsApp): "));
    message = message || (await ask(rl, "Message text: "));
    at =
      at ||
      (await ask(
        rl,
        "Send at (e.g. 2026-07-15T10:00:00, or shorthand +10m / +2h / +1d): "
      ));
    phone = phone || (await ask(rl, "Phone number (optional, only if name is shared by 2+ contacts): "));
    rl.close();
  }

  let sendAtIso;
  try {
    sendAtIso = resolveSendAt(at);
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }

  const row = {
    contact_name: contact,
    message,
    send_at: sendAtIso,
  };
  if (phone && phone.trim()) {
    row.phone_number = phone.trim();
  }

  const { data, error } = await supabase.from("scheduled_messages").insert(row).select().single();

  if (error) {
    console.error("Failed to queue message:", error.message);
    process.exit(1);
  }

  console.log(`\nQueued! Will send to "${data.contact_name}" at ${data.send_at} (id: ${data.id})`);
}

main();
