-- =====================================================================
--  Smart Finance Hub (SFH) – โมดูล: ปฏิทินกองคลัง (กิจกรรม / งานมอบหมาย / รักษาราชการแทน / ไม่อยู่ปฏิบัติงาน)
--  ไฟล์ : module_calendar.sql   (รันต่อจาก database.sql และ module_saraban.sql)
--
--  วิธีใช้ : Supabase > SQL Editor > New query > วางทั้งไฟล์ > Run
--  รันซ้ำได้โดยไม่ error
--
--  สารบัญ
--   1) ตาราง: cal_events, cal_tasks, cal_task_assignees, cal_acting, cal_absences, cal_activity
--   2) Trigger: updated_at, ตรวจช่วงวันที่, ไม่เก็บรายละเอียดการลา (PDPA)
--   3) ลงทะเบียนโมดูล + Permission + สิทธิ์ของ Role + เมนู
--   4) View สาธารณะ (ทุกคนดูได้ รวมบุคคลทั่วไป)
--   5) RLS + สิทธิ์
--   6) ข้อมูลตัวอย่าง (ไม่บังคับ – รันเฉพาะเมื่อสั่ง  set sfh.seed_demo = 'on';  ก่อน)
--
--  หลักการ
--   - ทุกคน (รวมบุคคลทั่วไปที่ไม่ได้เข้าสู่ระบบ) ดูปฏิทินและความเคลื่อนไหวได้
--   - org_admin / staff เป็นผู้บันทึกข้อมูล (บันทึกการมอบหมายของผู้บริหารเพื่อแจ้งให้ทุกคนทราบ)
--   - การลา: เก็บเฉพาะ "ลา" + ช่วงวันที่ ไม่เก็บประเภทหรือเหตุผลการลา
-- =====================================================================
set search_path = public, extensions;


-- =====================================================================
-- 1) ตาราง
-- =====================================================================

