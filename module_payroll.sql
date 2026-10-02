-- =====================================================================
--  Smart Finance Hub (SFH) – โมดูล: สลิปเงินเดือน (payroll)
--  ไฟล์ : module_payroll.sql
--  ลำดับการรัน : database.sql (ฉบับที่มีตาราง sfh_sessions) → module_payroll.sql
--  รันซ้ำได้โดยไม่ error
--
--  แนวคิดความปลอดภัย (ต่างจากโมดูลอื่นที่ใช้ Policy แบบ true):
--   • ตาราง payroll_* เปิด RLS แต่ "ไม่มี Policy" + revoke สิทธิ์ทั้งหมด → anon key อ่าน/เขียนตรงไม่ได้
--   • หน้าเว็บเข้าถึงผ่านฟังก์ชัน sfh_payroll_* (SECURITY DEFINER) เท่านั้น
--     ทุกฟังก์ชันตรวจ session token + บัญชีเปิดใช้งาน + Permission + หน่วยงาน และบันทึก Audit Log เอง
--   • ไม่เก็บไฟล์ Excel ต้นฉบับ (อ่านในเบราว์เซอร์) และไฟล์ไม่มีเลขบัตร/เลขบัญชี
--
--  สารบัญ
--   1) ตาราง payroll_periods, payroll_slips
--   2) ฟังก์ชันตรวจสิทธิ์ภายใน
--   3) ฟังก์ชัน RPC สำหรับหน้าเว็บ
--   4) ลงทะเบียนโมดูล / Permission / สิทธิ์
--   5) ปิดการเข้าถึงตรง + สิทธิ์เรียกฟังก์ชัน
-- =====================================================================
set search_path = public, extensions;

do $$ begin
  if to_regclass('public.sfh_sessions') is null then
    raise exception 'ไม่พบตาราง sfh_sessions – กรุณารัน database.sql ฉบับล่าสุดก่อน แล้วจึงรัน module_payroll.sql';
  end if;
end $$;


-- =====================================================================
-- 1) ตาราง
-- =====================================================================

-- 1.1 งวดเงินเดือน (1 งวด = 1 เดือน × 1 กลุ่ม ต่อหน่วยงาน)
create table if not exists public.payroll_periods (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid not null references public.organizations(id) on delete restrict,
  period_year      int  not null check (period_year between 2500 and 2700),   -- พ.ศ.
  period_month     int  not null check (period_month between 1 and 12),
  staff_group      text not null check (staff_group in ('regular','political')), -- ฝ่ายประจำ / ฝ่ายการเมือง
  status           text not null default 'draft' check (status in ('draft','published','closed')),
  org_title        text,          -- ชื่อหน่วยงานบนหัวสลิป (อ่านจากไฟล์)
  org_subtitle     text,          -- อำเภอ/จังหวัด
  source_filename  text,
  sheet_count      int not null default 0,
  employee_count   int not null default 0,
  total_income     numeric(14,2) not null default 0,
  total_deduction  numeric(14,2) not null default 0,
  total_net        numeric(14,2) not null default 0,
  imported_by      uuid,
  imported_at      timestamptz,
  published_at     timestamptz,
  closed_at        timestamptz,
  created_by       uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (org_id, period_year, period_month, staff_group)
);

