-- =====================================================================
--  Smart Finance Hub (SFH) – โมดูล: ทะเบียนคุมต่าง ๆ
--  ส่วนที่ 1 : ทะเบียนคุมเบิกค่าเช่าบ้าน
--  ไฟล์ : module_register.sql   (รันต่อจาก module_payroll.sql – ใช้ฟังก์ชันตรวจสิทธิ์และข้อมูลสลิปเงินเดือน)
--
--  วิธีใช้ : Supabase > SQL Editor > New query > วางทั้งไฟล์ > Run
--  รันซ้ำได้โดยไม่ error (ไม่ทับข้อมูลหรืออัตราที่แก้ไขไว้แล้ว)
--
--  สารบัญ
--   1) ตาราง: rent_rate_sets, rent_people, rent_entitlements, rent_claims
--   2) บัญชีอัตราค่าเช่าบ้าน (ระเบียบ มท. ว่าด้วยค่าเช่าบ้านของข้าราชการส่วนท้องถิ่น พ.ศ. 2548
--      แก้ไขเพิ่มเติมถึง (ฉบับที่ 5) พ.ศ. 2565)
--   3) ฟังก์ชัน RPC (ตรวจ session token + permission ที่ฐานข้อมูลทุกครั้ง)
--   4) เปิดโมดูล + Permission + สิทธิ์ของ Role
--   5) RLS + สิทธิ์
--
--  ความปลอดภัย (ข้อมูลส่วนบุคคล / PDPA)
--   • ตาราง rent_people / rent_entitlements / rent_claims เปิด RLS แต่ไม่มี Policy + revoke ทั้งหมด
--     → anon key อ่าน/เขียนตรงไม่ได้ ต้องผ่านฟังก์ชัน sfh_rent_* เท่านั้น
--   • ผู้ใช้ต้องมี register.manage_rent (Super Admin / Org Admin / เจ้าหน้าที่การเงินที่ได้รับมอบหมาย)
--   • บุคคลทั่วไปมองไม่เห็นโมดูล (modules.allow_guest = false)
--   • ทุกการเพิ่ม/แก้ไข/ลบ/พิมพ์/ส่งออก ถูกบันทึกใน audit_logs
-- =====================================================================
set search_path = public, extensions;


-- =====================================================================
-- 1) ตาราง
-- =====================================================================

