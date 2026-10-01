-- =====================================================================
--  Smart Finance Hub (SFH) – โมดูล: งานสารบรรณอิเล็กทรอนิกส์ (e-Saraban)
--  ไฟล์ : module_saraban.sql   (รันต่อจาก database.sql)
--
--  วิธีใช้ : Supabase > SQL Editor > New query > วางทั้งไฟล์ > Run
--  รันซ้ำได้โดยไม่ error
--
--  สารบัญ
--   1) ตาราง: saraban_categories, saraban_documents, saraban_files
--   2) ฟังก์ชัน/Trigger: ปีงบประมาณ, ออกเลขทะเบียนอัตโนมัติ, นับการเข้าชม/ดาวน์โหลด
--   3) ลงทะเบียนโมดูล + Permission + สิทธิ์ของ Role + เมนู
--   4) ข้อมูลตัวอย่าง (ประเภทเอกสาร 9 ประเภท, เอกสาร 15 รายการ)
--   5) View สาธารณะ (Guest อ่านจาก View เท่านั้น)
--   6) RLS + สิทธิ์ + Storage
-- =====================================================================
set search_path = public, extensions;


-- =====================================================================
-- 1) ตาราง
-- =====================================================================

-- 1.1 ประเภทเอกสาร (จัดกลุ่มด้วย group_key)
create table if not exists public.saraban_categories (
  id           uuid primary key default gen_random_uuid(),
  cat_key      text not null unique,
  name         text not null,
  group_key    text not null,
  group_name   text not null,
  icon         text not null default 'file-text',
  color        text not null default '#5AA9E6',
  auto_number  boolean not null default false,   -- ออกเลขทะเบียนรับ/ส่งอัตโนมัติ (รายปีงบประมาณ)
  sort_order   int not null default 100,
  is_active    boolean not null default true,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- 1.2 ทะเบียนเอกสาร
create table if not exists public.saraban_documents (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid references public.organizations(id) on delete set null,
  category_id     uuid not null references public.saraban_categories(id) on delete restrict,
  reg_no          int,                 -- เลขทะเบียนรับ/ส่ง (ออกอัตโนมัติถ้าประเภทกำหนด auto_number)
  reg_year        int,                 -- ปีงบประมาณ พ.ศ. ของเลขทะเบียน
  doc_no          text,                -- เลขที่หนังสือ เช่น สท 52301/1520
  doc_date        date,                -- ลงวันที่
  received_date   date,                -- วันที่รับ (หนังสือเข้า)
  title           text not null,       -- เรื่อง
  from_org        text,                -- จาก
  to_org          text,                -- ถึง/เรียน
  summary         text,                -- สาระสำคัญ
  keywords        text,                -- คำค้น (คั่นด้วย ,)
  urgency         text not null default 'normal'
                  check (urgency in ('normal','urgent','very_urgent','most_urgent')),
  access_level    text not null default 'internal'
                  check (access_level in ('public','internal','restricted')),
  view_count      int not null default 0,
  download_count  int not null default 0,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists idx_saraban_docs_org      on public.saraban_documents(org_id);
create index if not exists idx_saraban_docs_cat      on public.saraban_documents(category_id);
create index if not exists idx_saraban_docs_access   on public.saraban_documents(access_level);
create index if not exists idx_saraban_docs_created  on public.saraban_documents(created_at desc);
create unique index if not exists ux_saraban_reg
  on public.saraban_documents (coalesce(org_id, '00000000-0000-0000-0000-000000000000'::uuid), category_id, reg_year, reg_no)
  where reg_no is not null;

-- 1.3 ไฟล์แนบ (1 เอกสารมีได้หลายไฟล์)
create table if not exists public.saraban_files (
  id          uuid primary key default gen_random_uuid(),
  doc_id      uuid not null references public.saraban_documents(id) on delete cascade,
  org_id      uuid,
  file_name   text not null,          -- ชื่อไฟล์เดิม (ใช้ตอนดาวน์โหลด)
  file_path   text not null,          -- path ใน Storage
  file_url    text not null,
  mime_type   text,
  file_size   bigint not null default 0,
  sort_order  int not null default 0,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists idx_saraban_files_doc on public.saraban_files(doc_id);


-- =====================================================================
-- 2) ฟังก์ชัน / Trigger
-- =====================================================================

-- 2.1 ปีงบประมาณไทย (1 ต.ค. – 30 ก.ย.) เป็น พ.ศ.
create or replace function public.sfh_fiscal_year(p_date date)
returns int language sql immutable set search_path = public as $$
  select (extract(year from p_date)::int + case when extract(month from p_date) >= 10 then 1 else 0 end) + 543;
$$;

-- 2.2 ก่อนบันทึก: กำหนดปีงบประมาณ + ออกเลขทะเบียนอัตโนมัติ + updated_at
create or replace function public.sfh_saraban_before_write()
returns trigger language plpgsql set search_path = public as $$
declare v_auto boolean;
begin
  if new.reg_year is null then
    new.reg_year := public.sfh_fiscal_year(coalesce(new.received_date, new.doc_date,
                                                    (coalesce(new.created_at, now()) at time zone 'Asia/Bangkok')::date));
  end if;
  if tg_op = 'INSERT' and new.reg_no is null then
    select auto_number into v_auto from public.saraban_categories where id = new.category_id;
    if coalesce(v_auto, false) then
      -- ล็อกกันเลขซ้ำเมื่อบันทึกพร้อมกันหลายคน
      perform pg_advisory_xact_lock(hashtext(coalesce(new.org_id::text, '-') || new.category_id::text || new.reg_year::text));
      select coalesce(max(reg_no), 0) + 1 into new.reg_no
        from public.saraban_documents
       where org_id is not distinct from new.org_id
         and category_id = new.category_id
         and reg_year = new.reg_year;
    end if;
  end if;
  -- ไม่เปลี่ยน updated_at เมื่ออัปเดตเฉพาะตัวนับเข้าชม/ดาวน์โหลด
  if tg_op = 'UPDATE' and new.view_count is not distinct from old.view_count
     and new.download_count is not distinct from old.download_count then
    new.updated_at := now();
  end if;
  return new;
end $$;

drop trigger if exists trg_saraban_documents_before on public.saraban_documents;
create trigger trg_saraban_documents_before before insert or update on public.saraban_documents
  for each row execute function public.sfh_saraban_before_write();

drop trigger if exists trg_saraban_categories_updated_at on public.saraban_categories;
create trigger trg_saraban_categories_updated_at before update on public.saraban_categories
  for each row execute function public.sfh_touch_updated_at();
drop trigger if exists trg_saraban_files_updated_at on public.saraban_files;
create trigger trg_saraban_files_updated_at before update on public.saraban_files
  for each row execute function public.sfh_touch_updated_at();

-- 2.3 นับการเข้าชม/ดาวน์โหลด (Guest เรียกได้ แต่แก้ได้เฉพาะตัวนับ)
drop function if exists public.sfh_saraban_hit(uuid, text);
create function public.sfh_saraban_hit(p_doc_id uuid, p_kind text default 'view')
returns void
language sql security definer
set search_path = public
as $$
  update public.saraban_documents
     set view_count     = view_count     + case when p_kind = 'view'     then 1 else 0 end,
         download_count = download_count + case when p_kind = 'download' then 1 else 0 end
   where id = p_doc_id;
$$;


-- =====================================================================
-- 3) ลงทะเบียนโมดูล / Permission / สิทธิ์ / เมนู
-- =====================================================================
insert into public.modules (module_key, name, description, icon, color, status, allow_guest, guest_locked, is_core, sort_order, version, planned_features) values
 ('saraban', 'งานสารบรรณอิเล็กทรอนิกส์ (e-Saraban)',
  'คลังเอกสารดิจิทัลสำหรับจัดเก็บและค้นหาเอกสารราชการ ได้แก่ หนังสือเข้า หนังสือส่ง คำสั่ง/ประกาศ ระเบียบ บันทึกข้อความ/หนังสือเวียน และคู่มือ/แบบฟอร์ม',
  'archive', '#F0A04B', 'active', true, false, false, 9, '1.0.0',
  '["ทะเบียนหนังสือเข้า-ส่ง ออกเลขรับ/ส่งอัตโนมัติตามปีงบประมาณ","แนบไฟล์ได้หลายไฟล์ (PDF, Word, Excel, รูปภาพ)","ค้นหาและกรองตามประเภท ปี ความเร่งด่วน","ประชาชนดาวน์โหลดเอกสารสาธารณะได้"]'::jsonb)
on conflict (module_key) do nothing;

insert into public.permissions (perm_key, module_key, action, name, description, org_admin_grantable, sort_order) values
 ('saraban.view_public',  'saraban', 'view_public',  'ดู/ดาวน์โหลดเอกสารสาธารณะ',          'ใช้กับ Role guest เพื่อเปิดคลังเอกสารให้บุคคลทั่วไป', true, 35),
 ('saraban.view',         'saraban', 'view',         'ดูเอกสารภายในหน่วยงาน',               'เห็นเอกสารระดับ "ภายในหน่วยงาน" และเอกสารที่ตนเองบันทึก', true, 36),
 ('saraban.create',       'saraban', 'create',       'เพิ่มเอกสาร',                         null, true, 37),
 ('saraban.update',       'saraban', 'update',       'แก้ไขเอกสาร (ของตนเอง)',              null, true, 38),
 ('saraban.delete',       'saraban', 'delete',       'ลบเอกสาร (ของตนเอง)',                 null, true, 39),
 ('saraban.view_all',     'saraban', 'view_all',     'ดู/แก้ไขเอกสารทุกฉบับในหน่วยงาน',      'รวมเอกสารลับ/จำกัดสิทธิ์ และแก้ไขเอกสารของผู้อื่นได้', true, 40),
 ('saraban.export',       'saraban', 'export',       'ส่งออกทะเบียนเอกสาร (CSV)',           null, true, 41),
 ('saraban.manage_types', 'saraban', 'manage_types', 'จัดการประเภทเอกสาร',                  null, false, 42)
on conflict (perm_key) do update
  set module_key = excluded.module_key, action = excluded.action,
      name = excluded.name, description = excluded.description, sort_order = excluded.sort_order;

-- super_admin : ทุกสิทธิ์
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p on p.module_key = 'saraban'
 where r.role_key = 'super_admin'
on conflict (role_id, permission_id) do nothing;

-- org_admin : ทุกสิทธิ์ในหน่วยงาน (ยกเว้นจัดการประเภทเอกสารซึ่งเป็นระดับ Platform)
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p on p.perm_key in (
  'saraban.view_public','saraban.view','saraban.create','saraban.update','saraban.delete','saraban.view_all','saraban.export')
 where r.role_key = 'org_admin'
on conflict (role_id, permission_id) do nothing;

-- staff : ดู + เพิ่ม/แก้ไข/ลบ เอกสารที่ตนเองบันทึก
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p on p.perm_key in (
  'saraban.view_public','saraban.view','saraban.create','saraban.update','saraban.delete')
 where r.role_key = 'staff'
on conflict (role_id, permission_id) do nothing;

-- guest : ดูและดาวน์โหลดเอกสารสาธารณะ
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p on p.perm_key = 'saraban.view_public'
 where r.role_key = 'guest'
on conflict (role_id, permission_id) do nothing;

insert into public.menus (menu_key, label, icon, module_key, required_permission, public_permission, sort_order, is_active, show_on_mobile, menu_group, description) values
 ('saraban', 'สารบรรณอิเล็กทรอนิกส์', 'archive', 'saraban', 'saraban.view_public', 'saraban.view_public', 9, true, true, 'module', 'คลังเอกสารราชการดิจิทัล (e-Saraban)')
on conflict (menu_key) do nothing;


-- =====================================================================
-- 4) ข้อมูลตัวอย่าง
-- =====================================================================
insert into public.saraban_categories (cat_key, name, group_key, group_name, icon, color, auto_number, sort_order) values
 ('incoming',     'หนังสือเข้า',      'official',   'หนังสือราชการ',              'mail-open',     '#5AA9E6', true,  1),
 ('outgoing',     'หนังสือส่ง',       'official',   'หนังสือราชการ',              'send',          '#3B8FD4', true,  2),
 ('order',        'คำสั่ง',           'order',      'คำสั่ง/ประกาศ',              'stamp',         '#EC7FA5', true,  3),
 ('announcement', 'ประกาศ',          'order',      'คำสั่ง/ประกาศ',              'megaphone',     '#D95C8A', true,  4),
 ('regulation',   'ระเบียบ',          'regulation', 'ระเบียบ',                    'scale',         '#A694E8', false, 5),
 ('memo',         'บันทึกข้อความ',     'memo',       'บันทึกข้อความ/หนังสือเวียน', 'notebook-pen',  '#F0A04B', true,  6),
 ('circular',     'หนังสือเวียน',      'memo',       'บันทึกข้อความ/หนังสือเวียน', 'repeat',        '#C9951F', true,  7),
 ('manual',       'คู่มือ',            'manual',     'คู่มือ/แบบฟอร์ม',             'book-open',     '#5CC49A', false, 8),
 ('form',         'แบบฟอร์ม',         'manual',     'คู่มือ/แบบฟอร์ม',             'clipboard-list','#3AA57C', false, 9)
