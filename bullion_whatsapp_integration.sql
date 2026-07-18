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

-- 2. Create the NEW, isolated customer subscriptions table
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

      -- If any price changed, insert the identical uniform message text
      if price_changed then
        message_text := 'Live Bullion Price Update: ' || chr(10) ||
                        '✨ Gold rate: ₹' || current_gold || chr(10) ||
                        '✨ Silver rate: ₹' || current_silver || chr(10);

        -- Expire any old pending price updates for this customer so they only get the latest one
        update scheduled_messages
        set status = 'expired', error = 'Superseded by newer price update'
        where contact_name = cust.contact_name
          and status = 'pending'
          and message like 'Live Bullion Price Update%';

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
begin
  -- Set any old pending greetings to expired before creating new ones
  update scheduled_messages 
  set status = 'expired', error = 'Superseded by new greeting'
  where status = 'pending' 
    and (message like '☀️ Good Morning%' or message like '🌙 Good Night%');

  for cust in select * from bullion_whatsapp_customers where is_active = true loop
    if greeting_type = 'morning' then
      msg := '☀️ Good Morning, ' || cust.contact_name || '! Have a profitable day ahead. Here are today''s starting bullion rates.';
    else
      msg := '🌙 Good Night, ' || cust.contact_name || '! Thank you for trading with us today.';
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
