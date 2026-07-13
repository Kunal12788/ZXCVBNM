-- =========================================================================
-- SUPABASE SQL SCRIPT: BULLION WHATSAPP AUTO-SCHEDULER & GREETINGS
-- =========================================================================
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
  cust record;
  time_interval interval;
  price_changed boolean;
  message_text text;
begin
  -- Fetch current live prices from your existing bullion_rates table
  select price into current_gold from bullion_rates where item = 'gold_995_100gms' order by created_at desc limit 1;
  select price into current_silver from bullion_rates where item = 'silver_999_1kg' order by created_at desc limit 1;

  -- Loop through active customers to check if they are due for an update
  for cust in select * from bullion_whatsapp_customers where is_active = true loop
    
    -- Determine the time interval based on Priority
    case cust.priority
      when 'high' then time_interval := interval '45 minutes';
      when 'medium' then time_interval := interval '2 hours';
      when 'low' then time_interval := interval '4 hours';
      else time_interval := interval '2 hours';
    end case;

    -- Check if the priority interval has elapsed
    if (now() - cust.last_notification_sent_at) >= time_interval then
      price_changed := false;
      message_text := 'Live Bullion Price Update: ' || chr(10);

      -- Check Gold Change
      if current_gold is not null and (cust.last_gold_price_sent is null or cust.last_gold_price_sent <> current_gold) then
        if cust.last_gold_price_sent is not null then
          if current_gold > cust.last_gold_price_sent then
            message_text := message_text || '📈 Gold increased to ₹' || current_gold || ' (was ₹' || cust.last_gold_price_sent || ')' || chr(10);
          else
            message_text := message_text || '📉 Gold decreased to ₹' || current_gold || ' (was ₹' || cust.last_gold_price_sent || ')' || chr(10);
          end if;
        else
          message_text := message_text || '✨ Gold rate is now ₹' || current_gold || chr(10);
        end if;
        price_changed := true;
      end if;

      -- Check Silver Change
      if current_silver is not null and (cust.last_silver_price_sent is null or cust.last_silver_price_sent <> current_silver) then
        if cust.last_silver_price_sent is not null then
          if current_silver > cust.last_silver_price_sent then
            message_text := message_text || '📈 Silver increased to ₹' || current_silver || ' (was ₹' || cust.last_silver_price_sent || ')' || chr(10);
          else
            message_text := message_text || '📉 Silver decreased to ₹' || current_silver || ' (was ₹' || cust.last_silver_price_sent || ')' || chr(10);
          end if;
        else
          message_text := message_text || '✨ Silver rate is now ₹' || current_silver || chr(10);
        end if;
        price_changed := true;
      end if;

      -- If any price changed, insert into the whatsapp scheduled_messages queue
      if price_changed then
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

-- 1. Check price updates every 15 minutes
select cron.schedule(
  'check-bullion-prices',
  '*/15 * * * *',
  'select check_bullion_price_updates();'
);

-- 2. Daily morning greeting at 8:00 AM IST (2:30 AM UTC)
select cron.schedule(
  'morning-greeting',
  '30 2 * * *',
  $$select queue_greetings('morning');$$
);

-- 3. Daily night greeting at 9:00 PM IST (3:30 PM UTC)
select cron.schedule(
  'night-greeting',
  '30 15 * * *',
  $$select queue_greetings('night');$$
);