on conflict (cat_key) do nothing;

-- เอกสารตัวอย่าง (เลขทะเบียนออกอัตโนมัติจาก Trigger)
insert into public.saraban_documents (id, org_id, category_id, doc_no, doc_date, received_date, title, from_org, to_org, summary, keywords, urgency, access_level, created_by, created_at)
select v.id::uuid, v.org::uuid, c.id, v.doc_no, v.doc_date::date, v.recv::date, v.title, v.from_org, v.to_org, v.summary, v.kw, v.urg, v.acc, v.by::uuid, v.created::timestamptz
  from (values
   ('dddddddd-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'incoming', 'มท 0808.2/ว 3512', '2026-09-10', '2026-09-14',
    'แนวทางการจัดทำงบประมาณรายจ่ายประจำปีงบประมาณ พ.ศ. 2570 ขององค์กรปกครองส่วนท้องถิ่น', 'กรมส่งเสริมการปกครองท้องถิ่น', 'นายกเทศมนตรีเมืองศรีสัชนาลัย',
    'แจ้งแนวทางและหลักเกณฑ์การตั้งงบประมาณรายจ่าย ให้ดำเนินการตามกรอบระยะเวลาที่กำหนด', 'งบประมาณ,2570,ข้อบัญญัติ', 'most_urgent', 'internal',
    'bbbbbbbb-0000-0000-0000-000000000003', '2026-09-14 09:15:00+07'),
   ('dddddddd-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'incoming', 'สท 0023.3/ว 1870', '2026-09-18', '2026-09-22',
    'การเบิกจ่ายเงินอุดหนุนทั่วไป ไตรมาสที่ 4 ประจำปีงบประมาณ พ.ศ. 2569', 'สำนักงานส่งเสริมการปกครองท้องถิ่นจังหวัดสุโขทัย', 'นายกเทศมนตรีเมืองศรีสัชนาลัย',
    'ให้ตรวจสอบยอดเงินอุดหนุนที่ได้รับจัดสรรและเบิกจ่ายให้แล้วเสร็จก่อนสิ้นปีงบประมาณ', 'เงินอุดหนุน,เบิกจ่าย', 'urgent', 'internal',
    'bbbbbbbb-0000-0000-0000-000000000004', '2026-09-22 10:30:00+07'),
   ('dddddddd-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'incoming', 'ตผ 0042/1155', '2026-09-24', '2026-09-25',
    'แจ้งผลการตรวจสอบงบการเงิน ประจำปีงบประมาณ พ.ศ. 2568', 'สำนักงานการตรวจเงินแผ่นดินจังหวัดสุโขทัย', 'นายกเทศมนตรีเมืองศรีสัชนาลัย',
    'แจ้งข้อตรวจพบและข้อเสนอแนะ ให้รายงานผลการดำเนินการภายใน 60 วัน (เอกสารจำกัดสิทธิ์)', 'ตรวจสอบ,งบการเงิน', 'very_urgent', 'restricted',
    'bbbbbbbb-0000-0000-0000-000000000002', '2026-09-25 14:00:00+07'),
   ('dddddddd-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'outgoing', 'สท 52301/1520', '2026-09-08', null,
    'ขอส่งรายงานแสดงฐานะการเงิน ประจำเดือนสิงหาคม 2569', 'กองคลัง เทศบาลเมืองศรีสัชนาลัย', 'ท้องถิ่นจังหวัดสุโขทัย',
    'ส่งรายงานแสดงฐานะการเงินและงบทดลองประจำเดือนสิงหาคม 2569', 'รายงานการเงิน,งบทดลอง', 'normal', 'internal',
    'bbbbbbbb-0000-0000-0000-000000000003', '2026-09-08 11:00:00+07'),
   ('dddddddd-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'outgoing', 'สท 52301/1588', '2026-09-20', null,
    'ขอความร่วมมือประชาสัมพันธ์การชำระภาษีที่ดินและสิ่งปลูกสร้าง ประจำปี 2569', 'เทศบาลเมืองศรีสัชนาลัย', 'กำนัน ผู้ใหญ่บ้าน และประธานชุมชนทุกชุมชน',
    'ขอให้ช่วยประชาสัมพันธ์ให้ผู้มีหน้าที่เสียภาษีชำระภาษีภายในกำหนดเวลา', 'ภาษีที่ดิน,ประชาสัมพันธ์', 'normal', 'public',
    'bbbbbbbb-0000-0000-0000-000000000003', '2026-09-20 13:20:00+07'),
   ('dddddddd-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111', 'order', 'ที่ 245/2569', '2026-09-01', null,
    'คำสั่งเทศบาลเมืองศรีสัชนาลัย เรื่อง แต่งตั้งคณะกรรมการตรวจรับพัสดุ ประจำปีงบประมาณ พ.ศ. 2570', 'นายกเทศมนตรีเมืองศรีสัชนาลัย', 'พนักงานเทศบาลทุกส่วนราชการ',
    'แต่งตั้งคณะกรรมการตรวจรับพัสดุสำหรับการจัดซื้อจัดจ้างในปีงบประมาณ พ.ศ. 2570', 'คำสั่ง,พัสดุ,ตรวจรับ', 'normal', 'public',
    'bbbbbbbb-0000-0000-0000-000000000002', '2026-09-01 15:00:00+07'),
   ('dddddddd-0000-0000-0000-000000000007', '11111111-1111-1111-1111-111111111111', 'announcement', null, '2026-09-28', null,
    'ประกาศเทศบาลเมืองศรีสัชนาลัย เรื่อง กำหนดระยะเวลาการยื่นแบบและชำระภาษีป้าย ประจำปี 2570', 'นายกเทศมนตรีเมืองศรีสัชนาลัย', 'ประชาชนทั่วไป',
    'ผู้มีหน้าที่เสียภาษีป้ายยื่นแบบ ภ.ป.1 ได้ตั้งแต่เดือนมกราคม ถึงมีนาคม 2570 ณ กองคลัง', 'ภาษีป้าย,ภ.ป.1,2570', 'normal', 'public',
    'bbbbbbbb-0000-0000-0000-000000000002', '2026-09-28 09:00:00+07'),
   ('dddddddd-0000-0000-0000-000000000008', '11111111-1111-1111-1111-111111111111', 'regulation', null, '2023-08-04', null,
    'ระเบียบกระทรวงมหาดไทยว่าด้วยการรับเงิน การเบิกจ่ายเงิน การฝากเงิน การเก็บรักษาเงิน และการตรวจเงินขององค์กรปกครองส่วนท้องถิ่น พ.ศ. 2566', 'กระทรวงมหาดไทย', null,
    'ระเบียบหลักด้านการเงินการคลังขององค์กรปกครองส่วนท้องถิ่น', 'ระเบียบ,การเงิน,เบิกจ่าย', 'normal', 'public',
    'bbbbbbbb-0000-0000-0000-000000000002', '2026-08-15 10:00:00+07'),
   ('dddddddd-0000-0000-0000-000000000009', '11111111-1111-1111-1111-111111111111', 'regulation', null, '2012-03-14', null,
    'ระเบียบกระทรวงมหาดไทยว่าด้วยค่าใช้จ่ายในการเดินทางไปราชการของเจ้าหน้าที่ท้องถิ่น พ.ศ. 2555 และที่แก้ไขเพิ่มเติม', 'กระทรวงมหาดไทย', null,
    'หลักเกณฑ์การเบิกค่าเบี้ยเลี้ยง ค่าเช่าที่พัก และค่าพาหนะในการเดินทางไปราชการ', 'ระเบียบ,ไปราชการ,เบี้ยเลี้ยง', 'normal', 'public',
    'bbbbbbbb-0000-0000-0000-000000000002', '2026-08-15 10:05:00+07'),
   ('dddddddd-0000-0000-0000-000000000010', '11111111-1111-1111-1111-111111111111', 'memo', 'สท 52301/บ 412', '2026-09-26', null,
    'ขออนุมัติเบิกจ่ายค่าวัสดุสำนักงาน กองคลัง', 'ผู้อำนวยการกองคลัง', 'ปลัดเทศบาล',
    'ขออนุมัติเบิกจ่ายค่าวัสดุสำนักงานตามใบส่งของ จำนวน 1 รายการ', 'บันทึกข้อความ,วัสดุ', 'normal', 'internal',
    'bbbbbbbb-0000-0000-0000-000000000004', '2026-09-26 10:10:00+07'),
   ('dddddddd-0000-0000-0000-000000000011', '11111111-1111-1111-1111-111111111111', 'circular', 'สท 52301/ว 38', '2026-09-29', null,
    'แจ้งกำหนดปิดงวดบัญชีและส่งเอกสารเบิกจ่าย สิ้นปีงบประมาณ พ.ศ. 2569', 'กองคลัง เทศบาลเมืองศรีสัชนาลัย', 'ทุกกอง/สำนัก',
    'แจ้งทุกส่วนราชการให้ส่งเอกสารขอเบิกที่ค้างอยู่ก่อนปิดงวดบัญชี', 'หนังสือเวียน,ปิดบัญชี', 'urgent', 'internal',
    'bbbbbbbb-0000-0000-0000-000000000003', '2026-09-29 08:45:00+07'),
   ('dddddddd-0000-0000-0000-000000000012', '11111111-1111-1111-1111-111111111111', 'manual', null, '2026-09-30', null,
    'คู่มือการใช้งานระบบ Smart Finance Hub (SFH) สำหรับเจ้าหน้าที่', 'กองคลัง เทศบาลเมืองศรีสัชนาลัย', null,
    'อธิบายการเข้าสู่ระบบ การจัดการข่าวสาร และการใช้งานคลังเอกสารสารบรรณ', 'คู่มือ,SFH', 'normal', 'public',
    'bbbbbbbb-0000-0000-0000-000000000003', '2026-09-30 16:00:00+07'),
   ('dddddddd-0000-0000-0000-000000000013', '11111111-1111-1111-1111-111111111111', 'form', null, null, null,
    'แบบคำขอเบิกเงินสวัสดิการเกี่ยวกับการรักษาพยาบาล', 'กองคลัง เทศบาลเมืองศรีสัชนาลัย', null,
    'แบบฟอร์มสำหรับพนักงานเทศบาลใช้ยื่นขอเบิกค่ารักษาพยาบาล', 'แบบฟอร์ม,สวัสดิการ,รักษาพยาบาล', 'normal', 'public',
    'bbbbbbbb-0000-0000-0000-000000000004', '2026-09-12 09:00:00+07'),
   ('dddddddd-0000-0000-0000-000000000014', '11111111-1111-1111-1111-111111111111', 'form', null, null, null,
    'แบบแสดงรายการภาษีป้าย (ภ.ป.1)', 'กองคลัง เทศบาลเมืองศรีสัชนาลัย', null,
    'แบบยื่นรายการภาษีป้ายสำหรับผู้ประกอบการ', 'แบบฟอร์ม,ภาษีป้าย,ภ.ป.1', 'normal', 'public',
    'bbbbbbbb-0000-0000-0000-000000000004', '2026-09-12 09:10:00+07'),
   ('dddddddd-0000-0000-0000-000000000015', '11111111-1111-1111-1111-111111111112', 'outgoing', 'สท 52302/905', '2026-09-23', null,
    'ขอเชิญประชุมประจำเดือนพนักงานเทศบาล', 'สำนักปลัดเทศบาล', 'หัวหน้าส่วนราชการทุกส่วน',
    'เชิญประชุมประจำเดือนกันยายน 2569', 'ประชุม', 'normal', 'internal',
    'bbbbbbbb-0000-0000-0000-000000000005', '2026-09-23 11:00:00+07')
  ) as v(id, org, cat, doc_no, doc_date, recv, title, from_org, to_org, summary, kw, urg, acc, by, created)
  join public.saraban_categories c on c.cat_key = v.cat
 order by v.created
