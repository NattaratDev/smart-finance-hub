-- =====================================================================
--  Smart Finance Hub (SFH) – โมดูล: โปรแกรมคำนวณค่าใช้จ่ายไปราชการ / ไปฝึกอบรม
--  ไฟล์ : module_travel.sql   (รันต่อจาก database.sql)
--
--  วิธีใช้ : Supabase > SQL Editor > New query > วางทั้งไฟล์ > Run
--  รันซ้ำได้โดยไม่ error (ไม่ทับอัตราที่ผู้ดูแลแก้ไขไว้แล้ว)
--
--  สารบัญ
--   1) ตาราง travel_rate_sets (ชุดอัตรา + กฎการคำนวณ เก็บเป็น JSON แก้ไขได้จากหน้าเว็บ)
--   2) ชุดอัตราเริ่มต้น ตามระเบียบกระทรวงมหาดไทยว่าด้วยค่าใช้จ่ายในการเดินทางไปราชการ
--      ของเจ้าหน้าที่ท้องถิ่น พ.ศ. 2555 แก้ไขเพิ่มเติมถึง (ฉบับที่ 4) พ.ศ. 2561
--   3) เปิดโมดูล + สิทธิ์ (Org Admin แก้ไขอัตราได้)
--   4) RLS + สิทธิ์
--
--  หลักการ
--   - เป็นเครื่องคำนวณ ไม่บันทึกข้อมูลผู้เดินทางหรือผลการคำนวณลงฐานข้อมูล
--   - บุคคลทั่วไปใช้คำนวณได้ (travel.use_public) · Super Admin / Org Admin แก้ไขอัตรา (travel.manage_rates)
--   - ชุดอัตรามี "วันที่มีผล" → ระบบเลือกชุดที่มีผล ณ วันออกเดินทางให้อัตโนมัติ
-- =====================================================================
set search_path = public, extensions;


-- =====================================================================
-- 1) ตาราง
-- =====================================================================
create table if not exists public.travel_rate_sets (
  id               uuid primary key default gen_random_uuid(),
  name             text not null,
  reference        text,                 -- ระเบียบ/หนังสือสั่งการที่อ้างอิง
  effective_from   date,                 -- ว่าง = ใช้ได้ทุกวันที่ (ชุดตั้งต้น)
  is_active        boolean not null default true,
  config           jsonb not null,       -- กลุ่มตำแหน่ง อัตรา กฎนับวัน ค่าพาหนะ การหักมื้ออาหาร
  note             text,
  created_by       uuid,
  created_by_name  text,
  updated_by_name  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists idx_travel_rate_sets_eff on public.travel_rate_sets(effective_from);

drop trigger if exists trg_travel_rate_sets_updated_at on public.travel_rate_sets;
create trigger trg_travel_rate_sets_updated_at before update on public.travel_rate_sets
  for each row execute function public.sfh_touch_updated_at();


-- =====================================================================
-- 2) ชุดอัตราเริ่มต้น
--    บัญชีหมายเลข 1 (เบี้ยเลี้ยง) และบัญชีหมายเลข 2 (ค่าเช่าที่พัก) – ตามไฟล์ระเบียบ
--    กฎนับวัน / ค่าพาหนะส่วนตัว / การหักมื้ออาหารเมื่อไปฝึกอบรม – ค่าเริ่มต้น ตรวจสอบและแก้ไขได้ที่หน้า "อัตราที่ใช้"
-- =====================================================================
insert into public.travel_rate_sets (id, name, reference, effective_from, is_active, config, note, created_by_name) values
 ('eeeeeeee-0000-0000-0000-000000000001',
  'อัตราตามระเบียบ มท. พ.ศ. 2555 (แก้ไขถึงฉบับที่ 4 พ.ศ. 2561)',
  'ระเบียบกระทรวงมหาดไทยว่าด้วยค่าใช้จ่ายในการเดินทางไปราชการของเจ้าหน้าที่ท้องถิ่น พ.ศ. 2555 แก้ไขเพิ่มเติมถึง (ฉบับที่ 4) พ.ศ. 2561 – บัญชีหมายเลข 1 และ 2',
  null, true,
  $json${
    "groups": [
      { "key": "A", "name": "กลุ่ม ก",
        "desc": "ตำแหน่งประเภททั่วไป · ประเภทวิชาการตั้งแต่ระดับชำนาญการพิเศษลงมา · ประเภทอำนวยการท้องถิ่นตั้งแต่ระดับกลางลงมา · ประเภทบริหารท้องถิ่นตั้งแต่ระดับกลางลงมา · หรือตำแหน่งตั้งแต่ระดับ 8 ลงมา หรือเทียบเท่า",
        "allowance": 240, "lodging_single": 1500, "lodging_double": 850, "lodging_lump": 800,
        "choose_room": false, "head_extra": false },
      { "key": "B", "name": "กลุ่ม ข",
        "desc": "ตำแหน่งประเภทวิชาการระดับเชี่ยวชาญ · ประเภทอำนวยการท้องถิ่นระดับสูง · หรือตำแหน่งระดับ 9 หรือเทียบเท่า",
        "allowance": 270, "lodging_single": 2200, "lodging_double": 1200, "lodging_lump": 1200,
        "choose_room": true, "head_extra": false },
      { "key": "C", "name": "กลุ่ม ค",
        "desc": "ตำแหน่งประเภทบริหารท้องถิ่นระดับสูง · หรือตำแหน่งตั้งแต่ระดับ 10 ขึ้นไป หรือเทียบเท่า",
        "allowance": 270, "lodging_single": 2500, "lodging_double": 1400, "lodging_lump": 1200,
        "choose_room": true, "head_extra": true }
    ],
    "day_rules": { "day_hours": 24, "overnight_full_over": 12, "noovernight_full_over": 12, "noovernight_half_over": 6 },
    "high_cost_pct": 25,
    "vehicles": [
      { "key": "car",   "name": "รถยนต์ส่วนบุคคล",        "mode": "km", "rate": 4 },
      { "key": "moto",  "name": "รถจักรยานยนต์ส่วนบุคคล",  "mode": "km", "rate": 2 },
      { "key": "bus",   "name": "รถโดยสารประจำทาง",       "mode": "actual" },
      { "key": "train", "name": "รถไฟ",                  "mode": "actual" },
      { "key": "taxi",  "name": "รถรับจ้าง",               "mode": "actual" },
      { "key": "air",   "name": "เครื่องบิน",              "mode": "actual" },
      { "key": "other", "name": "พาหนะอื่น ๆ",             "mode": "actual" }
    ],
    "training": { "meal_divisor": 3 }
  }$json$::jsonb,
  'กฎนับวัน อัตราค่าพาหนะส่วนตัว และการหักมื้ออาหาร (ฝึกอบรม) เป็นค่าเริ่มต้น กรุณาตรวจสอบกับระเบียบฉบับเต็มก่อนใช้งานจริง',
  'ระบบ')
