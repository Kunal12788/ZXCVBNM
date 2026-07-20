require("dotenv").config();
const { supabase } = require("./supabaseClient");
const { sendMessage } = require("./whatsapp");
const logger = require("./logger");

const POLL_INTERVAL_MS = (Number(process.env.POLL_INTERVAL_SECONDS) || 30) * 1000;

// Exponential backoff: 1st retry after 2min, 2nd after 4min, 3rd after 8min...
function backoffMinutes(retryCount) {
  return Math.pow(2, retryCount);
}

async function expireOldMessages() {
  const now = new Date();
  const istHourStr = now.toLocaleString("en-US", { timeZone: "Asia/Kolkata", hour: "numeric", hour12: false });
  const currentIstHour = parseInt(istHourStr, 10);

  // 1. Expire Morning Greetings if app is running outside morning window (past 11:00 AM IST or before 6:00 AM IST)
  if (currentIstHour >= 11 || currentIstHour < 6) {
    const { data } = await supabase
      .from("scheduled_messages")
      .update({ status: "expired", error: "Morning greeting window expired (past 11:00 AM IST)" })
      .eq("status", "pending")
      .or("message.ilike.%Good Morning%,message.ilike.%शुभ प्रभात%,message.ilike.%সুপ্রভাত%")
      .select("id");

    if (data && data.length > 0) {
      logger.info(`Expired ${data.length} pending Morning Greeting(s) outside morning window.`);
    }
  }

  // 2. Expire Night Greetings if app is running outside night window (past 1:00 AM IST / between 1:00 AM and 9:00 PM IST)
  if (currentIstHour >= 1 && currentIstHour < 21) {
    const { data } = await supabase
      .from("scheduled_messages")
      .update({ status: "expired", error: "Night greeting window expired" })
      .eq("status", "pending")
      .or("message.ilike.%Good Night%,message.ilike.%शुभ रात्रि%,message.ilike.%শুভ রাত্রি%")
      .select("id");

    if (data && data.length > 0) {
      logger.info(`Expired ${data.length} pending Night Greeting(s) outside night window.`);
    }
  }

  // 3. Expire any general pending backlog messages older than 20 minutes
  const cutoff = new Date(Date.now() - 20 * 60 * 1000).toISOString();
  const { data, error } = await supabase
    .from("scheduled_messages")
    .update({ status: "expired", error: "Offline backlog cleanup" })
    .eq("status", "pending")
    .lt("send_at", cutoff)
    .select("id");

  if (error) {
    logger.error(`Failed to expire old backlog messages: ${error.message}`);
  } else if (data && data.length > 0) {
    logger.info(`Cleaned up ${data.length} expired pending messages from offline backlog.`);
  }
}

async function fetchDueMessages() {
  const nowIso = new Date().toISOString();
  const { data, error } = await supabase
    .from("scheduled_messages")
    .select("*")
    .eq("status", "pending")
    .lte("send_at", nowIso)
    .or(`next_retry_at.is.null,next_retry_at.lte.${nowIso}`)
    .order("queue_order", { ascending: true });

  if (error) {
    logger.error(`Failed to fetch due messages: ${error.message}`);
    return [];
  }
  return data || [];
}

async function updateRow(id, fields) {
  const { error } = await supabase.from("scheduled_messages").update(fields).eq("id", id);
  if (error) {
    logger.error(`Failed to update row ${id}: ${error.message}`);
  }
}

async function processMessage(row) {
  const label = `"${row.contact_name}" (attempt ${row.retry_count + 1}/${row.max_retries + 1})`;
  logger.info(`Sending to ${label}: ${row.message.slice(0, 50)}...`);

  const nowIso = new Date().toISOString();

  // Mark as processing in DB immediately to lock the row and prevent duplicate processing
  await updateRow(row.id, {
    status: "processing",
    last_attempt_at: nowIso,
  });

  try {
    const deliveryStatus = await sendMessage(
      row.contact_name,
      row.message,
      row.phone_number,
      row.media_url,
      row.media_type
    );
    await updateRow(row.id, {
      status: "sent",
      delivery_status: deliveryStatus,
      sent_at: nowIso,
      last_attempt_at: nowIso,
    });
    logger.info(`Sent -> ${row.contact_name} (delivery_status: ${deliveryStatus})`);
  } catch (err) {
    const nextRetryCount = row.retry_count + 1;
    logger.error(`Failed -> ${row.contact_name}: ${err.message}`);

    if (nextRetryCount > row.max_retries) {
      await updateRow(row.id, {
        status: "failed",
        error: err.message,
        retry_count: nextRetryCount,
        last_attempt_at: nowIso,
      });
      logger.error(
        `Giving up on "${row.contact_name}" after ${nextRetryCount} attempts. Marked as failed.`
      );
    } else {
      const waitMin = backoffMinutes(nextRetryCount);
      const nextRetryAt = new Date(Date.now() + waitMin * 60 * 1000).toISOString();
      await updateRow(row.id, {
        error: err.message,
        retry_count: nextRetryCount,
        next_retry_at: nextRetryAt,
        last_attempt_at: nowIso,
      });
      logger.warn(
        `Will retry "${row.contact_name}" in ${waitMin} min (attempt ${nextRetryCount + 1}/${
          row.max_retries + 1
        }).`
      );
    }
  }
}

let isTicking = false;

async function tick() {
  if (isTicking) {
    logger.warn("Previous tick is still processing messages. Skipping this interval check.");
    return;
  }
  isTicking = true;

  try {
    // Clean up any stale backlog messages (e.g. from when the app was offline)
    await expireOldMessages();

    const due = await fetchDueMessages();
    if (due.length > 0) {
      logger.info(`${due.length} message(s) due.`);
    }
    for (const row of due) {
      // Sequential on purpose: WhatsApp Web can only do one search/send
      // flow at a time in a single browser tab.
      await processMessage(row);
    }
  } catch (err) {
    logger.error(`Error in scheduler tick: ${err.message}`);
  } finally {
    isTicking = false;
  }
}

async function main() {
  logger.info(`Scheduler starting. Polling every ${POLL_INTERVAL_MS / 1000}s.`);
  logger.info("Make sure Chrome is running via launch-chrome.bat and WhatsApp Web is logged in.");
  await tick();
  setInterval(tick, POLL_INTERVAL_MS);
}

main();
