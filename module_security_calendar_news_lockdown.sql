-- =====================================================================
--  ไฟล์     : module_security_calendar_news_lockdown.sql  (รันหลัง module_security_calendar_news.sql
--             และหลังหน้าเว็บรุ่นที่ใช้ฟังก์ชันใหม่ขึ้นระบบแล้ว · รันซ้ำได้)
--  เป้าหมาย : ปิดการเขียนตรงของปฏิทินกองคลัง / ข่าวประกาศ / ชุดอัตราไปราชการ
--
--  สิ่งที่ไฟล์นี้ทำ (เปลี่ยนเฉพาะสิทธิ์ ไม่แก้/ไม่ลบข้อมูล)
--   1) ตารางปฏิทิน (cal_*) และ announcements : ปิดทั้งอ่านและเขียนตรง
--      (บุคคลทั่วไปอ่านผ่าน View สาธารณะเหมือนเดิม · ข่าวภายในหน่วยงานอ่านผ่านฟังก์ชัน)
--   2) travel_rate_sets : อ่านได้ (ใช้คำนวณ) · ปิดการเขียนตรง
--   3) View สาธารณะของปฏิทินและข่าว : ทำงานด้วยสิทธิ์เจ้าของ View และอ่านได้อย่างเดียว
--
--  ย้อนกลับ: รันไฟล์ module_security_calendar_news_rollback.sql
-- =====================================================================
begin;

do $$
declare t text; p record;
begin
  foreach t in array array['cal_events', 'cal_tasks', 'cal_task_assignees', 'cal_acting', 'cal_absences', 'cal_activity', 'announcements'] loop
    for p in select policyname from pg_policies where schemaname = 'public' and tablename = t loop
      execute format('drop policy %I on public.%I', p.policyname, t);
    end loop;
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon, authenticated', t);
  end loop;

  for p in select policyname from pg_policies where schemaname = 'public' and tablename = 'travel_rate_sets' and cmd <> 'SELECT' loop
    execute format('drop policy %I on public.travel_rate_sets', p.policyname);
  end loop;
  revoke insert, update, delete, truncate, references, trigger on table public.travel_rate_sets from anon, authenticated;

  foreach t in array array['v_public_cal_events', 'v_public_cal_tasks', 'v_public_cal_acting', 'v_public_cal_absences', 'v_public_cal_activity', 'v_public_announcements'] loop
    execute format('alter view public.%I set (security_invoker = off)', t);
    execute format('revoke all on table public.%I from anon, authenticated', t);
    execute format('grant select on table public.%I to anon, authenticated', t);
  end loop;
end $$;

commit;

-- ตรวจผล (ควรได้ทุกแถว ok = true)
select 'anon แก้ตารางปฏิทินไม่ได้' as check_item, not (has_table_privilege('anon', 'public.cal_events', 'insert') or has_table_privilege('anon', 'public.cal_tasks', 'update') or has_table_privilege('anon', 'public.cal_activity', 'insert')) as ok
union all select 'anon อ่านข่าวภายในตรงไม่ได้', not has_table_privilege('anon', 'public.announcements', 'select')
union all select 'anon แก้ข่าวไม่ได้', not has_table_privilege('anon', 'public.announcements', 'update')
union all select 'anon แก้ชุดอัตราไม่ได้', not has_table_privilege('anon', 'public.travel_rate_sets', 'update')
union all select 'anon ยังอ่านชุดอัตราได้', has_table_privilege('anon', 'public.travel_rate_sets', 'select')
union all select 'anon ยังอ่านปฏิทินสาธารณะได้', has_table_privilege('anon', 'public.v_public_cal_events', 'select') and has_table_privilege('anon', 'public.v_public_cal_activity', 'select')
union all select 'anon ยังอ่านข่าวสาธารณะได้', has_table_privilege('anon', 'public.v_public_announcements', 'select')
union all select 'ไม่เหลือตารางที่คนนอกเขียนตรงได้', not exists (select 1 from pg_policies where schemaname = 'public' and cmd <> 'SELECT' and ('anon' = any(roles) or 'public' = any(roles)));
