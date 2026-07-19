const path = require("path");
const fs = require("fs");
const https = require("https");
const http = require("http");
const { chromium } = require("playwright");
const logger = require("./logger");

async function downloadFile(url, destFolder) {
  if (!fs.existsSync(destFolder)) {
    fs.mkdirSync(destFolder, { recursive: true });
  }
  
  let ext = ".jpg";
  const urlLower = url.toLowerCase();
  if (urlLower.includes(".png")) ext = ".png";
  else if (urlLower.includes(".jpeg") || urlLower.includes(".jpg")) ext = ".jpg";
  else if (urlLower.includes(".mp4")) ext = ".mp4";
  else if (urlLower.includes(".webp")) ext = ".webp";
  else if (urlLower.includes(".gif")) ext = ".gif";

  const filePath = path.join(destFolder, `temp_${Date.now()}_${Math.floor(Math.random()*1000)}${ext}`);
  const file = fs.createWriteStream(filePath);

  return new Promise((resolve, reject) => {
    const client = url.startsWith("https") ? https : http;
    const request = client.get(url, (response) => {
      if (response.statusCode >= 300 && response.statusCode < 400 && response.headers.location) {
        fs.unlink(filePath, () => {});
        downloadFile(response.headers.location, destFolder).then(resolve).catch(reject);
        return;
      }
      if (response.statusCode !== 200) {
        fs.unlink(filePath, () => {});
        reject(new Error(`Failed to download media: HTTP ${response.statusCode}`));
        return;
      }
      response.pipe(file);
      file.on("finish", () => {
        file.close(() => resolve(filePath));
      });
    });

    request.on("error", (err) => {
      fs.unlink(filePath, () => {});
      reject(err);
    });
  });
}

const DEBUG_PORT = process.env.CHROME_DEBUG_PORT || "9222";
const DELIVERY_CONFIRM_TIMEOUT_MS = 5000; // Reduced from 15s to 5s to process multiple customers much faster

let browserPromise = null;

// Connects to the Chrome instance YOU already opened (via launch-chrome.bat),
// rather than launching a new one. Reuses the connection across calls.
async function getWhatsAppPage() {
  try {
    if (!browserPromise) {
      browserPromise = chromium.connectOverCDP(`http://localhost:${DEBUG_PORT}`);
    }
    const browser = await browserPromise;
    const contexts = browser.contexts();
    if (contexts.length === 0) {
      throw new Error("No browser context found. Is Chrome open via launch-chrome.bat?");
    }
    const context = contexts[0];

    let page = context.pages().find((p) => p.url().includes("web.whatsapp.com"));
    if (!page) {
      page = await context.newPage();
      await page.goto("https://web.whatsapp.com");
    }
    await page.bringToFront();
    return page;
  } catch (error) {
    browserPromise = null;
    throw error;
  }
}

// NOTE: WhatsApp Web's DOM/attributes shift periodically with updates.
// These selectors reflect a recent layout. If a step starts failing,
// the fix is almost always: re-inspect that one element in Chrome DevTools
// and swap in its current aria-label/testid here.
const SELECTORS = {
  searchBox: 'input.html-input, input[role="textbox"]',
  messageBox: 'footer div[contenteditable="true"]',
  sendButton: 'button[aria-label="Send"]',
  chatHeaderTitle: 'header span[title]',
  // Opens the contact info panel where the phone number is visible
  chatHeaderClickable: 'div[role="main"] header, header:has([aria-label="Video call"]), header:has([aria-label="Search"]), header',
  infoPanelPhone: 'div:has(button[aria-label*="Block "]) span:has-text("+"), div:has([aria-label="Delete chat"]) span:has-text("+"), span:has-text("+")',
  outgoingBubbles: "div.message-out",
  // Tick icons WhatsApp renders on outgoing messages
  tickSent: 'span[data-icon="msg-check"]',
  tickDelivered: 'span[data-icon="msg-dblcheck"]',
  tickRead: 'span[data-icon="msg-dblcheck-ack"]',
};

async function waitForLoggedIn(page, timeoutMs = 60000) {
  await page.waitForSelector(SELECTORS.searchBox, { timeout: timeoutMs }).catch(() => {
    throw new Error(
      "WhatsApp Web search box not found. Make sure you're logged in (scan the QR code) in the Chrome window opened by launch-chrome.bat."
    );
  });
}

