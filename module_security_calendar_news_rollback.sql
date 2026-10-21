-- =====================================================================
--  ไฟล์     : module_security_calendar_news_rollback.sql  (ใช้เฉพาะกรณีฉุกเฉิน)
--  เป้าหมาย : ย้อนผลของ module_security_calendar_news_lockdown.sql กลับเป็นสิทธิ์แบบเดิม
--  คำเตือน  : หลังรันไฟล์นี้ ปฏิทิน/ข่าว/ชุดอัตรา จะกลับมาให้ทุกคนแก้ไขตรงได้ชั่วคราว
-- =====================================================================
begin;

do $$
declare t text;
begin
  foreach t in array array['cal_events', 'cal_tasks', 'cal_task_assignees', 'cal_acting', 'cal_absences', 'cal_activity', 'announcements', 'travel_rate_sets'] loop
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
  foreach t in array array['v_public_cal_absences', 'v_public_cal_activity', 'v_public_announcements'] loop
    execute format('alter view public.%I set (security_invoker = on)', t);
  end loop;
end $$;

commit;
select 'ย้อนกลับเรียบร้อย (ปฏิทิน/ข่าว/ชุดอัตรา กลับเป็นแบบไม่ปลอดภัยชั่วคราว)' as result;
