-- =====================================================================
--  Smart Finance Hub (SFH) – โมดูล: ทะเบียนคุมต่าง ๆ
--  ส่วนที่ 2 : ทะเบียนคุมเบิกเงินสวัสดิการเกี่ยวกับการศึกษาบุตร (ค่าเล่าเรียนบุตร)
--  ไฟล์ : module_register_tuition.sql   (รันต่อจาก module_register.sql)
--
--  อ้างอิง
--   - ระเบียบกระทรวงมหาดไทยว่าด้วยเงินสวัสดิการเกี่ยวกับการศึกษาบุตรขององค์กรปกครองส่วนท้องถิ่น พ.ศ. 2563
--   - ประเภทและอัตราเงินบำรุงการศึกษาและค่าเล่าเรียน ตามหนังสือกรมบัญชีกลาง ที่ กค 0422.3/ว 257 ลว. 28 มิ.ย. 2559
--
--  สารบัญ
--   1) ตาราง: edu_rate_sets, edu_spouses, edu_children, edu_claims
--   2) บัญชีอัตรา (ชุดตั้งต้น)
--   3) ฟังก์ชัน RPC (ตรวจ session token + permission ที่ฐานข้อมูลทุกครั้ง)
--      * ปรับฟังก์ชันบุคลากร (sfh_rent_person_*) ให้ใช้ได้ทั้งผู้ดูแลทะเบียนค่าเช่าบ้านและค่าเล่าเรียนบุตร
--   4) Permission + สิทธิ์ของ Role
--   5) RLS + สิทธิ์
--
--  หลักการ
--   - ใช้รายชื่อบุคลากรชุดเดียวกับทะเบียนค่าเช่าบ้าน (rent_people – ดึงจากสลิปเงินเดือน)
--   - คุมตาม "ปีการศึกษา" (เพดานเป็นรายปีการศึกษา) · รายงานตาม "ปีงบประมาณ" จากวันที่วางฎีกา
--   - ฐานข้อมูลตรวจ: ยอดเบิกไม่เกินที่จ่ายจริง (หรือครึ่งหนึ่งสำหรับหลักสูตรที่กำหนด) และยอดสะสมทั้งปีการศึกษาไม่เกินอัตรา
-- =====================================================================
set search_path = public, extensions;


