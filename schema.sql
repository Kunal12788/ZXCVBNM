-- Run this once in the Supabase SQL editor.
-- If you already created the old version of this table, see the
-- "migration" block at the bottom instead of running this whole file.

create table if not exists scheduled_messages (
  id uuid primary key default gen_random_uuid(),
  contact_name text not null,        -- must match the name exactly as saved in WhatsApp
  phone_number text,                 -- OPTIONAL: only needed if you have two+ contacts
                                      -- saved with the exact same display name, used to
                                      -- disambiguate which one to message
  message text not null,
  send_at timestamptz not null,      -- when the message should go out

  status text not null default 'pending',   -- pending | sent | failed
  delivery_status text default 'unconfirmed', -- unconfirmed | sent | delivered
  error text,                        -- populated if status = 'failed'

  retry_count int not null default 0,
  max_retries int not null default 3,
  next_retry_at timestamptz,         -- set after a failed attempt; null = ready now

  sent_at timestamptz,
  last_attempt_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists idx_scheduled_messages_due
  on scheduled_messages (status, send_at, next_retry_at);

-- Example row (no disambiguation needed):
-- insert into scheduled_messages (contact_name, message, send_at)
-- values ('Mom', 'Happy birthday!', now() + interval '5 minutes');

-- Example row (disambiguating between two "Rahul" contacts):
-- insert into scheduled_messages (contact_name, phone_number, message, send_at)
-- values ('Rahul', '+919876543210', 'Meeting at 5pm', now() + interval '10 minutes');


-- ============================================================
-- MIGRATION: if you already have the old table from before,
-- run this instead of the create table above:
-- ============================================================
-- alter table scheduled_messages add column if not exists phone_number text;
-- alter table scheduled_messages add column if not exists delivery_status text default 'unconfirmed';
-- alter table scheduled_messages add column if not exists retry_count int not null default 0;
-- alter table scheduled_messages add column if not exists max_retries int not null default 3;
-- alter table scheduled_messages add column if not exists next_retry_at timestamptz;
-- alter table scheduled_messages add column if not exists last_attempt_at timestamptz;
-- create index if not exists idx_scheduled_messages_due
--   on scheduled_messages (status, send_at, next_retry_at);