// Reads the phone number out of the currently-open chat's info panel.
// Returns null if it can't find one (e.g. contact has no number displayed,
// which happens for some saved-contact views).
async function getOpenChatPhoneNumber(page) {
  try {
    await page.locator(SELECTORS.chatHeaderClickable).first().click();
    
    // Wait for the contact info panel to open by waiting for the Delete chat button
    const deleteBtn = page.locator('[aria-label="Delete chat"]').first();
    await deleteBtn.waitFor({ state: "visible", timeout: 5000 });
    
    // The panel container is about 7 levels up from the Delete chat button
    const sidebar = deleteBtn.locator('xpath=../../../../../../..');
    const spans = sidebar.locator('span');
    const count = await spans.count();
    
    for (let i = 0; i < count; i++) {
      const text = await spans.nth(i).innerText();
      if (/\+\d[\d\s-]+/.test(text)) {
        await page.keyboard.press("Escape").catch(() => {});
        return text;
      }
    }
    
    await page.keyboard.press("Escape").catch(() => {});
    return null;
  } catch (error) {
    await page.keyboard.press("Escape").catch(() => {});
    return null;
  }
}

function cleanPhone(num) {
  if (!num) return "";
  let cleaned = num.replace(/\D/g, "");
  if (cleaned.length > 10 && (cleaned.startsWith("91") || cleaned.startsWith("1"))) {
    cleaned = cleaned.slice(cleaned.startsWith("91") ? 2 : 1);
  }
  return cleaned;
}

function comparePhoneNumbers(num1, num2) {
  const clean1 = cleanPhone(num1);
  const clean2 = cleanPhone(num2);
  return clean1 === clean2 && clean1 !== "";
}

function normalizeText(str) {
  if (!str) return "";
  return str
    .normalize("NFKD")
    .toLowerCase()
    .replace(/[^\w\s]/g, "") // Removes emojis and special punctuation
    .trim();
}

// Finds the correct chat to open when multiple contacts share a display name.
// If phoneNumber is given, it clicks through each matching result and checks
// the info panel until the number matches. If not given, or if none match,
// falls back to the first result (and logs a warning if there were duplicates).
async function clearSearchBox(page) {
  try {
    const searchBox = page.locator(SELECTORS.searchBox);
    await searchBox.click();
    // Use Ctrl+A and Backspace to ensure the input field is 100% empty
    await page.keyboard.press("Control+A");
    await page.keyboard.press("Backspace");
    await page.keyboard.press("Escape");
    await page.waitForTimeout(500); // Wait for the search state UI to reset
  } catch (e) {
    logger.warn(`Warning clearing search box: ${e.message}`);
  }
}

async function openChat(page, contactName, phoneNumber) {
  const searchVal = phoneNumber || contactName; // Fallback to contactName if no phone is specified, but prefer phone
  if (!searchVal) {
    throw new Error("Search value (phone number or name) is required.");
  }
  
  // 1. Clear any previous text completely to prevent query concatenation
  await clearSearchBox(page);
  
  const searchBox = page.locator(SELECTORS.searchBox);
  await searchBox.click();
  
  // Clean search value: keep only digits if it looks like a phone number, otherwise use it raw
  const isPhone = /^\+?[\d\s-]+$/.test(searchVal);
  const cleanSearch = isPhone ? searchVal.replace(/[\s-]/g, "") : searchVal;
  
  logger.info(`Searching for chat using: "${cleanSearch}"...`);
  await searchBox.pressSequentially(cleanSearch, { delay: 30 });
  
  // 2. Wait 1.5 seconds for WhatsApp Web search results to update dynamically
  await page.waitForTimeout(1500);

  // Wait for the contact list to update. We wait for any title span inside the grid to load.
  const contactSpan = page.locator('#pane-side span[title], [role="grid"] span[title]').first();
  await contactSpan.waitFor({ state: "visible", timeout: 10000 }).catch(() => {
    throw new Error(`Could not find any contact matching "${cleanSearch}" in WhatsApp Web.`);
  });

  const title = await contactSpan.getAttribute("title");
  logger.info(`Found contact row matching search: "${title}". Clicking to open chat...`);
  await contactSpan.click({ force: true });
}