-- =====================================================================
-- 1) ตาราง
-- =====================================================================
create table if not exists public.edu_rate_sets (
  id               uuid primary key default gen_random_uuid(),
  name             text not null,
  reference        text,
  effective_from   date,
  is_active        boolean not null default true,
  config           jsonb not null,       -- { items: [ { key, group, name, fee, cap, half } ] }
  note             text,
  updated_by_name  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- 1.1 คู่สมรส / ผู้ใช้สิทธิ์ (1 แถวต่อบุคลากร)
create table if not exists public.edu_spouses (
  person_id        uuid primary key references public.rent_people(id) on delete cascade,
  org_id           uuid,
  claimant_role    text not null default 'father' check (claimant_role in ('father','mother')),   -- ผู้มีสิทธิเป็นบิดา/มารดา
  spouse_name      text,
  spouse_status    text not null default 'none' check (spouse_status in ('none','gov','other')),
                   -- none = ไม่เป็นข้าราชการ/ลูกจ้างประจำ · gov = ข้าราชการ/ลูกจ้างประจำ · other = รัฐวิสาหกิจ/หน่วยงานอื่น
  spouse_position  text,
  spouse_unit      text,
  note             text,
  updated_by_name  text,
  updated_at       timestamptz not null default now()
);

-- 1.2 บุตร
create table if not exists public.edu_children (
  id               uuid primary key default gen_random_uuid(),
  person_id        uuid not null references public.rent_people(id) on delete cascade,
  org_id           uuid,
  full_name        text not null,
  birth_date       date,
  order_father     int,                  -- เป็นบุตรลำดับที่ (ของบิดา)
  order_mother     int,                  -- เป็นบุตรลำดับที่ (ของมารดา)
  is_substitute    boolean not null default false,   -- เป็นบุตรแทนที่บุตรซึ่งถึงแก่กรรมแล้ว
  sub_order        int,
  sub_name         text,
  sub_birth_date   date,
  sub_death_date   date,
  is_active        boolean not null default true,
  note             text,
  created_by       uuid,
  updated_by_name  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists idx_edu_children_person on public.edu_children(person_id);

-- 1.3 รายการเบิก (ต่อบุตร ต่อปีการศึกษา ต่อภาคเรียน)
create table if not exists public.edu_claims (
  id               uuid primary key default gen_random_uuid(),
  child_id         uuid not null references public.edu_children(id) on delete cascade,
  org_id           uuid,
  academic_year    int not null,         -- ปีการศึกษา พ.ศ.
  semester         text not null check (semester in ('1','2','year')),
  school_name      text not null,
  school_district  text,
  school_province  text,
  rate_key         text not null,        -- ประเภท/ระดับตามบัญชีอัตรา
  rate_name        text,
  fee_type         text not null default 'maintenance' check (fee_type in ('maintenance','tuition')),
  grade            text,                 -- ชั้นที่ศึกษา
  amount_paid      numeric(12,2) not null check (amount_paid >= 0),     -- ยอดตามใบเสร็จ
  spouse_received  numeric(12,2) not null default 0 check (spouse_received >= 0),   -- คู่สมรสได้รับจากหน่วยงานอื่นแล้ว
  amount_claim     numeric(12,2) not null check (amount_claim >= 0),    -- ยอดที่เบิก
  status           text not null default 'paid' check (status in ('pending','paid')),
  doc_no           text,                 -- เลขที่ฎีกา
  doc_date         date,                 -- วันที่วางฎีกา
  note             text,
  created_by       uuid,
  updated_by_name  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (child_id, academic_year, semester)
);
create index if not exists idx_edu_claims_ay on public.edu_claims(org_id, academic_year);
create index if not exists idx_edu_claims_doc on public.edu_claims(org_id, doc_date);

do $$
declare t text;
begin
  foreach t in array array['edu_rate_sets','edu_spouses','edu_children','edu_claims'] loop
    execute format('drop trigger if exists %I on public.%I', 'trg_' || t || '_updated_at', t);
    execute format('create trigger %I before update on public.%I for each row execute function public.sfh_touch_updated_at()', 'trg_' || t || '_updated_at', t);
  end loop;
end $$;


-- =====================================================================
-- 2) บัญชีอัตรา (ว 257/2559) – ปีการศึกษาละไม่เกิน · half = เบิกได้ครึ่งหนึ่งของที่จ่ายจริง
-- =====================================================================
insert into public.edu_rate_sets (id, name, reference, effective_from, config, note) values
 ('eeeeeeee-0000-0000-0000-000000000201',
  'อัตราเงินบำรุงการศึกษาและค่าเล่าเรียน (ว 257/2559)',
  'หนังสือกรมบัญชีกลาง ด่วนที่สุด ที่ กค 0422.3/ว 257 ลงวันที่ 28 มิถุนายน 2559 (ถือปฏิบัติตั้งแต่ปีการศึกษา 2559)',
  null,
  $json${ "items": [
    { "key": "gov_k",   "group": "สถานศึกษาของทางราชการ (เงินบำรุงการศึกษา)", "name": "ระดับอนุบาลหรือเทียบเท่า", "fee": "maintenance", "cap": 5800, "half": false },
    { "key": "gov_p",   "group": "สถานศึกษาของทางราชการ (เงินบำรุงการศึกษา)", "name": "ระดับประถมศึกษาหรือเทียบเท่า", "fee": "maintenance", "cap": 4000, "half": false },
    { "key": "gov_m1",  "group": "สถานศึกษาของทางราชการ (เงินบำรุงการศึกษา)", "name": "ระดับมัธยมศึกษาตอนต้นหรือเทียบเท่า", "fee": "maintenance", "cap": 4800, "half": false },
    { "key": "gov_m2",  "group": "สถานศึกษาของทางราชการ (เงินบำรุงการศึกษา)", "name": "ระดับมัธยมศึกษาตอนปลาย/ปวช. หรือเทียบเท่า", "fee": "maintenance", "cap": 4800, "half": false },
    { "key": "gov_dip", "group": "สถานศึกษาของทางราชการ (เงินบำรุงการศึกษา)", "name": "ระดับอนุปริญญาหรือเทียบเท่า", "fee": "maintenance", "cap": 13700, "half": false },
    { "key": "gov_ba",  "group": "สถานศึกษาของทางราชการ (เงินบำรุงการศึกษา)", "name": "ระดับปริญญาตรี", "fee": "maintenance", "cap": 25000, "half": false },
    { "key": "pvn_k",   "group": "เอกชน สามัญศึกษา – ไม่รับเงินอุดหนุน", "name": "ระดับอนุบาลหรือเทียบเท่า", "fee": "tuition", "cap": 13600, "half": false },
    { "key": "pvn_p",   "group": "เอกชน สามัญศึกษา – ไม่รับเงินอุดหนุน", "name": "ระดับประถมศึกษาหรือเทียบเท่า", "fee": "tuition", "cap": 13200, "half": false },
    { "key": "pvn_m1",  "group": "เอกชน สามัญศึกษา – ไม่รับเงินอุดหนุน", "name": "ระดับมัธยมศึกษาตอนต้นหรือเทียบเท่า", "fee": "tuition", "cap": 15800, "half": false },
    { "key": "pvn_m2",  "group": "เอกชน สามัญศึกษา – ไม่รับเงินอุดหนุน", "name": "ระดับมัธยมศึกษาตอนปลายหรือเทียบเท่า", "fee": "tuition", "cap": 16200, "half": false },
    { "key": "pvs_k",   "group": "เอกชน สามัญศึกษา – รับเงินอุดหนุน", "name": "ระดับอนุบาลหรือเทียบเท่า", "fee": "tuition", "cap": 4800, "half": false },
    { "key": "pvs_p",   "group": "เอกชน สามัญศึกษา – รับเงินอุดหนุน", "name": "ระดับประถมศึกษาหรือเทียบเท่า", "fee": "tuition", "cap": 4200, "half": false },
    { "key": "pvs_m1",  "group": "เอกชน สามัญศึกษา – รับเงินอุดหนุน", "name": "ระดับมัธยมศึกษาตอนต้นหรือเทียบเท่า", "fee": "tuition", "cap": 3300, "half": false },
    { "key": "pvs_m2",  "group": "เอกชน สามัญศึกษา – รับเงินอุดหนุน", "name": "ระดับมัธยมศึกษาตอนปลายหรือเทียบเท่า", "fee": "tuition", "cap": 3200, "half": false },
    { "key": "vcn_home",  "group": "เอกชน ปวช. – ไม่รับเงินอุดหนุน", "name": "คหกรรม หรือคหกรรมศาสตร์", "fee": "tuition", "cap": 16500, "half": false },
    { "key": "vcn_biz",   "group": "เอกชน ปวช. – ไม่รับเงินอุดหนุน", "name": "พาณิชยกรรม หรือบริหารธุรกิจ", "fee": "tuition", "cap": 19900, "half": false },
    { "key": "vcn_art",   "group": "เอกชน ปวช. – ไม่รับเงินอุดหนุน", "name": "ศิลปหัตถกรรม หรือศิลปกรรม", "fee": "tuition", "cap": 20000, "half": false },
    { "key": "vcn_agri",  "group": "เอกชน ปวช. – ไม่รับเงินอุดหนุน", "name": "เกษตรกรรม หรือเกษตรศาสตร์", "fee": "tuition", "cap": 21000, "half": false },
    { "key": "vcn_ind",   "group": "เอกชน ปวช. – ไม่รับเงินอุดหนุน", "name": "ช่างอุตสาหกรรม หรืออุตสาหกรรม", "fee": "tuition", "cap": 24400, "half": false },
    { "key": "vcn_fish",  "group": "เอกชน ปวช. – ไม่รับเงินอุดหนุน", "name": "ประมง", "fee": "tuition", "cap": 21100, "half": false },
    { "key": "vcn_tour",  "group": "เอกชน ปวช. – ไม่รับเงินอุดหนุน", "name": "อุตสาหกรรมการท่องเที่ยว", "fee": "tuition", "cap": 19900, "half": false },
    { "key": "vcn_tex",   "group": "เอกชน ปวช. – ไม่รับเงินอุดหนุน", "name": "อุตสาหกรรมสิ่งทอ", "fee": "tuition", "cap": 24400, "half": false },
    { "key": "vcs_home",  "group": "เอกชน ปวช. – รับเงินอุดหนุน", "name": "คหกรรม หรือคหกรรมศาสตร์", "fee": "tuition", "cap": 3400, "half": false },
    { "key": "vcs_biz",   "group": "เอกชน ปวช. – รับเงินอุดหนุน", "name": "พาณิชยกรรม หรือบริหารธุรกิจ", "fee": "tuition", "cap": 5100, "half": false },
    { "key": "vcs_art",   "group": "เอกชน ปวช. – รับเงินอุดหนุน", "name": "ศิลปหัตถกรรม หรือศิลปกรรม", "fee": "tuition", "cap": 3600, "half": false },
    { "key": "vcs_agri",  "group": "เอกชน ปวช. – รับเงินอุดหนุน", "name": "เกษตรกรรม หรือเกษตรศาสตร์", "fee": "tuition", "cap": 5000, "half": false },
    { "key": "vcs_ind",   "group": "เอกชน ปวช. – รับเงินอุดหนุน", "name": "ช่างอุตสาหกรรม หรืออุตสาหกรรม", "fee": "tuition", "cap": 7200, "half": false },
    { "key": "vcs_fish",  "group": "เอกชน ปวช. – รับเงินอุดหนุน", "name": "ประมง", "fee": "tuition", "cap": 5000, "half": false },
    { "key": "vcs_tour",  "group": "เอกชน ปวช. – รับเงินอุดหนุน", "name": "อุตสาหกรรมการท่องเที่ยว", "fee": "tuition", "cap": 5100, "half": false },
    { "key": "vcs_tex",   "group": "เอกชน ปวช. – รับเงินอุดหนุน", "name": "อุตสาหกรรมสิ่งทอ", "fee": "tuition", "cap": 7200, "half": false },
    { "key": "hv_tech",  "group": "เอกชน ปวส./ปวท. (เบิกครึ่งหนึ่งของที่จ่ายจริง)", "name": "ช่างอุตสาหกรรม/อุตสาหกรรมเทคโนโลยี สารสนเทศและการสื่อสาร ทัศนศาสตร์", "fee": "tuition", "cap": 30000, "half": true },
    { "key": "hv_other", "group": "เอกชน ปวส./ปวท. (เบิกครึ่งหนึ่งของที่จ่ายจริง)", "name": "พาณิชยกรรม/บริหารธุรกิจ ศิลปหัตถกรรม/ศิลปกรรม เกษตรกรรม คหกรรม อุตสาหกรรมการท่องเที่ยว", "fee": "tuition", "cap": 25000, "half": true },
    { "key": "pv_ba",    "group": "เอกชน ปริญญาตรี (เบิกครึ่งหนึ่งของที่จ่ายจริง)", "name": "หลักสูตรระดับปริญญาตรี", "fee": "tuition", "cap": 25000, "half": true }
  ] }$json$::jsonb,
  'อัตราตามสิ่งที่ส่งมาด้วยในระเบียบฯ พ.ศ. 2563 · แก้ไขได้ที่แท็บ "บัญชีอัตรา"')
on conflict (id) do nothing;


-- =====================================================================
-- 3) ฟังก์ชัน RPC
-- =====================================================================

