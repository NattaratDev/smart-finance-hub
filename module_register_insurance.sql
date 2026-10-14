-- =====================================================================
--  Smart Finance Hub (SFH) – โมดูล: ทะเบียนคุมต่าง ๆ
--  ส่วนที่ 3 : ทะเบียนคุมประกันภัย (รถยนต์/ยานพาหนะ และอาคาร/ทรัพย์สิน)
--  ไฟล์ : module_register_insurance.sql   (รันต่อจาก module_register_tuition.sql)
--
--  สารบัญ
--   1) ตาราง: ins_assets (ทรัพย์สินที่เอาประกัน), ins_policies (กรมธรรม์), ins_claims (การเคลม)
--   2) ฟังก์ชัน RPC (ตรวจ session token + register.manage_insurance ที่ฐานข้อมูลทุกครั้ง)
--   3) Permission + สิทธิ์ของ Role
--   4) RLS + สิทธิ์
--
--  หลักการ
--   - 1 ทรัพย์สิน มีได้หลายกรมธรรม์ (พ.ร.บ. / ภาคสมัครใจ / อัคคีภัย-ทรัพย์สิน / อื่น ๆ) และต่ออายุทุกปี
--   - คุมเบี้ยประกันพร้อมเลขที่ฎีกา/วันที่วางฎีกา · รายงานเบี้ยประกันตามปีงบประมาณจากวันที่วางฎีกา
--   - แจ้งเตือนกรมธรรม์ใกล้หมดอายุ (ภายใน 60 วัน) และหมดอายุแล้ว
-- =====================================================================
set search_path = public, extensions;


