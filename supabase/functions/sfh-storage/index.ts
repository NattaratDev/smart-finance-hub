// Edge Function: sfh-storage
// อัปโหลด/ลบไฟล์ใน bucket sfh-files แทนหน้าเว็บ (หน้าเว็บไม่มีสิทธิ์เขียน Storage ตรง)
//  - action "sign"   : ตรวจ session token + สิทธิ์ตามโฟลเดอร์ (sfh_storage_auth) → ออกลิงก์อัปโหลดครั้งเดียว
//  - action "delete" : ลบเฉพาะไฟล์ที่ไม่มีข้อมูลใดอ้างอิงแล้ว (ตรวจในฐานข้อมูล)
import { createClient } from 'npm:@supabase/supabase-js@2';

const BUCKET = 'sfh-files';
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'METHOD_NOT_ALLOWED' }, 405);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: 'BAD_REQUEST' }, 400); }
  const { action, token, folder, ext, paths } = body ?? {};
  if ((action !== 'sign' && action !== 'delete') || typeof token !== 'string' || !token) return json({ error: 'BAD_REQUEST' }, 400);

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data, error } = await admin.rpc('sfh_storage_auth', {
    p_token: token,
    p_action: action,
    p_folder: typeof folder === 'string' ? folder : null,
    p_ext: typeof ext === 'string' ? ext : null,
    p_paths: Array.isArray(paths) ? paths.slice(0, 50).map(String) : null,
  });
  if (error) {
    const msg = String(error.message || '');
    if (msg.includes('SESSION_EXPIRED')) return json({ error: 'SESSION_EXPIRED' }, 401);
    return json({ error: msg.startsWith('FORBIDDEN') ? msg : 'ไม่สามารถตรวจสอบสิทธิ์ได้' }, 403);
  }

  if (action === 'sign') {
    const path = (data as { path: string }).path;
    const { data: s, error: e } = await admin.storage.from(BUCKET).createSignedUploadUrl(path);
    if (e || !s) return json({ error: 'สร้างลิงก์อัปโหลดไม่สำเร็จ' }, 500);
    return json({ path, token: s.token });
  }

  const list = ((data as { paths: string[] }).paths) || [];
  if (list.length) {
    const { error: e } = await admin.storage.from(BUCKET).remove(list);
    if (e) return json({ error: 'ลบไฟล์ไม่สำเร็จ' }, 500);
  }
  return json({ removed: list });
});