-- 1.1 กิจกรรม (ประชุม / อบรม / งานพิธี / กำหนดส่ง ฯลฯ)
create table if not exists public.cal_events (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid references public.organizations(id) on delete set null,
  title            text not null,
  category         text not null default 'meeting'
                   check (category in ('meeting','training','event','deadline','other')),
  start_date       date not null,
  end_date         date not null,
  all_day          boolean not null default true,
  start_time       time,
  end_time         time,
  location         text,
  attendees        text,              -- ผู้เข้าร่วม (ข้อความ)
  description      text,
  saraban_doc_id   uuid references public.saraban_documents(id) on delete set null,   -- หนังสือ/คำสั่งที่เกี่ยวข้อง
  created_by       uuid,
  created_by_name  text,
  updated_by_name  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists idx_cal_events_dates on public.cal_events(start_date, end_date);
create index if not exists idx_cal_events_org   on public.cal_events(org_id);

-- 1.2 งานมอบหมาย (ผู้บริหารสั่งการ → เจ้าหน้าที่บันทึกแจ้งให้ทุกคนทราบ)
create table if not exists public.cal_tasks (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid references public.organizations(id) on delete set null,
  title            text not null,
  detail           text,
  assigned_by      text not null,     -- ผู้มอบหมาย/ผู้สั่งการ เช่น นายกเทศมนตรี, ปลัดเทศบาล
  assign_date      date not null default ((now() at time zone 'Asia/Bangkok')::date),
  due_date         date,
  priority         text not null default 'normal' check (priority in ('normal','high','urgent')),
  status           text not null default 'pending' check (status in ('pending','in_progress','done','cancelled')),
  done_at          timestamptz,
  saraban_doc_id   uuid references public.saraban_documents(id) on delete set null,
  created_by       uuid,
  created_by_name  text,
  updated_by_name  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists idx_cal_tasks_due    on public.cal_tasks(due_date);
create index if not exists idx_cal_tasks_status on public.cal_tasks(status);
create index if not exists idx_cal_tasks_org    on public.cal_tasks(org_id);

-- 1.3 ผู้รับผิดชอบงาน (1 งานมีได้หลายคน · user_id ว่างได้ กรณีบุคคลนอกระบบ)
create table if not exists public.cal_task_assignees (
  id          uuid primary key default gen_random_uuid(),
  task_id     uuid not null references public.cal_tasks(id) on delete cascade,
  user_id     uuid references public.users(id) on delete set null,
  name        text not null,          -- ชื่อ ณ วันที่มอบหมาย
  position    text,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now()
);
create index if not exists idx_cal_assignees_task on public.cal_task_assignees(task_id);
create index if not exists idx_cal_assignees_user on public.cal_task_assignees(user_id);

-- 1.4 รักษาราชการแทน
create table if not exists public.cal_acting (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid references public.organizations(id) on delete set null,
  position_title   text not null,     -- ตำแหน่งที่ให้รักษาราชการแทน เช่น ผู้อำนวยการกองคลัง
  holder_user_id   uuid references public.users(id) on delete set null,
  holder_name      text,              -- ผู้ดำรงตำแหน่ง (ว่างได้ กรณีตำแหน่งว่าง)
  acting_user_id   uuid references public.users(id) on delete set null,
  acting_name      text not null,     -- ผู้รักษาราชการแทน
  acting_position  text,              -- ตำแหน่งเดิมของผู้รักษาราชการแทน
  start_date       date not null,
  end_date         date not null,
  order_no         text,              -- เลขที่คำสั่ง
  saraban_doc_id   uuid references public.saraban_documents(id) on delete set null,
  note             text,
  created_by       uuid,
  created_by_name  text,
  updated_by_name  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists idx_cal_acting_dates on public.cal_acting(start_date, end_date);

-- 1.5 ไม่อยู่ปฏิบัติงาน (ลา / ไปราชการ / อบรม) – ไม่เก็บประเภทหรือเหตุผลการลา
create table if not exists public.cal_absences (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid references public.organizations(id) on delete set null,
  user_id          uuid references public.users(id) on delete set null,
  person_name      text not null,
  person_position  text,
  kind             text not null default 'leave' check (kind in ('leave','official','training')),
  start_date       date not null,
  end_date         date not null,
  period           text not null default 'full' check (period in ('full','morning','afternoon')),
  place            text,              -- สถานที่ (เฉพาะไปราชการ/อบรม · การลาจะถูกล้างเป็นค่าว่างเสมอ)
  created_by       uuid,
  created_by_name  text,
  updated_by_name  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists idx_cal_absences_dates on public.cal_absences(start_date, end_date);

-- 1.6 ความเคลื่อนไหว (ประวัติการเพิ่ม/แก้ไข/เปลี่ยนสถานะ – แสดงในฟีดหน้าแรก)
create table if not exists public.cal_activity (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid,
  item_type    text not null check (item_type in ('event','task','acting','absence')),
  item_id      uuid,
  action       text not null check (action in ('create','update','delete','status','comment')),
  title        text not null,
  detail       text,
  from_status  text,
  to_status    text,
  by_user_id   uuid,
  by_name      text,
  created_at   timestamptz not null default now()
);
create index if not exists idx_cal_activity_created on public.cal_activity(created_at desc);
create index if not exists idx_cal_activity_item    on public.cal_activity(item_type, item_id);


-- =====================================================================
-- 2) Trigger
-- =====================================================================

-- 2.1 ตรวจช่วงวันที่ (วันสิ้นสุดว่าง = วันเดียว · ห้ามสิ้นสุดก่อนเริ่ม) + updated_at
create or replace function public.sfh_cal_before_write()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.end_date is null then new.end_date := new.start_date; end if;
  if new.end_date < new.start_date then
    raise exception 'วันที่สิ้นสุดต้องไม่ก่อนวันที่เริ่ม';
  end if;
  if tg_op = 'UPDATE' then new.updated_at := now(); end if;
  return new;
end $$;

-- 2.2 การลา: ไม่เก็บสถานที่/รายละเอียดใด ๆ (PDPA)
create or replace function public.sfh_cal_absence_privacy()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.kind = 'leave' then new.place := null; end if;
  return new;
end $$;

-- 2.3 งาน: บันทึกเวลาที่เสร็จ + updated_at
create or replace function public.sfh_cal_task_before_write()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.status = 'done' and (tg_op = 'INSERT' or old.status is distinct from 'done') then new.done_at := now(); end if;
  if new.status <> 'done' then new.done_at := null; end if;
  if tg_op = 'UPDATE' then new.updated_at := now(); end if;
  return new;
end $$;

drop trigger if exists trg_cal_events_before   on public.cal_events;
create trigger trg_cal_events_before   before insert or update on public.cal_events
  for each row execute function public.sfh_cal_before_write();
drop trigger if exists trg_cal_acting_before   on public.cal_acting;
create trigger trg_cal_acting_before   before insert or update on public.cal_acting
  for each row execute function public.sfh_cal_before_write();
drop trigger if exists trg_cal_absences_before on public.cal_absences;
create trigger trg_cal_absences_before before insert or update on public.cal_absences
  for each row execute function public.sfh_cal_before_write();
drop trigger if exists trg_cal_absences_privacy on public.cal_absences;
create trigger trg_cal_absences_privacy before insert or update on public.cal_absences
  for each row execute function public.sfh_cal_absence_privacy();
drop trigger if exists trg_cal_tasks_before    on public.cal_tasks;
create trigger trg_cal_tasks_before    before insert or update on public.cal_tasks
  for each row execute function public.sfh_cal_task_before_write();


-- =====================================================================
-- 3) ลงทะเบียนโมดูล / Permission / สิทธิ์ / เมนู
-- =====================================================================
insert into public.modules (module_key, name, description, icon, color, status, allow_guest, guest_locked, is_core, sort_order, version, planned_features) values
 ('calendar', 'ปฏิทินกองคลัง',
  'ปฏิทินกิจกรรม งานที่ผู้บริหารมอบหมาย การรักษาราชการแทน และผู้ไม่อยู่ปฏิบัติงาน เพื่อให้ทุกคนเห็นความเคลื่อนไหวของหน่วยงาน',
  'calendar-days', '#8670D6', 'active', true, false, false, 2, '1.0.0',
  '["ปฏิทินรายเดือนและมุมมองรายการ แยกสีตามประเภท","บันทึกงานที่ผู้บริหารมอบหมาย พร้อมผู้รับผิดชอบ กำหนดส่ง และสถานะ","บันทึกการรักษาราชการแทน เชื่อมกับคำสั่งในงานสารบรรณ","แสดงผู้ไม่อยู่ปฏิบัติงาน (ลา/ไปราชการ/อบรม) โดยไม่เปิดเผยเหตุผลการลา","ฟีดความเคลื่อนไหวบนหน้าแรก"]'::jsonb)
on conflict (module_key) do nothing;

insert into public.permissions (perm_key, module_key, action, name, description, org_admin_grantable, sort_order) values
 ('calendar.view_public', 'calendar', 'view_public', 'ดูปฏิทินและความเคลื่อนไหว',            'ใช้กับ Role guest เพื่อเปิดปฏิทินให้บุคคลทั่วไป', true, 30),
 ('calendar.create',      'calendar', 'create',      'บันทึกกิจกรรม/งานมอบหมาย/รักษาราชการแทน/การไม่อยู่', null, true, 31),
 ('calendar.update',      'calendar', 'update',      'แก้ไขรายการ (ของตนเอง) และอัปเดตสถานะงาน', 'อัปเดตสถานะได้เมื่อเป็นผู้บันทึกหรือผู้รับผิดชอบงาน', true, 32),
 ('calendar.delete',      'calendar', 'delete',      'ลบรายการ (ของตนเอง)',                    null, true, 33),
 ('calendar.manage_all',  'calendar', 'manage_all',  'แก้ไข/ลบรายการทุกรายการในหน่วยงาน',        null, true, 34)
on conflict (perm_key) do update
  set module_key = excluded.module_key, action = excluded.action,
      name = excluded.name, description = excluded.description, sort_order = excluded.sort_order;

-- super_admin + org_admin : ทุกสิทธิ์
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p on p.module_key = 'calendar'
 where r.role_key in ('super_admin','org_admin')
on conflict (role_id, permission_id) do nothing;

-- staff : ดู + บันทึก/แก้ไข/ลบ รายการที่ตนเองบันทึก
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p on p.perm_key in (
  'calendar.view_public','calendar.create','calendar.update','calendar.delete')
 where r.role_key = 'staff'
on conflict (role_id, permission_id) do nothing;

-- guest : ดูอย่างเดียว
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p on p.perm_key = 'calendar.view_public'
 where r.role_key = 'guest'
on conflict (role_id, permission_id) do nothing;

insert into public.menus (menu_key, label, icon, module_key, required_permission, public_permission, sort_order, is_active, show_on_mobile, menu_group, description) values
 ('calendar', 'ปฏิทินกองคลัง', 'calendar-days', 'calendar', 'calendar.view_public', 'calendar.view_public', 4, true, true, 'main', 'กิจกรรม งานมอบหมาย รักษาราชการแทน และผู้ไม่อยู่ปฏิบัติงาน')
on conflict (menu_key) do nothing;


-- =====================================================================
-- 4) View สาธารณะ (ทุกคนดูได้)
--    แสดงเลขที่/ชื่อหนังสือที่เชื่อมโยง เฉพาะหนังสือระดับ "สาธารณะ"
-- =====================================================================
drop view if exists public.v_public_cal_events;
drop view if exists public.v_public_cal_tasks;
drop view if exists public.v_public_cal_acting;
drop view if exists public.v_public_cal_absences;
drop view if exists public.v_public_cal_activity;

create view public.v_public_cal_events with (security_invoker = on) as
select e.id, e.org_id, o.short_name as org_short_name, e.title, e.category, e.start_date, e.end_date,
       e.all_day, e.start_time, e.end_time, e.location, e.attendees, e.description, e.saraban_doc_id,
       case when d.access_level = 'public' then d.doc_no end as saraban_doc_no,
       case when d.access_level = 'public' then d.title  end as saraban_title,
       d.access_level as saraban_access,
       e.created_by, e.created_by_name, e.updated_by_name, e.created_at, e.updated_at
  from public.cal_events e
  left join public.organizations o on o.id = e.org_id
  left join public.saraban_documents d on d.id = e.saraban_doc_id;

create view public.v_public_cal_tasks with (security_invoker = on) as
select t.id, t.org_id, o.short_name as org_short_name, t.title, t.detail, t.assigned_by, t.assign_date, t.due_date,
       t.priority, t.status, t.done_at, t.saraban_doc_id,
       case when d.access_level = 'public' then d.doc_no end as saraban_doc_no,
       case when d.access_level = 'public' then d.title  end as saraban_title,
       d.access_level as saraban_access,
       coalesce((select jsonb_agg(jsonb_build_object('user_id', a.user_id, 'name', a.name, 'position', a.position) order by a.sort_order, a.created_at)
                   from public.cal_task_assignees a where a.task_id = t.id), '[]'::jsonb) as assignees,
       t.created_by, t.created_by_name, t.updated_by_name, t.created_at, t.updated_at
  from public.cal_tasks t
  left join public.organizations o on o.id = t.org_id
  left join public.saraban_documents d on d.id = t.saraban_doc_id;

create view public.v_public_cal_acting with (security_invoker = on) as
select a.id, a.org_id, o.short_name as org_short_name, a.position_title, a.holder_user_id, a.holder_name,
       a.acting_user_id, a.acting_name, a.acting_position, a.start_date, a.end_date, a.order_no, a.note, a.saraban_doc_id,
       case when d.access_level = 'public' then d.doc_no end as saraban_doc_no,
       case when d.access_level = 'public' then d.title  end as saraban_title,
       d.access_level as saraban_access,
       a.created_by, a.created_by_name, a.updated_by_name, a.created_at, a.updated_at
  from public.cal_acting a
  left join public.organizations o on o.id = a.org_id
  left join public.saraban_documents d on d.id = a.saraban_doc_id;

-- การลา: ไม่มีคอลัมน์เหตุผล และไม่แสดงสถานที่
create view public.v_public_cal_absences with (security_invoker = on) as
select b.id, b.org_id, o.short_name as org_short_name, b.user_id, b.person_name, b.person_position, b.kind,
       b.start_date, b.end_date, b.period, case when b.kind = 'leave' then null else b.place end as place,
       b.created_by, b.created_by_name, b.updated_by_name, b.created_at, b.updated_at
  from public.cal_absences b
  left join public.organizations o on o.id = b.org_id;

create view public.v_public_cal_activity with (security_invoker = on) as
select id, org_id, item_type, item_id, action, title, detail, from_status, to_status, by_name, created_at
  from public.cal_activity;


-- =====================================================================
-- 5) RLS + สิทธิ์
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['cal_events','cal_tasks','cal_task_assignees','cal_acting','cal_absences','cal_activity'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format('drop policy if exists %I on public.%I', t || '_insert', t);
    execute format('drop policy if exists %I on public.%I', t || '_update', t);
    execute format('drop policy if exists %I on public.%I', t || '_delete', t);
    execute format('create policy %I on public.%I for select to anon, authenticated using (true)', t || '_select', t);
    execute format('create policy %I on public.%I for insert to anon, authenticated with check (true)', t || '_insert', t);
    execute format('create policy %I on public.%I for update to anon, authenticated using (true) with check (true)', t || '_update', t);
    execute format('create policy %I on public.%I for delete to anon, authenticated using (true)', t || '_delete', t);
    execute format('grant select, insert, update, delete on public.%I to anon, authenticated', t);
  end loop;
end $$;

grant select on public.v_public_cal_events, public.v_public_cal_tasks, public.v_public_cal_acting,
                public.v_public_cal_absences, public.v_public_cal_activity to anon, authenticated;

-- ---------------------------------------------------------------------
-- ⚠️ หมายเหตุ: Policy แบบ true ใช้เพื่อการสอน/ทดสอบเท่านั้น
--   การจำกัดว่าใครแก้ไข/ลบได้ ทำในหน้าเว็บ (ตาม permission + ผู้บันทึก)
--   ถ้าใช้งานจริงควรย้ายการเขียนข้อมูลไปเป็น RPC ที่ตรวจ session token แบบโมดูลสลิปเงินเดือน
-- ---------------------------------------------------------------------


-- =====================================================================
-- 6) ข้อมูลตัวอย่าง (ไม่บังคับ)
--    รันเฉพาะเมื่อต้องการทดลอง: วาง  set sfh.seed_demo = 'on';  ไว้บรรทัดแรกก่อน Run ทั้งไฟล์
--    (ฐานข้อมูลที่ใช้งานจริงไม่ต้องรันส่วนนี้)
-- =====================================================================
do $$
declare
  v_org   uuid := '11111111-1111-1111-1111-111111111111';
  v_today date := (now() at time zone 'Asia/Bangkok')::date;
  v_task  uuid;
