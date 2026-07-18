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

create index if not exists idx_scheduled_messages_due
  on scheduled_messages (status, send_at, next_retry_at);

-- 2. Create the message templates table
create table if not exists bullion_whatsapp_templates (
  language text primary key,                        -- Language key in lowercase (e.g. 'english', 'hindi', 'bengali')
  price_update_template text not null,             -- Message structure for price updates (uses {gold} and {silver})
  morning_greeting_template text not null,         -- Message structure for morning greetings (uses {name})
  night_greeting_template text not null,           -- Message structure for night greetings (uses {name})
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Seed initial templates for English, Hindi, and Bengali
insert into bullion_whatsapp_templates (language, price_update_template, morning_greeting_template, night_greeting_template)
values 
  ('english', 
   'Live Bullion Price Update: ' || chr(10) || '✨ Gold rate: ₹{gold}' || chr(10) || '✨ Silver rate: ₹{silver}',
   '☀️ Good Morning, {name}! Have a profitable day ahead. Here are today''s starting bullion rates.',
   '🌙 Good Night, {name}! Thank you for trading with us today.'),
  ('hindi',
   'लाइव बुलियन मूल्य अपडेट: ' || chr(10) || '✨ सोने की दर: ₹{gold}' || chr(10) || '✨ चांदी की दर: ₹{silver}',
   '☀️ शुभ प्रभात, {name}! आपका दिन लाभदायक रहे। ये हैं आज के बुलियन भाव।',
   '🌙 शुभ रात्रि, {name}! आज हमारे साथ व्यापार करने के लिए धन्यवाद।'),
  ('bengali',
   'লাইভ বুলিয়ন মূল্য আপডেট: ' || chr(10) || '✨ সোনার দাম: ₹{gold}' || chr(10) || '✨ রূপার দাম: ₹{silver}',
   '☀️ সুপ্রভাত, {name}! আপনার আজকের দিনটি লাভজনক হোক। এই হলো আজকের বুলিয়নের প্রারম্ভিক দর।',
   '🌙 শুভ রাত্রি, {name}! আজ আমাদের সাথে ব্যবসা করার জন্য ধন্যবাদ।')
on conflict (language) do nothing;

-- 3. Create the NEW, isolated customer subscriptions table
create table if not exists bullion_whatsapp_customers (
  id uuid primary key default gen_random_uuid(),
  contact_name text not null,
  phone_number text not null,               -- WhatsApp phone number (e.g. +919836282432)
  priority text not null default 'medium',  -- 'high' (45m), 'medium' (2h), 'low' (4h)
  
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
  current_gold numeric;
  current_silver numeric;
  latest_timestamp timestamptz;
  cust record;
  time_interval interval;
  price_changed boolean;
  message_text text;
  tpl record;
begin
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
      when 'high' then time_interval := interval '5 minutes';
      when 'medium' then time_interval := interval '2 hours';
      when 'low' then time_interval := interval '4 hours';
      else time_interval := interval '2 hours';
    end case;

    -- Check if the priority interval has elapsed
    if (now() - cust.last_notification_sent_at) >= time_interval then
      price_changed := false;

      -- Check Gold Change since last sent to this customer
      if current_gold is not null and (cust.last_gold_price_sent is null or cust.last_gold_price_sent <> current_gold) then
        price_changed := true;
      end if;

      -- Check Silver Change since last sent to this customer
      if current_silver is not null and (cust.last_silver_price_sent is null or cust.last_silver_price_sent <> current_silver) then
        price_changed := true;
      end if;

      -- If any price changed, insert the language-specific dynamic message
      if price_changed then
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

        -- Format price update text using placeholders
        message_text := replace(
          replace(tpl.price_update_template, '{gold}', current_gold::text),
          '{silver}', current_silver::text
        );

        -- Expire any old pending price updates for this customer so they only get the latest one
        update scheduled_messages
        set status = 'expired', error = 'Superseded by newer price update'
        where contact_name = cust.contact_name
          and status = 'pending'
          and (message like '%Price Update%' or message like '%মূল্য আপডেট%' or message like '%मूल्य अपडेट%');

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

        -- Update customer's last notified status
        update bullion_whatsapp_customers
        set 
          last_gold_price_sent = current_gold,
          last_silver_price_sent = current_silver,
          last_notification_sent_at = now()
        where id = cust.id;
      end if;

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

-- 2. Daily morning greeting at 8:00 AM IST (local database time)
select cron.schedule(
  'morning-greeting',
  '0 8 * * *',
  $$select queue_greetings('morning');$$
);

-- 3. Daily night greeting at 10:00 PM IST (local database time)
select cron.schedule(
  'night-greeting',
  '0 22 * * *',
  $$select queue_greetings('night');$$
);