-- 1.1 ชุดอัตราค่าเช่าบ้าน (บัญชีอัตรา เก็บเป็น JSON – แก้ไขได้โดย register.manage_rates)
create table if not exists public.rent_rate_sets (
  id               uuid primary key default gen_random_uuid(),
  name             text not null,
  reference        text,
  effective_from   date,                 -- ว่าง = ชุดตั้งต้น
  is_active        boolean not null default true,
  config           jsonb not null,
  note             text,
  updated_by_name  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- 1.2 บุคลากร (ดึงจากสลิปเงินเดือน หรือเพิ่มเอง)
create table if not exists public.rent_people (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid references public.organizations(id) on delete set null,
  full_name        text not null,
  employee_type    text,                 -- ประเภทบุคลากร (จากสลิป) เช่น ข้าราชการส่วนท้องถิ่น, ข้าราชการครู
  unit_name        text,                 -- สังกัด/กอง
  position_title   text,                 -- ชื่อตำแหน่ง
  position_type    text,                 -- ประเภทตำแหน่งตามบัญชีอัตรา: general / academic / director / executive / teacher
  position_level   text,                 -- ระดับตำแหน่งตามบัญชีอัตรา
  salary_step      numeric(5,1),         -- ขั้นเงินเดือน (ใช้กับบัญชีที่กำหนดตามขั้น)
  salary           numeric(12,2),        -- เงินเดือน (ใช้กับบัญชีครู)
  source           text not null default 'manual' check (source in ('payroll','manual')),
  is_active        boolean not null default true,
  note             text,
  created_by       uuid,
  updated_by_name  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create unique index if not exists ux_rent_people_name on public.rent_people(org_id, full_name);

-- 1.3 สิทธิ์ค่าเช่าบ้านรายปีงบประมาณ
create table if not exists public.rent_entitlements (
  id               uuid primary key default gen_random_uuid(),
  person_id        uuid not null references public.rent_people(id) on delete cascade,
  org_id           uuid,
  fiscal_year      int not null,         -- ปีงบประมาณ พ.ศ.
  start_date       date not null,        -- มีสิทธิ์ตั้งแต่
  end_date         date,                 -- สิ้นสุดสิทธิ์ (ว่าง = ตลอดปีงบ)
  housing_type     text not null default 'rent' check (housing_type in ('rent','hire_purchase','loan')),
  monthly_rent     numeric(12,2) not null default 0,   -- ค่าเช่า/ค่าผ่อนชำระจริงต่อเดือน
  rate_cap         numeric(12,2) not null default 0,   -- เพดานตามบัญชีอัตรา (เดือนละไม่เกิน)
  address          text,
  contract_start   date,
  contract_end     date,
  order_no         text,                 -- คำสั่ง/หนังสืออนุมัติให้มีสิทธิ์
  note             text,
  created_by       uuid,
  updated_by_name  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (person_id, fiscal_year)
);
create index if not exists idx_rent_ent_fy on public.rent_entitlements(org_id, fiscal_year);

-- 1.4 รายการเบิกรายเดือน
create table if not exists public.rent_claims (
  id               uuid primary key default gen_random_uuid(),
  entitlement_id   uuid not null references public.rent_entitlements(id) on delete cascade,
  org_id           uuid,
  claim_year       int not null,         -- ปี ค.ศ. ของเดือนที่เบิก
  claim_month      int not null check (claim_month between 1 and 12),
  amount           numeric(12,2) not null check (amount >= 0),
  status           text not null default 'paid' check (status in ('pending','paid')),
  doc_no           text,                 -- เลขที่ฎีกา/ใบสำคัญ
  paid_date        date,
  note             text,
  created_by       uuid,
  updated_by_name  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (entitlement_id, claim_year, claim_month)
);

do $$
declare t text;
begin
  foreach t in array array['rent_rate_sets','rent_people','rent_entitlements','rent_claims'] loop
    execute format('drop trigger if exists %I on public.%I', 'trg_' || t || '_updated_at', t);
    execute format('create trigger %I before update on public.%I for each row execute function public.sfh_touch_updated_at()', 'trg_' || t || '_updated_at', t);
  end loop;
end $$;


-- =====================================================================
-- 2) บัญชีอัตราค่าเช่าบ้าน (ชุดตั้งต้น)
--    by = step → ใช้ขั้นเงินเดือน · by = salary → ใช้เงินเดือน (บัญชีครู) · max ว่าง = "ขึ้นไป"
-- =====================================================================
insert into public.rent_rate_sets (id, name, reference, effective_from, config, note) values
 ('eeeeeeee-0000-0000-0000-000000000101',
  'บัญชีอัตราค่าเช่าบ้าน (แก้ไขถึงฉบับที่ 5 พ.ศ. 2565)',
  'ระเบียบกระทรวงมหาดไทยว่าด้วยค่าเช่าบ้านของข้าราชการส่วนท้องถิ่น พ.ศ. 2548 แก้ไขเพิ่มเติมถึง (ฉบับที่ 5) พ.ศ. 2565',
  null,
  $json${
    "types": [
      { "key": "general", "name": "ตำแหน่งประเภททั่วไป", "by": "step", "levels": [
        { "key": "operational", "name": "ระดับปฏิบัติงาน", "tiers": [ { "min": 1, "max": 15.5, "rate": 2500 }, { "min": 16, "max": null, "rate": 3000 } ] },
        { "key": "experienced", "name": "ระดับชำนาญงาน", "tiers": [ { "min": 1, "max": 2.5, "rate": 2500 }, { "min": 3, "max": 8, "rate": 3000 }, { "min": 8.5, "max": null, "rate": 4000 } ] },
        { "key": "senior", "name": "ระดับอาวุโส", "tiers": [ { "min": 1, "max": 11, "rate": 4000 }, { "min": 11.5, "max": 17, "rate": 5000 }, { "min": 17.5, "max": null, "rate": 6000 } ] } ] },
      { "key": "academic", "name": "ตำแหน่งประเภทวิชาการ", "by": "step", "levels": [
        { "key": "practitioner", "name": "ระดับปฏิบัติการ", "tiers": [ { "min": 1, "max": 9.5, "rate": 2500 }, { "min": 10, "max": 14, "rate": 3000 }, { "min": 14.5, "max": null, "rate": 4000 } ] },
        { "key": "professional", "name": "ระดับชำนาญการ", "tiers": [ { "min": 1, "max": 4, "rate": 3000 }, { "min": 4.5, "max": 12, "rate": 4000 }, { "min": 12.5, "max": 20.5, "rate": 5000 }, { "min": 21, "max": null, "rate": 6000 } ] },
        { "key": "senior_professional", "name": "ระดับชำนาญการพิเศษ", "tiers": [ { "min": 1, "max": 6.5, "rate": 4000 }, { "min": 7, "max": 11.5, "rate": 5000 }, { "min": 12, "max": null, "rate": 6000 } ] },
        { "key": "expert", "name": "ระดับเชี่ยวชาญ", "tiers": [ { "min": 1, "max": 7.5, "rate": 5000 }, { "min": 8, "max": null, "rate": 6000 } ] } ] },
      { "key": "director", "name": "ตำแหน่งประเภทอำนวยการท้องถิ่น", "by": "step", "levels": [
        { "key": "low", "name": "ระดับต้น", "tiers": [ { "min": 1, "max": 5.5, "rate": 3000 }, { "min": 6, "max": 14, "rate": 4000 }, { "min": 14.5, "max": 20, "rate": 5000 }, { "min": 20.5, "max": null, "rate": 6000 } ] },
        { "key": "mid", "name": "ระดับกลาง", "tiers": [ { "min": 1, "max": 5.5, "rate": 4000 }, { "min": 6, "max": 11, "rate": 5000 }, { "min": 11.5, "max": null, "rate": 6000 } ] },
        { "key": "high", "name": "ระดับสูง", "tiers": [ { "min": 1, "max": 7, "rate": 5000 }, { "min": 7.5, "max": null, "rate": 6000 } ] } ] },
      { "key": "executive", "name": "ตำแหน่งประเภทบริหารท้องถิ่น", "by": "step", "levels": [
        { "key": "low", "name": "ระดับต้น", "tiers": [ { "min": 1, "max": 10, "rate": 4000 }, { "min": 10.5, "max": 19.5, "rate": 5000 }, { "min": 20, "max": null, "rate": 6000 } ] },
        { "key": "mid", "name": "ระดับกลาง", "tiers": [ { "min": 1, "max": 2, "rate": 4000 }, { "min": 2.5, "max": 10.5, "rate": 5000 }, { "min": 11, "max": null, "rate": 6000 } ] },
        { "key": "high", "name": "ระดับสูง", "tiers": [ { "min": 1, "max": 6.5, "rate": 5000 }, { "min": 7, "max": null, "rate": 6000 } ] } ] },
      { "key": "teacher", "name": "ข้าราชการครู พนักงานครู และบุคลากรทางการศึกษา", "by": "salary", "levels": [
        { "key": "assistant", "name": "ครูผู้ช่วย", "tiers": [ { "min": 15050, "max": 20740, "rate": 2500 }, { "min": 20741, "max": 24290, "rate": 3000 }, { "min": 24291, "max": null, "rate": 4000 } ] },
        { "key": "k1", "name": "คศ. 1", "tiers": [ { "min": 15440, "max": 15840, "rate": 2500 }, { "min": 15841, "max": 19920, "rate": 3000 }, { "min": 19921, "max": null, "rate": 4000 } ] },
        { "key": "k2", "name": "คศ. 2", "tiers": [ { "min": 16190, "max": 28050, "rate": 4000 }, { "min": 28051, "max": 33850, "rate": 5000 }, { "min": 33851, "max": null, "rate": 6000 } ] },
        { "key": "k3", "name": "คศ. 3", "tiers": [ { "min": 19860, "max": 26970, "rate": 4000 }, { "min": 26971, "max": 34470, "rate": 5000 }, { "min": 34471, "max": null, "rate": 6000 } ] },
        { "key": "k4", "name": "คศ. 4", "tiers": [ { "min": 24400, "max": 34690, "rate": 5000 }, { "min": 34691, "max": null, "rate": 6000 } ] },
        { "key": "k5", "name": "คศ. 5", "tiers": [ { "min": null, "max": null, "rate": 6000 } ] } ] }
    ]
  }$json$::jsonb,
  'บัญชีอัตราตามระเบียบฯ (ฉบับที่ 4) พ.ศ. 2562 และบัญชีครูตาม (ฉบับที่ 5) พ.ศ. 2565')
on conflict (id) do nothing;


-- =====================================================================
-- 3) ฟังก์ชัน RPC
-- =====================================================================
drop function if exists public.sfh_rent_audit(public.users, text, text, text, jsonb);
drop function if exists public.sfh_rent_list(text, int);
drop function if exists public.sfh_rent_person_save(text, uuid, jsonb);
drop function if exists public.sfh_rent_person_delete(text, uuid);
drop function if exists public.sfh_rent_import_payroll(text);
drop function if exists public.sfh_rent_ent_save(text, uuid, jsonb);
drop function if exists public.sfh_rent_ent_delete(text, uuid);
drop function if exists public.sfh_rent_claim_save(text, uuid, int, int, jsonb);
drop function if exists public.sfh_rent_claim_delete(text, uuid);
drop function if exists public.sfh_rent_log(text, text, jsonb);
drop function if exists public.sfh_rent_rates_save(text, uuid, jsonb);

