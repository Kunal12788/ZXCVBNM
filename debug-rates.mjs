import { createClient } from '@supabase/supabase-js';
import dotenv from 'dotenv';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
dotenv.config({ path: path.join(__dirname, '.env') });

const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);

async function debug() {
  const { data: rates } = await supabase.from('bullion_rates').select('*').order('created_at', { ascending: false }).limit(2);
  const { data: customers } = await supabase.from('bullion_whatsapp_customers').select('*');
  const { data: messages } = await supabase.from('scheduled_messages').select('*').order('created_at', { ascending: false }).limit(2);

  console.log('--- LATEST RATES ---');
  console.log(rates);

  console.log('\n--- CUSTOMERS ---');
  console.log(customers);

  console.log('\n--- SCHEDULER QUEUE ---');
  console.log(messages);
}

debug().catch(console.error);
