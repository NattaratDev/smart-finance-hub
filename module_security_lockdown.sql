-- =====================================================================
--  ไฟล์     : module_security_lockdown.sql  (ขั้นที่ 3 · รันหลัง module_security.sql · รันซ้ำได้)
--  เป้าหมาย : ปิดการเข้าถึงตารางแกนกลางโดยตรงจากหน้าเว็บ (anon key)
--             ทุกการอ่าน/เขียนข้อมูลผู้ใช้ สิทธิ์ ตั้งค่า Audit Log ต้องผ่านฟังก์ชัน sfh_* ที่ตรวจ token + สิทธิ์
--
--  สิ่งที่ไฟล์นี้ทำ (เปลี่ยนเฉพาะสิทธิ์ ไม่แก้/ไม่ลบข้อมูลในตาราง)
--   1) users / user_permissions / audit_logs / system_settings : ปิดทั้งอ่านและเขียนตรง
--   2) roles / permissions / role_permissions / menus / modules / organizations : อ่านได้ (ใช้สร้างเมนู) · ปิดการเขียนตรง
--   3) View สาธารณะ v_public_settings / v_public_stats : อ่านได้อย่างเดียว (ทำงานด้วยสิทธิ์เจ้าของ View)
--   4) sfh_set_password : เรียกจากหน้าเว็บไม่ได้อีก (ใช้ผ่าน sfh_admin_set_password / sfh_change_password)
--
--  ย้อนกลับ: รันไฟล์ module_security_rollback.sql
-- =====================================================================
begin;

do $$
declare t text; p record;
begin
  -- 1) ตารางข้อมูลบุคคล/ตั้งค่า/บันทึกการใช้งาน: ไม่มี policy = ปฏิเสธทั้งหมด (RLS เปิดอยู่แล้ว)
  foreach t in array array['users', 'user_permissions', 'audit_logs', 'system_settings'] loop
    for p in select policyname from pg_policies where schemaname = 'public' and tablename = t loop
      execute format('drop policy %I on public.%I', p.policyname, t);
    end loop;
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon, authenticated', t);
  end loop;

  -- 2) ตารางโครงสร้างระบบ: เก็บเฉพาะ policy อ่าน
  foreach t in array array['roles', 'permissions', 'role_permissions', 'menus', 'modules', 'organizations'] loop
    for p in select policyname from pg_policies where schemaname = 'public' and tablename = t and cmd <> 'SELECT' loop
      execute format('drop policy %I on public.%I', p.policyname, t);
    end loop;
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke insert, update, delete, truncate, references, trigger on table public.%I from anon, authenticated', t);
  end loop;
end $$;

-- 3) View สาธารณะ: ให้ทำงานด้วยสิทธิ์เจ้าของ (อ่านเฉพาะค่าสาธารณะ/ตัวเลขสรุป) และอ่านได้อย่างเดียว
alter view public.v_public_settings set (security_invoker = off);
alter view public.v_public_stats set (security_invoker = off);
revoke all on table public.v_public_settings, public.v_public_stats from anon, authenticated;
grant select on table public.v_public_settings, public.v_public_stats to anon, authenticated;

-- 4) ปิดช่องโหว่ตั้งรหัสผ่านโดยไม่ตรวจผู้เรียก
revoke execute on function public.sfh_set_password(uuid, text) from public, anon, authenticated;

commit;

-- ตรวจผล (ควรได้ทุกแถว ok = true)
select 'anon อ่าน users ไม่ได้' as check_item, not has_table_privilege('anon', 'public.users', 'select') as ok
union all select 'anon อ่าน audit_logs ไม่ได้', not has_table_privilege('anon', 'public.audit_logs', 'select')
union all select 'anon อ่าน system_settings ไม่ได้', not has_table_privilege('anon', 'public.system_settings', 'select')
union all select 'anon แก้ roles ไม่ได้', not has_table_privilege('anon', 'public.roles', 'update')
union all select 'anon ยังอ่าน menus ได้', has_table_privilege('anon', 'public.menus', 'select')
union all select 'anon ยังอ่าน v_public_settings ได้', has_table_privilege('anon', 'public.v_public_settings', 'select')
union all select 'anon แก้ v_public_settings ไม่ได้', not has_table_privilege('anon', 'public.v_public_settings', 'update')
union all select 'anon เรียก sfh_set_password ไม่ได้', not has_function_privilege('anon', 'public.sfh_set_password(uuid, text)', 'execute')
union all select 'anon ยังเรียก sfh_login ได้', has_function_privilege('anon', 'public.sfh_login(text, text)', 'execute');