-- =====================================================================
-- 1) ตาราง
-- =====================================================================
create table if not exists public.ins_assets (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid references public.organizations(id) on delete set null,
  asset_type       text not null check (asset_type in ('vehicle','building','other')),
  name             text not null,        -- ชื่อเรียก เช่น รถยนต์ส่วนกลาง, อาคารสำนักงานเทศบาล
  vehicle_kind     text,                 -- ประเภทรถ เช่น รถยนต์นั่ง รถกระบะ รถจักรยานยนต์ รถบรรทุกขยะ
  plate_no         text,                 -- เลขทะเบียนรถ
  plate_province   text,
  brand_model      text,                 -- ยี่ห้อ/รุ่น
  chassis_no       text,                 -- เลขตัวถัง
  engine_no        text,                 -- เลขเครื่องยนต์
  asset_code       text,                 -- เลขรหัสครุภัณฑ์
  location         text,                 -- ที่ตั้ง (อาคาร/ทรัพย์สิน)
  unit_name        text,                 -- หน่วยงานที่รับผิดชอบ
  is_active        boolean not null default true,
  note             text,
  created_by       uuid,
  updated_by_name  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists idx_ins_assets_org on public.ins_assets(org_id);

create table if not exists public.ins_policies (
  id               uuid primary key default gen_random_uuid(),
  asset_id         uuid not null references public.ins_assets(id) on delete cascade,
  org_id           uuid,
  policy_type      text not null check (policy_type in ('compulsory','voluntary','property','other')),
                   -- compulsory = พ.ร.บ. (ภาคบังคับ) · voluntary = ภาคสมัครใจ · property = อัคคีภัย/ทรัพย์สิน · other = อื่น ๆ
  coverage_class   text,                 -- ชั้นประกัน เช่น ชั้น 1, 2+, 3
  insurer          text not null,        -- บริษัทผู้รับประกัน
  policy_no        text,                 -- เลขที่กรมธรรม์
  start_date       date not null,
  end_date         date not null,
  sum_insured      numeric(14,2) not null default 0 check (sum_insured >= 0),  -- ทุนประกัน
  premium          numeric(12,2) not null default 0 check (premium >= 0),      -- เบี้ยประกัน (รวมภาษีอากร)
  pay_status       text not null default 'pending' check (pay_status in ('pending','paid')),
  doc_no           text,                 -- เลขที่ฎีกา
  doc_date         date,                 -- วันที่วางฎีกา
  note             text,
  created_by       uuid,
  updated_by_name  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (end_date >= start_date)
);
create index if not exists idx_ins_policies_asset on public.ins_policies(asset_id);
create index if not exists idx_ins_policies_end on public.ins_policies(org_id, end_date);

create table if not exists public.ins_claims (
  id               uuid primary key default gen_random_uuid(),
  policy_id        uuid not null references public.ins_policies(id) on delete cascade,
  org_id           uuid,
  incident_date    date not null,
  description      text not null,        -- เหตุ/ความเสียหาย
  claim_no         text,                 -- เลขที่เคลม
  claim_amount     numeric(12,2) not null default 0 check (claim_amount >= 0),   -- ค่าเสียหายที่เรียกร้อง
  paid_amount      numeric(12,2) not null default 0 check (paid_amount >= 0),    -- บริษัทจ่ายแล้ว
  status           text not null default 'open' check (status in ('open','closed','rejected')),
  note             text,
  created_by       uuid,
  updated_by_name  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists idx_ins_claims_policy on public.ins_claims(policy_id);

do $$
declare t text;
begin
  foreach t in array array['ins_assets','ins_policies','ins_claims'] loop
    execute format('drop trigger if exists %I on public.%I', 'trg_' || t || '_updated_at', t);
    execute format('create trigger %I before update on public.%I for each row execute function public.sfh_touch_updated_at()', 'trg_' || t || '_updated_at', t);
  end loop;
end $$;


-- =====================================================================
-- 2) ฟังก์ชัน RPC
-- =====================================================================
drop function if exists public.sfh_ins_list(text);
drop function if exists public.sfh_ins_asset_save(text, uuid, jsonb);
drop function if exists public.sfh_ins_asset_delete(text, uuid);
drop function if exists public.sfh_ins_policy_save(text, uuid, jsonb);
drop function if exists public.sfh_ins_policy_delete(text, uuid);
drop function if exists public.sfh_ins_claim_save(text, uuid, jsonb);
drop function if exists public.sfh_ins_claim_delete(text, uuid);
drop function if exists public.sfh_ins_log(text, text, jsonb);

-- 2.1 ข้อมูลทั้งหมดของหน่วยงาน
create function public.sfh_ins_list(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_super boolean;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_insurance');
  v_super := public.sfh_is_super(v_user);
  return jsonb_build_object(
    'assets',   coalesce((select jsonb_agg(to_jsonb(a) order by a.asset_type, a.name) from public.ins_assets a where v_super or a.org_id = v_user.org_id), '[]'::jsonb),
    'policies', coalesce((select jsonb_agg(to_jsonb(p) order by p.end_date desc) from public.ins_policies p where v_super or p.org_id = v_user.org_id), '[]'::jsonb),
    'claims',   coalesce((select jsonb_agg(to_jsonb(c) order by c.incident_date desc) from public.ins_claims c where v_super or c.org_id = v_user.org_id), '[]'::jsonb));
end $$;

-- 2.2 ทรัพย์สิน
create function public.sfh_ins_asset_save(p_token text, p_id uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_row public.ins_assets%rowtype;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_insurance');
  if coalesce(btrim(p_data->>'name'), '') = '' then raise exception 'กรุณาระบุชื่อทรัพย์สิน'; end if;
  if coalesce(p_data->>'asset_type', '') not in ('vehicle','building','other') then raise exception 'ประเภททรัพย์สินไม่ถูกต้อง'; end if;
  if p_id is null then
    insert into public.ins_assets (org_id, asset_type, name, vehicle_kind, plate_no, plate_province, brand_model, chassis_no, engine_no,
                                   asset_code, location, unit_name, is_active, note, created_by, updated_by_name)
    values (v_user.org_id, p_data->>'asset_type', btrim(p_data->>'name'), p_data->>'vehicle_kind', p_data->>'plate_no', p_data->>'plate_province',
            p_data->>'brand_model', p_data->>'chassis_no', p_data->>'engine_no', p_data->>'asset_code', p_data->>'location', p_data->>'unit_name',
            coalesce((p_data->>'is_active')::boolean, true), p_data->>'note', v_user.id, v_user.full_name)
    returning * into v_row;
  else
    select * into v_row from public.ins_assets where id = p_id;
    if not found then raise exception 'ไม่พบทรัพย์สิน'; end if;
    if v_row.org_id is distinct from v_user.org_id and not public.sfh_is_super(v_user) then raise exception 'FORBIDDEN: org'; end if;
    update public.ins_assets set asset_type = p_data->>'asset_type', name = btrim(p_data->>'name'), vehicle_kind = p_data->>'vehicle_kind',
           plate_no = p_data->>'plate_no', plate_province = p_data->>'plate_province', brand_model = p_data->>'brand_model',
           chassis_no = p_data->>'chassis_no', engine_no = p_data->>'engine_no', asset_code = p_data->>'asset_code', location = p_data->>'location',
           unit_name = p_data->>'unit_name', is_active = coalesce((p_data->>'is_active')::boolean, true), note = p_data->>'note', updated_by_name = v_user.full_name
     where id = p_id returning * into v_row;
  end if;
  perform public.sfh_rent_audit(v_user, case when p_id is null then 'create' else 'update' end, 'ins_assets', v_row.id::text, jsonb_build_object('name', v_row.name, 'plate_no', v_row.plate_no));
  return to_jsonb(v_row);
end $$;

create function public.sfh_ins_asset_delete(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_row public.ins_assets%rowtype;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_insurance');
  select * into v_row from public.ins_assets where id = p_id;
  if not found then return; end if;
  if v_row.org_id is distinct from v_user.org_id and not public.sfh_is_super(v_user) then raise exception 'FORBIDDEN: org'; end if;
  delete from public.ins_assets where id = p_id;
  perform public.sfh_rent_audit(v_user, 'delete', 'ins_assets', p_id::text, jsonb_build_object('name', v_row.name));
end $$;

-- 2.3 กรมธรรม์
create function public.sfh_ins_policy_save(p_token text, p_id uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_asset public.ins_assets%rowtype; v_row public.ins_policies%rowtype; v_start date; v_end date;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_insurance');
  select * into v_asset from public.ins_assets where id = (p_data->>'asset_id')::uuid;
  if not found then raise exception 'ไม่พบทรัพย์สิน'; end if;
  if v_asset.org_id is distinct from v_user.org_id and not public.sfh_is_super(v_user) then raise exception 'FORBIDDEN: org'; end if;
  v_start := nullif(p_data->>'start_date', '')::date; v_end := nullif(p_data->>'end_date', '')::date;
  if coalesce(p_data->>'policy_type', '') not in ('compulsory','voluntary','property','other') then raise exception 'ประเภทกรมธรรม์ไม่ถูกต้อง'; end if;
  if coalesce(btrim(p_data->>'insurer'), '') = '' then raise exception 'กรุณาระบุบริษัทผู้รับประกัน'; end if;
  if v_start is null or v_end is null then raise exception 'กรุณาระบุวันเริ่มและวันสิ้นสุดความคุ้มครอง'; end if;
  if v_end < v_start then raise exception 'วันสิ้นสุดต้องไม่ก่อนวันเริ่มคุ้มครอง'; end if;
  if p_id is null then
    insert into public.ins_policies (asset_id, org_id, policy_type, coverage_class, insurer, policy_no, start_date, end_date, sum_insured, premium,
                                     pay_status, doc_no, doc_date, note, created_by, updated_by_name)
    values (v_asset.id, v_asset.org_id, p_data->>'policy_type', p_data->>'coverage_class', btrim(p_data->>'insurer'), p_data->>'policy_no', v_start, v_end,
            coalesce(nullif(p_data->>'sum_insured', '')::numeric, 0), coalesce(nullif(p_data->>'premium', '')::numeric, 0),
            coalesce(p_data->>'pay_status', 'pending'), p_data->>'doc_no', nullif(p_data->>'doc_date', '')::date, p_data->>'note', v_user.id, v_user.full_name)
    returning * into v_row;
  else
    update public.ins_policies set policy_type = p_data->>'policy_type', coverage_class = p_data->>'coverage_class', insurer = btrim(p_data->>'insurer'),
           policy_no = p_data->>'policy_no', start_date = v_start, end_date = v_end, sum_insured = coalesce(nullif(p_data->>'sum_insured', '')::numeric, 0),
           premium = coalesce(nullif(p_data->>'premium', '')::numeric, 0), pay_status = coalesce(p_data->>'pay_status', 'pending'),
           doc_no = p_data->>'doc_no', doc_date = nullif(p_data->>'doc_date', '')::date, note = p_data->>'note', updated_by_name = v_user.full_name
     where id = p_id and asset_id = v_asset.id returning * into v_row;
    if not found then raise exception 'ไม่พบกรมธรรม์'; end if;
  end if;
  perform public.sfh_rent_audit(v_user, case when p_id is null then 'create' else 'update' end, 'ins_policies', v_row.id::text,
                                jsonb_build_object('asset', v_asset.name, 'type', v_row.policy_type, 'end_date', v_row.end_date, 'premium', v_row.premium));
  return to_jsonb(v_row);
end $$;

create function public.sfh_ins_policy_delete(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_row public.ins_policies%rowtype;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_insurance');
  select * into v_row from public.ins_policies where id = p_id;
  if not found then return; end if;
  if v_row.org_id is distinct from v_user.org_id and not public.sfh_is_super(v_user) then raise exception 'FORBIDDEN: org'; end if;
  delete from public.ins_policies where id = p_id;
  perform public.sfh_rent_audit(v_user, 'delete', 'ins_policies', p_id::text, jsonb_build_object('policy_no', v_row.policy_no, 'end_date', v_row.end_date));
end $$;

-- 2.4 การเคลม
create function public.sfh_ins_claim_save(p_token text, p_id uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_pol public.ins_policies%rowtype; v_row public.ins_claims%rowtype;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_insurance');
  select * into v_pol from public.ins_policies where id = (p_data->>'policy_id')::uuid;
  if not found then raise exception 'ไม่พบกรมธรรม์'; end if;
  if v_pol.org_id is distinct from v_user.org_id and not public.sfh_is_super(v_user) then raise exception 'FORBIDDEN: org'; end if;
  if nullif(p_data->>'incident_date', '') is null then raise exception 'กรุณาระบุวันที่เกิดเหตุ'; end if;
  if coalesce(btrim(p_data->>'description'), '') = '' then raise exception 'กรุณาระบุเหตุ/ความเสียหาย'; end if;
  if p_id is null then
    insert into public.ins_claims (policy_id, org_id, incident_date, description, claim_no, claim_amount, paid_amount, status, note, created_by, updated_by_name)
    values (v_pol.id, v_pol.org_id, (p_data->>'incident_date')::date, btrim(p_data->>'description'), p_data->>'claim_no',
            coalesce(nullif(p_data->>'claim_amount', '')::numeric, 0), coalesce(nullif(p_data->>'paid_amount', '')::numeric, 0),
            coalesce(p_data->>'status', 'open'), p_data->>'note', v_user.id, v_user.full_name)
    returning * into v_row;
  else
    update public.ins_claims set policy_id = v_pol.id, incident_date = (p_data->>'incident_date')::date, description = btrim(p_data->>'description'),
           claim_no = p_data->>'claim_no', claim_amount = coalesce(nullif(p_data->>'claim_amount', '')::numeric, 0),
           paid_amount = coalesce(nullif(p_data->>'paid_amount', '')::numeric, 0), status = coalesce(p_data->>'status', 'open'),
           note = p_data->>'note', updated_by_name = v_user.full_name
     where id = p_id returning * into v_row;
    if not found then raise exception 'ไม่พบรายการเคลม'; end if;
  end if;
  perform public.sfh_rent_audit(v_user, case when p_id is null then 'create' else 'update' end, 'ins_claims', v_row.id::text,
                                jsonb_build_object('policy_no', v_pol.policy_no, 'incident_date', v_row.incident_date, 'status', v_row.status));
  return to_jsonb(v_row);
end $$;

create function public.sfh_ins_claim_delete(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_row public.ins_claims%rowtype;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_insurance');
  select * into v_row from public.ins_claims where id = p_id;
  if not found then return; end if;
  if v_row.org_id is distinct from v_user.org_id and not public.sfh_is_super(v_user) then raise exception 'FORBIDDEN: org'; end if;
  delete from public.ins_claims where id = p_id;
  perform public.sfh_rent_audit(v_user, 'delete', 'ins_claims', p_id::text, jsonb_build_object('incident_date', v_row.incident_date));
end $$;

create function public.sfh_ins_log(p_token text, p_kind text, p_details jsonb)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype;
begin
  v_user := public.sfh_payroll_auth(p_token, 'register.manage_insurance');
  perform public.sfh_rent_audit(v_user, 'export', 'ins_policies', null, coalesce(p_details, '{}'::jsonb) || jsonb_build_object('kind', p_kind));
end $$;


-- =====================================================================
-- 3) Permission + สิทธิ์ของ Role
-- =====================================================================
insert into public.permissions (perm_key, module_key, action, name, description, org_admin_grantable, sort_order) values
 ('register.manage_insurance', 'register', 'manage_insurance', 'ทะเบียนคุมประกันภัย (ดู/บันทึก/แก้ไข/ลบ)', 'กรมธรรม์ประกันภัยรถยนต์ อาคารและทรัพย์สิน', true, 50)
on conflict (perm_key) do update
  set module_key = excluded.module_key, action = excluded.action, name = excluded.name,
      description = excluded.description, org_admin_grantable = excluded.org_admin_grantable, sort_order = excluded.sort_order;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p on p.perm_key = 'register.manage_insurance'
 where r.role_key in ('super_admin','org_admin')
on conflict (role_id, permission_id) do nothing;

update public.modules
   set planned_features = '["ทะเบียนคุมเบิกค่าเช่าบ้าน รายเดือนตามปีงบประมาณ","ทะเบียนคุมเบิกค่าเล่าเรียนบุตร รายภาคเรียนตามปีการศึกษา","ทะเบียนคุมประกันภัย รถยนต์ อาคารและทรัพย์สิน พร้อมแจ้งเตือนกรมธรรม์ใกล้หมดอายุ","ดึงรายชื่อข้าราชการจากสลิปเงินเดือน","พิมพ์ทะเบียน / PDF / Excel"]'::jsonb
 where module_key = 'register';


-- =====================================================================
-- 4) RLS + สิทธิ์
-- =====================================================================
alter table public.ins_assets   enable row level security;
alter table public.ins_policies enable row level security;
alter table public.ins_claims   enable row level security;
revoke all on public.ins_assets, public.ins_policies, public.ins_claims from anon, authenticated;

grant execute on function public.sfh_ins_list(text)                     to anon, authenticated;
grant execute on function public.sfh_ins_asset_save(text, uuid, jsonb)  to anon, authenticated;
grant execute on function public.sfh_ins_asset_delete(text, uuid)       to anon, authenticated;
grant execute on function public.sfh_ins_policy_save(text, uuid, jsonb) to anon, authenticated;
grant execute on function public.sfh_ins_policy_delete(text, uuid)      to anon, authenticated;
grant execute on function public.sfh_ins_claim_save(text, uuid, jsonb)  to anon, authenticated;
grant execute on function public.sfh_ins_claim_delete(text, uuid)       to anon, authenticated;
grant execute on function public.sfh_ins_log(text, text, jsonb)         to anon, authenticated;
