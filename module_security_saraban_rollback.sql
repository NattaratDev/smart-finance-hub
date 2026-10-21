-- =====================================================================
--  ไฟล์     : module_security_saraban_rollback.sql  (ใช้เฉพาะกรณีฉุกเฉิน)
--  เป้าหมาย : ย้อนผลของ module_security_saraban_lockdown.sql กลับเป็นสิทธิ์แบบเดิม
--  คำเตือน  : หลังรันไฟล์นี้ เอกสารภายใน/ลับ และไฟล์ใน Storage จะกลับมาเปิดให้ทุกคนอ่าน/แก้/ลบได้ชั่วคราว
-- =====================================================================
begin;

do $$
declare t text;
begin
  foreach t in array array['saraban_categories', 'saraban_documents', 'saraban_files'] loop
    execute format('grant select, insert, update, delete on table public.%I to anon, authenticated', t);
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format('drop policy if exists %I on public.%I', t || '_insert', t);
    execute format('drop policy if exists %I on public.%I', t || '_update', t);
    execute format('drop policy if exists %I on public.%I', t || '_delete', t);
    execute format('create policy %I on public.%I for select to anon, authenticated using (true)', t || '_select', t);
    execute format('create policy %I on public.%I for insert to anon, authenticated with check (true)', t || '_insert', t);
    execute format('create policy %I on public.%I for update to anon, authenticated using (true) with check (true)', t || '_update', t);
    execute format('create policy %I on public.%I for delete to anon, authenticated using (true)', t || '_delete', t);
  end loop;
  foreach t in array array['v_public_saraban', 'v_public_saraban_files', 'v_public_cal_events', 'v_public_cal_tasks', 'v_public_cal_acting'] loop
    execute format('alter view public.%I set (security_invoker = on)', t);
  end loop;
end $$;

drop policy if exists sfh_files_select on storage.objects;
drop policy if exists sfh_files_insert on storage.objects;
drop policy if exists sfh_files_update on storage.objects;
drop policy if exists sfh_files_delete on storage.objects;
create policy sfh_files_select on storage.objects for select using (bucket_id = 'sfh-files');
create policy sfh_files_insert on storage.objects for insert to anon, authenticated with check (bucket_id = 'sfh-files');
create policy sfh_files_update on storage.objects for update to anon, authenticated using (bucket_id = 'sfh-files') with check (bucket_id = 'sfh-files');
create policy sfh_files_delete on storage.objects for delete to anon, authenticated using (bucket_id = 'sfh-files');

commit;
select 'ย้อนกลับเรียบร้อย (งานสารบรรณ/Storage กลับเป็นแบบไม่ปลอดภัยชั่วคราว)' as result;
