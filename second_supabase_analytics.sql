-- =========================================================================
-- SECOND SUPABASE ACCOUNT SQL SCRIPT: APP OPEN & DEVICE ANALYTICS
-- =========================================================================
-- Run this script in the SQL Editor of your SECOND Supabase Account:
-- Project URL: https://imfnckteflxjrgzzmfze.supabase.co
-- =========================================================================

-- 1. Set default database timezone to Indian Standard Time (IST)
ALTER DATABASE postgres SET timezone TO 'Asia/Kolkata';

-- 2. Detailed activity log table (records every single app open session)
create table if not exists user_app_activity_logs (
  id uuid primary key default gen_random_uuid(),
  phone_number text not null,
  contact_name text,
  device_type text not null,        -- 'Mobile (Median APK)', 'Desktop'
  os_name text not null,            -- 'Android 14', 'iOS 17', etc.
  browser_name text not null,       -- 'Samsung (SM-S918B) [Median APK]', etc.
  screen_resolution text,           -- e.g. '384x832'
  opened_at timestamptz not null default now()
);

-- Enable RLS and grant public access so APK can insert logs
alter table user_app_activity_logs enable row level security;

drop policy if exists "Allow public insert to activity logs" on user_app_activity_logs;
create policy "Allow public insert to activity logs"
  on user_app_activity_logs for insert
  to anon, authenticated, public
  with check (true);

drop policy if exists "Allow public select on activity logs" on user_app_activity_logs;
create policy "Allow public select on activity logs"
  on user_app_activity_logs for select
  to anon, authenticated, public
  using (true);

-- Index for searching activity history by phone number & IST timestamp
create index if not exists idx_user_activity_phone 
  on user_app_activity_logs (phone_number, opened_at desc);

-- 3. Grouped Customer Summary Table (1 row per unique customer with all aggregated details)
create table if not exists user_activity_summary (
  phone_number text primary key,
  contact_name text,
  total_app_opens int not null default 1,
  device_model_brand text,           -- Exact Device Brand & Model
  os_version text,                   -- Exact OS & Version
  device_type text,                  -- Device Category
  first_opened_at timestamptz not null default now(),
  last_opened_at timestamptz not null default now()
);

-- Ensure columns exist if updating table schema
alter table user_activity_summary add column if not exists device_model_brand text;
alter table user_activity_summary add column if not exists os_version text;
alter table user_activity_summary add column if not exists first_opened_at timestamptz default now();

-- Enable RLS and grant public access for summary
alter table user_activity_summary enable row level security;

drop policy if exists "Allow public access to summary" on user_activity_summary;
create policy "Allow public access to summary"
  on user_activity_summary for all
  to anon, authenticated, public
  using (true)
  with check (true);

-- 4. Function to log open activity and increment user open counter (SECURITY DEFINER)
create or replace function record_app_open_event(
  p_phone text,
  p_name text,
  p_device_type text,
  p_os_name text,
  p_browser_name text,
  p_screen_res text
) returns void 
language plpgsql
security definer -- Allows anonymous clients to execute without permission errors
as $$
begin
  -- 1. Insert history log
  insert into user_app_activity_logs (
    phone_number, contact_name, device_type, os_name, browser_name, screen_resolution, opened_at
  ) values (
    p_phone, p_name, p_device_type, p_os_name, p_browser_name, p_screen_res, now()
  );

  -- 2. Upsert customer summary record and increment counter
  insert into user_activity_summary (
    phone_number, contact_name, total_app_opens, device_model_brand, os_version, device_type, first_opened_at, last_opened_at
  ) values (
    p_phone, p_name, 1, p_browser_name, p_os_name, p_device_type, now(), now()
  )
  on conflict (phone_number) do update set
    contact_name = coalesce(nullif(EXCLUDED.contact_name, 'Guest User'), user_activity_summary.contact_name),
    total_app_opens = user_activity_summary.total_app_opens + 1,
    device_model_brand = EXCLUDED.device_model_brand,
    os_version = EXCLUDED.os_version,
    device_type = EXCLUDED.device_type,
    last_opened_at = now();
end;
$$;

-- Grant execution permission to anon and authenticated roles
grant execute on function record_app_open_event to anon, authenticated, public;

-- 5. Create a clean Grouped View for Supabase Dashboard
create or replace view customer_analytics_dashboard as
select 
  s.contact_name,
  s.phone_number,
  s.total_app_opens,
  s.device_model_brand,
  s.os_version,
  s.device_type,
  s.first_opened_at as first_opened_at_ist,
  s.last_opened_at as last_opened_at_ist
from user_activity_summary s
order by s.last_opened_at desc;

-- Grant select permission on the view
grant select on customer_analytics_dashboard to anon, authenticated, public;