on conflict (id) do nothing;


-- =====================================================================
-- 5) View สาธารณะ (เฉพาะเอกสาร access_level = 'public')
-- =====================================================================
drop view if exists public.v_public_saraban_files;
drop view if exists public.v_public_saraban;
create view public.v_public_saraban with (security_invoker = on) as
select d.id, d.reg_no, d.reg_year, d.doc_no, d.doc_date, d.received_date, d.title, d.from_org, d.to_org,
       d.summary, d.keywords, d.urgency, d.view_count, d.download_count, d.created_at,
       c.cat_key, c.name as category_name, c.group_key, c.group_name, c.icon as category_icon, c.color as category_color,
       o.name as org_name, o.short_name as org_short_name,
       (select count(*) from public.saraban_files f where f.doc_id = d.id) as file_count
  from public.saraban_documents d
  join public.saraban_categories c on c.id = d.category_id
  left join public.organizations o on o.id = d.org_id
 where d.access_level = 'public' and c.is_active;

create view public.v_public_saraban_files with (security_invoker = on) as
select f.id, f.doc_id, f.file_name, f.file_path, f.file_url, f.mime_type, f.file_size, f.sort_order
  from public.saraban_files f
  join public.saraban_documents d on d.id = f.doc_id
 where d.access_level = 'public';