-- 3.0 (ภายใน) บันทึก Audit Log
create function public.sfh_rent_audit(p_user public.users, p_action text, p_table text, p_record text, p_details jsonb)
returns void language sql security definer set search_path = public, extensions as $$
  insert into public.audit_logs (action, table_name, record_id, details, user_id, username, org_id, created_by, user_agent)
  values (p_action, p_table, p_record, coalesce(p_details, '{}'::jsonb), p_user.id, p_user.username, p_user.org_id, p_user.id, 'rpc');
$$;

-- (ภายใน) ผู้ใช้เป็น super_admin หรือไม่
create or replace function public.sfh_is_super(p_user public.users)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.roles where id = p_user.role_id and role_key = 'super_admin');
$$;

-- 3.1 ข้อมูลทั้งหมดของปีงบประมาณ (บุคลากร + สิทธิ์ + รายการเบิก)
create function public.sfh_rent_list(p_token text, p_fy int)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_super boolean;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_rent');
  v_super := public.sfh_is_super(v_user);
  return jsonb_build_object(
    'people', coalesce((select jsonb_agg(to_jsonb(p) order by p.full_name) from public.rent_people p
                         where v_super or p.org_id = v_user.org_id), '[]'::jsonb),
    'entitlements', coalesce((select jsonb_agg(to_jsonb(e)) from public.rent_entitlements e
                         where e.fiscal_year = p_fy and (v_super or e.org_id = v_user.org_id)), '[]'::jsonb),
    'claims', coalesce((select jsonb_agg(to_jsonb(c)) from public.rent_claims c
                         join public.rent_entitlements e on e.id = c.entitlement_id
                         where e.fiscal_year = p_fy and (v_super or e.org_id = v_user.org_id)), '[]'::jsonb),
    'years', coalesce((select jsonb_agg(distinct e.fiscal_year) from public.rent_entitlements e
                         where v_super or e.org_id = v_user.org_id), '[]'::jsonb));
