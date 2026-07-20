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
  device_type text not null,        -- 'Mobile', 'Tablet', 'Desktop', 'Median Android App'
  os_name text not null,            -- 'Android (Median App)', 'iOS (Median App)', 'Windows', etc.
  browser_name text not null,       -- 'Median APK WebView', 'Chrome', 'Safari', etc.
  screen_resolution text,           -- e.g. '412x915'
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

-- 3. User summary table (tracks total app open count & latest device info)
create table if not exists user_activity_summary (
  phone_number text primary key,
  contact_name text,
  total_app_opens int not null default 1,
  last_device_type text,
  last_os_name text,
  last_browser_name text,
  last_opened_at timestamptz not null default now()
);

-- Enable RLS and grant public access for summary
alter table user_activity_summary enable row level security;

drop policy if exists "Allow public access to summary" on user_activity_summary;
create policy "Allow public access to summary"
  on user_activity_summary for all
  to anon, authenticated, public
  using (true)
  with check (true);

-- 4. Function to log open activity and increment user open counter (with SECURITY DEFINER)
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
    phone_number, contact_name, total_app_opens, last_device_type, last_os_name, last_browser_name, last_opened_at
  ) values (
    p_phone, p_name, 1, p_device_type, p_os_name, p_browser_name, now()
  )
  on conflict (phone_number) do update set
    contact_name = coalesce(nullif(EXCLUDED.contact_name, 'Guest User'), user_activity_summary.contact_name),
    total_app_opens = user_activity_summary.total_app_opens + 1,
    last_device_type = EXCLUDED.last_device_type,
    last_os_name = EXCLUDED.last_os_name,
    last_browser_name = EXCLUDED.last_browser_name,
    last_opened_at = now();
end;
$$;

-- Grant execution permission to anon and authenticated roles
grant execute on function record_app_open_event to anon, authenticated, public;