-- 1.2 สลิปรายคน (รายการรับ/หักเก็บเป็น JSON เพราะแต่ละงานมีรายการไม่เท่ากัน)
create table if not exists public.payroll_slips (
  id               uuid primary key default gen_random_uuid(),
  period_id        uuid not null references public.payroll_periods(id) on delete cascade,
  org_id           uuid not null,
  seq              int  not null default 0,
  full_name        text not null,
  employee_type    text,
  unit_name        text,          -- งาน (จากชื่อชีต)
  sub_unit         text,          -- หน่วยงานย่อย (ถ้ามีในไฟล์ เช่น โรงเรียน)
  sheet_name       text,
  incomes          jsonb not null default '[]'::jsonb,   -- [{ "name": "เงินเดือน", "amount": 28750 }]
  deductions       jsonb not null default '[]'::jsonb,
  total_income     numeric(14,2) not null default 0,
  total_deduction  numeric(14,2) not null default 0,
  net_amount       numeric(14,2) not null default 0,
  warnings         jsonb not null default '[]'::jsonb,
  entry_type       text not null default 'import' check (entry_type in ('import','edited','manual')),  -- นำเข้า / แก้ไขด้วยมือ / เพิ่มด้วยมือ
  original         jsonb,         -- ค่าจากไฟล์ก่อนแก้ไขครั้งแรก (เก็บไว้ตรวจสอบย้อนหลัง)
  edit_reason      text,
  edited_by        uuid,
  edited_by_name   text,
  edited_at        timestamptz,
  created_by       uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists idx_payroll_slips_period on public.payroll_slips(period_id, seq);
create index if not exists idx_payroll_slips_name   on public.payroll_slips(full_name);

-- อัปเกรดจากรุ่นแรก: คอลัมน์สำหรับสลิปที่แก้ไข/เพิ่มด้วยมือ
alter table public.payroll_slips add column if not exists entry_type     text not null default 'import';
alter table public.payroll_slips add column if not exists original       jsonb;
alter table public.payroll_slips add column if not exists edit_reason    text;
alter table public.payroll_slips add column if not exists edited_by      uuid;
alter table public.payroll_slips add column if not exists edited_by_name text;
alter table public.payroll_slips add column if not exists edited_at      timestamptz;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'payroll_slips_entry_type_check') then
    alter table public.payroll_slips add constraint payroll_slips_entry_type_check check (entry_type in ('import','edited','manual'));
  end if;
end $$;

drop trigger if exists trg_payroll_periods_updated_at on public.payroll_periods;
create trigger trg_payroll_periods_updated_at before update on public.payroll_periods
  for each row execute function public.sfh_touch_updated_at();
drop trigger if exists trg_payroll_slips_updated_at on public.payroll_slips;
create trigger trg_payroll_slips_updated_at before update on public.payroll_slips
  for each row execute function public.sfh_touch_updated_at();


-- =====================================================================
-- 2) ฟังก์ชันตรวจสิทธิ์ภายใน (หน้าเว็บเรียกตรงไม่ได้)
-- =====================================================================
drop function if exists public.sfh_payroll_auth(text, text);
drop function if exists public.sfh_has_perm(uuid, text);

-- ผู้ใช้มี Permission นี้หรือไม่ (super_admin ได้ทุกสิทธิ์)
create function public.sfh_has_perm(p_user_id uuid, p_perm text)
returns boolean
language sql stable security definer
set search_path = public, extensions
as $$
  select exists (select 1 from public.users u join public.roles r on r.id = u.role_id
                  where u.id = p_user_id and r.role_key = 'super_admin')
      or exists (select 1 from public.users u
                   join public.role_permissions rp on rp.role_id = u.role_id
                   join public.permissions p on p.id = rp.permission_id
                  where u.id = p_user_id and p.perm_key = p_perm)
      or exists (select 1 from public.user_permissions up
                   join public.permissions p on p.id = up.permission_id
                  where up.user_id = p_user_id and p.perm_key = p_perm);
$$;

-- ตรวจ token + permission → คืนข้อมูลผู้ใช้ (raise exception ถ้าไม่ผ่าน)
create function public.sfh_payroll_auth(p_token text, p_perm text)
returns public.users
language plpgsql stable security definer
set search_path = public, extensions
as $$
declare
  v_uid  uuid;
  v_user public.users%rowtype;
begin
  v_uid := public.sfh_session_user(p_token);
  if v_uid is null then
    raise exception 'SESSION_EXPIRED' using hint = 'เซสชันหมดอายุ กรุณาเข้าสู่ระบบใหม่';
  end if;
  select * into v_user from public.users where id = v_uid;
  if p_perm is not null and not public.sfh_has_perm(v_uid, p_perm) then
    raise exception 'FORBIDDEN: %', p_perm using hint = 'ไม่มีสิทธิ์ทำรายการนี้';
  end if;
  return v_user;
end $$;


-- =====================================================================
-- 3) ฟังก์ชัน RPC
-- =====================================================================
drop function if exists public.sfh_payroll_periods(text);
drop function if exists public.sfh_payroll_slips(text, uuid);
drop function if exists public.sfh_payroll_import(text, jsonb, jsonb, boolean);
drop function if exists public.sfh_payroll_set_status(text, uuid, text);
drop function if exists public.sfh_payroll_delete_period(text, uuid);
drop function if exists public.sfh_payroll_log(text, uuid, text, int, text, text);