end $$;

-- 3.2 เพิ่ม/แก้ไขบุคลากร
create function public.sfh_rent_person_save(p_token text, p_id uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_row public.rent_people%rowtype; v_name text;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_rent');
  v_name := nullif(btrim(p_data->>'full_name'), '');
  if v_name is null then raise exception 'กรุณากรอกชื่อ-สกุล'; end if;
  if p_id is null then
    insert into public.rent_people (org_id, full_name, employee_type, unit_name, position_title, position_type, position_level,
                                    salary_step, salary, source, is_active, note, created_by, updated_by_name)
    values (v_user.org_id, v_name, p_data->>'employee_type', p_data->>'unit_name', p_data->>'position_title', p_data->>'position_type',
            p_data->>'position_level', nullif(p_data->>'salary_step', '')::numeric, nullif(p_data->>'salary', '')::numeric, 'manual',
            coalesce((p_data->>'is_active')::boolean, true), p_data->>'note', v_user.id, v_user.full_name)
    returning * into v_row;
  else
    select * into v_row from public.rent_people where id = p_id;
    if not found then raise exception 'ไม่พบบุคลากร'; end if;
    if v_row.org_id is distinct from v_user.org_id and not public.sfh_is_super(v_user) then raise exception 'FORBIDDEN: org'; end if;
    update public.rent_people set full_name = v_name, employee_type = p_data->>'employee_type', unit_name = p_data->>'unit_name',
           position_title = p_data->>'position_title', position_type = p_data->>'position_type', position_level = p_data->>'position_level',
           salary_step = nullif(p_data->>'salary_step', '')::numeric, salary = nullif(p_data->>'salary', '')::numeric,
           is_active = coalesce((p_data->>'is_active')::boolean, true), note = p_data->>'note', updated_by_name = v_user.full_name
     where id = p_id returning * into v_row;
  end if;
  perform public.sfh_rent_audit(v_user, case when p_id is null then 'create' else 'update' end, 'rent_people', v_row.id::text, jsonb_build_object('full_name', v_row.full_name));
  return to_jsonb(v_row);
exception when unique_violation then raise exception 'มีชื่อ "%" อยู่ในทะเบียนแล้ว', v_name;
end $$;

-- 3.3 ลบบุคลากร (ลบสิทธิ์และรายการเบิกทั้งหมดของบุคคลนี้ด้วย)
create function public.sfh_rent_person_delete(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_row public.rent_people%rowtype;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_rent');
  select * into v_row from public.rent_people where id = p_id;
  if not found then return; end if;
  if v_row.org_id is distinct from v_user.org_id and not public.sfh_is_super(v_user) then raise exception 'FORBIDDEN: org'; end if;
  delete from public.rent_people where id = p_id;
  perform public.sfh_rent_audit(v_user, 'delete', 'rent_people', p_id::text, jsonb_build_object('full_name', v_row.full_name));
end $$;

-- 3.4 ดึงรายชื่อข้าราชการจากสลิปเงินเดือนงวดล่าสุด (เพิ่มเฉพาะชื่อที่ยังไม่มี · อัปเดตเงินเดือนของรายชื่อที่มาจากสลิป)
create function public.sfh_rent_import_payroll(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_added int := 0; v_updated int := 0; v_period text; r record;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_rent');
  for r in
    with latest as (
      select s.full_name, s.employee_type, s.unit_name,
             (select sum((e->>'amount')::numeric) from jsonb_array_elements(s.incomes) e where e->>'name' = 'เงินเดือน') as salary,
             row_number() over (partition by btrim(s.full_name) order by p.period_year desc, p.period_month desc) as rn,
             p.period_year, p.period_month
        from public.payroll_slips s join public.payroll_periods p on p.id = s.period_id
       where p.org_id = v_user.org_id and s.employee_type like 'ข้าราชการ%' and coalesce(btrim(s.full_name), '') <> '')
    select btrim(full_name) as full_name, employee_type, unit_name, salary, period_year, period_month from latest where rn = 1
  loop
    v_period := coalesce(v_period, r.period_month || '/' || r.period_year);
    if exists (select 1 from public.rent_people where org_id = v_user.org_id and full_name = r.full_name) then
      update public.rent_people set salary = coalesce(r.salary, salary), unit_name = coalesce(unit_name, r.unit_name),
             employee_type = coalesce(employee_type, r.employee_type), updated_by_name = v_user.full_name
       where org_id = v_user.org_id and full_name = r.full_name and source = 'payroll'
         and (salary is distinct from coalesce(r.salary, salary) or unit_name is null or employee_type is null);
      if found then v_updated := v_updated + 1; end if;
    else
      insert into public.rent_people (org_id, full_name, employee_type, unit_name, salary,
                                      position_type, source, created_by, updated_by_name)
      values (v_user.org_id, r.full_name, r.employee_type, r.unit_name, r.salary,
              case when r.employee_type like 'ข้าราชการครู%' then 'teacher' end, 'payroll', v_user.id, v_user.full_name);
      v_added := v_added + 1;
    end if;
  end loop;
  perform public.sfh_rent_audit(v_user, 'create', 'rent_people', null, jsonb_build_object('import_payroll', true, 'added', v_added, 'updated', v_updated));
  return jsonb_build_object('added', v_added, 'updated', v_updated, 'period', v_period);
end $$;

-- 3.5 เพิ่ม/แก้ไขสิทธิ์รายปีงบประมาณ
create function public.sfh_rent_ent_save(p_token text, p_id uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_person public.rent_people%rowtype; v_row public.rent_entitlements%rowtype;
        v_fy int; v_start date; v_end date; v_cap numeric; v_rent numeric;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_rent');
  select * into v_person from public.rent_people where id = (p_data->>'person_id')::uuid;
  if not found then raise exception 'ไม่พบบุคลากร'; end if;
  if v_person.org_id is distinct from v_user.org_id and not public.sfh_is_super(v_user) then raise exception 'FORBIDDEN: org'; end if;
  v_fy := (p_data->>'fiscal_year')::int;
  v_start := (p_data->>'start_date')::date;
  v_end := nullif(p_data->>'end_date', '')::date;
  v_cap := coalesce(nullif(p_data->>'rate_cap', '')::numeric, 0);
  v_rent := coalesce(nullif(p_data->>'monthly_rent', '')::numeric, 0);
  if v_fy is null or v_start is null then raise exception 'กรุณาระบุปีงบประมาณและวันที่มีสิทธิ์'; end if;
  if v_cap <= 0 then raise exception 'กรุณาระบุอัตราที่มีสิทธิ์เบิก (เดือนละไม่เกิน)'; end if;
  if v_rent < 0 then raise exception 'ค่าเช่าต้องไม่ติดลบ'; end if;
  if v_end is not null and v_end < v_start then raise exception 'วันที่สิ้นสุดสิทธิ์ต้องไม่ก่อนวันที่เริ่ม'; end if;
  if p_id is null then
    insert into public.rent_entitlements (person_id, org_id, fiscal_year, start_date, end_date, housing_type, monthly_rent, rate_cap,
                                          address, contract_start, contract_end, order_no, note, created_by, updated_by_name)
    values (v_person.id, v_person.org_id, v_fy, v_start, v_end, coalesce(p_data->>'housing_type', 'rent'), v_rent, v_cap,
            p_data->>'address', nullif(p_data->>'contract_start', '')::date, nullif(p_data->>'contract_end', '')::date,
            p_data->>'order_no', p_data->>'note', v_user.id, v_user.full_name)
    returning * into v_row;
  else
    update public.rent_entitlements set fiscal_year = v_fy, start_date = v_start, end_date = v_end,
           housing_type = coalesce(p_data->>'housing_type', 'rent'), monthly_rent = v_rent, rate_cap = v_cap,
           address = p_data->>'address', contract_start = nullif(p_data->>'contract_start', '')::date,
           contract_end = nullif(p_data->>'contract_end', '')::date, order_no = p_data->>'order_no', note = p_data->>'note',
           updated_by_name = v_user.full_name
     where id = p_id and person_id = v_person.id returning * into v_row;
    if not found then raise exception 'ไม่พบสิทธิ์ที่ต้องการแก้ไข'; end if;
  end if;
  perform public.sfh_rent_audit(v_user, case when p_id is null then 'create' else 'update' end, 'rent_entitlements', v_row.id::text,
                                jsonb_build_object('full_name', v_person.full_name, 'fiscal_year', v_fy, 'rate_cap', v_cap, 'monthly_rent', v_rent));
  return to_jsonb(v_row);
exception when unique_violation then raise exception 'บุคลากรนี้มีสิทธิ์ในปีงบประมาณ % อยู่แล้ว', v_fy;
end $$;

-- 3.6 ลบสิทธิ์ (ลบรายการเบิกของปีนั้นด้วย)
create function public.sfh_rent_ent_delete(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_row public.rent_entitlements%rowtype;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_rent');
  select * into v_row from public.rent_entitlements where id = p_id;
  if not found then return; end if;
  if v_row.org_id is distinct from v_user.org_id and not public.sfh_is_super(v_user) then raise exception 'FORBIDDEN: org'; end if;
  delete from public.rent_entitlements where id = p_id;
  perform public.sfh_rent_audit(v_user, 'delete', 'rent_entitlements', p_id::text, jsonb_build_object('fiscal_year', v_row.fiscal_year));
end $$;

-- 3.7 บันทึกการเบิกรายเดือน (เดือนละ 1 รายการ · ไม่เกินเพดานและค่าเช่าจริง · อยู่ในช่วงที่มีสิทธิ์)
create function public.sfh_rent_claim_save(p_token text, p_ent_id uuid, p_year int, p_month int, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_ent public.rent_entitlements%rowtype; v_row public.rent_claims%rowtype;
        v_amount numeric; v_limit numeric; v_first date; v_last date; v_fy int;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_rent');
  select * into v_ent from public.rent_entitlements where id = p_ent_id;
  if not found then raise exception 'ไม่พบสิทธิ์ค่าเช่าบ้าน'; end if;
  if v_ent.org_id is distinct from v_user.org_id and not public.sfh_is_super(v_user) then raise exception 'FORBIDDEN: org'; end if;
  v_first := make_date(p_year, p_month, 1);
  v_last := (v_first + interval '1 month - 1 day')::date;
  v_fy := p_year + 543 + case when p_month >= 10 then 1 else 0 end;
  if v_fy <> v_ent.fiscal_year then raise exception 'เดือนที่เบิกไม่อยู่ในปีงบประมาณ %', v_ent.fiscal_year; end if;
  if v_last < v_ent.start_date or (v_ent.end_date is not null and v_first > v_ent.end_date) then
    raise exception 'เดือนนี้อยู่นอกช่วงที่มีสิทธิ์เบิก';
  end if;
  v_amount := coalesce(nullif(p_data->>'amount', '')::numeric, 0);
  v_limit := case when v_ent.monthly_rent > 0 then least(v_ent.rate_cap, v_ent.monthly_rent) else v_ent.rate_cap end;
  if v_amount <= 0 then raise exception 'กรุณาระบุจำนวนเงิน'; end if;
  if v_amount > v_limit then raise exception 'จำนวนเงินเกินสิทธิ์ (เดือนละไม่เกิน % บาท)', to_char(v_limit, 'FM999,999,990.00'); end if;
  insert into public.rent_claims (entitlement_id, org_id, claim_year, claim_month, amount, status, doc_no, paid_date, note, created_by, updated_by_name)
  values (v_ent.id, v_ent.org_id, p_year, p_month, v_amount, coalesce(p_data->>'status', 'paid'), p_data->>'doc_no',
          nullif(p_data->>'paid_date', '')::date, p_data->>'note', v_user.id, v_user.full_name)
  on conflict (entitlement_id, claim_year, claim_month) do update
     set amount = excluded.amount, status = excluded.status, doc_no = excluded.doc_no, paid_date = excluded.paid_date,
         note = excluded.note, updated_by_name = v_user.full_name
  returning * into v_row;
  perform public.sfh_rent_audit(v_user, 'update', 'rent_claims', v_row.id::text,
                                jsonb_build_object('entitlement_id', v_ent.id, 'month', p_month, 'year', p_year, 'amount', v_amount, 'status', v_row.status));
  return to_jsonb(v_row);
end $$;

-- 3.7.1 บันทึกการเบิกหลายรายการพร้อมกัน (เช่น บันทึกประจำเดือนทั้งหน่วยงาน) – ตรวจทีละรายการด้วยกฎเดียวกับ 3.7
--       p_items = [{ entitlement_id, year, month, amount, status, doc_no, paid_date, note }, ...] · ผิดพลาดรายการใดยกเลิกทั้งชุด
drop function if exists public.sfh_rent_claim_batch(text, jsonb);
create function public.sfh_rent_claim_batch(p_token text, p_items jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_item jsonb; v_n int := 0; v_name text;
begin
  perform public.sfh_payroll_auth(p_token, 'register.manage_rent');
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'ไม่มีรายการที่จะบันทึก'; end if;
  for v_item in select * from jsonb_array_elements(p_items) loop
    begin
      perform public.sfh_rent_claim_save(p_token, (v_item->>'entitlement_id')::uuid, (v_item->>'year')::int, (v_item->>'month')::int, v_item);
    exception when others then
      select p.full_name into v_name from public.rent_entitlements e join public.rent_people p on p.id = e.person_id
       where e.id = (v_item->>'entitlement_id')::uuid;
      raise exception '%: %', coalesce(v_name, 'รายการที่ ' || (v_n + 1)), sqlerrm;
    end;
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('saved', v_n);
end $$;

-- 3.8 ลบรายการเบิก
create function public.sfh_rent_claim_delete(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_row public.rent_claims%rowtype;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_rent');
  select * into v_row from public.rent_claims where id = p_id;
  if not found then return; end if;
  if v_row.org_id is distinct from v_user.org_id and not public.sfh_is_super(v_user) then raise exception 'FORBIDDEN: org'; end if;
  delete from public.rent_claims where id = p_id;
  perform public.sfh_rent_audit(v_user, 'delete', 'rent_claims', p_id::text, jsonb_build_object('month', v_row.claim_month, 'year', v_row.claim_year, 'amount', v_row.amount));
end $$;

-- 3.9 บันทึกการพิมพ์/ส่งออก
create function public.sfh_rent_log(p_token text, p_kind text, p_details jsonb)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_rent');
  perform public.sfh_rent_audit(v_user, 'export', 'rent_claims', null, coalesce(p_details, '{}'::jsonb) || jsonb_build_object('kind', p_kind));
end $$;

-- 3.10 บันทึกชุดอัตรา (เฉพาะ register.manage_rates)
create function public.sfh_rent_rates_save(p_token text, p_id uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_row public.rent_rate_sets%rowtype;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_rates');
  if coalesce(btrim(p_data->>'name'), '') = '' then raise exception 'กรุณากรอกชื่อชุดอัตรา'; end if;
  if jsonb_typeof(p_data->'config'->'types') <> 'array' then raise exception 'รูปแบบบัญชีอัตราไม่ถูกต้อง'; end if;
  if p_id is null then
    insert into public.rent_rate_sets (name, reference, effective_from, is_active, config, note, updated_by_name)
    values (p_data->>'name', p_data->>'reference', nullif(p_data->>'effective_from', '')::date,
            coalesce((p_data->>'is_active')::boolean, true), p_data->'config', p_data->>'note', v_user.full_name)
    returning * into v_row;
  else
    update public.rent_rate_sets set name = p_data->>'name', reference = p_data->>'reference',
           effective_from = nullif(p_data->>'effective_from', '')::date, is_active = coalesce((p_data->>'is_active')::boolean, true),
           config = p_data->'config', note = p_data->>'note', updated_by_name = v_user.full_name
     where id = p_id returning * into v_row;
    if not found then raise exception 'ไม่พบชุดอัตรา'; end if;
  end if;
  perform public.sfh_rent_audit(v_user, case when p_id is null then 'create' else 'update' end, 'rent_rate_sets', v_row.id::text, jsonb_build_object('name', v_row.name));
  return to_jsonb(v_row);
end $$;


-- =====================================================================
-- 4) เปิดโมดูล + Permission + สิทธิ์ของ Role
-- =====================================================================
update public.modules
   set status = 'active', version = '1.0.0',
       description = 'ทะเบียนคุมการเบิกจ่ายของบุคลากร เริ่มจากทะเบียนคุมเบิกค่าเช่าบ้าน (ทะเบียนอื่นจะเพิ่มภายหลัง) – เฉพาะเจ้าหน้าที่ที่ได้รับสิทธิ์',
       planned_features = '["ทะเบียนคุมเบิกค่าเช่าบ้าน รายเดือนตามปีงบประมาณ","คำนวณเพดานตามบัญชีอัตราค่าเช่าบ้าน","ดึงรายชื่อข้าราชการจากสลิปเงินเดือน","พิมพ์ทะเบียน / PDF / Excel","ทะเบียนคุมเบิกค่าเล่าเรียนบุตร (เร็ว ๆ นี้)"]'::jsonb
 where module_key = 'register';

insert into public.permissions (perm_key, module_key, action, name, description, org_admin_grantable, sort_order) values
 ('register.manage_rent',  'register', 'manage_rent',  'ทะเบียนคุมเบิกค่าเช่าบ้าน (ดู/บันทึก/แก้ไข/ลบ)', 'ข้อมูลส่วนบุคคล – ให้เฉพาะเจ้าหน้าที่การเงินที่ดูแลทะเบียน', true, 47),
 ('register.manage_rates', 'register', 'manage_rates', 'แก้ไขบัญชีอัตราของทะเบียนคุม',                null, true, 48)
on conflict (perm_key) do update
  set module_key = excluded.module_key, action = excluded.action, name = excluded.name,
      description = excluded.description, org_admin_grantable = excluded.org_admin_grantable, sort_order = excluded.sort_order;

-- org_admin ได้สิทธิ์ทั้งสอง (super_admin ได้ทุกสิทธิ์อยู่แล้ว)
-- เจ้าหน้าที่การเงินที่ดูแลทะเบียน: ให้สิทธิ์ register.manage_rent รายบุคคลที่หน้า "จัดการผู้ใช้งาน > สิทธิ์"
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p on p.perm_key in ('register.manage_rent','register.manage_rates')
 where r.role_key in ('super_admin','org_admin')
on conflict (role_id, permission_id) do nothing;


-- =====================================================================
-- 5) RLS + สิทธิ์
-- =====================================================================
alter table public.rent_people       enable row level security;
alter table public.rent_entitlements enable row level security;
alter table public.rent_claims       enable row level security;
revoke all on public.rent_people, public.rent_entitlements, public.rent_claims from anon, authenticated;

-- บัญชีอัตราไม่ใช่ข้อมูลส่วนบุคคล → อ่านได้ (แก้ไขผ่าน sfh_rent_rates_save เท่านั้น)
alter table public.rent_rate_sets enable row level security;
drop policy if exists rent_rate_sets_select on public.rent_rate_sets;
create policy rent_rate_sets_select on public.rent_rate_sets for select to anon, authenticated using (true);
revoke all on public.rent_rate_sets from anon, authenticated;
grant select on public.rent_rate_sets to anon, authenticated;

revoke execute on function public.sfh_rent_audit(public.users, text, text, text, jsonb) from public, anon, authenticated;
revoke execute on function public.sfh_is_super(public.users) from public, anon, authenticated;
grant execute on function public.sfh_rent_list(text, int)                         to anon, authenticated;
grant execute on function public.sfh_rent_person_save(text, uuid, jsonb)          to anon, authenticated;
grant execute on function public.sfh_rent_person_delete(text, uuid)               to anon, authenticated;
grant execute on function public.sfh_rent_import_payroll(text)                    to anon, authenticated;
grant execute on function public.sfh_rent_ent_save(text, uuid, jsonb)             to anon, authenticated;
grant execute on function public.sfh_rent_ent_delete(text, uuid)                  to anon, authenticated;
grant execute on function public.sfh_rent_claim_save(text, uuid, int, int, jsonb) to anon, authenticated;
grant execute on function public.sfh_rent_claim_batch(text, jsonb)                to anon, authenticated;
grant execute on function public.sfh_rent_claim_delete(text, uuid)                to anon, authenticated;
grant execute on function public.sfh_rent_log(text, text, jsonb)                  to anon, authenticated;
grant execute on function public.sfh_rent_rates_save(text, uuid, jsonb)           to anon, authenticated;