-- =====================================================================
-- 6) RLS + สิทธิ์ + Storage
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['saraban_categories','saraban_documents','saraban_files'] loop
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

grant select on public.v_public_saraban, public.v_public_saraban_files to anon, authenticated;
grant execute on function public.sfh_saraban_hit(uuid, text) to anon, authenticated;
grant execute on function public.sfh_fiscal_year(date) to anon, authenticated;

-- ไฟล์เอกสารราชการอาจใหญ่กว่ารูปภาพ → ขยายขนาดสูงสุดต่อไฟล์เป็น 20 MB
update storage.buckets set file_size_limit = 20971520 where id = 'sfh-files';

-- ---------------------------------------------------------------------
-- ⚠️ หมายเหตุ: Policy แบบ true ใช้เพื่อการสอน/ทดสอบเท่านั้น (PDPA)
--   - bucket sfh-files เป็น Public: ไฟล์ของเอกสาร "ภายใน/ลับ" เปิดได้ถ้ารู้ URL
--     ถ้าใช้งานจริง ให้ย้ายไฟล์ภายใน/ลับไป bucket แบบ Private แล้วใช้ Signed URL
--   - การจำกัดสิทธิ์ "ลับ/จำกัดสิทธิ์" ในหน้าเว็บเป็นเพียงการซ่อนข้อมูล
--     ต้องเขียน RLS ตาม org_id / created_by / สิทธิ์ view_all จึงจะปลอดภัยจริง
-- ---------------------------------------------------------------------
