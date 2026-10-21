-- =====================================================================
--  ไฟล์     : module_backup.sql  (รันต่อจาก module_security.sql · รันซ้ำได้)
--  เป้าหมาย : สำรองข้อมูลทั้งระบบเป็นไฟล์ JSON จากหน้า "ตั้งค่าระบบ" (เฉพาะ Super Admin)
--
--  - รวมทุกตารางใน schema public อัตโนมัติ (ตารางที่เพิ่มในอนาคตจะถูกรวมด้วย)
--  - ไม่รวม user_credentials (รหัสผ่านแบบ hash) และ sfh_sessions (session ที่กำลังใช้งาน)
--  - ไฟล์ใน Storage ไม่ถูกรวม แต่มีรายชื่อไฟล์ (path/ขนาด) แนบไว้ใน meta.storage_files
--  - ทุกครั้งที่สำรองจะบันทึก Audit Log (action = backup_export)
-- =====================================================================
-- จำนวนตาราง (ใช้ใน Audit Log)
create or replace function public.sfh_jsonb_key_count(p jsonb)
returns int language sql immutable as $$ select count(*)::int from jsonb_object_keys(coalesce(p, '{}'::jsonb)); $$;

create or replace function public.sfh_backup_export(p_token text)
returns jsonb language plpgsql security definer set search_path = public, storage as $$
declare v_u public.users%rowtype; v_data jsonb := '{}'::jsonb; v_counts jsonb := '{}'::jsonb; v_t text; v_rows jsonb;
begin
  v_u := public.sfh_payroll_auth(p_token, null);
  if not public.sfh_is_super(v_u) then raise exception 'FORBIDDEN: สำรองข้อมูลได้เฉพาะ Super Admin'; end if;

  for v_t in select c.relname from pg_class c
              where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
                and c.relname not in ('user_credentials', 'sfh_sessions')
              order by c.relname loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from public.%I x', v_t) into v_rows;
    v_data := v_data || jsonb_build_object(v_t, v_rows);
    v_counts := v_counts || jsonb_build_object(v_t, jsonb_array_length(v_rows));
  end loop;

  perform public.sfh_rent_audit(v_u, 'backup_export', 'system', null, jsonb_build_object('tables', public.sfh_jsonb_key_count(v_counts)));
  return jsonb_build_object(
    'meta', jsonb_build_object(
      'app', 'Smart Finance Hub', 'format', 'sfh-backup-v1',
      'generated_at', now(), 'generated_by', v_u.username,
      'excluded', jsonb_build_array('user_credentials', 'sfh_sessions'),
      'counts', v_counts,
      'storage_files', coalesce((select jsonb_agg(jsonb_build_object('path', o.name, 'size', (o.metadata->>'size')::bigint, 'created_at', o.created_at) order by o.name)
                                   from storage.objects o where o.bucket_id = 'sfh-files'), '[]'::jsonb)),
    'data', v_data);
end $$;

grant execute on function public.sfh_backup_export(text) to anon, authenticated;
revoke execute on function public.sfh_jsonb_key_count(jsonb) from public, anon, authenticated;

select 'ติดตั้งฟังก์ชันสำรองข้อมูลเรียบร้อย' as result;
