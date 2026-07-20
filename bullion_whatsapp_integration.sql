-- =========================================================================
-- SUPABASE SQL SCRIPT: BULLION WHATSAPP AUTO-SCHEDULER & GREETINGS
-- =========================================================================
-- Set Supabase database default timezone to IST (Indian Standard Time)
ALTER DATABASE postgres SET timezone TO 'Asia/Kolkata';

-- Copy and run this entire file in your Supabase SQL Editor.
-- It will NOT affect or modify your existing bullion_rates table in any way.
-- =========================================================================

-- 1. Create the WhatsApp message queue table (if not already created)
create table if not exists scheduled_messages (
  id uuid primary key default gen_random_uuid(),
  contact_name text not null,
  phone_number text,
  message text not null,
  send_at timestamptz not null,
  status text not null default 'pending',
  delivery_status text default 'unconfirmed',
  error text,
  retry_count int not null default 0,
  max_retries int not null default 3,
  next_retry_at timestamptz,
  sent_at timestamptz,
  last_attempt_at timestamptz,
  created_at timestamptz not null default now()
);

-- Ensure auto-incrementing queue order exists for strict sequential processing
alter table scheduled_messages add column if not exists queue_order serial;
alter table scheduled_messages add column if not exists media_url text;
alter table scheduled_messages add column if not exists media_type text default 'image';

create index if not exists idx_scheduled_messages_due
  on scheduled_messages (status, send_at, next_retry_at);

-- Create the advertisements broadcast table
create table if not exists bullion_whatsapp_advertisements (
  id uuid primary key default gen_random_uuid(),
  media_url text not null,                          -- Direct URL to image or video
  media_type text not null default 'image',        -- 'image' or 'video'
  caption text,                                     -- Optional text caption (supports {name} placeholder)
  status text not null default 'pending',           -- 'pending', 'processing', 'completed'
  total_customers int default 0,
  created_at timestamptz not null default now()
);

