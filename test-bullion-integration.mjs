import { createClient } from '@supabase/supabase-js';
import dotenv from 'dotenv';
import path from 'path';
import { fileURLToPath } from 'url';

// Load environment variables
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
dotenv.config({ path: path.join(__dirname, '.env') });

const supabaseUrl = process.env.SUPABASE_URL;
const supabaseKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!supabaseUrl || !supabaseKey || supabaseUrl.includes('your-project')) {
  console.error('❌ Supabase credentials are not configured in .env file!');
  process.exit(1);
}

const supabase = createClient(supabaseUrl, supabaseKey);

async function runTest() {
  console.log('🚀 Starting Bullion WhatsApp Integration Test...');

  // 1. Insert a test rate into the existing bullion_rates table
  const testGoldPrice = Math.floor(70000 + Math.random() * 5000);
  const testSilverPrice = Math.floor(90000 + Math.random() * 5000);

  console.log(`\n1. Inserting test rates: Gold = ₹${testGoldPrice}, Silver = ₹${testSilverPrice}...`);
  const { data: rateData, error: rateError } = await supabase
    .from('bullion_rates')
    .insert([
      { item: 'gold_995_100gms', label: 'Gold 995 (100gms Ready)', price: testGoldPrice, unit: 'INR / 10 gm', raw_text: 'Test rate ocr simulation' },
      { item: 'silver_999_1kg', label: 'Silver 999 (1kg Ready)', price: testSilverPrice, unit: 'INR / 1 kg', raw_text: 'Test rate ocr simulation' }
    ])
    .select();

  if (rateError) {
    console.error('❌ Failed to insert test rates:', rateError.message);
    console.error('Please make sure you have run the bullion_whatsapp_integration.sql script in your Supabase SQL Editor first!');
    process.exit(1);
  }
  console.log('✅ Test rates inserted successfully.');

  // 2. Ensure test customer exists in bullion_whatsapp_customers
  const testContactName = '𝙺𝚄𝙽𝙰𝙻 😎';
  const testPhoneNumber = '9836282432';

  console.log(`\n2. Checking if test customer "${testContactName}" (${testPhoneNumber}) exists...`);
  const { data: customers, error: custFetchError } = await supabase
    .from('bullion_whatsapp_customers')
    .select('*')
    .eq('phone_number', testPhoneNumber);

  if (custFetchError) {
    console.error('❌ Failed to query customer table:', custFetchError.message);
    process.exit(1);
  }

  let customerId;
  if (customers.length === 0) {
    console.log(`Adding new test customer: ${testContactName}...`);
    const { data: newCust, error: custInsertError } = await supabase
      .from('bullion_whatsapp_customers')
      .insert({
        contact_name: testContactName,
        phone_number: testPhoneNumber,
        priority: 'high',
        last_notification_sent_at: new Date(Date.now() - 60 * 60 * 1000).toISOString() // 1 hour ago (so it's due for high priority 45m limit)
      })
      .select();

    if (custInsertError) {
      console.error('❌ Failed to create test customer:', custInsertError.message);
      process.exit(1);
    }
    customerId = newCust[0].id;
    console.log('✅ Test customer created.');
  } else {
    customerId = customers[0].id;
    console.log('✅ Test customer already exists. Resetting last sent timestamps and formatting columns to ensure they are due...');
    const { error: resetError } = await supabase
      .from('bullion_whatsapp_customers')
      .update({
        contact_name: testContactName,
        priority: 'high',
        last_gold_price_sent: null,
        last_silver_price_sent: null,
        last_notification_sent_at: new Date(0).toISOString() // Far past (1970) so it's guaranteed to be due
      })
      .eq('id', customerId);

    if (resetError) {
      console.error('❌ Failed to update test customer status:', resetError.message);
      process.exit(1);
    }
  }

  // 3. Trigger the price check function via RPC
  console.log('\n3. Triggering check_bullion_price_updates() function via RPC...');
  const { error: rpcError } = await supabase.rpc('check_bullion_price_updates');
  if (rpcError) {
    console.error('❌ RPC Function call failed:', rpcError.message);
    process.exit(1);
  }
  console.log('✅ Function executed successfully.');

  // 4. Verify if message was queued in scheduled_messages
  console.log('\n4. Checking for pending messages in the queue...');
  const { data: messages, error: msgError } = await supabase
    .from('scheduled_messages')
    .select('*')
    .eq('phone_number', testPhoneNumber)
    .eq('status', 'pending')
    .order('created_at', { ascending: false })
    .limit(1);

  if (msgError) {
    console.error('❌ Failed to check queue:', msgError.message);
    process.exit(1);
  }

  if (messages.length === 0) {
    console.log('⚠️ No pending message found in the queue. (This may happen if the price did not trigger a change check or time interval conditions were not met)');
  } else {
    console.log('\n🎉 SUCCESS! A new message has been queued:');
    console.log('--------------------------------------------------');
    console.log(`TO      : ${messages[0].contact_name} (${messages[0].phone_number})`);
    console.log(`MESSAGE :\n${messages[0].message}`);
    console.log('--------------------------------------------------');
    console.log('Next Step: Run your local WhatsApp automation: "npm run start" or double click "start-all.bat" to send it!');
  }
}

runTest().catch(console.error);