-- 3.1 รายการงวด (ผู้ไม่มีสิทธิ์ manage เห็นเฉพาะงวดที่เผยแพร่/ปิดแล้ว)
create function public.sfh_payroll_periods(p_token text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_user   public.users%rowtype;
  v_super  boolean;
  v_manage boolean;
begin
  v_user   := public.sfh_payroll_auth(p_token, 'payroll.view');
  v_super  := exists (select 1 from public.roles where id = v_user.role_id and role_key = 'super_admin');
  v_manage := public.sfh_has_perm(v_user.id, 'payroll.manage');
  return coalesce((
    select jsonb_agg(to_jsonb(p) || jsonb_build_object('org_name', o.name)
                     order by p.period_year desc, p.period_month desc, p.staff_group desc)
      from public.payroll_periods p
      join public.organizations o on o.id = p.org_id
     where (v_super or p.org_id = v_user.org_id)
       and (v_manage or p.status <> 'draft')
  ), '[]'::jsonb);
end $$;

-- 3.2 สลิปทั้งหมดของงวด
create function public.sfh_payroll_slips(p_token text, p_period_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_user   public.users%rowtype;
  v_period public.payroll_periods%rowtype;
begin
  v_user := public.sfh_payroll_auth(p_token, 'payroll.view');
  select * into v_period from public.payroll_periods where id = p_period_id;
  if not found then raise exception 'ไม่พบงวดเงินเดือนที่ต้องการ'; end if;
  if v_period.org_id <> v_user.org_id
     and not exists (select 1 from public.roles where id = v_user.role_id and role_key = 'super_admin') then
    raise exception 'FORBIDDEN: org';
  end if;
  if v_period.status = 'draft' and not public.sfh_has_perm(v_user.id, 'payroll.manage') then
    raise exception 'FORBIDDEN: draft';
  end if;
  return jsonb_build_object(
    'period', to_jsonb(v_period),
    'slips', coalesce((select jsonb_agg(to_jsonb(s) - 'created_by' order by s.seq)
                         from public.payroll_slips s where s.period_id = p_period_id), '[]'::jsonb));
end $$;

-- 3.3 นำเข้า (สร้างงวดใหม่ หรือแทนที่งวดเดิมที่ยังไม่ปิด) – ตรวจยอดซ้ำฝั่งฐานข้อมูล
create function public.sfh_payroll_import(p_token text, p_period jsonb, p_slips jsonb, p_replace boolean default false)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_user     public.users%rowtype;
  v_year     int  := (p_period->>'period_year')::int;
  v_month    int  := (p_period->>'period_month')::int;
  v_group    text := p_period->>'staff_group';
  v_existing public.payroll_periods%rowtype;
  v_pid      uuid;
  v_count    int;
  v_bad      int;
begin
  v_user := public.sfh_payroll_auth(p_token, 'payroll.manage');
  if v_user.org_id is null then raise exception 'บัญชีนี้ไม่ได้สังกัดหน่วยงาน'; end if;
  if v_group not in ('regular','political') then raise exception 'กลุ่มบุคลากรไม่ถูกต้อง'; end if;
  if jsonb_typeof(p_slips) <> 'array' or jsonb_array_length(p_slips) = 0 then raise exception 'ไม่มีข้อมูลสลิปที่จะนำเข้า'; end if;

  -- ตรวจยอดทุกแถว: รวมรายการ = ยอดรวม และ สุทธิ = รับ − หัก
  select count(*) into v_bad
    from jsonb_array_elements(p_slips) s
   where coalesce(nullif(trim(s->>'full_name'), ''), '') = ''
      or abs(coalesce((select sum((x->>'amount')::numeric) from jsonb_array_elements(s->'incomes') x), 0) - (s->>'total_income')::numeric) > 0.009
      or abs(coalesce((select sum((x->>'amount')::numeric) from jsonb_array_elements(s->'deductions') x), 0) - (s->>'total_deduction')::numeric) > 0.009
      or abs((s->>'total_income')::numeric - (s->>'total_deduction')::numeric - (s->>'net_amount')::numeric) > 0.009;
  if v_bad > 0 then raise exception 'ข้อมูลไม่ผ่านการตรวจยอด % แถว กรุณาตรวจสอบไฟล์อีกครั้ง', v_bad; end if;

  select * into v_existing from public.payroll_periods
   where org_id = v_user.org_id and period_year = v_year and period_month = v_month and staff_group = v_group;
  if found then
    if v_existing.status = 'closed' then
      raise exception 'งวดนี้ปิดแล้ว ไม่สามารถนำเข้าซ้ำได้ (ให้ผู้ดูแลระบบเปิดงวดก่อน)';
    end if;
    if not coalesce(p_replace, false) then
      return jsonb_build_object('success', false, 'code', 'EXISTS', 'period_id', v_existing.id, 'status', v_existing.status,
                                'employee_count', v_existing.employee_count,
                                'manual_count', (select count(*) from public.payroll_slips
                                                  where period_id = v_existing.id and entry_type <> 'import'));
    end if;
    delete from public.payroll_slips where period_id = v_existing.id;
    v_pid := v_existing.id;
    update public.payroll_periods set status = 'draft', published_at = null where id = v_pid;
  else
    insert into public.payroll_periods(org_id, period_year, period_month, staff_group, created_by)
    values (v_user.org_id, v_year, v_month, v_group, v_user.id) returning id into v_pid;
  end if;

  insert into public.payroll_slips(period_id, org_id, seq, full_name, employee_type, unit_name, sub_unit, sheet_name,
                                   incomes, deductions, total_income, total_deduction, net_amount, warnings, created_by)
  select v_pid, v_user.org_id, (e.ord)::int, trim(e.s->>'full_name'), e.s->>'employee_type', e.s->>'unit_name',
         nullif(e.s->>'sub_unit', ''), e.s->>'sheet_name',
         coalesce(e.s->'incomes', '[]'::jsonb), coalesce(e.s->'deductions', '[]'::jsonb),
         (e.s->>'total_income')::numeric, (e.s->>'total_deduction')::numeric, (e.s->>'net_amount')::numeric,
         coalesce(e.s->'warnings', '[]'::jsonb), v_user.id
    from jsonb_array_elements(p_slips) with ordinality as e(s, ord);
  get diagnostics v_count = row_count;

  update public.payroll_periods p set
    org_title = nullif(p_period->>'org_title', ''), org_subtitle = nullif(p_period->>'org_subtitle', ''),
    source_filename = p_period->>'source_filename', sheet_count = coalesce((p_period->>'sheet_count')::int, 0),
    employee_count = v_count,
    total_income    = (select coalesce(sum(total_income), 0)    from public.payroll_slips where period_id = v_pid),
    total_deduction = (select coalesce(sum(total_deduction), 0) from public.payroll_slips where period_id = v_pid),
    total_net       = (select coalesce(sum(net_amount), 0)      from public.payroll_slips where period_id = v_pid),
    imported_by = v_user.id, imported_at = now()
   where p.id = v_pid;

  insert into public.audit_logs(org_id, user_id, username, action, table_name, record_id, details, created_by)
  values (v_user.org_id, v_user.id, v_user.username, 'import', 'payroll_periods', v_pid::text,
          jsonb_build_object('period', v_month || '/' || v_year, 'group', v_group, 'count', v_count,
                             'file', p_period->>'source_filename', 'replaced', v_existing.id is not null), v_user.id);
  return jsonb_build_object('success', true, 'period_id', v_pid, 'count', v_count);
end $$;

-- 3.4 เปลี่ยนสถานะงวด: draft → published → closed (ย้อนกลับได้ตามสิทธิ์)
create function public.sfh_payroll_set_status(p_token text, p_period_id uuid, p_status text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_user   public.users%rowtype;
  v_period public.payroll_periods%rowtype;
  v_super  boolean;
  v_action text;
begin
  v_user  := public.sfh_payroll_auth(p_token, 'payroll.manage');
  v_super := exists (select 1 from public.roles where id = v_user.role_id and role_key = 'super_admin');
  select * into v_period from public.payroll_periods where id = p_period_id;
  if not found then raise exception 'ไม่พบงวดเงินเดือน'; end if;
  if v_period.org_id <> v_user.org_id and not v_super then raise exception 'FORBIDDEN: org'; end if;
  v_action := case
    when v_period.status = 'draft'     and p_status = 'published' then 'publish'
    when v_period.status = 'published' and p_status = 'closed'    then 'close'
    when v_period.status = 'published' and p_status = 'draft'     then 'unpublish'
    when v_period.status = 'closed'    and p_status = 'published' and v_super then 'reopen'
    else null end;
  if v_action is null then
    raise exception 'ไม่สามารถเปลี่ยนสถานะจาก % เป็น % ได้', v_period.status, p_status;
  end if;
  update public.payroll_periods set status = p_status,
         published_at = case when p_status = 'published' then coalesce(published_at, now()) when p_status = 'draft' then null else published_at end,
         closed_at    = case when p_status = 'closed' then now() else null end
   where id = p_period_id;
  insert into public.audit_logs(org_id, user_id, username, action, table_name, record_id, details, created_by)
  values (v_period.org_id, v_user.id, v_user.username, v_action, 'payroll_periods', p_period_id::text,
          jsonb_build_object('period', v_period.period_month || '/' || v_period.period_year, 'group', v_period.staff_group,
                             'from', v_period.status, 'to', p_status), v_user.id);
  return jsonb_build_object('success', true, 'status', p_status);
end $$;

-- 3.5 ลบงวด (เฉพาะงวดที่ยังไม่ปิด)
create function public.sfh_payroll_delete_period(p_token text, p_period_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_user   public.users%rowtype;
  v_period public.payroll_periods%rowtype;
begin
  v_user := public.sfh_payroll_auth(p_token, 'payroll.manage');
  select * into v_period from public.payroll_periods where id = p_period_id;
  if not found then raise exception 'ไม่พบงวดเงินเดือน'; end if;
  if v_period.org_id <> v_user.org_id
     and not exists (select 1 from public.roles where id = v_user.role_id and role_key = 'super_admin') then
    raise exception 'FORBIDDEN: org';
  end if;
  if v_period.status = 'closed' then raise exception 'งวดที่ปิดแล้วลบไม่ได้'; end if;
  delete from public.payroll_periods where id = p_period_id;
  insert into public.audit_logs(org_id, user_id, username, action, table_name, record_id, details, created_by)
  values (v_period.org_id, v_user.id, v_user.username, 'delete', 'payroll_periods', p_period_id::text,
          jsonb_build_object('period', v_period.period_month || '/' || v_period.period_year, 'group', v_period.staff_group,
                             'count', v_period.employee_count), v_user.id);
  return jsonb_build_object('success', true);
end $$;

-- 3.6 บันทึกการพิมพ์ / ส่งออก (ตรวจสิทธิ์ print หรือ export)
create function public.sfh_payroll_log(p_token text, p_period_id uuid, p_kind text, p_count int,
                                       p_signer_name text default null, p_signer_position text default null)
returns void
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_user   public.users%rowtype;
  v_period public.payroll_periods%rowtype;
begin
  if p_kind not in ('print','export') then raise exception 'ประเภทไม่ถูกต้อง'; end if;
  v_user := public.sfh_payroll_auth(p_token, 'payroll.' || p_kind);
  select * into v_period from public.payroll_periods where id = p_period_id;
  insert into public.audit_logs(org_id, user_id, username, action, table_name, record_id, details, created_by)
  values (coalesce(v_period.org_id, v_user.org_id), v_user.id, v_user.username, p_kind, 'payroll_slips', p_period_id::text,
          jsonb_build_object('period', v_period.period_month || '/' || v_period.period_year, 'group', v_period.staff_group,
                             'count', p_count, 'signer', p_signer_name, 'signer_position', p_signer_position), v_user.id);
end $$;


-- 3.7 (ภายใน) คำนวณยอดรวมของงวดใหม่หลังแก้ไขสลิป
drop function if exists public.sfh_payroll_save_slip(text, uuid, uuid, jsonb, text);
drop function if exists public.sfh_payroll_delete_slip(text, uuid, text);
drop function if exists public.sfh_payroll_recalc(uuid);
create function public.sfh_payroll_recalc(p_period_id uuid)
returns void
language sql security definer
set search_path = public, extensions
as $$
  update public.payroll_periods p set
    employee_count  = (select count(*)                           from public.payroll_slips where period_id = p.id),
    total_income    = (select coalesce(sum(total_income), 0)    from public.payroll_slips where period_id = p.id),
    total_deduction = (select coalesce(sum(total_deduction), 0) from public.payroll_slips where period_id = p.id),
    total_net       = (select coalesce(sum(net_amount), 0)      from public.payroll_slips where period_id = p.id)
   where p.id = p_period_id;
$$;

-- 3.8 จัดทำสลิปแบบ Manual: แก้ไขสลิปเดิม (p_slip_id) หรือเพิ่มสลิปใหม่ (p_slip_id = null)
--     ยอดรวมคำนวณฝั่งฐานข้อมูลจากรายการเสมอ · ต้องระบุเหตุผล · เก็บค่าจากไฟล์เดิมไว้ใน original
create function public.sfh_payroll_save_slip(p_token text, p_period_id uuid, p_slip_id uuid, p_slip jsonb, p_reason text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_user   public.users%rowtype;
  v_period public.payroll_periods%rowtype;
  v_old    public.payroll_slips%rowtype;
  v_name   text := trim(coalesce(p_slip->>'full_name', ''));
  v_inc    jsonb;
  v_ded    jsonb;
  v_ti     numeric;
  v_td     numeric;
  v_id     uuid;
begin
  v_user := public.sfh_payroll_auth(p_token, 'payroll.manage');
  select * into v_period from public.payroll_periods where id = p_period_id;
  if not found then raise exception 'ไม่พบงวดเงินเดือน'; end if;
  if v_period.org_id <> v_user.org_id
     and not exists (select 1 from public.roles where id = v_user.role_id and role_key = 'super_admin') then
    raise exception 'FORBIDDEN: org';
  end if;
  if v_period.status = 'closed' then raise exception 'งวดนี้ปิดแล้ว แก้ไขสลิปไม่ได้ (ให้ Super Admin เปิดงวดก่อน)'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'กรุณาระบุเหตุผลการแก้ไข'; end if;
  if v_name = '' then raise exception 'กรุณาระบุชื่อ-สกุล'; end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p_slip->'incomes', '[]') || coalesce(p_slip->'deductions', '[]')) x
              where (x->>'amount')::numeric < 0) then
    raise exception 'จำนวนเงินต้องไม่ติดลบ';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('name', trim(x->>'name'), 'amount', round((x->>'amount')::numeric, 2)) order by o), '[]'::jsonb)
    into v_inc
    from jsonb_array_elements(coalesce(p_slip->'incomes', '[]')) with ordinality t(x, o)
   where trim(coalesce(x->>'name', '')) <> '' and round((x->>'amount')::numeric, 2) <> 0;
  select coalesce(jsonb_agg(jsonb_build_object('name', trim(x->>'name'), 'amount', round((x->>'amount')::numeric, 2)) order by o), '[]'::jsonb)
    into v_ded
    from jsonb_array_elements(coalesce(p_slip->'deductions', '[]')) with ordinality t(x, o)
   where trim(coalesce(x->>'name', '')) <> '' and round((x->>'amount')::numeric, 2) <> 0;
  v_ti := coalesce((select sum((x->>'amount')::numeric) from jsonb_array_elements(v_inc) x), 0);
  v_td := coalesce((select sum((x->>'amount')::numeric) from jsonb_array_elements(v_ded) x), 0);
  if v_ti <= 0 then raise exception 'ต้องมีรายการรับอย่างน้อย 1 รายการ'; end if;

  if p_slip_id is null then
    insert into public.payroll_slips(period_id, org_id, seq, full_name, employee_type, unit_name, sub_unit, sheet_name,
                                     incomes, deductions, total_income, total_deduction, net_amount, entry_type,
                                     edit_reason, edited_by, edited_by_name, edited_at, created_by)
    values (p_period_id, v_period.org_id,
            coalesce((select max(seq) from public.payroll_slips where period_id = p_period_id), 0) + 1,
            v_name, nullif(trim(p_slip->>'employee_type'), ''), nullif(trim(p_slip->>'unit_name'), ''), nullif(trim(p_slip->>'sub_unit'), ''), null,
            v_inc, v_ded, v_ti, v_td, v_ti - v_td, 'manual',
            trim(p_reason), v_user.id, v_user.full_name, now(), v_user.id)
    returning id into v_id;
    insert into public.audit_logs(org_id, user_id, username, action, table_name, record_id, details, created_by)
    values (v_period.org_id, v_user.id, v_user.username, 'create', 'payroll_slips', v_id::text,
            jsonb_build_object('manual', true, 'name', v_name, 'net', v_ti - v_td, 'reason', trim(p_reason),
                               'period', v_period.period_month || '/' || v_period.period_year, 'group', v_period.staff_group), v_user.id);
  else
    select * into v_old from public.payroll_slips where id = p_slip_id and period_id = p_period_id;
    if not found then raise exception 'ไม่พบสลิปที่ต้องการแก้ไข'; end if;
    update public.payroll_slips set
      full_name = v_name, employee_type = nullif(trim(p_slip->>'employee_type'), ''),
      unit_name = nullif(trim(p_slip->>'unit_name'), ''), sub_unit = nullif(trim(p_slip->>'sub_unit'), ''),
      incomes = v_inc, deductions = v_ded, total_income = v_ti, total_deduction = v_td, net_amount = v_ti - v_td,
      entry_type = case when v_old.entry_type = 'import' then 'edited' else v_old.entry_type end,
      original = coalesce(v_old.original, case when v_old.entry_type = 'import' then jsonb_build_object(
                   'full_name', v_old.full_name, 'employee_type', v_old.employee_type, 'unit_name', v_old.unit_name,
                   'incomes', v_old.incomes, 'deductions', v_old.deductions, 'total_income', v_old.total_income,
                   'total_deduction', v_old.total_deduction, 'net_amount', v_old.net_amount) end),
      warnings = '[]'::jsonb,
      edit_reason = trim(p_reason), edited_by = v_user.id, edited_by_name = v_user.full_name, edited_at = now()
     where id = p_slip_id;
    v_id := p_slip_id;
    insert into public.audit_logs(org_id, user_id, username, action, table_name, record_id, details, created_by)
    values (v_period.org_id, v_user.id, v_user.username, 'update', 'payroll_slips', v_id::text,
            jsonb_build_object('manual', true, 'name', v_name, 'reason', trim(p_reason),
                               'net_before', v_old.net_amount, 'net_after', v_ti - v_td,
                               'period', v_period.period_month || '/' || v_period.period_year, 'group', v_period.staff_group), v_user.id);
  end if;
  perform public.sfh_payroll_recalc(p_period_id);
  return jsonb_build_object('success', true, 'slip_id', v_id, 'net_amount', v_ti - v_td);
