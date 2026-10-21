-- =====================================================================
--  ไฟล์     : module_security_saraban_lockdown.sql  (รันหลัง module_security_saraban.sql
--             และหลังหน้าเว็บรุ่นที่ใช้ฟังก์ชันใหม่ขึ้นระบบแล้ว · รันซ้ำได้)
--  เป้าหมาย : ปิดการเข้าถึงงานสารบรรณและที่เก็บไฟล์โดยตรงจากหน้าเว็บ (anon key)
--
--  สิ่งที่ไฟล์นี้ทำ (เปลี่ยนเฉพาะสิทธิ์ ไม่แก้/ไม่ลบข้อมูลหรือไฟล์)
--   1) saraban_documents / saraban_files : ปิดทั้งอ่านและเขียนตรง (เอกสารภายใน/ลับ ไม่รั่วอีก)
--   2) saraban_categories : อ่านได้ · ปิดการเขียนตรง
--   3) View สาธารณะที่อ่านเอกสาร (v_public_saraban*, v_public_cal_events/tasks/acting)
--      : ทำงานด้วยสิทธิ์เจ้าของ View และอ่านได้อย่างเดียว (แสดงเฉพาะเอกสารสาธารณะเหมือนเดิม)
--   4) Storage bucket sfh-files : ปิดการอัปโหลด/แก้/ลบ/แสดงรายชื่อไฟล์จากหน้าเว็บ
--      (อัปโหลด/ลบผ่าน Edge Function "sfh-storage" · ลิงก์ไฟล์สาธารณะที่มีอยู่ยังเปิดได้)
--
--  ย้อนกลับ: รันไฟล์ module_security_saraban_rollback.sql
-- =====================================================================
begin;

do $$
declare t text; p record;
begin
  foreach t in array array['saraban_documents', 'saraban_files'] loop
    for p in select policyname from pg_policies where schemaname = 'public' and tablename = t loop
      execute format('drop policy %I on public.%I', p.policyname, t);
    end loop;
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon, authenticated', t);
  end loop;

  for p in select policyname from pg_policies where schemaname = 'public' and tablename = 'saraban_categories' and cmd <> 'SELECT' loop
    execute format('drop policy %I on public.saraban_categories', p.policyname);
  end loop;
  revoke insert, update, delete, truncate, references, trigger on table public.saraban_categories from anon, authenticated;

  foreach t in array array['v_public_saraban', 'v_public_saraban_files', 'v_public_cal_events', 'v_public_cal_tasks', 'v_public_cal_acting'] loop
    execute format('alter view public.%I set (security_invoker = off)', t);
    execute format('revoke all on table public.%I from anon, authenticated', t);
    execute format('grant select on table public.%I to anon, authenticated', t);
  end loop;
end $$;

-- Storage: ไม่มี policy สำหรับ anon/authenticated = อัปโหลด/แก้/ลบ/แสดงรายชื่อไม่ได้
-- (bucket เป็น public จึงยังเปิดไฟล์ผ่านลิงก์สาธารณะได้ตามเดิม)
drop policy if exists sfh_files_insert on storage.objects;
drop policy if exists sfh_files_update on storage.objects;
drop policy if exists sfh_files_delete on storage.objects;
drop policy if exists sfh_files_select on storage.objects;

commit;

-- ตรวจผล (ควรได้ทุกแถว ok = true)
select 'anon อ่าน saraban_documents ไม่ได้' as check_item, not has_table_privilege('anon', 'public.saraban_documents', 'select') as ok
union all select 'anon อ่าน saraban_files ไม่ได้', not has_table_privilege('anon', 'public.saraban_files', 'select')
union all select 'anon แก้ประเภทเอกสารไม่ได้', not has_table_privilege('anon', 'public.saraban_categories', 'update')
union all select 'anon ยังอ่านประเภทเอกสารได้', has_table_privilege('anon', 'public.saraban_categories', 'select')
union all select 'anon ยังอ่าน v_public_saraban ได้', has_table_privilege('anon', 'public.v_public_saraban', 'select')
union all select 'anon ยังอ่าน v_public_cal_events ได้', has_table_privilege('anon', 'public.v_public_cal_events', 'select')
union all select 'Storage ไม่มีสิทธิ์เขียน/แสดงรายชื่อจากหน้าเว็บ', not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'sfh_files_%')
union all select 'ฟังก์ชัน Storage เรียกจากหน้าเว็บไม่ได้', not has_function_privilege('anon', 'public.sfh_storage_auth(text, text, text, text, text[])', 'execute');
