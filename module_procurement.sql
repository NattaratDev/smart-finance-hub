-- =====================================================================
--  Smart Finance Hub (SFH) – โมดูล: งานจัดซื้อจัดจ้างภาครัฐ วงเงินไม่เกิน 5,000 บาท
--  ไฟล์ : module_procurement.sql   (รันต่อจาก module_register_insurance.sql / รันซ้ำได้)
--  - บุคคลทั่วไปใช้งานได้ (ข้อมูลเก็บในเบราว์เซอร์ของผู้ใช้เอง ไม่ผ่านฐานข้อมูล)
--  - เจ้าหน้าที่ที่เข้าสู่ระบบ: บันทึกโครงการ/ร้านค้า/ค่าเริ่มต้นของหน่วยงาน ผ่าน RPC sfh_proc_* (ตรวจ session token + procurement.save)
--  - โครงการเก็บย้อนหลัง 3 เดือน นับจากแก้ไขล่าสุด (ลบอัตโนมัติเมื่อเปิดรายการ) · ร้านค้าเก็บจนกว่าจะลบ
-- =====================================================================

-- =====================================================================
-- 1) ตาราง
-- =====================================================================
create table if not exists public.proc_settings (          -- ค่าเริ่มต้นของหน่วยงาน (ข้อมูลหน่วยงาน + เจ้าหน้าที่)
  org_id           uuid primary key references public.organizations(id) on delete cascade,
  data             jsonb not null default '{}'::jsonb,
  updated_by_name  text,
  updated_at       timestamptz not null default now()
);

create table if not exists public.proc_vendors (           -- ทะเบียนร้านค้า/ผู้รับจ้าง (เก็บจนกว่าจะลบ)
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid references public.organizations(id) on delete cascade,
  name             text not null,
  tax_id           text,
  address          text,
  phone            text,
  data             jsonb not null default '{}'::jsonb,       -- ข้อมูลอื่น เช่น บัญชีธนาคาร
  updated_by_name  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists idx_proc_vendors_org on public.proc_vendors(org_id, name);

create table if not exists public.proc_projects (          -- โครงการจัดซื้อจัดจ้าง (เก็บ 3 เดือนนับจากแก้ไขล่าสุด)
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid references public.organizations(id) on delete cascade,
  fiscal_year      int  not null,                           -- ปีงบประมาณ (พ.ศ.) ตามวันที่รายงานขอซื้อขอจ้าง
  seq              int  not null,                           -- ลำดับโครงการในปีงบ ของหน่วยงาน
  kind             text not null check (kind in ('buy','hire')),
  title            text not null,
  vendor_name      text,
  total            numeric(12,2) not null default 0 check (total >= 0 and total <= 5000),
  data             jsonb not null default '{}'::jsonb,       -- ข้อมูลแบบฟอร์มทั้งหมด
  created_by       uuid,
  created_by_name  text,
  updated_by_name  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (org_id, fiscal_year, seq)
);
create index if not exists idx_proc_projects_org on public.proc_projects(org_id, updated_at desc);

do $$
declare t text;
begin
  foreach t in array array['proc_vendors','proc_projects'] loop
    execute format('drop trigger if exists %I on public.%I', 'trg_' || t || '_updated_at', t);
    execute format('create trigger %I before update on public.%I for each row execute function public.sfh_touch_updated_at()', 'trg_' || t || '_updated_at', t);
  end loop;
end $$;


-- =====================================================================
-- 2) ฟังก์ชัน RPC
-- =====================================================================
drop function if exists public.sfh_proc_list(text);
drop function if exists public.sfh_proc_save(text, uuid, jsonb);
drop function if exists public.sfh_proc_delete(text, uuid);
drop function if exists public.sfh_proc_vendor_save(text, uuid, jsonb);
drop function if exists public.sfh_proc_vendor_delete(text, uuid);
drop function if exists public.sfh_proc_settings_save(text, jsonb);
drop function if exists public.sfh_proc_total(jsonb);

-- ยอดรวมจากรายการ (ลิตร/จำนวน × ราคา) + ภาษีมูลค่าเพิ่มกรณีบวกเพิ่ม 7%
create function public.sfh_proc_total(p_data jsonb)
returns numeric language sql immutable as $$
  select round(coalesce(sum(coalesce(nullif(i->>'qty', '')::numeric, 0) * coalesce(nullif(i->>'price', '')::numeric, 0)), 0)
               * case when p_data->>'vat' = 'add' then 1.07 else 1 end, 2)
    from jsonb_array_elements(coalesce(p_data->'items', '[]'::jsonb)) i;