-- 2. Create the message templates table
create table if not exists bullion_whatsapp_templates (
  language text primary key,                        -- Language key in lowercase (e.g. 'english', 'hindi', 'bengali')
  price_update_template text not null,             -- Message structure for price updates (uses {gold} and {silver})
  morning_greeting_template text not null,         -- Message structure for morning greetings (uses {name})
  night_greeting_template text not null,           -- Message structure for night greetings (uses {name})
  welcome_template text,                           -- Message structure for welcome message (uses {name})
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Ensure welcome_template column exists on existing installations
alter table bullion_whatsapp_templates add column if not exists welcome_template text;

-- Seed initial templates for English, Hindi, and Bengali
insert into bullion_whatsapp_templates (language, price_update_template, morning_greeting_template, night_greeting_template, welcome_template)
values 
  ('english', 
   '*SSR BULLION | MARKET ALERT*' || chr(10) || chr(10) || 'The bullion market has been updated.' || chr(10) || chr(10) || 'Check the latest Gold & Silver prices, explore live market trends, and make informed decisions with the *SSR Bullion* app.' || chr(10) || chr(10) || '👉 *Open SSR BULLION now to view the latest rates.*' || chr(10) || chr(10) || '━━━━━━━━━━━━━━━━━━' || chr(10) || '*SSR BULLION*' || chr(10) || '_TRUSTED SOURCE FOR LIVE BULLION RATES._',
   '*☀️ GOOD MORNING | SSR BULLION*' || chr(10) || chr(10) || 'Wishing you a successful and prosperous day ahead.' || chr(10) || chr(10) || 'Start your day with the latest Gold & Silver bullion rates and stay informed with real-time market updates.' || chr(10) || chr(10) || '*👉 Open SSR BULLION to check today''s live market prices.*' || chr(10) || chr(10) || '━━━━━━━━━━━━━━━━━━' || chr(10) || ' *SSR BULLION*' || chr(10) || '_Your Trusted Source for Live Bullion Rates._',
   '*🌙 GOOD NIGHT | SSR BULLION*' || chr(10) || chr(10) || 'The trading day has come to an end.' || chr(10) || chr(10) || 'Thank you for trusting *SSR BULLION* for your daily bullion market updates. Wishing you a peaceful night, and we look forward to serving you with fresh market insights tomorrow.' || chr(10) || chr(10) || '*👉 See you tomorrow on SSR BULLION for the latest live Gold & Silver rates.*' || chr(10) || chr(10) || '━━━━━━━━━━━━━━━━━━' || chr(10) || '*SSR BULLION*' || chr(10) || '_Your Trusted Source for Live Bullion Rates._',
   '*✨ WELCOME TO SSR BULLION*' || chr(10) || chr(10) || 'Welcome to a trusted platform for live bullion market intelligence.' || chr(10) || chr(10) || 'Thank you for choosing *SSR BULLION*. You are now connected to real-time Gold & Silver bullion rates, live market updates, and accurate pricing information designed to help you stay informed throughout the trading day.' || chr(10) || chr(10) || '*👉 Open SSR BULLION to access the latest live bullion rates and begin your experience.*' || chr(10) || chr(10) || '━━━━━━━━━━━━━━━━━━' || chr(10) || '*SSR BULLION*' || chr(10) || '_Your Trusted Source for Live Bullion Rates._'),
  ('hindi',
   '*SSR BULLION | मार्केट अलर्ट*' || chr(10) || chr(10) || 'बुलियन मार्केट अपडेट हो गया है।' || chr(10) || chr(10) || '*SSR Bullion* ऐप पर सोने और चांदी के नवीनतम भाव देखें, लाइव मार्केट ट्रेंड्स की जानकारी लें और सही निर्णय लें।' || chr(10) || chr(10) || '👉 *नवीनतम दरें देखने के लिए अभी SSR BULLION खोलें।*' || chr(10) || chr(10) || '━━━━━━━━━━━━━━━━━━' || chr(10) || '*SSR BULLION*' || chr(10) || '_लाइव बुलियन दरों के लिए आपका विश्वसनीय स्रोत।_',
   '*☀️ शुभ प्रभात | SSR BULLION*' || chr(10) || chr(10) || 'आपके लिए एक सफल और समृद्ध दिन की कामना करते हैं।' || chr(10) || chr(10) || 'अपने दिन की शुरुआत सोने और चांदी के नवीनतम बुलियन भावों के साथ करें और रियल-टाइम मार्केट अपडेट्स से जुड़े रहें।' || chr(10) || chr(10) || '*👉 आज के लाइव मार्केट भाव देखने के लिए SSR BULLION खोलें।*' || chr(10) || chr(10) || '━━━━━━━━━━━━━━━━━━' || chr(10) || ' *SSR BULLION*' || chr(10) || '_लाइव बुलियन दरों के लिए आपका विश्वसनीय स्रोत।_',
   '*🌙 शुभ रात्रि | SSR BULLION*' || chr(10) || chr(10) || 'आज का व्यावसायिक दिन समाप्त हो गया है।' || chr(10) || chr(10) || 'अपने दैनिक बुलियन मार्केट अपडेट्स के लिए *SSR BULLION* पर भरोसा करने के लिए धन्यवाद। आपको एक शांतिपूर्ण रात की शुभकामनाएं, और हम कल ताज़ा मार्केट अपडेट्स के साथ आपकी सेवा करने के लिए उत्सुक हैं।' || chr(10) || chr(10) || '*👉 नवीनतम लाइव सोने और चांदी के भावों के लिए कल फिर SSR BULLION पर मिलते हैं।*' || chr(10) || chr(10) || '━━━━━━━━━━━━━━━━━━' || chr(10) || '*SSR BULLION*' || chr(10) || '_लाइव बुलियन दरों के लिए आपका विश्वसनीय स्रोत।_',
   '*✨ SSR BULLION में आपका स्वागत है*' || chr(10) || chr(10) || 'लाइव बुलियन मार्केट इंटेलिजेंस के एक विश्वसनीय प्लेटफॉर्म में आपका स्वागत है।' || chr(10) || chr(10) || '*SSR BULLION* को चुनने के लिए धन्यवाद। अब आप वास्तविक समय के सोने और चांदी के बुलियन भाव, लाइव मार्केट अपडेट्स और सटीक मूल्य निर्धारण जानकारी से जुड़ गए हैं, जो आपको पूरे कारोबारी दिन सूचित रखने के लिए डिज़ाइन की गई हैं।' || chr(10) || chr(10) || '*👉 नवीनतम लाइव बुलियन भाव देखने और अपने अनुभव की शुरुआत करने के लिए SSR BULLION खोलें।*' || chr(10) || chr(10) || '━━━━━━━━━━━━━━━━━━' || chr(10) || '*SSR BULLION*' || chr(10) || '_लाइव बुलियन दरों के लिए आपका विश्वसनीय स्रोत।_'),
  ('bengali',
   '*SSR BULLION | মার্কেট অ্যালার্ট*' || chr(10) || chr(10) || 'বুলিয়ন মার্কেট আপডেট হয়েছে।' || chr(10) || chr(10) || '*SSR Bullion* অ্যাপে সোনা ও রূপার নতুন দর দেখুন, লাইভ মার্কেট ট্রেন্ড জানুন এবং সঠিক সিদ্ধান্ত নিন।' || chr(10) || chr(10) || '👉 *সর্বশেষ দর দেখতে এখনই SSR BULLION ওপেন করুন।*' || chr(10) || chr(10) || '━━━━━━━━━━━━━━━━━━' || chr(10) || '*SSR BULLION*' || chr(10) || '_লাইভ বুলিয়ন রেটের বিশ্বস্ত প্রতিষ্ঠান।_',
   '*☀️ সুপ্রভাত | SSR BULLION*' || chr(10) || chr(10) || 'আপনার আজকের দিনটি সফল ও সমৃদ্ধ হোক।' || chr(10) || chr(10) || 'সোনা ও রূপার সর্বশেষ বুলিয়ন দর দিয়ে আপনার দিন শুরু করুন এবং রিয়েল-টাইম মার্কেট আপডেটের সাথে থাকুন।' || chr(10) || chr(10) || '*👉 আজকের লাইভ মার্কেট দর দেখতে SSR BULLION ওপেন করুন।*' || chr(10) || chr(10) || '━━━━━━━━━━━━━━━━━━' || chr(10) || ' *SSR BULLION*' || chr(10) || '_লাইভ বুলিয়ন রেটের বিশ্বস্ত প্রতিষ্ঠান।_',
   '*🌙 শুভ রাত্রি | SSR BULLION*' || chr(10) || chr(10) || 'আজকের ট্রেডিং দিন শেষ হয়েছে।' || chr(10) || chr(10) || 'আপনার দৈনিক বুলিয়ন মার্কেট আপডেটের জন্য *SSR BULLION*-এর ওপর ভরসা রাখার জন্য ধন্যবাদ। আপনাকে একটি শান্তিময় রাতের শুভেচ্ছা, এবং আমরা আগামীকাল নতুন মার্কেট আপডেট নিয়ে আপনার সেবায় নিয়োজিত থাকার প্রত্যাশা করছি।' || chr(10) || chr(10) || '*👉 সর্বশেষ লাইভ সোনা ও রূপার দর দেখতে আগামীকাল আবার দেখা হবে SSR BULLION-এ।*' || chr(10) || chr(10) || '━━━━━━━━━━━━━━━━━━' || chr(10) || '*SSR BULLION*' || chr(10) || '_লাইভ বুলিয়ন রেটের বিশ্বস্ত প্রতিষ্ঠান।_',
   '*✨ SSR BULLION-এ আপনাকে স্বাগতম*' || chr(10) || chr(10) || 'লাইভ বুলিয়ন মার্কেট ইন্টেলিজেন্সের একটি বিশ্বস্ত প্ল্যাটফর্মে আপনাকে স্বাগতম।' || chr(10) || chr(10) || '*SSR BULLION* বেছে নেওয়ার জন্য ধন্যবাদ। আপনি এখন রিয়েল-টাইম সোনা ও রূপার বুলিয়ন দর, লাইভ মার্কেট আপডেট এবং নির্ভুল মূল্যের তথ্যের সাথে সংযুক্ত, যা আপনাকে পুরো ট্রেডিং দিন জুড়ে অবহিত রাখতে সাহায্য করবে।' || chr(10) || chr(10) || '*👉 সর্বশেষ লাইভ বুলিয়ন দর দেখতে এবং আপনার অভিজ্ঞতা শুরু করতে SSR BULLION ওপেন করুন।*' || chr(10) || chr(10) || '━━━━━━━━━━━━━━━━━━' || chr(10) || '*SSR BULLION*' || chr(10) || '_লাইভ বুলিয়ন রেটের বিশ্বস্ত প্রতিষ্ঠান।_')
on conflict (language) do update set
  price_update_template = EXCLUDED.price_update_template,
  morning_greeting_template = EXCLUDED.morning_greeting_template,
  night_greeting_template = EXCLUDED.night_greeting_template,
  welcome_template = EXCLUDED.welcome_template;

-- 3. Create the NEW, isolated customer subscriptions table
create table if not exists bullion_whatsapp_customers (
  id uuid primary key default gen_random_uuid(),
  contact_name text not null,
  phone_number text not null,               -- WhatsApp phone number (e.g. +919836282432)
  priority text not null default 'medium',  -- 'high' (10m), 'medium' (15m), 'low' (4h)
  
  last_gold_price_sent numeric,             -- Tracks last gold rate notified to this customer
  last_silver_price_sent numeric,           -- Tracks last silver rate notified to this customer
  last_notification_sent_at timestamptz default '-infinity'::timestamptz,
  
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Ensure auto-incrementing serial number exists to prioritize customers
alter table bullion_whatsapp_customers add column if not exists serial_no serial;

-- Ensure language preference column exists (defaults to 'english')
alter table bullion_whatsapp_customers add column if not exists preferred_language text not null default 'english';

-- Index for scanning active notifications
create index if not exists idx_whatsapp_customers_notifications 
  on bullion_whatsapp_customers (is_active, last_notification_sent_at);

-- =========================================================================
-- 3. Live Price Check Function (Read-Only access on bullion_rates)
-- =========================================================================
create or replace function check_bullion_price_updates()
returns void as $$
declare
  current_time_ist time;
  current_gold numeric;
  current_silver numeric;
  latest_timestamp timestamptz;
  cust record;
  time_interval interval;
  price_changed boolean;
  message_text text;
  tpl record;
begin
  -- Restrict Market Alert updates strictly between 10:30 AM IST and 9:45 PM IST
  current_time_ist := (now() at time zone 'Asia/Kolkata')::time;
  if current_time_ist < '10:30:00'::time or current_time_ist > '21:45:00'::time then
    return; -- Outside market hours, do not queue price update alerts
  end if;

  -- 1. Find the latest upload timestamp in the rates table (most recent row)
  select created_at into latest_timestamp from bullion_rates order by id desc limit 1;

  -- 2. Fetch Gold and Silver prices matching this exact timestamp (same batch upload)
  select price into current_gold from bullion_rates where item = 'gold_995_100gms' and created_at = latest_timestamp limit 1;
  select price into current_silver from bullion_rates where item = 'silver_999_1kg' and created_at = latest_timestamp limit 1;

  -- 3. Fallback: if either rate was not in the same batch, grab its latest independent price
  if current_gold is null then
    select price into current_gold from bullion_rates where item = 'gold_995_100gms' order by id desc limit 1;
  end if;
  if current_silver is null then
    select price into current_silver from bullion_rates where item = 'silver_999_1kg' order by id desc limit 1;
  end if;

  -- Loop through active customers strictly sorted by their serial number
  for cust in select * from bullion_whatsapp_customers where is_active = true order by serial_no asc loop
    
    -- Determine the time interval based on Priority (trimmed and case-insensitive for safety)
    case lower(trim(both from cust.priority))
      when 'high' then time_interval := interval '10 minutes';
      when 'medium' then time_interval := interval '15 minutes';
      when 'low' then time_interval := interval '4 hours';
      else time_interval := interval '15 minutes';
    end case;

    -- Check if the priority interval has elapsed (sends unconditionally on interval schedule)
    if (now() - cust.last_notification_sent_at) >= time_interval then
      -- Find template for preferred language
      select * into tpl 
      from bullion_whatsapp_templates 
      where lower(trim(both from language)) = lower(trim(both from cust.preferred_language));

      -- Fallback to english if template not found
      if not found then
        select * into tpl 
        from bullion_whatsapp_templates 
        where lower(language) = 'english';
      end if;

      -- Format market alert text (replaces placeholders if present)
      message_text := replace(
        replace(tpl.price_update_template, '{gold}', coalesce(current_gold::text, '')),
        '{silver}', coalesce(current_silver::text, '')
      );

      -- Expire any old pending market alerts for this customer so they only get the latest one
      update scheduled_messages
      set status = 'expired', error = 'Superseded by newer interval alert'
      where contact_name = cust.contact_name
        and status = 'pending'
        and (
          message like '%MARKET ALERT%' or 
          message like '%मार्केट अलर्ट%' or 
          message like '%মার্কেট অ্যালার্ট%' or 
          message like '%Price Update%'
        );

      insert into scheduled_messages (
        contact_name,
        phone_number,
        message,
        send_at,
        status
      ) values (
        cust.contact_name,
        cust.phone_number,
        message_text,
        now(),
        'pending'
      );

      -- Update customer's last notified status and timestamp
      update bullion_whatsapp_customers
      set 
        last_gold_price_sent = current_gold,
        last_silver_price_sent = current_silver,
        last_notification_sent_at = now()
      where id = cust.id;

    end if;
  end loop;
end;
$$ language plpgsql;

-- =========================================================================
-- 4. Greetings Function
-- =========================================================================
create or replace function queue_greetings(greeting_type text)
returns void as $$
declare
  cust record;
  msg text;
  tpl record;
begin
  -- Set any old pending greetings to expired before creating new ones
  update scheduled_messages 
  set status = 'expired', error = 'Superseded by new greeting'
  where status = 'pending' 
    and (
      message like '☀️ Good Morning%' or message like '🌙 Good Night%' or
      message like '☀️ शुभ प्रभात%' or message like '🌙 शुभ रात्रि%' or
      message like '☀️ সুপ্রভাত%' or message like '🌙 শুভ রাত্রি%'
    );

  for cust in select * from bullion_whatsapp_customers where is_active = true loop
    -- Find template for preferred language
    select * into tpl 
    from bullion_whatsapp_templates 
    where lower(trim(both from language)) = lower(trim(both from cust.preferred_language));

    -- Fallback to english if template not found
    if not found then
      select * into tpl 
      from bullion_whatsapp_templates 
      where lower(language) = 'english';
    end if;

    -- Pick the correct morning or night template and replace the name placeholder
    if greeting_type = 'morning' then
      msg := replace(tpl.morning_greeting_template, '{name}', cust.contact_name);
    else
      msg := replace(tpl.night_greeting_template, '{name}', cust.contact_name);
    end if;

    insert into scheduled_messages (
      contact_name,
      phone_number,
      message,
      send_at,
      status
    ) values (
      cust.contact_name,
      cust.phone_number,
      msg,
      now(),
      'pending'
    );
  end loop;
end;
$$ language plpgsql;

-- =========================================================================
-- 5. Automate Cron Scheduling (Using pg_cron in Supabase)
-- =========================================================================
-- Enable the pg_cron extension (requires admin role)
create extension if not exists pg_cron;

-- Unschedule any existing jobs first to avoid duplicates
select cron.unschedule('check-bullion-prices') where exists (select 1 from cron.job where jobname = 'check-bullion-prices');
select cron.unschedule('morning-greeting') where exists (select 1 from cron.job where jobname = 'morning-greeting');
select cron.unschedule('night-greeting') where exists (select 1 from cron.job where jobname = 'night-greeting');

-- 1. Check price updates every 5 minutes
select cron.schedule(
  'check-bullion-prices',
  '*/5 * * * *',
  'select check_bullion_price_updates();'
);

-- 2. Daily morning greeting at 7:00 AM IST (1:30 AM UTC server time)
select cron.schedule(
  'morning-greeting',
  '30 1 * * *',
  $$select queue_greetings('morning');$$
);

-- 3. Daily night greeting at 10:00 PM IST (4:30 PM UTC / 16:30 UTC server time)
select cron.schedule(
  'night-greeting',
  '30 16 * * *',
  $$select queue_greetings('night');$$
);

-- =========================================================================
-- 6. Automatic One-Time Welcome Message Trigger for New Registrations
-- =========================================================================
create or replace function handle_new_customer_welcome()
returns trigger as $$
declare
  msg text;
  tpl record;
  current_gold numeric;
  current_silver numeric;
  latest_timestamp timestamptz;
begin
  -- 1. Look up template for customer's preferred language
  select * into tpl 
  from bullion_whatsapp_templates 
  where lower(trim(both from language)) = lower(trim(both from NEW.preferred_language));

  -- Fallback to english if language template is missing
  if not found then
    select * into tpl 
    from bullion_whatsapp_templates 
    where lower(language) = 'english';
  end if;

  -- 2. Format welcome message replacing {name} placeholder
  msg := replace(coalesce(tpl.welcome_template, 'Welcome {name}! Thank you for registering with SSR Bullion.'), '{name}', NEW.contact_name);

  -- 3. Insert welcome message into queue for immediate delivery
  insert into scheduled_messages (
    contact_name,
    phone_number,
    message,
    send_at,
    status
  ) values (
    NEW.contact_name,
    NEW.phone_number,
    msg,
    now(),
    'pending'
  );

  -- 4. Fetch the latest live market rates to set baseline for this new customer
  select created_at into latest_timestamp from bullion_rates order by id desc limit 1;
  select price into current_gold from bullion_rates where item = 'gold_995_100gms' order by id desc limit 1;
  select price into current_silver from bullion_rates where item = 'silver_999_1kg' order by id desc limit 1;

  -- 5. Initialize the new customer's timestamp & baseline prices so they don't get an extra live rate message right away
  update bullion_whatsapp_customers
  set 
    last_notification_sent_at = now(),
    last_gold_price_sent = current_gold,
    last_silver_price_sent = current_silver
  where id = NEW.id;

  return NEW;
end;
$$ language plpgsql;

-- Attach trigger to execute ONLY on new customer INSERT
drop trigger if exists trigger_onboard_new_customer on bullion_whatsapp_customers;

create trigger trigger_onboard_new_customer
after insert on bullion_whatsapp_customers
for each row
execute function handle_new_customer_welcome();

-- =========================================================================
-- 7. Media Advertisement Broadcast Trigger
-- =========================================================================
create or replace function handle_new_advertisement_broadcast()
returns trigger as $$
declare
  cust record;
  caption_text text;
  count_queued int := 0;
begin
  if NEW.status = 'pending' then
    -- Loop through active customers ordered strictly by serial number
    for cust in select * from bullion_whatsapp_customers where is_active = true order by serial_no asc loop
      -- Replace optional {name} placeholder in caption if present
      caption_text := replace(coalesce(NEW.caption, ''), '{name}', cust.contact_name);

      insert into scheduled_messages (
        contact_name,
        phone_number,
        message,
        media_url,
        media_type,
        send_at,
        status
      ) values (
        cust.contact_name,
        cust.phone_number,
        caption_text,
        NEW.media_url,
        lower(NEW.media_type),
        now(),
        'pending'
      );

      count_queued := count_queued + 1;
    end loop;

    -- Mark ad as completed broadcast setup
    update bullion_whatsapp_advertisements 
    set status = 'completed', total_customers = count_queued 
    where id = NEW.id;
  end if;

  return NEW;
end;
$$ language plpgsql;

-- Attach trigger to execute on new advertisement INSERT
drop trigger if exists trigger_broadcast_advertisement on bullion_whatsapp_advertisements;

create trigger trigger_broadcast_advertisement
after insert on bullion_whatsapp_advertisements
for each row
execute function handle_new_advertisement_broadcast();