on conflict (id) do nothing;


-- =====================================================================
-- 3) เปิดโมดูล + สิทธิ์
-- =====================================================================
update public.modules
   set status = 'active', version = '1.0.0',
       description = 'คำนวณเบี้ยเลี้ยง ค่าที่พัก ค่าพาหนะ และค่าใช้จ่ายรวมในการเดินทางไปราชการและไปฝึกอบรม ทั้งแบบคนเดียวและหมู่คณะ ตามระเบียบกระทรวงมหาดไทย',
       planned_features = '["คำนวณเบี้ยเลี้ยงตามกฎนับวัน (พักแรม/ไม่พักแรม)","คำนวณค่าที่พักแบบจ่ายจริงและเหมาจ่าย","คำนวณค่าพาหนะส่วนตัวตามระยะทาง","รวมค่าใช้จ่ายไปราชการ/ไปฝึกอบรม (ค่าลงทะเบียน ค่าใช้จ่ายอื่น)","รองรับคนเดียวและหมู่คณะ พร้อมพิมพ์สรุป"]'::jsonb
 where module_key = 'travel';

update public.permissions set org_admin_grantable = true,
       description = 'แก้ไขอัตราเบี้ยเลี้ยง/ที่พัก/พาหนะ และกฎการคำนวณ'
 where perm_key = 'travel.manage_rates';

-- Org Admin แก้ไขอัตราได้ (Super Admin ได้ทุกสิทธิ์อยู่แล้ว)
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p on p.perm_key = 'travel.manage_rates'
 where r.role_key in ('super_admin','org_admin')
on conflict (role_id, permission_id) do nothing;


-- =====================================================================
-- 4) RLS + สิทธิ์
-- =====================================================================
alter table public.travel_rate_sets enable row level security;
drop policy if exists travel_rate_sets_select on public.travel_rate_sets;
drop policy if exists travel_rate_sets_insert on public.travel_rate_sets;
drop policy if exists travel_rate_sets_update on public.travel_rate_sets;
drop policy if exists travel_rate_sets_delete on public.travel_rate_sets;
create policy travel_rate_sets_select on public.travel_rate_sets for select to anon, authenticated using (true);
create policy travel_rate_sets_insert on public.travel_rate_sets for insert to anon, authenticated with check (true);
create policy travel_rate_sets_update on public.travel_rate_sets for update to anon, authenticated using (true) with check (true);
create policy travel_rate_sets_delete on public.travel_rate_sets for delete to anon, authenticated using (true);
grant select, insert, update, delete on public.travel_rate_sets to anon, authenticated;

-- ---------------------------------------------------------------------
-- ⚠️ หมายเหตุ: Policy แบบ true ใช้เพื่อการสอน/ทดสอบ
--   การจำกัดว่าเฉพาะ Super Admin / Org Admin แก้ไขอัตราได้ ทำในหน้าเว็บ (travel.manage_rates)
--   ถ้าใช้งานจริงควรย้ายการแก้ไขอัตราไปเป็น RPC ที่ตรวจ session token แบบโมดูลสลิปเงินเดือน
-- ---------------------------------------------------------------------