end $$;

-- 3.9 ลบสลิป (เช่น ซ้ำ หรือไม่มีสิทธิ์รับเงินงวดนี้) – ต้องระบุเหตุผล
create function public.sfh_payroll_delete_slip(p_token text, p_slip_id uuid, p_reason text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_user   public.users%rowtype;
  v_slip   public.payroll_slips%rowtype;
  v_period public.payroll_periods%rowtype;
begin
  v_user := public.sfh_payroll_auth(p_token, 'payroll.manage');
  select * into v_slip from public.payroll_slips where id = p_slip_id;
  if not found then raise exception 'ไม่พบสลิป'; end if;
  select * into v_period from public.payroll_periods where id = v_slip.period_id;
  if v_period.org_id <> v_user.org_id
     and not exists (select 1 from public.roles where id = v_user.role_id and role_key = 'super_admin') then
    raise exception 'FORBIDDEN: org';
  end if;
  if v_period.status = 'closed' then raise exception 'งวดนี้ปิดแล้ว ลบสลิปไม่ได้'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'กรุณาระบุเหตุผลการลบ'; end if;
  delete from public.payroll_slips where id = p_slip_id;
  perform public.sfh_payroll_recalc(v_slip.period_id);
  insert into public.audit_logs(org_id, user_id, username, action, table_name, record_id, details, created_by)
  values (v_period.org_id, v_user.id, v_user.username, 'delete', 'payroll_slips', p_slip_id::text,
          jsonb_build_object('manual', true, 'name', v_slip.full_name, 'net', v_slip.net_amount, 'reason', trim(p_reason),
                             'period', v_period.period_month || '/' || v_period.period_year, 'group', v_period.staff_group), v_user.id);
  return jsonb_build_object('success', true);
end $$;


-- =====================================================================
-- 4) ลงทะเบียนโมดูล / Permission / สิทธิ์
-- =====================================================================
update public.modules set
  status = 'active', version = '1.0.0',
  description = 'นำเข้าไฟล์ Excel รายละเอียดผู้มีสิทธิรับเงิน (งด.2) ตรวจสอบยอดอัตโนมัติ แล้วพิมพ์สลิปเงินเดือนรายคน (A4) หรือบันทึกเป็น PDF',
  planned_features = '["นำเข้าไฟล์ Excel งด.2 ได้ทันทีโดยไม่ต้องจับคู่คอลัมน์","ตรวจยอดรายคนและยอดรวมกับแถวรวมทั้งสิ้น","เทียบกับงวดก่อน: คนใหม่ คนที่หายไป ยอดเปลี่ยนผิดปกติ","พิมพ์สลิป A4 / บันทึกเป็น PDF พร้อมเปลี่ยนชื่อผู้ลงนามได้"]'::jsonb
 where module_key = 'payroll';

