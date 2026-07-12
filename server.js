require("dotenv").config();
const express = require("express");
const path = require("path");
const cors = require("cors");
const { sendMessage } = require("./whatsapp");
const logger = require("./logger");

const app = express();
const PORT = process.env.TEST_UI_PORT || 4545;

app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname, "dist")));

// Direct-send endpoint — bypasses Supabase entirely. This is the manual
// testing path: whatever you type in the browser goes straight to
// WhatsApp Web via the same sendMessage() function the real scheduler uses.
app.post("/api/send", async (req, res) => {
  const { contact, message, phone } = req.body || {};

  if (!contact || !contact.trim()) {
    return res.status(400).json({ ok: false, error: "Contact name is required." });
  }
  if (!message || !message.trim()) {
    return res.status(400).json({ ok: false, error: "Message text is required." });
  }

  logger.info(`[test-ui] Manual send requested -> "${contact}"`);

  try {
    const deliveryStatus = await sendMessage(contact.trim(), message, phone ? phone.trim() : null);
    logger.info(`[test-ui] Sent -> "${contact}" (delivery_status: ${deliveryStatus})`);
    res.json({ ok: true, deliveryStatus });
  } catch (err) {
    logger.error(`[test-ui] Failed -> "${contact}": ${err.message}`);
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.listen(PORT, () => {
  logger.info(`Test console running at http://localhost:${PORT}`);
  logger.info("Supabase is NOT used here — this sends directly from what you type.");
});
