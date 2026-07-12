# WhatsApp + Supabase Scheduled Messenger

Single-user automation: you log into WhatsApp Web manually, this app takes it
from there — reading contact/message/time info from Supabase and sending
messages automatically via WhatsApp Web.

## How it works

1. `launch-chrome.bat` opens Chrome with a remote debugging port and a
   dedicated profile folder (so this WhatsApp login is separate from your
   normal Chrome profile and stays logged in between runs).
2. You scan the WhatsApp Web QR code once, like normal.
3. `npm start` runs a Node process that connects to that already-open Chrome
   tab via the Chrome DevTools Protocol, and:
   - polls your Supabase `scheduled_messages` table every N seconds
   - for each row that's due, searches the contact, opens the chat,
     disambiguates by phone number if you have duplicate names, types the
     message, sends it, and confirms delivery via the tick icon
   - retries failed sends automatically with backoff, up to a configurable
     limit
   - logs everything to both the console and a daily log file

No screen resizing or coordinates are needed — Playwright finds elements by
their actual HTML attributes, so it works regardless of window size.

## One-time setup

1. Install dependencies:
   ```
   npm install
   ```
2. In Supabase: open the SQL editor and run `schema.sql` to create the
   `scheduled_messages` table. (If you're upgrading from an earlier version
   of this project, use the migration block at the bottom of that file
   instead.)
3. Copy `.env.example` to `.env` and fill in:
   - `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` (Project Settings -> API)
4. Edit `launch-chrome.bat` if your Chrome isn't installed at the default path.

## Running it — the easy way (recommended)

Two double-clickable files handle everything:

- **`start-all.bat`** — launches Chrome (with remote debugging + a dedicated
  WhatsApp profile) AND starts the Node app in one go. First run will show
  the QR code to scan; after that it just reconnects.
- **`stop-all.bat`** — shuts down both Chrome and the Node process cleanly.

By default `start-all.bat` starts the **Send Line test console**
(`server.js`) — the manual send UI, with Supabase untouched. Once you've
finished testing and want the real Supabase-driven scheduler instead, open
`start-all.ps1` and change this line near the top:
```
$entryFile = "server.js"
```
to:
```
$entryFile = "scheduler.js"
```
That's the only switch needed to move from manual testing to live scheduling.

Note: `start-all.bat` calls PowerShell under the hood (to reliably track
process IDs so `stop-all.bat` can find and close them) — you don't need to
do anything differently, just double-click the `.bat` files as normal.

## Running it — manually (if you'd rather run pieces individually)

1. Double-click `launch-chrome.bat`. Log into WhatsApp Web if not already.
2. In a terminal, in this folder, run either:
   ```
   npm run test-ui
   ```
   for the manual Send Line console, or:
   ```
   npm start
   ```
   for the real Supabase-driven scheduler.
3. Leave both open (Chrome window + terminal).

## Testing without Supabase — the manual Send console

Before wiring up scheduling, use this to confirm the WhatsApp automation
itself actually works end to end:

```
npm run test-ui
```

Then open **http://localhost:4545** in your browser. It's a simple page:
type a contact name, optional phone (only needed for duplicate names), and
a message, hit Send — it goes straight to WhatsApp Web through your linked
Chrome session. Supabase is not touched at all by this page; it calls the
same `sendMessage()` function directly.

Each attempt shows up in a session log below the form with a tick icon
(pending → sent/delivered/read, or an error if it failed) so you can see
exactly what happened without digging through the terminal.

Once this is reliably working, move on to the scheduler (`npm start`) and
Supabase-backed flow described below.

## Adding a message to send (scheduled, via Supabase)

**Option 1 — the CLI helper (recommended, no SQL needed):**
```
npm run add
```
This walks you through it interactively: contact name, message, send time
(accepts either a full timestamp or shorthand like `+10m`, `+2h`, `+1d`),
and an optional phone number.

Or skip the prompts with flags:
```
node add-message.js --contact "Mom" --message "Happy birthday!" --at "+10m"
```

**Option 2 — directly in Supabase**, via the table editor or SQL:
```sql
insert into scheduled_messages (contact_name, message, send_at)
values ('Mom', 'Happy birthday!', now() + interval '5 minutes');
```

## Handling duplicate contact names

If you have two+ WhatsApp contacts saved with the exact same display name,
add their `phone_number` when queuing the message — the app will open each
matching search result, check its info panel for the number, and message the
one that actually matches. Without a phone number, it falls back to
whichever result WhatsApp lists first, and logs a warning so you know it happened.

## Retries

Each row has `retry_count` / `max_retries` (default 3) / `next_retry_at`.
On a failed send, the scheduler:
- increments `retry_count`
- schedules the next attempt with exponential backoff (2min, 4min, 8min, ...)
- once `retry_count` exceeds `max_retries`, marks the row `failed`
  permanently with the error message saved in the `error` column

You can raise/lower `max_retries` per row directly in Supabase if some
messages are more important than others.

## Delivery confirmation

After clicking Send, the app watches the last outgoing message bubble for
WhatsApp's tick icon (sent / delivered / read) rather than assuming success
just because Send was clicked. This gets saved to `delivery_status` on the
row: `sent`, `delivered`, `read`, or `unconfirmed` if the tick didn't render
in time (rare — the message almost certainly still went through, WhatsApp's
UI can just lag).

## Logs

Every run writes to `logs/YYYY-MM-DD.log` (one file per day) in addition to
the console, so you have a record even if you weren't watching the terminal
when something failed.

## Important notes

- **contact_name must match exactly** what shows up in your WhatsApp chat
  list — that's how the search finds them.
- **Selectors may need updating over time.** WhatsApp Web's HTML structure
  changes with their updates. If sending suddenly stops working, the fix is
  usually: right-click the broken element (search box, send button, info
  panel, etc.) in Chrome DevTools -> Inspect, and update the matching
  selector in `whatsapp.js`.
- **Rate/ban risk:** WhatsApp's terms don't officially permit third-party
  automation of WhatsApp Web. For a single personal account sending a
  reasonable volume of messages to your own contacts, this is low-risk and
  widely done, but avoid high-volume or bulk/unsolicited sending.
- Keep both the Chrome window and the `npm start` terminal running for this
  to work — closing either stops the automation.