update public.permissions set name = 'ดูงวดและสลิปเงินเดือน', description = 'เข้าเมนูสลิปเงินเดือน ดูงวดที่เผยแพร่แล้ว', org_admin_grantable = true where perm_key = 'payroll.view';
update public.permissions set name = 'นำเข้า/เผยแพร่/ปิดงวดเงินเดือน', description = 'นำเข้าไฟล์ Excel และจัดการสถานะงวด', org_admin_grantable = true where perm_key = 'payroll.manage';
update public.permissions set name = 'พิมพ์สลิป / บันทึก PDF', org_admin_grantable = true where perm_key = 'payroll.print';
update public.permissions set name = 'ส่งออกข้อมูลเงินเดือน (CSV)', org_admin_grantable = true where perm_key = 'payroll.export';

-- org_admin : ได้สิทธิ์จัดการงวดด้วย (ผู้อำนวยการกองคลัง)
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p on p.perm_key in ('payroll.view','payroll.manage','payroll.print','payroll.export')
 where r.role_key = 'org_admin'
on conflict (role_id, permission_id) do nothing;

-- staff1 (นักวิชาการเงินและบัญชี) : เพิ่มสิทธิ์นำเข้าและส่งออก (เดิมมี view + print)
insert into public.user_permissions (user_id, permission_id, org_id, created_by)
select 'bbbbbbbb-0000-0000-0000-000000000003'::uuid, p.id, '11111111-1111-1111-1111-111111111111'::uuid, 'bbbbbbbb-0000-0000-0000-000000000001'::uuid
  from public.permissions p
 where p.perm_key in ('payroll.manage','payroll.export')
   and exists (select 1 from public.users where id = 'bbbbbbbb-0000-0000-0000-000000000003')
