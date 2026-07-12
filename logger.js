const fs = require("fs");
const path = require("path");

const LOG_DIR = path.join(__dirname, "logs");
if (!fs.existsSync(LOG_DIR)) {
  fs.mkdirSync(LOG_DIR, { recursive: true });
}

function logFilePath() {
  const date = new Date().toISOString().slice(0, 10); // YYYY-MM-DD
  return path.join(LOG_DIR, `${date}.log`);
}

function write(level, message) {
  const timestamp = new Date().toISOString();
  const line = `[${timestamp}] [${level}] ${message}`;

  // Console (kept colorless/simple so it reads fine in any terminal)
  if (level === "ERROR") {
    console.error(line);
  } else if (level === "WARN") {
    console.warn(line);
  } else {
    console.log(line);
  }

  // File — append, one file per day
  try {
    fs.appendFileSync(logFilePath(), line + "\n");
  } catch (err) {
    // If logging to disk fails, don't crash the app over it —
    // just surface it once on the console.
    console.error(`[${timestamp}] [ERROR] Failed to write to log file: ${err.message}`);
  }
}

module.exports = {
  info: (msg) => write("INFO", msg),
  warn: (msg) => write("WARN", msg),
  error: (msg) => write("ERROR", msg),
};