// Waits for at least a single grey tick to appear on the most recent
// outgoing message bubble, confirming WhatsApp actually accepted/sent it
// (not just that the Send button was clicked).
async function waitForDeliveryConfirmation(page) {
  const lastBubble = page.locator(SELECTORS.outgoingBubbles).last();
  try {
    await lastBubble.waitFor({ state: "visible", timeout: DELIVERY_CONFIRM_TIMEOUT_MS });

    const tick = lastBubble
      .locator(SELECTORS.tickRead)
      .or(lastBubble.locator(SELECTORS.tickDelivered))
      .or(lastBubble.locator(SELECTORS.tickSent));

    await tick.first().waitFor({ state: "visible", timeout: DELIVERY_CONFIRM_TIMEOUT_MS });

    const hasDelivered = await lastBubble.locator(SELECTORS.tickDelivered).count();
    const hasRead = await lastBubble.locator(SELECTORS.tickRead).count();
    if (hasRead > 0) return "read";
    if (hasDelivered > 0) return "delivered";
    return "sent";
  } catch {
    return "unconfirmed";
  }
}

async function sendMessage(contactName, messageText, phoneNumber = null, mediaUrl = null, mediaType = "image") {
  const page = await getWhatsAppPage();
  await waitForLoggedIn(page);

  await openChat(page, contactName, phoneNumber);

  if (mediaUrl) {
    let tempFilePath = null;
    try {
      const tempDir = path.join(__dirname, "temp_media");
      logger.info(`Downloading ${mediaType || "media"} from ${mediaUrl}...`);
      tempFilePath = await downloadFile(mediaUrl, tempDir);

      logger.info(`Attaching media file: ${tempFilePath}...`);
      // Target file input element in WhatsApp Web
      const fileInput = page.locator('input[type="file"]').first();
      await fileInput.setInputFiles(tempFilePath);

      // Wait for media preview overlay screen to open
      await page.waitForTimeout(2500);

      // If caption text is provided, fill it into the caption textbox in media preview screen
      if (messageText && messageText.trim() !== "") {
        const captionBox = page.locator('div[contenteditable="true"]').last();
        await captionBox.waitFor({ state: "visible", timeout: 5000 }).catch(() => {});
        await captionBox.click().catch(() => {});

        const lines = messageText.split("\n");
        for (let i = 0; i < lines.length; i++) {
          await captionBox.pressSequentially(lines[i], { delay: 15 });
          if (i < lines.length - 1) {
            await page.keyboard.down("Shift");
            await page.keyboard.press("Enter");
            await page.keyboard.up("Shift");
          }
        }
      }

      // Click the send button on the media preview screen
      const mediaSendBtn = page.locator('span[data-icon="send"], button[aria-label="Send"], div[aria-label="Send"]').last();
      await mediaSendBtn.waitFor({ state: "visible", timeout: 5000 });
      await mediaSendBtn.click();
      await page.waitForTimeout(2000);
    } catch (mediaErr) {
      logger.error(`Error sending media attachment: ${mediaErr.message}`);
      throw mediaErr;
    } finally {
      if (tempFilePath && fs.existsSync(tempFilePath)) {
        try {
          fs.unlinkSync(tempFilePath);
        } catch (e) {}
      }
    }
  } else {
    // Normal text-only message flow
    const messageBox = page.locator(SELECTORS.messageBox);
    await messageBox.waitFor({ state: "visible", timeout: 10000 });
    await messageBox.click();

    const lines = (messageText || "").split("\n");
    for (let i = 0; i < lines.length; i++) {
      await messageBox.pressSequentially(lines[i], { delay: 15 });
      if (i < lines.length - 1) {
        await page.keyboard.down("Shift");
        await page.keyboard.press("Enter");
        await page.keyboard.up("Shift");
      }
    }

    await page.locator(SELECTORS.sendButton).click();
  }

  const deliveryStatus = await waitForDeliveryConfirmation(page);
  if (deliveryStatus === "unconfirmed") {
    logger.warn(
      `Sent to "${contactName}" but couldn't confirm delivery via tick icon within ` +
        `${DELIVERY_CONFIRM_TIMEOUT_MS / 1000}s. It likely still went through.`
    );
  }

  // Clear the search box so the next run starts clean
  await clearSearchBox(page);

  return deliveryStatus;
}

module.exports = { sendMessage, getWhatsAppPage };