$$;

-- 2.1 รายการทั้งหมดของหน่วยงาน (ลบโครงการที่ไม่ได้แก้ไขเกิน 3 เดือนก่อน)
create function public.sfh_proc_list(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_super boolean; v_n int;
begin
  v_user := public.sfh_payroll_auth(p_token, 'procurement.save');
  v_super := public.sfh_is_super(v_user);
  delete from public.proc_projects where org_id = v_user.org_id and updated_at < now() - interval '3 months';
  get diagnostics v_n = row_count;
  if v_n > 0 then
    perform public.sfh_rent_audit(v_user, 'delete', 'proc_projects', null, jsonb_build_object('auto_expire', v_n, 'older_than', '3 months'));
  end if;
  return jsonb_build_object(
    'settings', coalesce((select data from public.proc_settings where org_id = v_user.org_id), '{}'::jsonb),
    'vendors',  coalesce((select jsonb_agg(to_jsonb(v) order by v.name) from public.proc_vendors v where v_super or v.org_id = v_user.org_id), '[]'::jsonb),
    'projects', coalesce((select jsonb_agg(to_jsonb(p) order by p.updated_at desc) from public.proc_projects p where v_super or p.org_id = v_user.org_id), '[]'::jsonb));
end $$;

-- 2.2 บันทึกโครงการ (ใหม่ = ออกลำดับที่ในปีงบ)
create function public.sfh_proc_save(p_token text, p_id uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_row public.proc_projects%rowtype; v_fy int; v_total numeric; v_seq int; v_kind text; v_title text;
begin
  v_user := public.sfh_payroll_auth(p_token, 'procurement.save');
  v_kind := coalesce(p_data->>'kind', 'buy');
  if v_kind not in ('buy','hire') then raise exception 'ประเภทไม่ถูกต้อง'; end if;
  v_title := btrim(coalesce(p_data->>'subject', ''));
  if v_title = '' then raise exception 'กรุณาระบุชื่อเรื่อง/รายการที่จะซื้อหรือจ้าง'; end if;
  v_total := public.sfh_proc_total(p_data);
  if v_total > 5000 then raise exception 'วงเงินรวม % บาท เกิน 5,000 บาท', to_char(v_total, 'FM999,999,990.00'); end if;
  v_fy := nullif(p_data->>'fy', '')::int;
  if v_fy is null or v_fy < 2500 or v_fy > 2700 then raise exception 'ปีงบประมาณไม่ถูกต้อง'; end if;
  if p_id is null then
    perform pg_advisory_xact_lock(hashtext('proc:' || coalesce(v_user.org_id::text, '-') || ':' || v_fy));
    select coalesce(max(seq), 0) + 1 into v_seq from public.proc_projects where org_id is not distinct from v_user.org_id and fiscal_year = v_fy;
    insert into public.proc_projects (org_id, fiscal_year, seq, kind, title, vendor_name, total, data, created_by, created_by_name, updated_by_name)
    values (v_user.org_id, v_fy, v_seq, v_kind, v_title, nullif(btrim(p_data#>>'{vendor,name}'), ''), v_total, p_data, v_user.id, v_user.full_name, v_user.full_name)
    returning * into v_row;
  else
    select * into v_row from public.proc_projects where id = p_id;
    if not found then raise exception 'ไม่พบโครงการ (อาจถูกลบเนื่องจากเกิน 3 เดือน)'; end if;
    if v_row.org_id is distinct from v_user.org_id and not public.sfh_is_super(v_user) then raise exception 'FORBIDDEN: org'; end if;
    if v_fy <> v_row.fiscal_year then        -- เปลี่ยนปีงบ → ออกลำดับใหม่ในปีงบนั้น
      perform pg_advisory_xact_lock(hashtext('proc:' || coalesce(v_row.org_id::text, '-') || ':' || v_fy));
      select coalesce(max(seq), 0) + 1 into v_seq from public.proc_projects where org_id is not distinct from v_row.org_id and fiscal_year = v_fy;
    else v_seq := v_row.seq; end if;
    update public.proc_projects set fiscal_year = v_fy, seq = v_seq, kind = v_kind, title = v_title, vendor_name = nullif(btrim(p_data#>>'{vendor,name}'), ''),
           total = v_total, data = p_data, updated_by_name = v_user.full_name
     where id = p_id returning * into v_row;
  end if;
  perform public.sfh_rent_audit(v_user, case when p_id is null then 'create' else 'update' end, 'proc_projects', v_row.id::text,
                                jsonb_build_object('title', v_row.title, 'seq', v_row.seq || '/' || v_row.fiscal_year, 'total', v_row.total));
  return to_jsonb(v_row);
end $$;

create function public.sfh_proc_delete(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_row public.proc_projects%rowtype;
begin
  v_user := public.sfh_payroll_auth(p_token, 'procurement.save');
  select * into v_row from public.proc_projects where id = p_id;
  if not found then return; end if;
  if v_row.org_id is distinct from v_user.org_id and not public.sfh_is_super(v_user) then raise exception 'FORBIDDEN: org'; end if;
  delete from public.proc_projects where id = p_id;
  perform public.sfh_rent_audit(v_user, 'delete', 'proc_projects', p_id::text, jsonb_build_object('title', v_row.title, 'seq', v_row.seq || '/' || v_row.fiscal_year));
end $$;

-- 2.3 ร้านค้า/ผู้รับจ้าง
create function public.sfh_proc_vendor_save(p_token text, p_id uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_row public.proc_vendors%rowtype; v_name text;
begin
  v_user := public.sfh_payroll_auth(p_token, 'procurement.save');
  v_name := btrim(coalesce(p_data->>'name', ''));
  if v_name = '' then raise exception 'กรุณาระบุชื่อร้านค้า/ผู้รับจ้าง'; end if;
  if p_id is null then
    select * into v_row from public.proc_vendors where org_id is not distinct from v_user.org_id and lower(name) = lower(v_name) limit 1;
    if found then p_id := v_row.id; end if;      -- ชื่อซ้ำ → ปรับปรุงรายการเดิม
  end if;
  if p_id is null then
    insert into public.proc_vendors (org_id, name, tax_id, address, phone, data, updated_by_name)
    values (v_user.org_id, v_name, nullif(btrim(p_data->>'tax_id'), ''), nullif(btrim(p_data->>'address'), ''), nullif(btrim(p_data->>'phone'), ''),
            coalesce(p_data->'data', '{}'::jsonb), v_user.full_name)
    returning * into v_row;
  else
    select * into v_row from public.proc_vendors where id = p_id;
    if not found then raise exception 'ไม่พบร้านค้า'; end if;
    if v_row.org_id is distinct from v_user.org_id and not public.sfh_is_super(v_user) then raise exception 'FORBIDDEN: org'; end if;
    update public.proc_vendors set name = v_name, tax_id = nullif(btrim(p_data->>'tax_id'), ''), address = nullif(btrim(p_data->>'address'), ''),
           phone = nullif(btrim(p_data->>'phone'), ''), data = coalesce(p_data->'data', '{}'::jsonb), updated_by_name = v_user.full_name
     where id = p_id returning * into v_row;
  end if;
  perform public.sfh_rent_audit(v_user, 'update', 'proc_vendors', v_row.id::text, jsonb_build_object('name', v_row.name));
  return to_jsonb(v_row);
end $$;

create function public.sfh_proc_vendor_delete(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype; v_row public.proc_vendors%rowtype;
begin
  v_user := public.sfh_payroll_auth(p_token, 'procurement.save');
  select * into v_row from public.proc_vendors where id = p_id;
  if not found then return; end if;
  if v_row.org_id is distinct from v_user.org_id and not public.sfh_is_super(v_user) then raise exception 'FORBIDDEN: org'; end if;
  delete from public.proc_vendors where id = p_id;
  perform public.sfh_rent_audit(v_user, 'delete', 'proc_vendors', p_id::text, jsonb_build_object('name', v_row.name));
end $$;

-- 2.4 ค่าเริ่มต้นของหน่วยงาน (ข้อมูลหน่วยงาน + เจ้าหน้าที่/ผู้อนุมัติ)
create function public.sfh_proc_settings_save(p_token text, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_user public.users%rowtype;
begin
  v_user := public.sfh_payroll_auth(p_token, 'procurement.save');
  if v_user.org_id is null then raise exception 'บัญชีนี้ไม่ได้สังกัดหน่วยงาน'; end if;
  insert into public.proc_settings (org_id, data, updated_by_name, updated_at) values (v_user.org_id, coalesce(p_data, '{}'::jsonb), v_user.full_name, now())
  on conflict (org_id) do update set data = excluded.data, updated_by_name = excluded.updated_by_name, updated_at = now();
  perform public.sfh_rent_audit(v_user, 'update', 'proc_settings', v_user.org_id::text, '{}'::jsonb);
  return p_data;
end $$;


-- =====================================================================
-- 3) โมดูล + เมนู + Permission
-- =====================================================================
insert into public.modules (module_key, name, description, icon, color, status, allow_guest, guest_locked, is_core, sort_order, version, planned_features)
select 'procurement', 'งานจัดซื้อจัดจ้าง (วงเงินไม่เกิน 5,000 บาท)',
       'จัดทำเอกสารจัดซื้อจัดจ้างวิธีเฉพาะเจาะจง วงเงินไม่เกิน 5,000 บาท ครบชุด 8 ฉบับ แสดงตัวอย่างหนังสือ A4 ตามหลักงานสารบรรณ พิมพ์ / PDF / Word',
       'shopping-cart', '#E58FB1', 'active', true, false, false, 13, '1.0.0',
       '["รายงานขอซื้อขอจ้าง","คำสั่งแต่งตั้งผู้กำหนดร่างขอบเขตของงาน/รายละเอียดคุณลักษณะเฉพาะ","คำสั่งแต่งตั้งผู้ตรวจรับพัสดุ","รายงานผลการพิจารณา","ประกาศผู้ชนะการเสนอราคา","ใบสั่งซื้อ/สั่งจ้าง","ใบตรวจรับพัสดุ","บันทึกขออนุมัติเบิกจ่ายเงิน"]'::jsonb
 where not exists (select 1 from public.modules where module_key = 'procurement');
update public.modules set status = 'active', allow_guest = true, guest_locked = false where module_key = 'procurement';

insert into public.menus (menu_key, label, icon, module_key, required_permission, public_permission, sort_order, is_active, show_on_mobile, menu_group, description)
select 'procurement', 'จัดซื้อจัดจ้าง ≤ 5,000', 'shopping-cart', 'procurement', 'procurement.use_public', 'procurement.use_public', 13, true, true, 'module',
       'จัดทำเอกสารจัดซื้อจัดจ้าง วงเงินไม่เกิน 5,000 บาท'
 where not exists (select 1 from public.menus where menu_key = 'procurement');

insert into public.permissions (perm_key, module_key, action, name, description, org_admin_grantable, sort_order) values   -- is_public คำนวณอัตโนมัติ (generated)
 ('procurement.use_public', 'procurement', 'use_public', 'ใช้งานจัดทำเอกสารจัดซื้อจัดจ้าง (≤ 5,000 บาท)', 'บุคคลทั่วไปใช้ได้ · ข้อมูลเก็บในเบราว์เซอร์ของผู้ใช้', true, 60),
 ('procurement.save', 'procurement', 'save', 'บันทึกโครงการ/ร้านค้าจัดซื้อจัดจ้างของหน่วยงาน', 'เก็บโครงการ 3 เดือน · ร้านค้าเก็บจนกว่าจะลบ', true, 61)
on conflict (perm_key) do update
  set module_key = excluded.module_key, action = excluded.action, name = excluded.name, description = excluded.description,
      org_admin_grantable = excluded.org_admin_grantable, sort_order = excluded.sort_order;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p on p.perm_key = 'procurement.use_public'
 where r.role_key in ('guest','staff','org_admin','super_admin')
on conflict (role_id, permission_id) do nothing;
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p on p.perm_key = 'procurement.save'
 where r.role_key in ('staff','org_admin','super_admin')
on conflict (role_id, permission_id) do nothing;


-- =====================================================================
-- 4) RLS + สิทธิ์ (ตารางปิดการเข้าถึงตรง ใช้ผ่าน RPC เท่านั้น)
-- =====================================================================
alter table public.proc_settings enable row level security;
alter table public.proc_vendors  enable row level security;
alter table public.proc_projects enable row level security;
revoke all on public.proc_settings, public.proc_vendors, public.proc_projects from anon, authenticated;

grant execute on function public.sfh_proc_list(text)                    to anon, authenticated;
grant execute on function public.sfh_proc_save(text, uuid, jsonb)       to anon, authenticated;
grant execute on function public.sfh_proc_delete(text, uuid)            to anon, authenticated;
grant execute on function public.sfh_proc_vendor_save(text, uuid, jsonb) to anon, authenticated;
grant execute on function public.sfh_proc_vendor_delete(text, uuid)     to anon, authenticated;
grant execute on function public.sfh_proc_settings_save(text, jsonb)    to anon, authenticated;
revoke execute on function public.sfh_proc_total(jsonb) from public, anon, authenticated;