-- 3.0 (ภายใน) ตรวจ token + ต้องมีสิทธิ์อย่างน้อย 1 รายการในรายการที่กำหนด
create or replace function public.sfh_reg_auth(p_token text, p_perms text[])
returns public.users language plpgsql stable security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; p text;
begin
  v_user := public.sfh_payroll_auth(p_token, null);
  foreach p in array p_perms loop
    if public.sfh_has_perm(v_user.id, p) then return v_user; end if;
  end loop;
  raise exception 'FORBIDDEN: %', array_to_string(p_perms, ' / ') using hint = 'ไม่มีสิทธิ์ทำรายการนี้';
end $$;

-- 3.0.1 ฟังก์ชันบุคลากร (ใช้ร่วมกัน 2 ทะเบียน) – คงพฤติกรรมเดิม แต่รับสิทธิ์ได้ทั้ง manage_rent / manage_tuition
create or replace function public.sfh_rent_person_save(p_token text, p_id uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_row public.rent_people%rowtype; v_name text;
begin
  v_user := public.sfh_reg_auth(p_token, array['register.manage_rent','register.manage_tuition']);
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

create or replace function public.sfh_rent_person_delete(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_row public.rent_people%rowtype;
begin
  v_user := public.sfh_reg_auth(p_token, array['register.manage_rent','register.manage_tuition']);
  select * into v_row from public.rent_people where id = p_id;
  if not found then return; end if;
  if v_row.org_id is distinct from v_user.org_id and not public.sfh_is_super(v_user) then raise exception 'FORBIDDEN: org'; end if;
  delete from public.rent_people where id = p_id;
  perform public.sfh_rent_audit(v_user, 'delete', 'rent_people', p_id::text, jsonb_build_object('full_name', v_row.full_name));
end $$;

create or replace function public.sfh_rent_import_payroll(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_added int := 0; v_updated int := 0; v_period text; r record;
begin
  v_user := public.sfh_reg_auth(p_token, array['register.manage_rent','register.manage_tuition']);
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
      insert into public.rent_people (org_id, full_name, employee_type, unit_name, salary, position_type, source, created_by, updated_by_name)
      values (v_user.org_id, r.full_name, r.employee_type, r.unit_name, r.salary,
              case when r.employee_type like 'ข้าราชการครู%' then 'teacher' end, 'payroll', v_user.id, v_user.full_name);
      v_added := v_added + 1;
    end if;
  end loop;
  perform public.sfh_rent_audit(v_user, 'create', 'rent_people', null, jsonb_build_object('import_payroll', true, 'added', v_added, 'updated', v_updated));
  return jsonb_build_object('added', v_added, 'updated', v_updated, 'period', v_period);
end $$;

drop function if exists public.sfh_edu_list(text, int);
drop function if exists public.sfh_edu_report(text, date, date);
drop function if exists public.sfh_edu_spouse_save(text, uuid, jsonb);
drop function if exists public.sfh_edu_child_save(text, uuid, jsonb);
drop function if exists public.sfh_edu_child_delete(text, uuid);
drop function if exists public.sfh_edu_claim_save(text, uuid, jsonb);
drop function if exists public.sfh_edu_claim_delete(text, uuid);
drop function if exists public.sfh_edu_log(text, text, jsonb);
drop function if exists public.sfh_edu_rates_save(text, uuid, jsonb);

-- 3.1 ข้อมูลทั้งหมดของปีการศึกษา (บุคลากร + คู่สมรส + บุตร + รายการเบิกของปีนั้น)
create function public.sfh_edu_list(p_token text, p_ay int)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_super boolean;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_tuition');
  v_super := public.sfh_is_super(v_user);
  return jsonb_build_object(
    'people',   coalesce((select jsonb_agg(to_jsonb(p) order by p.full_name) from public.rent_people p where v_super or p.org_id = v_user.org_id), '[]'::jsonb),
    'spouses',  coalesce((select jsonb_agg(to_jsonb(s)) from public.edu_spouses s where v_super or s.org_id = v_user.org_id), '[]'::jsonb),
    'children', coalesce((select jsonb_agg(to_jsonb(c) order by c.birth_date nulls last) from public.edu_children c where v_super or c.org_id = v_user.org_id), '[]'::jsonb),
    'claims',   coalesce((select jsonb_agg(to_jsonb(x)) from public.edu_claims x where x.academic_year = p_ay and (v_super or x.org_id = v_user.org_id)), '[]'::jsonb),
    'years',    coalesce((select jsonb_agg(distinct x.academic_year) from public.edu_claims x where v_super or x.org_id = v_user.org_id), '[]'::jsonb));
end $$;

-- 3.2 รายการเบิกตามช่วงวันที่วางฎีกา (รายงานประจำเดือน / ปีงบประมาณ)
create function public.sfh_edu_report(p_token text, p_from date, p_to date)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_super boolean;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_tuition');
  v_super := public.sfh_is_super(v_user);
  return coalesce((select jsonb_agg(to_jsonb(x) || jsonb_build_object('child_name', c.full_name, 'person_id', c.person_id, 'person_name', p.full_name,
                                                                        'position_title', p.position_title, 'unit_name', p.unit_name)
                                    order by x.doc_date, p.full_name, c.full_name)
                     from public.edu_claims x join public.edu_children c on c.id = x.child_id join public.rent_people p on p.id = c.person_id
                    where x.doc_date between p_from and p_to and (v_super or x.org_id = v_user.org_id)), '[]'::jsonb);
end $$;

-- 3.3 บันทึกข้อมูลคู่สมรส/ผู้ใช้สิทธิ์
create function public.sfh_edu_spouse_save(p_token text, p_person_id uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_person public.rent_people%rowtype; v_row public.edu_spouses%rowtype;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_tuition');
  select * into v_person from public.rent_people where id = p_person_id;
  if not found then raise exception 'ไม่พบบุคลากร'; end if;
  if v_person.org_id is distinct from v_user.org_id and not public.sfh_is_super(v_user) then raise exception 'FORBIDDEN: org'; end if;
  insert into public.edu_spouses (person_id, org_id, claimant_role, spouse_name, spouse_status, spouse_position, spouse_unit, note, updated_by_name)
  values (p_person_id, v_person.org_id, coalesce(p_data->>'claimant_role', 'father'), p_data->>'spouse_name', coalesce(p_data->>'spouse_status', 'none'),
          p_data->>'spouse_position', p_data->>'spouse_unit', p_data->>'note', v_user.full_name)
  on conflict (person_id) do update set claimant_role = excluded.claimant_role, spouse_name = excluded.spouse_name, spouse_status = excluded.spouse_status,
     spouse_position = excluded.spouse_position, spouse_unit = excluded.spouse_unit, note = excluded.note, updated_by_name = v_user.full_name
  returning * into v_row;
  perform public.sfh_rent_audit(v_user, 'update', 'edu_spouses', p_person_id::text, jsonb_build_object('full_name', v_person.full_name));
  return to_jsonb(v_row);
end $$;

-- 3.4 เพิ่ม/แก้ไขบุตร
create function public.sfh_edu_child_save(p_token text, p_id uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_person public.rent_people%rowtype; v_row public.edu_children%rowtype; v_name text;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_tuition');
  select * into v_person from public.rent_people where id = (p_data->>'person_id')::uuid;
  if not found then raise exception 'ไม่พบบุคลากร'; end if;
  if v_person.org_id is distinct from v_user.org_id and not public.sfh_is_super(v_user) then raise exception 'FORBIDDEN: org'; end if;
  v_name := nullif(btrim(p_data->>'full_name'), '');
  if v_name is null then raise exception 'กรุณากรอกชื่อบุตร'; end if;
  if p_id is null then
    insert into public.edu_children (person_id, org_id, full_name, birth_date, order_father, order_mother, is_substitute, sub_order, sub_name,
                                     sub_birth_date, sub_death_date, is_active, note, created_by, updated_by_name)
    values (v_person.id, v_person.org_id, v_name, nullif(p_data->>'birth_date', '')::date, nullif(p_data->>'order_father', '')::int,
            nullif(p_data->>'order_mother', '')::int, coalesce((p_data->>'is_substitute')::boolean, false), nullif(p_data->>'sub_order', '')::int,
            p_data->>'sub_name', nullif(p_data->>'sub_birth_date', '')::date, nullif(p_data->>'sub_death_date', '')::date,
            coalesce((p_data->>'is_active')::boolean, true), p_data->>'note', v_user.id, v_user.full_name)
    returning * into v_row;
  else
    update public.edu_children set full_name = v_name, birth_date = nullif(p_data->>'birth_date', '')::date,
           order_father = nullif(p_data->>'order_father', '')::int, order_mother = nullif(p_data->>'order_mother', '')::int,
           is_substitute = coalesce((p_data->>'is_substitute')::boolean, false), sub_order = nullif(p_data->>'sub_order', '')::int,
           sub_name = p_data->>'sub_name', sub_birth_date = nullif(p_data->>'sub_birth_date', '')::date,
           sub_death_date = nullif(p_data->>'sub_death_date', '')::date, is_active = coalesce((p_data->>'is_active')::boolean, true),
           note = p_data->>'note', updated_by_name = v_user.full_name
     where id = p_id and person_id = v_person.id returning * into v_row;
    if not found then raise exception 'ไม่พบข้อมูลบุตร'; end if;
  end if;
  perform public.sfh_rent_audit(v_user, case when p_id is null then 'create' else 'update' end, 'edu_children', v_row.id::text,
                                jsonb_build_object('person', v_person.full_name, 'child', v_row.full_name));
  return to_jsonb(v_row);
end $$;

create function public.sfh_edu_child_delete(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_row public.edu_children%rowtype;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_tuition');
  select * into v_row from public.edu_children where id = p_id;
  if not found then return; end if;
  if v_row.org_id is distinct from v_user.org_id and not public.sfh_is_super(v_user) then raise exception 'FORBIDDEN: org'; end if;
  delete from public.edu_children where id = p_id;
  perform public.sfh_rent_audit(v_user, 'delete', 'edu_children', p_id::text, jsonb_build_object('child', v_row.full_name));
end $$;

-- 3.5 บันทึกการเบิก – ตรวจ: ไม่เกินที่จ่ายจริง (หรือครึ่งหนึ่ง) หักส่วนที่คู่สมรสได้รับแล้ว และยอดสะสมทั้งปีการศึกษาไม่เกินอัตรา
create function public.sfh_edu_claim_save(p_token text, p_id uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_child public.edu_children%rowtype; v_row public.edu_claims%rowtype;
        v_set public.edu_rate_sets%rowtype; v_item jsonb; v_ay int; v_paid numeric; v_spouse numeric; v_claim numeric;
        v_base numeric; v_used numeric; v_cap numeric;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_tuition');
  select * into v_child from public.edu_children where id = (p_data->>'child_id')::uuid;
  if not found then raise exception 'ไม่พบข้อมูลบุตร'; end if;
  if v_child.org_id is distinct from v_user.org_id and not public.sfh_is_super(v_user) then raise exception 'FORBIDDEN: org'; end if;
  v_ay := (p_data->>'academic_year')::int;
  if v_ay is null or coalesce(p_data->>'semester', '') not in ('1','2','year') then raise exception 'กรุณาระบุปีการศึกษาและภาคเรียน'; end if;
  if coalesce(btrim(p_data->>'school_name'), '') = '' then raise exception 'กรุณาระบุสถานศึกษา'; end if;
  -- ชุดอัตราที่มีผล ณ วันเปิดปีการศึกษา (16 พ.ค.)
  select * into v_set from public.edu_rate_sets where is_active
     and (effective_from is null or effective_from <= make_date(v_ay - 543, 5, 16))
   order by effective_from desc nulls last limit 1;
  select i into v_item from jsonb_array_elements(v_set.config->'items') i where i->>'key' = p_data->>'rate_key';
  if v_item is null then raise exception 'ไม่พบประเภท/ระดับในบัญชีอัตรา'; end if;
  v_paid   := coalesce(nullif(p_data->>'amount_paid', '')::numeric, 0);
  v_spouse := coalesce(nullif(p_data->>'spouse_received', '')::numeric, 0);
  v_claim  := coalesce(nullif(p_data->>'amount_claim', '')::numeric, 0);
  v_cap    := (v_item->>'cap')::numeric;
  v_base   := case when (v_item->>'half')::boolean then round(v_paid / 2, 2) else v_paid end;
  if exists (select 1 from public.edu_claims where child_id = v_child.id and academic_year = v_ay
                and semester = p_data->>'semester' and id is distinct from p_id) then
    raise exception 'บุตรคนนี้มีรายการเบิกปีการศึกษา % ภาคเรียนนี้แล้ว', v_ay;
  end if;
  select coalesce(sum(amount_claim), 0) into v_used from public.edu_claims
   where child_id = v_child.id and academic_year = v_ay and id is distinct from p_id;
  if v_paid <= 0 then raise exception 'กรุณาระบุจำนวนเงินตามใบเสร็จ'; end if;
  if v_claim <= 0 then raise exception 'กรุณาระบุจำนวนเงินที่เบิก'; end if;
  if v_claim > greatest(v_base - v_spouse, 0) then
    raise exception 'จำนวนเงินที่เบิกเกินกว่าที่มีสิทธิ (ไม่เกิน % บาท)', to_char(greatest(v_base - v_spouse, 0), 'FM999,999,990.00');
  end if;
  if v_used + v_claim > v_cap then
    raise exception 'ยอดเบิกทั้งปีการศึกษาเกินอัตรา % บาท (เบิกไปแล้ว % บาท)', to_char(v_cap, 'FM999,999,990.00'), to_char(v_used, 'FM999,999,990.00');
  end if;
  if p_id is null then
    insert into public.edu_claims (child_id, org_id, academic_year, semester, school_name, school_district, school_province, rate_key, rate_name, fee_type,
                                   grade, amount_paid, spouse_received, amount_claim, status, doc_no, doc_date, note, created_by, updated_by_name)
    values (v_child.id, v_child.org_id, v_ay, p_data->>'semester', btrim(p_data->>'school_name'), p_data->>'school_district', p_data->>'school_province',
            v_item->>'key', (v_item->>'group') || ' · ' || (v_item->>'name'), v_item->>'fee', p_data->>'grade', v_paid, v_spouse, v_claim,
            coalesce(p_data->>'status', 'paid'), p_data->>'doc_no', nullif(p_data->>'doc_date', '')::date, p_data->>'note', v_user.id, v_user.full_name)
    returning * into v_row;
  else
    update public.edu_claims set academic_year = v_ay, semester = p_data->>'semester', school_name = btrim(p_data->>'school_name'),
           school_district = p_data->>'school_district', school_province = p_data->>'school_province', rate_key = v_item->>'key',
           rate_name = (v_item->>'group') || ' · ' || (v_item->>'name'), fee_type = v_item->>'fee', grade = p_data->>'grade',
           amount_paid = v_paid, spouse_received = v_spouse, amount_claim = v_claim, status = coalesce(p_data->>'status', 'paid'),
           doc_no = p_data->>'doc_no', doc_date = nullif(p_data->>'doc_date', '')::date, note = p_data->>'note', updated_by_name = v_user.full_name
     where id = p_id and child_id = v_child.id returning * into v_row;
    if not found then raise exception 'ไม่พบรายการเบิก'; end if;
  end if;
  perform public.sfh_rent_audit(v_user, case when p_id is null then 'create' else 'update' end, 'edu_claims', v_row.id::text,
                                jsonb_build_object('child', v_child.full_name, 'academic_year', v_ay, 'semester', v_row.semester, 'amount', v_claim));
  return to_jsonb(v_row);
exception when unique_violation then raise exception 'บุตรคนนี้มีรายการเบิกปีการศึกษา % ภาคเรียนนี้แล้ว', v_ay;
end $$;

create function public.sfh_edu_claim_delete(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_row public.edu_claims%rowtype;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_tuition');
  select * into v_row from public.edu_claims where id = p_id;
  if not found then return; end if;
  if v_row.org_id is distinct from v_user.org_id and not public.sfh_is_super(v_user) then raise exception 'FORBIDDEN: org'; end if;
  delete from public.edu_claims where id = p_id;
  perform public.sfh_rent_audit(v_user, 'delete', 'edu_claims', p_id::text, jsonb_build_object('academic_year', v_row.academic_year, 'semester', v_row.semester, 'amount', v_row.amount_claim));
end $$;

create function public.sfh_edu_log(p_token text, p_kind text, p_details jsonb)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_tuition');
  perform public.sfh_rent_audit(v_user, 'export', 'edu_claims', null, coalesce(p_details, '{}'::jsonb) || jsonb_build_object('kind', p_kind));
end $$;

create function public.sfh_edu_rates_save(p_token text, p_id uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_row public.edu_rate_sets%rowtype;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_rates');
  if coalesce(btrim(p_data->>'name'), '') = '' then raise exception 'กรุณากรอกชื่อชุดอัตรา'; end if;
  if jsonb_typeof(p_data->'config'->'items') <> 'array' then raise exception 'รูปแบบบัญชีอัตราไม่ถูกต้อง'; end if;
  update public.edu_rate_sets set name = p_data->>'name', reference = p_data->>'reference',
         effective_from = nullif(p_data->>'effective_from', '')::date, config = p_data->'config', note = p_data->>'note', updated_by_name = v_user.full_name
   where id = p_id returning * into v_row;
  if not found then raise exception 'ไม่พบชุดอัตรา'; end if;
  perform public.sfh_rent_audit(v_user, 'update', 'edu_rate_sets', v_row.id::text, jsonb_build_object('name', v_row.name));
  return to_jsonb(v_row);
end $$;


-- =====================================================================
-- 4) Permission + สิทธิ์ของ Role
-- =====================================================================
insert into public.permissions (perm_key, module_key, action, name, description, org_admin_grantable, sort_order) values
 ('register.manage_tuition', 'register', 'manage_tuition', 'ทะเบียนคุมเบิกค่าเล่าเรียนบุตร (ดู/บันทึก/แก้ไข/ลบ)', 'ข้อมูลส่วนบุคคล (รวมข้อมูลบุตร) – ให้เฉพาะเจ้าหน้าที่การเงินที่ดูแลทะเบียน', true, 49)
on conflict (perm_key) do update
  set module_key = excluded.module_key, action = excluded.action, name = excluded.name,
      description = excluded.description, org_admin_grantable = excluded.org_admin_grantable, sort_order = excluded.sort_order;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p on p.perm_key = 'register.manage_tuition'
 where r.role_key in ('super_admin','org_admin')
on conflict (role_id, permission_id) do nothing;

update public.modules
   set planned_features = '["ทะเบียนคุมเบิกค่าเช่าบ้าน รายเดือนตามปีงบประมาณ","ทะเบียนคุมเบิกค่าเล่าเรียนบุตร รายภาคเรียนตามปีการศึกษา","คำนวณเพดานตามบัญชีอัตรา","ดึงรายชื่อข้าราชการจากสลิปเงินเดือน","พิมพ์ทะเบียน / PDF / Excel"]'::jsonb
 where module_key = 'register';


-- =====================================================================
-- 5) RLS + สิทธิ์
-- =====================================================================
alter table public.edu_spouses  enable row level security;
alter table public.edu_children enable row level security;
alter table public.edu_claims   enable row level security;
revoke all on public.edu_spouses, public.edu_children, public.edu_claims from anon, authenticated;

alter table public.edu_rate_sets enable row level security;
drop policy if exists edu_rate_sets_select on public.edu_rate_sets;
create policy edu_rate_sets_select on public.edu_rate_sets for select to anon, authenticated using (true);
revoke all on public.edu_rate_sets from anon, authenticated;
grant select on public.edu_rate_sets to anon, authenticated;

revoke execute on function public.sfh_reg_auth(text, text[]) from public, anon, authenticated;
grant execute on function public.sfh_edu_list(text, int)               to anon, authenticated;
grant execute on function public.sfh_edu_report(text, date, date)      to anon, authenticated;
grant execute on function public.sfh_edu_spouse_save(text, uuid, jsonb) to anon, authenticated;
grant execute on function public.sfh_edu_child_save(text, uuid, jsonb) to anon, authenticated;
grant execute on function public.sfh_edu_child_delete(text, uuid)      to anon, authenticated;
grant execute on function public.sfh_edu_claim_save(text, uuid, jsonb) to anon, authenticated;
grant execute on function public.sfh_edu_claim_delete(text, uuid)      to anon, authenticated;
grant execute on function public.sfh_edu_log(text, text, jsonb)        to anon, authenticated;
grant execute on function public.sfh_edu_rates_save(text, uuid, jsonb) to anon, authenticated;
grant execute on function public.sfh_rent_person_save(text, uuid, jsonb) to anon, authenticated;
grant execute on function public.sfh_rent_person_delete(text, uuid)      to anon, authenticated;
grant execute on function public.sfh_rent_import_payroll(text)           to anon, authenticated;