on conflict (user_id, permission_id) do nothing;


-- =====================================================================
-- 5) ปิดการเข้าถึงตรง + สิทธิ์เรียกฟังก์ชัน
-- =====================================================================
alter table public.payroll_periods enable row level security;
alter table public.payroll_slips   enable row level security;
do $$
declare p record;
begin
  for p in select policyname, tablename from pg_policies
            where schemaname = 'public' and tablename in ('payroll_periods','payroll_slips') loop
    execute format('drop policy if exists %I on public.%I', p.policyname, p.tablename);
  end loop;
end $$;
revoke all on public.payroll_periods, public.payroll_slips from anon, authenticated;

revoke execute on function public.sfh_has_perm(uuid, text)       from public, anon, authenticated;
revoke execute on function public.sfh_payroll_auth(text, text)   from public, anon, authenticated;
grant execute on function public.sfh_payroll_periods(text)                               to anon, authenticated;
grant execute on function public.sfh_payroll_slips(text, uuid)                           to anon, authenticated;
grant execute on function public.sfh_payroll_import(text, jsonb, jsonb, boolean)         to anon, authenticated;
grant execute on function public.sfh_payroll_set_status(text, uuid, text)                to anon, authenticated;
grant execute on function public.sfh_payroll_delete_period(text, uuid)                   to anon, authenticated;
grant execute on function public.sfh_payroll_log(text, uuid, text, int, text, text)      to anon, authenticated;
grant execute on function public.sfh_payroll_save_slip(text, uuid, uuid, jsonb, text)    to anon, authenticated;
grant execute on function public.sfh_payroll_delete_slip(text, uuid, text)               to anon, authenticated;
revoke execute on function public.sfh_payroll_recalc(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- หมายเหตุ: ข้อมูลเงินเดือนเป็นข้อมูลส่วนบุคคล (PDPA)
--  • token อายุ 8 ชั่วโมง ยกเลิกทันทีเมื่อออกจากระบบ (sfh_logout)
--  • ตรวจสอบได้ว่าใครนำเข้า/เผยแพร่/พิมพ์/ส่งออก จาก audit_logs (บันทึกโดยฟังก์ชันฝั่งฐานข้อมูล)
--  • ถ้าใช้งานจริงควรเพิ่ม: จำกัดจำนวนครั้ง Login ผิด, บังคับรหัสผ่านที่ปลอดภัย,
--    ย้ายตาราง audit_logs ให้เขียนได้อย่างเดียว และใช้ HTTPS เท่านั้น (GitHub Pages เป็น HTTPS อยู่แล้ว)
-- ---------------------------------------------------------------------
