-- =====================================================================
--  ไฟล์     : module_security_rollback.sql  (ใช้เฉพาะกรณีฉุกเฉิน)
--  เป้าหมาย : ย้อนผลของ module_security_lockdown.sql กลับเป็นสิทธิ์แบบเดิม (ก่อนขั้นที่ 3)
--  คำเตือน  : หลังรันไฟล์นี้ ช่องโหว่เดิมจะกลับมา (ทุกคนอ่าน/แก้ตารางแกนกลางได้ และตั้งรหัสผ่านบัญชีใดก็ได้)
--             ใช้เพื่อให้ระบบกลับมาทำงานชั่วคราวเท่านั้น แล้วแจ้งผู้พัฒนาให้แก้สาเหตุ จากนั้นรัน lockdown ใหม่
-- =====================================================================
begin;

do $$
declare t text;
begin
  foreach t in array array['users', 'user_permissions', 'audit_logs', 'system_settings',
                           'roles', 'permissions', 'role_permissions', 'menus', 'modules', 'organizations'] loop
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
end $$;

alter view public.v_public_settings set (security_invoker = on);
alter view public.v_public_stats set (security_invoker = on);
grant execute on function public.sfh_set_password(uuid, text) to anon, authenticated;

commit;
select 'ย้อนกลับเรียบร้อย (ระบบกลับเป็นแบบไม่ปลอดภัยชั่วคราว)' as result;