begin
  if coalesce(current_setting('sfh.seed_demo', true), '') <> 'on' then return; end if;
  if exists (select 1 from public.cal_events where org_id = v_org) then return; end if;

  insert into public.cal_events (org_id, title, category, start_date, end_date, all_day, start_time, end_time, location, attendees, created_by_name) values
   (v_org, 'ประชุมประจำเดือนกองคลัง', 'meeting', v_today + 2, v_today + 2, false, '09:30', '12:00', 'ห้องประชุมกองคลัง', 'เจ้าหน้าที่กองคลังทุกคน', 'ข้อมูลตัวอย่าง'),
   (v_org, 'อบรมการใช้งานระบบ e-LAAS', 'training', v_today + 5, v_today + 6, true, null, null, 'ศาลากลางจังหวัดสุโขทัย', 'งานการเงินและบัญชี', 'ข้อมูลตัวอย่าง'),
   (v_org, 'กำหนดส่งรายงานแสดงฐานะการเงินประจำเดือน', 'deadline', v_today + 9, v_today + 9, true, null, null, null, null, 'ข้อมูลตัวอย่าง');

  insert into public.cal_tasks (org_id, title, detail, assigned_by, assign_date, due_date, priority, status, created_by_name)
  values (v_org, 'จัดทำรายงานเงินสะสมคงเหลือ เสนอผู้บริหาร', 'สรุปยอดเงินสะสมและทุนสำรองเงินสะสม ณ สิ้นเดือน', 'นายกเทศมนตรี', v_today, v_today + 7, 'high', 'in_progress', 'ข้อมูลตัวอย่าง')
  returning id into v_task;
  insert into public.cal_task_assignees (task_id, user_id, name, position, sort_order) values
   (v_task, 'bbbbbbbb-0000-0000-0000-000000000003', 'นายธนากร บุญมา', 'นักวิชาการเงินและบัญชีชำนาญการ', 0);

  insert into public.cal_acting (org_id, position_title, holder_user_id, holder_name, acting_user_id, acting_name, acting_position, start_date, end_date, order_no, created_by_name) values
   (v_org, 'ผู้อำนวยการกองคลัง', 'bbbbbbbb-0000-0000-0000-000000000002', 'นางสาวพิมพ์ชนก แก้วมณี',
    'bbbbbbbb-0000-0000-0000-000000000003', 'นายธนากร บุญมา', 'นักวิชาการเงินและบัญชีชำนาญการ', v_today + 5, v_today + 6, 'ที่ 999/2569 (ตัวอย่าง)', 'ข้อมูลตัวอย่าง');

  insert into public.cal_absences (org_id, user_id, person_name, person_position, kind, start_date, end_date, period, place, created_by_name) values
   (v_org, 'bbbbbbbb-0000-0000-0000-000000000002', 'นางสาวพิมพ์ชนก แก้วมณี', 'ผู้อำนวยการกองคลัง', 'official', v_today + 5, v_today + 6, 'full', 'ศาลากลางจังหวัดสุโขทัย', 'ข้อมูลตัวอย่าง'),
   (v_org, 'bbbbbbbb-0000-0000-0000-000000000004', 'นางสาวกัญญารัตน์ ทองดี', 'เจ้าพนักงานการเงินและบัญชีปฏิบัติงาน', 'leave', v_today + 1, v_today + 1, 'morning', null, 'ข้อมูลตัวอย่าง');

  insert into public.cal_activity (org_id, item_type, item_id, action, title, by_name) values
   (v_org, 'task', v_task, 'create', 'จัดทำรายงานเงินสะสมคงเหลือ เสนอผู้บริหาร', 'ข้อมูลตัวอย่าง');
end $$;
