-- =====================================================================
--  Smart Finance Hub (SFH) – ศูนย์กลางการเงินการคลังดิจิทัล
--  หน่วยงาน : กองคลัง เทศบาลเมืองศรีสัชนาลัย
--  ไฟล์     : database.sql  (Phase 1 – ระบบแกนกลาง)
--
--  วิธีใช้ : Supabase Dashboard > SQL Editor > New query > วางทั้งไฟล์ > Run
--  รันซ้ำได้โดยไม่ error (ใช้ IF NOT EXISTS / DROP ... IF EXISTS / ON CONFLICT)
--
--  สารบัญ
--   0) Extension
--   1) ตารางระบบ (12 ตาราง)
--   2) Trigger กลาง (updated_at, ป้องกัน Role ระบบ, ป้องกันสิทธิ์ Guest)
--   3) ฟังก์ชัน RPC (Custom Login)
--   4) ข้อมูลตัวอย่าง
--   5) View สำหรับข้อมูลสาธารณะ
--   6) RLS + สิทธิ์การเข้าถึง
--   7) Storage (bucket sfh-files)
--   8) หมายเหตุด้านความปลอดภัย (อ่านก่อนใช้งานจริง)
-- =====================================================================


-- =====================================================================
-- 0) EXTENSION
-- =====================================================================
create extension if not exists pgcrypto with schema extensions;
set search_path = public, extensions;


-- =====================================================================
-- 1) ตารางระบบ
-- =====================================================================

-- 1.1 หน่วยงาน
create table if not exists public.organizations (
  id           uuid primary key default gen_random_uuid(),
  code         text not null unique,
  name         text not null,
  short_name   text,
  address      text,
  phone        text,
  email        text,
  description  text,
  is_active    boolean not null default true,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- 1.2 Role (กลุ่มผู้ใช้งาน)
create table if not exists public.roles (
  id           uuid primary key default gen_random_uuid(),
  role_key     text not null unique,
  name         text not null,
  description  text,
  level        int  not null default 10,          -- ใช้เทียบลำดับชั้น (super_admin 100, org_admin 50, staff 10, guest 0)
  color        text not null default '#5AA9E6',
  is_system    boolean not null default false,    -- Role ระบบ: ห้ามลบ ห้ามเปลี่ยนชื่อ
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- 1.3 ผู้ใช้งาน (ไม่เก็บรหัสผ่านในตารางนี้)
create table if not exists public.users (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid references public.organizations(id) on delete restrict,
  role_id        uuid not null references public.roles(id) on delete restrict,
  username       text not null unique,
  full_name      text not null,
  position       text,
  email          text,
  phone          text,
  avatar_url     text,
  is_active      boolean not null default true,
  last_login_at  timestamptz,
  created_by     uuid,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index if not exists idx_users_org  on public.users(org_id);
create index if not exists idx_users_role on public.users(role_id);

-- 1.4 รหัสผ่าน (แยกตาราง + เปิด RLS แต่ไม่มี Policy → หน้าเว็บอ่านไม่ได้)
create table if not exists public.user_credentials (
  id                   uuid primary key default gen_random_uuid(),
  user_id              uuid not null unique references public.users(id) on delete cascade,
  password_hash        text not null,
  password_changed_at  timestamptz not null default now(),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

-- 1.5 โมดูล
create table if not exists public.modules (
  id                uuid primary key default gen_random_uuid(),
  module_key        text not null unique,
  name              text not null,
  description       text,
  icon              text not null default 'box',
  color             text not null default '#5AA9E6',
  status            text not null default 'coming_soon'
                    check (status in ('active','coming_soon','disabled')),
  allow_guest       boolean not null default false,
  guest_locked      boolean not null default false,  -- true = ห้ามเปิดให้ Guest เด็ดขาด
  is_core           boolean not null default false,
  sort_order        int not null default 100,
  version           text not null default '0.1.0',
  planned_features  jsonb not null default '[]'::jsonb,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

-- 1.6 Permission รูปแบบ <module>.<action>
create table if not exists public.permissions (
  id                   uuid primary key default gen_random_uuid(),
  perm_key             text not null unique,
  module_key           text not null,
  action               text not null,
  name                 text not null,
  description          text,
  is_public            boolean generated always as (action in ('view_public','use_public')) stored,
  org_admin_grantable  boolean not null default false, -- Super Admin อนุญาตให้ Org Admin มอบสิทธิ์นี้ได้
  sort_order           int not null default 100,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

-- 1.7 สิทธิ์ของ Role
create table if not exists public.role_permissions (
  id             uuid primary key default gen_random_uuid(),
  role_id        uuid not null references public.roles(id) on delete cascade,
  permission_id  uuid not null references public.permissions(id) on delete cascade,
  created_by     uuid,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (role_id, permission_id)
);

-- 1.8 สิทธิ์รายบุคคล (เพิ่มจาก Role)
create table if not exists public.user_permissions (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references public.users(id) on delete cascade,
  permission_id  uuid not null references public.permissions(id) on delete cascade,
  org_id         uuid,
  created_by     uuid,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (user_id, permission_id)
);

-- 1.9 เมนู (Sidebar / Bottom Nav สร้างจากตารางนี้ทั้งหมด)
create table if not exists public.menus (
  id                   uuid primary key default gen_random_uuid(),
  menu_key             text not null unique,
  label                text not null,
  icon                 text not null default 'circle',   -- ชื่อไอคอน Lucide
  module_key           text,
  required_permission  text,        -- สิทธิ์ที่ผู้ Login ต้องมี (null = ผู้ Login ทุกคน)
  public_permission    text,        -- สิทธิ์ของ Role guest ที่ใช้เปิดเมนูนี้ให้บุคคลทั่วไป
  sort_order           int not null default 100,
  is_active            boolean not null default true,
  show_on_mobile       boolean not null default true,
  menu_group           text not null default 'main' check (menu_group in ('main','module','admin')),
  description          text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

-- 1.10 ตั้งค่าระบบ (org_id = null คือระดับ Platform)
create table if not exists public.system_settings (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid references public.organizations(id) on delete cascade,
  setting_key    text not null,
  setting_value  text,
  value_type     text not null default 'text',
  label          text,
  description    text,
  is_public      boolean not null default false,
  created_by     uuid,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create unique index if not exists ux_system_settings_scope_key
  on public.system_settings (coalesce(org_id, '00000000-0000-0000-0000-000000000000'::uuid), setting_key);

-- 1.11 Audit Log
create table if not exists public.audit_logs (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid,
  user_id     uuid,
  username    text,
  action      text not null,
  table_name  text,
  record_id   text,
  details     jsonb not null default '{}'::jsonb,
  user_agent  text,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists idx_audit_created on public.audit_logs(created_at desc);
create index if not exists idx_audit_org     on public.audit_logs(org_id);
create index if not exists idx_audit_action  on public.audit_logs(action);

-- 1.12 ข่าวสาร/ประกาศ
create table if not exists public.announcements (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid references public.organizations(id) on delete set null,
  title         text not null,
  content       text not null default '',
  cover_url     text,
  cover_path    text,                  -- path ใน Storage ใช้ลบไฟล์เก่าเมื่อเปลี่ยนรูป
  category      text not null default 'ประชาสัมพันธ์',
  is_public     boolean not null default true,
  is_pinned     boolean not null default false,
  published_at  timestamptz not null default now(),
  created_by    uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists idx_announcements_pub on public.announcements(published_at desc);
create index if not exists idx_announcements_org on public.announcements(org_id);


-- =====================================================================
-- 2) TRIGGER กลาง
-- =====================================================================

-- 2.1 อัปเดต updated_at อัตโนมัติ
create or replace function public.sfh_touch_updated_at()
returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['organizations','roles','users','user_credentials','modules','permissions',
                           'role_permissions','user_permissions','menus','system_settings','audit_logs','announcements']
  loop
    execute format('drop trigger if exists trg_%s_updated_at on public.%I', t, t);
    execute format('create trigger trg_%s_updated_at before update on public.%I
                    for each row execute function public.sfh_touch_updated_at()', t, t);
  end loop;
end $$;

-- 2.2 ป้องกัน Role ระบบ (ห้ามลบ / ห้ามเปลี่ยนชื่อหรือรหัส)
create or replace function public.sfh_protect_system_roles()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    if old.is_system then
      raise exception 'ไม่สามารถลบ Role ระบบ "%" ได้', old.name;
    end if;
    return old;
  end if;
  if old.is_system and (new.role_key is distinct from old.role_key
                        or new.name is distinct from old.name
                        or new.is_system is distinct from old.is_system) then
    raise exception 'ไม่สามารถเปลี่ยนชื่อหรือรหัสของ Role ระบบ "%" ได้', old.name;
  end if;
  return new;
end $$;

drop trigger if exists trg_roles_protect on public.roles;
create trigger trg_roles_protect before update or delete on public.roles
  for each row execute function public.sfh_protect_system_roles();

-- 2.3 Guest ได้เฉพาะ .view_public / .use_public และเฉพาะโมดูลที่ allow_guest = true
create or replace function public.sfh_guard_guest_permissions()
returns trigger language plpgsql set search_path = public as $$
declare
  v_role   text;
  v_action text;
  v_module text;
  v_allow  boolean;
begin
  select role_key into v_role from public.roles where id = new.role_id;
  if v_role = 'guest' then
    select action, module_key into v_action, v_module from public.permissions where id = new.permission_id;
    if coalesce(v_action, '') not in ('view_public','use_public') then
      raise exception 'Role guest ได้รับเฉพาะ Permission ประเภท view_public / use_public เท่านั้น (%.%)', v_module, v_action;
    end if;
    select allow_guest into v_allow from public.modules where module_key = v_module;
    if v_allow is not null and v_allow = false then
      raise exception 'โมดูล "%" ไม่อนุญาตให้บุคคลทั่วไปเข้าใช้งาน', v_module;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_role_permissions_guest on public.role_permissions;
create trigger trg_role_permissions_guest before insert or update on public.role_permissions
  for each row execute function public.sfh_guard_guest_permissions();

-- 2.4 โมดูลที่ถูกล็อก (ทะเบียนคุม/สลิปเงินเดือน) ห้ามเปิด allow_guest
--     และเมื่อปิด allow_guest ให้ถอนสิทธิ์ guest ของโมดูลนั้นอัตโนมัติ
create or replace function public.sfh_guard_modules()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.guest_locked and new.allow_guest then
    raise exception 'โมดูล "%" ถูกล็อกไว้ ไม่สามารถเปิดให้บุคคลทั่วไปได้', new.name;
  end if;
  if tg_op = 'UPDATE' and old.allow_guest and not new.allow_guest then
    delete from public.role_permissions rp
     using public.roles r, public.permissions p
     where rp.role_id = r.id and rp.permission_id = p.id
       and r.role_key = 'guest' and p.module_key = new.module_key;
  end if;
  return new;
end $$;

drop trigger if exists trg_modules_guard on public.modules;
create trigger trg_modules_guard before insert or update on public.modules
  for each row execute function public.sfh_guard_modules();

-- 2.5 ห้ามกำหนดผู้ใช้ให้เป็น Role guest (guest ใช้สำหรับผู้ไม่ Login เท่านั้น)
create or replace function public.sfh_guard_users()
returns trigger language plpgsql set search_path = public as $$
begin
  if exists (select 1 from public.roles where id = new.role_id and role_key = 'guest') then
    raise exception 'ไม่สามารถกำหนดผู้ใช้งานให้เป็น Role guest ได้';
  end if;
  new.username := lower(trim(new.username));
  return new;
end $$;

drop trigger if exists trg_users_guard on public.users;
create trigger trg_users_guard before insert or update on public.users
  for each row execute function public.sfh_guard_users();


-- =====================================================================
-- 3) ฟังก์ชัน RPC – Custom Login (ไม่ใช้ Supabase Auth)
-- =====================================================================
drop function if exists public.sfh_login(text, text);
drop function if exists public.sfh_set_password(uuid, text);
drop function if exists public.sfh_change_password(uuid, text, text);
drop function if exists public.sfh_refresh_session(uuid);
drop function if exists public.sfh_guest_menus();
drop function if exists public.sfh_user_payload(uuid);

-- 3.1 (ภายใน) ข้อมูลผู้ใช้ + role + permission ไม่มี hash
create function public.sfh_user_payload(p_user_id uuid)
returns jsonb
language sql stable security definer
set search_path = public, extensions
as $$
  select jsonb_build_object(
    'user', jsonb_build_object(
        'id', u.id, 'username', u.username, 'full_name', u.full_name, 'position', u.position,
        'email', u.email, 'phone', u.phone, 'avatar_url', u.avatar_url, 'org_id', u.org_id,
        'role_id', u.role_id, 'is_active', u.is_active, 'last_login_at', u.last_login_at),
    'role', jsonb_build_object(
        'id', r.id, 'role_key', r.role_key, 'name', r.name, 'level', r.level, 'color', r.color),
    'organization', case when o.id is null then null else jsonb_build_object(
        'id', o.id, 'code', o.code, 'name', o.name, 'short_name', o.short_name) end,
    'permissions', coalesce((
        select jsonb_agg(distinct p.perm_key order by p.perm_key)
          from public.permissions p
         where r.role_key = 'super_admin'
            or p.id in (select rp.permission_id from public.role_permissions rp where rp.role_id = u.role_id)
            or p.id in (select up.permission_id from public.user_permissions up where up.user_id = u.id)
      ), '[]'::jsonb)
  )
  from public.users u
  join public.roles r on r.id = u.role_id
  left join public.organizations o on o.id = u.org_id
  where u.id = p_user_id;
$$;

-- 3.2 เข้าสู่ระบบ
create function public.sfh_login(p_username text, p_password text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_user       public.users%rowtype;
  v_hash       text;
  v_org_active boolean;
begin
  select * into v_user from public.users where username = lower(trim(coalesce(p_username, '')));

  if not found then
    insert into public.audit_logs(action, table_name, username, details)
    values ('login_failed', 'users', p_username, jsonb_build_object('reason', 'user_not_found'));
    return jsonb_build_object('success', false, 'message', 'ชื่อผู้ใช้หรือรหัสผ่านไม่ถูกต้อง');
  end if;

  select password_hash into v_hash from public.user_credentials where user_id = v_user.id;
  if v_hash is null or v_hash <> crypt(coalesce(p_password, ''), v_hash) then
    insert into public.audit_logs(org_id, user_id, username, action, table_name, record_id, details)
    values (v_user.org_id, v_user.id, v_user.username, 'login_failed', 'users', v_user.id::text,
            jsonb_build_object('reason', 'wrong_password'));
    return jsonb_build_object('success', false, 'message', 'ชื่อผู้ใช้หรือรหัสผ่านไม่ถูกต้อง');
  end if;

  if not v_user.is_active then
    insert into public.audit_logs(org_id, user_id, username, action, table_name, record_id, details)
    values (v_user.org_id, v_user.id, v_user.username, 'login_failed', 'users', v_user.id::text,
            jsonb_build_object('reason', 'inactive'));
    return jsonb_build_object('success', false, 'message', 'บัญชีนี้ถูกปิดการใช้งาน กรุณาติดต่อผู้ดูแลระบบ');
  end if;

  if v_user.org_id is not null then
    select is_active into v_org_active from public.organizations where id = v_user.org_id;
    if v_org_active = false then
      return jsonb_build_object('success', false, 'message', 'หน่วยงานของท่านถูกปิดการใช้งาน กรุณาติดต่อผู้ดูแลระบบ');
    end if;
  end if;

  update public.users set last_login_at = now() where id = v_user.id;

  insert into public.audit_logs(org_id, user_id, username, action, table_name, record_id, created_by)
  values (v_user.org_id, v_user.id, v_user.username, 'login', 'users', v_user.id::text, v_user.id);

  return jsonb_build_object('success', true, 'message', 'เข้าสู่ระบบสำเร็จ') || public.sfh_user_payload(v_user.id);
end $$;

-- 3.3 ตรวจ session ซ้ำเมื่อเปิดหน้าเว็บใหม่ (is_active + permission ล่าสุด)
create function public.sfh_refresh_session(p_user_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_active     boolean;
  v_org_active boolean;
begin
  select u.is_active, coalesce(o.is_active, true) into v_active, v_org_active
    from public.users u left join public.organizations o on o.id = u.org_id
   where u.id = p_user_id;
  if v_active is null then
    return jsonb_build_object('success', false, 'message', 'ไม่พบบัญชีผู้ใช้ กรุณาเข้าสู่ระบบใหม่');
  end if;
  if not v_active or not v_org_active then
    return jsonb_build_object('success', false, 'message', 'บัญชีของท่านถูกปิดการใช้งาน');
  end if;
  return jsonb_build_object('success', true) || public.sfh_user_payload(p_user_id);
end $$;

-- 3.4 ตั้งรหัสผ่าน (ใช้ตอนสร้างผู้ใช้ / รีเซ็ตรหัสผ่าน)
create function public.sfh_set_password(p_user_id uuid, p_new_password text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
begin
  if not exists (select 1 from public.users where id = p_user_id) then
    return jsonb_build_object('success', false, 'message', 'ไม่พบผู้ใช้งาน');
  end if;
  if coalesce(length(p_new_password), 0) < 6 then
    return jsonb_build_object('success', false, 'message', 'รหัสผ่านต้องมีอย่างน้อย 6 ตัวอักษร');
  end if;
  insert into public.user_credentials(user_id, password_hash, password_changed_at)
  values (p_user_id, crypt(p_new_password, gen_salt('bf')), now())
  on conflict (user_id) do update
     set password_hash = excluded.password_hash,
         password_changed_at = now();
  return jsonb_build_object('success', true, 'message', 'บันทึกรหัสผ่านเรียบร้อย');
end $$;

-- 3.5 เปลี่ยนรหัสผ่านของตนเอง (ตรวจรหัสเดิมก่อน)
create function public.sfh_change_password(p_user_id uuid, p_old_password text, p_new_password text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_hash text;
begin
  select password_hash into v_hash from public.user_credentials where user_id = p_user_id;
  if v_hash is null or v_hash <> crypt(coalesce(p_old_password, ''), v_hash) then
    return jsonb_build_object('success', false, 'message', 'รหัสผ่านเดิมไม่ถูกต้อง');
  end if;
  return public.sfh_set_password(p_user_id, p_new_password);
end $$;

-- 3.6 เมนูที่เปิดให้ Guest (เรียงตาม sort_order พร้อมสถานะโมดูล)
create function public.sfh_guest_menus()
returns table (
  menu_key text, label text, icon text, module_key text, menu_group text, sort_order int,
  show_on_mobile boolean, public_permission text,
  module_name text, module_description text, module_status text, module_color text,
  module_icon text, module_version text, module_features jsonb
)
language sql stable security definer
set search_path = public, extensions
as $$
  select m.menu_key, m.label, m.icon, m.module_key, m.menu_group, m.sort_order,
         m.show_on_mobile, m.public_permission,
         md.name, md.description, md.status, md.color, md.icon, md.version, md.planned_features
    from public.menus m
    left join public.modules md on md.module_key = m.module_key
   where m.is_active
     and (md.id is null or (md.status <> 'disabled' and md.allow_guest))
     and ( m.menu_key = 'home'
           or exists (select 1
                        from public.role_permissions rp
                        join public.roles r       on r.id = rp.role_id
                        join public.permissions p on p.id = rp.permission_id
                       where r.role_key = 'guest' and p.perm_key = m.public_permission) )
   order by m.sort_order, m.label;
$$;


-- =====================================================================
-- 4) ข้อมูลตัวอย่าง
-- =====================================================================

-- 4.1 หน่วยงาน
insert into public.organizations (id, code, name, short_name, address, phone, email, description) values
 ('11111111-1111-1111-1111-111111111111', 'SSN-FIN', 'กองคลัง เทศบาลเมืองศรีสัชนาลัย', 'กองคลัง',
  'ตำบลหาดเสี้ยว อำเภอศรีสัชนาลัย จังหวัดสุโขทัย', '0-5500-0001', 'finance@ssn-city.example',
  'รับผิดชอบงานการเงิน บัญชี พัสดุ และจัดเก็บรายได้ของเทศบาล'),
 ('11111111-1111-1111-1111-111111111112', 'SSN-OFF', 'สำนักปลัดเทศบาล เทศบาลเมืองศรีสัชนาลัย', 'สำนักปลัด',
  'ตำบลหาดเสี้ยว อำเภอศรีสัชนาลัย จังหวัดสุโขทัย', '0-5500-0002', 'office@ssn-city.example',
  'งานบริหารทั่วไป งานการเจ้าหน้าที่ และงานธุรการของเทศบาล')
on conflict (id) do nothing;

-- 4.2 Role ระบบ
insert into public.roles (id, role_key, name, description, level, color, is_system) values
 ('aaaaaaaa-0000-0000-0000-000000000001', 'super_admin', 'Super Admin',        'ผู้ดูแลระบบสูงสุด จัดการได้ทั้งระบบ',                 100, '#EC7FA5', true),
 ('aaaaaaaa-0000-0000-0000-000000000002', 'org_admin',   'Organization Admin', 'ผู้ดูแลระดับหน่วยงาน จัดการผู้ใช้ในหน่วยงานของตนเอง',  50, '#F0A04B', true),
 ('aaaaaaaa-0000-0000-0000-000000000003', 'staff',       'เจ้าหน้าที่กองคลัง',   'ใช้งานโมดูลตาม Permission ที่ได้รับ',                  10, '#5AA9E6', true),
 ('aaaaaaaa-0000-0000-0000-000000000004', 'guest',       'บุคคลทั่วไป',         'ผู้ใช้ที่ไม่ได้เข้าสู่ระบบ เห็นเฉพาะเมนูสาธารณะ',       0, '#94A3B8', true)
on conflict (role_key) do nothing;

-- 4.3 โมดูล (announcements = โมดูลแกนกลางที่พัฒนาแล้ว, อีก 3 โมดูล = coming_soon)
insert into public.modules (module_key, name, description, icon, color, status, allow_guest, guest_locked, is_core, sort_order, version, planned_features) values
 ('announcements', 'ข่าวสาร/ประกาศ',
  'เผยแพร่ข่าวประชาสัมพันธ์และประกาศของกองคลัง ทั้งแบบสาธารณะและภายในหน่วยงาน',
  'megaphone', '#EC7FA5', 'active', true, false, true, 1, '1.0.0',
  '["ประกาศข่าวสาธารณะและภายในหน่วยงาน","แนบภาพปกพร้อมบีบอัดอัตโนมัติ","ปักหมุดข่าวสำคัญ","ตั้งวันเผยแพร่ล่วงหน้า"]'::jsonb),
 ('travel', 'โปรแกรมคำนวณค่าใช้จ่ายไปราชการ',
  'คำนวณค่าเบี้ยเลี้ยง ค่าเช่าที่พัก และค่าพาหนะในการเดินทางไปราชการ ตามระเบียบกระทรวงมหาดไทยว่าด้วยค่าใช้จ่ายในการเดินทางไปราชการของเจ้าหน้าที่ท้องถิ่น',
  'plane', '#5AA9E6', 'coming_soon', true, false, false, 10, '0.1.0',
  '["คำนวณเบี้ยเลี้ยง ค่าที่พัก ค่าพาหนะตามระดับตำแหน่ง","รองรับการเดินทางหลายวันและแบบหมู่คณะ","พิมพ์หลักฐานการขอเบิกค่าใช้จ่ายในการเดินทาง","บันทึกประวัติการคำนวณสำหรับเจ้าหน้าที่"]'::jsonb),
 ('register', 'ทะเบียนคุมต่าง ๆ',
  'บันทึกและติดตามทะเบียนคุมของกองคลัง เช่น ทะเบียนคุมฎีกา ทะเบียนคุมเช็ค ทะเบียนเงินรับฝาก และทะเบียนคุมเอกสารสำคัญ',
  'book-open-check', '#A694E8', 'coming_soon', false, true, false, 11, '0.1.0',
  '["ทะเบียนคุมฎีกา เช็ค และเงินรับฝาก","กำหนดประเภททะเบียนคุมได้เอง","ค้นหา กรอง และส่งออกรายงาน CSV","ติดตามสถานะเอกสารแบบเรียลไทม์"]'::jsonb),
 ('payroll', 'สลิปเงินเดือน',
  'ระบบสลิปเงินเดือนอิเล็กทรอนิกส์สำหรับบุคลากรเทศบาล ดูรายการรับ-รายการหัก และพิมพ์สลิปย้อนหลังได้ด้วยตนเอง',
  'receipt-text', '#5CC49A', 'coming_soon', false, true, false, 12, '0.1.0',
  '["ดูและพิมพ์สลิปเงินเดือนย้อนหลัง","แสดงรายการรับ-หักพร้อมจำนวนเงินตัวอักษร","นำเข้าข้อมูลเงินเดือนจากไฟล์ CSV","ส่งออกรายงานสรุปเงินเดือนรายเดือน"]'::jsonb)
on conflict (module_key) do nothing;

-- 4.4 Permission
insert into public.permissions (perm_key, module_key, action, name, description, org_admin_grantable, sort_order) values
 ('dashboard.view',            'dashboard',     'view',          'ดูแดชบอร์ด',                              'เข้าหน้าแดชบอร์ดหลัง Login', true, 10),
 ('announcements.view_public', 'announcements', 'view_public',   'ดูข่าวสาร/ประกาศสาธารณะ',                 'ใช้กับ Role guest เพื่อเปิดเมนูข่าวสารให้บุคคลทั่วไป', true, 20),
 ('announcements.view',        'announcements', 'view',          'ดูข่าวสารภายในหน่วยงาน',                   'เห็นข่าวที่ไม่เป็นสาธารณะของหน่วยงานตนเอง', true, 21),
 ('announcements.manage',      'announcements', 'manage',        'เพิ่ม/แก้ไข/ลบข่าวสาร',                    'จัดการข่าวสาร/ประกาศ', true, 22),
 ('travel.use_public',         'travel',        'use_public',    'ใช้โปรแกรมคำนวณค่าใช้จ่ายไปราชการ',        'ใช้งานได้ทั้งบุคคลทั่วไปและเจ้าหน้าที่', true, 30),
 ('travel.save',               'travel',        'save',          'บันทึกผลการคำนวณ',                         'บันทึกประวัติการคำนวณ', true, 31),
 ('travel.manage_rates',       'travel',        'manage_rates',  'จัดการอัตราค่าใช้จ่าย',                     'แก้ไขอัตราเบี้ยเลี้ยง/ที่พัก/พาหนะ', false, 32),
 ('register.view',             'register',      'view',          'ดูทะเบียนคุม (ของตนเอง)',                   'ดูรายการที่ตนเองเป็นผู้บันทึก', true, 40),
 ('register.create',           'register',      'create',        'เพิ่มรายการทะเบียนคุม',                     null, true, 41),
 ('register.update',           'register',      'update',        'แก้ไขรายการทะเบียนคุม',                     null, true, 42),
 ('register.delete',           'register',      'delete',        'ลบรายการทะเบียนคุม',                        null, true, 43),
 ('register.view_all',         'register',      'view_all',      'ดูทะเบียนคุมของทุกคนในหน่วยงาน',            'ข้ามเงื่อนไข created_by = ตนเอง', true, 44),
 ('register.export',           'register',      'export',        'ส่งออกทะเบียนคุม (CSV)',                     null, true, 45),
 ('register.manage_types',     'register',      'manage_types',  'จัดการประเภททะเบียนคุม',                    null, false, 46),
 ('payroll.view',              'payroll',       'view',          'ดูสลิปเงินเดือน',                            'ดูสลิปของตนเอง', true, 50),
 ('payroll.manage',            'payroll',       'manage',        'จัดการข้อมูลเงินเดือน',                      'นำเข้า/แก้ไขข้อมูลเงินเดือน', false, 51),
 ('payroll.print',             'payroll',       'print',         'พิมพ์สลิปเงินเดือน',                         null, true, 52),
 ('payroll.export',            'payroll',       'export',        'ส่งออกรายงานเงินเดือน',                      null, true, 53),
 ('users.view',                'users',         'view',          'ดูรายชื่อผู้ใช้งาน',                          null, false, 60),
 ('users.manage',              'users',         'manage',        'เพิ่ม/แก้ไข/ปิดบัญชีผู้ใช้งาน',               null, false, 61),
 ('users.export',              'users',         'export',        'ส่งออกรายชื่อผู้ใช้งาน (CSV)',                null, false, 62),
 ('roles.manage',              'roles',         'manage',        'จัดการ Role & Permission',                   null, false, 70),
 ('organizations.manage',      'organizations', 'manage',        'จัดการหน่วยงาน',                             null, false, 71),
 ('modules.manage',            'modules',       'manage',        'จัดการโมดูล',                                null, false, 72),
 ('public_menu.manage',        'public_menu',   'manage',        'ตั้งค่าเมนูสาธารณะ',                          null, false, 73),
 ('settings.manage',           'settings',      'manage',        'ตั้งค่าระดับ Platform',                        null, false, 74),
 ('settings.org',              'settings',      'org',           'ตั้งค่าระดับหน่วยงาน',                         null, false, 75),
 ('audit.view',                'audit',         'view',          'ดู Audit Log',                                null, false, 80),
 ('audit.export',              'audit',         'export',        'ส่งออก Audit Log (CSV)',                       null, false, 81)
on conflict (perm_key) do update
  set module_key = excluded.module_key, action = excluded.action,
      name = excluded.name, description = excluded.description, sort_order = excluded.sort_order;

-- 4.5 สิทธิ์ของแต่ละ Role
-- super_admin : ได้ทุกสิทธิ์
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r cross join public.permissions p
 where r.role_key = 'super_admin'
on conflict (role_id, permission_id) do nothing;

-- org_admin
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p on p.perm_key in (
  'dashboard.view','announcements.view_public','announcements.view','announcements.manage',
  'travel.use_public','travel.save',
  'register.view','register.create','register.update','register.delete','register.view_all','register.export',
  'payroll.view','payroll.print','payroll.export',
  'users.view','users.manage','users.export','settings.org','audit.view','audit.export')
 where r.role_key = 'org_admin'
on conflict (role_id, permission_id) do nothing;

-- staff
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p on p.perm_key in (
  'dashboard.view','announcements.view_public','announcements.view',
  'travel.use_public','travel.save','register.view','register.create','register.update')
 where r.role_key = 'staff'
on conflict (role_id, permission_id) do nothing;

-- guest : ข่าวสาร + โปรแกรมคำนวณค่าใช้จ่ายไปราชการ
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p on p.perm_key in (
  'announcements.view_public','travel.use_public')
 where r.role_key = 'guest'
on conflict (role_id, permission_id) do nothing;

-- 4.6 ผู้ใช้งานตัวอย่าง
insert into public.users (id, org_id, role_id, username, full_name, position, email, phone, is_active) values
 ('bbbbbbbb-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000001',
  'superadmin', 'นายวีระพงษ์ ศรีสุวรรณ', 'นักวิชาการคอมพิวเตอร์ชำนาญการ', 'superadmin@ssn-city.example', '08-1000-0001', true),
 ('bbbbbbbb-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000002',
  'orgadmin', 'นางสาวพิมพ์ชนก แก้วมณี', 'ผู้อำนวยการกองคลัง', 'orgadmin@ssn-city.example', '08-1000-0002', true),
 ('bbbbbbbb-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000003',
  'staff1', 'นายธนากร บุญมา', 'นักวิชาการเงินและบัญชีชำนาญการ', 'staff1@ssn-city.example', '08-1000-0003', true),
 ('bbbbbbbb-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000003',
  'staff2', 'นางสาวกัญญารัตน์ ทองดี', 'เจ้าพนักงานการเงินและบัญชีปฏิบัติงาน', 'staff2@ssn-city.example', '08-1000-0004', true),
 ('bbbbbbbb-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111112', 'aaaaaaaa-0000-0000-0000-000000000002',
  'orgadmin2', 'นายสมเกียรติ ใจงาม', 'หัวหน้าสำนักปลัดเทศบาล', 'orgadmin2@ssn-city.example', '08-1000-0005', true),
 ('bbbbbbbb-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111112', 'aaaaaaaa-0000-0000-0000-000000000003',
  'staff3', 'นางมาลัย พรหมสุข', 'เจ้าพนักงานธุรการชำนาญงาน (บัญชีถูกปิด)', 'staff3@ssn-city.example', '08-1000-0006', false)
on conflict (id) do nothing;

-- รหัสผ่านทดสอบ (hash ด้วย bcrypt) – ไม่เขียนทับถ้าเคยตั้งแล้ว
insert into public.user_credentials (user_id, password_hash)
select v.id, crypt(v.pwd, gen_salt('bf'))
  from (values
    ('bbbbbbbb-0000-0000-0000-000000000001'::uuid, 'admin1234'),
    ('bbbbbbbb-0000-0000-0000-000000000002'::uuid, 'org1234'),
    ('bbbbbbbb-0000-0000-0000-000000000003'::uuid, 'staff1234'),
    ('bbbbbbbb-0000-0000-0000-000000000004'::uuid, 'staff1234'),
    ('bbbbbbbb-0000-0000-0000-000000000005'::uuid, 'org1234'),
    ('bbbbbbbb-0000-0000-0000-000000000006'::uuid, 'staff1234')
  ) as v(id, pwd)
on conflict (user_id) do nothing;

-- สิทธิ์รายบุคคล: staff1 ได้เพิ่ม "สลิปเงินเดือน" + ส่งออกทะเบียนคุม (staff2 ใช้ Role เดียวกันแต่ไม่ได้)
insert into public.user_permissions (user_id, permission_id, org_id, created_by)
select 'bbbbbbbb-0000-0000-0000-000000000003'::uuid, p.id,
       '11111111-1111-1111-1111-111111111111'::uuid, 'bbbbbbbb-0000-0000-0000-000000000001'::uuid
  from public.permissions p where p.perm_key in ('payroll.view','payroll.print','register.export')
on conflict (user_id, permission_id) do nothing;

-- 4.7 เมนู
insert into public.menus (menu_key, label, icon, module_key, required_permission, public_permission, sort_order, is_active, show_on_mobile, menu_group, description) values
 ('home',          'หน้าแรก',                 'home',             null,            null,                   null,                        1, true, true, 'main',   'หน้าแรกของระบบ (เปิดตลอด)'),
 ('dashboard',     'แดชบอร์ด',                'layout-dashboard', null,            'dashboard.view',       null,                        2, true, true, 'main',   'ภาพรวมตามสิทธิ์ผู้ใช้'),
 ('announcements', 'ข่าวสาร/ประกาศ',          'megaphone',        'announcements', 'announcements.view',   'announcements.view_public', 3, true, true, 'main',   'ข่าวประชาสัมพันธ์และประกาศ'),
 ('travel',        'ค่าใช้จ่ายไปราชการ',        'plane',            'travel',        'travel.use_public',    'travel.use_public',         10, true, true, 'module', 'โปรแกรมคำนวณค่าใช้จ่ายไปราชการ'),
 ('register',      'ทะเบียนคุมต่าง ๆ',          'book-open-check',  'register',      'register.view',        null,                        11, true, true, 'module', 'ทะเบียนคุมของกองคลัง'),
 ('payroll',       'สลิปเงินเดือน',             'receipt-text',     'payroll',       'payroll.view',         null,                        12, true, true, 'module', 'สลิปเงินเดือนอิเล็กทรอนิกส์'),
 ('users',         'จัดการผู้ใช้งาน',            'users',            null,            'users.view',           null,                        20, true, true, 'admin',  null),
 ('roles',         'Role & Permission',        'shield-check',     null,            'roles.manage',         null,                        21, true, true, 'admin',  null),
 ('organizations', 'จัดการหน่วยงาน',           'building-2',       null,            'organizations.manage', null,                        22, true, true, 'admin',  null),
 ('modules',       'จัดการโมดูล',              'puzzle',           null,            'modules.manage',       null,                        23, true, true, 'admin',  null),
 ('public_menu',   'เมนูสาธารณะ',              'globe',            null,            'public_menu.manage',   null,                        24, true, true, 'admin',  null),
 ('settings',      'ตั้งค่าระบบ',               'settings',         null,            'settings.org',         null,                        25, true, true, 'admin',  null),
 ('audit',         'Audit Log',                'history',          null,            'audit.view',           null,                        26, true, true, 'admin',  null)
on conflict (menu_key) do nothing;

-- 4.8 ตั้งค่าระบบ (Platform)
insert into public.system_settings (org_id, setting_key, setting_value, label, is_public)
select null, v.k, v.val, v.lbl, v.pub
  from (values
    ('site_name',     'Smart Finance Hub',                    'ชื่อระบบ',                 true),
    ('site_short',    'SFH',                                  'ชื่อย่อระบบ',              true),
    ('site_subtitle', 'ศูนย์กลางการเงินการคลังดิจิทัล',          'คำอธิบายระบบ',             true),
    ('org_name',      'กองคลัง เทศบาลเมืองศรีสัชนาลัย',           'ชื่อหน่วยงาน',              true),
    ('hero_title',    'Smart Finance Hub',                    'หัวข้อหน้าแรก',            true),
    ('hero_text',     'บริการข้อมูลการเงินการคลังของเทศบาลอย่างโปร่งใส สะดวก รวดเร็ว ตรวจสอบได้ ทุกที่ ทุกเวลา', 'ข้อความหน้าแรก', true),
    ('logo_url',      '',                                     'โลโก้ (URL)',              true),
    ('logo_path',     '',                                     'โลโก้ (path ใน Storage)',  false),
    ('contact_phone', '0-5500-0001',                          'เบอร์โทรติดต่อ',           true),
    ('contact_email', 'finance@ssn-city.example',             'อีเมลติดต่อ',              true),
    ('footer_text',   '© 2569 กองคลัง เทศบาลเมืองศรีสัชนาลัย', 'ข้อความท้ายเว็บ',          true)
  ) as v(k, val, lbl, pub)
 where not exists (select 1 from public.system_settings s where s.org_id is null and s.setting_key = v.k);

-- ตั้งค่าระดับหน่วยงาน (กองคลัง)
insert into public.system_settings (org_id, setting_key, setting_value, label, is_public)
select '11111111-1111-1111-1111-111111111111'::uuid, v.k, v.val, v.lbl, false
  from (values
    ('signer_name',     'นางสาวพิมพ์ชนก แก้วมณี',  'ชื่อผู้ลงนามในเอกสาร'),
    ('signer_position', 'ผู้อำนวยการกองคลัง',       'ตำแหน่งผู้ลงนาม'),
    ('doc_footer',      'กองคลัง เทศบาลเมืองศรีสัชนาลัย โทร 0-5500-0001', 'ข้อความท้ายเอกสาร/รายงาน')
  ) as v(k, val, lbl)
 where not exists (select 1 from public.system_settings s
                    where s.org_id = '11111111-1111-1111-1111-111111111111'::uuid and s.setting_key = v.k);

-- 4.9 ข่าวสาร/ประกาศ 6 รายการ (สาธารณะ 4 / ภายใน 2)
insert into public.announcements (id, org_id, title, content, category, is_public, is_pinned, published_at, created_by) values
 ('cccccccc-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
  'เปิดให้บริการ Smart Finance Hub ศูนย์กลางการเงินการคลังดิจิทัล',
  E'กองคลัง เทศบาลเมืองศรีสัชนาลัย เปิดให้บริการระบบ Smart Finance Hub (SFH) เพื่อเป็นช่องทางเผยแพร่ข่าวสารด้านการเงินการคลังและให้บริการเครื่องมือดิจิทัลแก่ประชาชนและบุคลากร\n\nในระยะแรกประชาชนสามารถติดตามข่าวประกาศ และจะเปิดให้ใช้โปรแกรมคำนวณค่าใช้จ่ายไปราชการในเร็ว ๆ นี้',
  'ประชาสัมพันธ์', true, true, now() - interval '1 day', 'bbbbbbbb-0000-0000-0000-000000000002'),
 ('cccccccc-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
  'ประชาสัมพันธ์การชำระภาษีที่ดินและสิ่งปลูกสร้าง ประจำปี 2569',
  E'ขอเชิญชวนผู้มีหน้าที่เสียภาษีที่ดินและสิ่งปลูกสร้าง ชำระภาษีภายในกำหนด ณ งานพัฒนาและจัดเก็บรายได้ กองคลัง ในวันและเวลาราชการ\n\nผู้ที่ชำระเกินกำหนดจะต้องเสียเบี้ยปรับและเงินเพิ่มตามที่กฎหมายกำหนด สอบถามรายละเอียดเพิ่มเติมได้ที่ 0-5500-0001',
  'ภาษีและรายได้', true, false, now() - interval '4 days', 'bbbbbbbb-0000-0000-0000-000000000003'),
 ('cccccccc-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
  'รายงานผลการเบิกจ่ายงบประมาณ ไตรมาสที่ 3 ปีงบประมาณ 2569',
  E'กองคลังขอรายงานผลการเบิกจ่ายงบประมาณรายจ่ายประจำปีงบประมาณ 2569 ไตรมาสที่ 3 (เมษายน – มิถุนายน 2569) เพื่อความโปร่งใสและให้ประชาชนสามารถตรวจสอบได้\n\nภาพรวมการเบิกจ่ายเป็นไปตามแผนที่กำหนด รายละเอียดสามารถขอดูเอกสารฉบับเต็มได้ที่กองคลัง',
  'การเงินการคลัง', true, false, now() - interval '8 days', 'bbbbbbbb-0000-0000-0000-000000000002'),
 ('cccccccc-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111',
  'ประกาศผู้ชนะการเสนอราคา จัดซื้อวัสดุสำนักงาน โดยวิธีเฉพาะเจาะจง',
  E'ตามที่เทศบาลเมืองศรีสัชนาลัยได้มีโครงการจัดซื้อวัสดุสำนักงาน จำนวน 1 โครงการ โดยวิธีเฉพาะเจาะจง บัดนี้ได้คัดเลือกผู้เสนอราคาเรียบร้อยแล้ว\n\nรายละเอียดผู้ชนะและราคาที่เสนอ ดูได้ที่ป้ายประกาศของเทศบาลและระบบ e-GP',
  'จัดซื้อจัดจ้าง', true, false, now() - interval '12 days', 'bbbbbbbb-0000-0000-0000-000000000003'),
 ('cccccccc-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111',
  '[ภายใน] แจ้งกำหนดส่งเอกสารเบิกจ่ายก่อนปิดปีงบประมาณ 2569',
  E'ขอให้ทุกกอง/สำนัก ส่งเอกสารขอเบิกจ่ายที่ค้างอยู่ให้กองคลังภายในวันที่ 25 กันยายน 2569 เพื่อให้ทันการวางฎีกาก่อนปิดปีงบประมาณ\n\nเอกสารที่ส่งหลังกำหนดจะดำเนินการเป็นรายการกันเงินไว้เบิกเหลื่อมปี',
  'การเงินการคลัง', false, true, now() - interval '10 days', 'bbbbbbbb-0000-0000-0000-000000000002'),
 ('cccccccc-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111',
  '[ภายใน] นัดประชุมเจ้าหน้าที่กองคลัง ประจำเดือนตุลาคม 2569',
  E'ขอเชิญเจ้าหน้าที่กองคลังทุกท่านเข้าร่วมประชุมประจำเดือน ในวันที่ 2 ตุลาคม 2569 เวลา 13.30 น. ณ ห้องประชุมกองคลัง\n\nวาระสำคัญ: สรุปผลการปิดบัญชีสิ้นปีงบประมาณ และแผนการใช้งานระบบ SFH ระยะที่ 2',
  'ข่าวกิจกรรม', false, false, now() - interval '2 days', 'bbbbbbbb-0000-0000-0000-000000000002')
on conflict (id) do nothing;

-- 4.10 Audit Log ตัวอย่าง 20 รายการ (กระจาย 14 วัน ให้กราฟมีข้อมูล)
do $$
begin
  if not exists (select 1 from public.audit_logs where details->>'seed' = 'true') then
    insert into public.audit_logs (org_id, user_id, username, action, table_name, record_id, details, created_by, created_at)
    select v.org_id, v.user_id, v.username, v.action, v.tbl, v.rec, jsonb_build_object('seed', true) || v.extra, v.user_id,
           -- เวลาตามเขตเวลาไทย และไม่ให้เกินเวลาปัจจุบัน
           least(
             (date_trunc('day', now() at time zone 'Asia/Bangkok') - make_interval(days => v.d)
               + make_interval(hours => v.h, mins => v.mi)) at time zone 'Asia/Bangkok',
             now() - make_interval(mins => 30 - v.mi / 2))
      from (values
        ('11111111-1111-1111-1111-111111111111'::uuid, 'bbbbbbbb-0000-0000-0000-000000000001'::uuid, 'superadmin', 'login',  'users',         'bbbbbbbb-0000-0000-0000-000000000001', '{}'::jsonb, 13,  8, 30),
        ('11111111-1111-1111-1111-111111111111'::uuid, 'bbbbbbbb-0000-0000-0000-000000000002'::uuid, 'orgadmin',   'login',  'users',         'bbbbbbbb-0000-0000-0000-000000000002', '{}'::jsonb, 13,  9, 10),
        ('11111111-1111-1111-1111-111111111111'::uuid, 'bbbbbbbb-0000-0000-0000-000000000003'::uuid, 'staff1',     'login',  'users',         'bbbbbbbb-0000-0000-0000-000000000003', '{}'::jsonb, 12,  8, 45),
        ('11111111-1111-1111-1111-111111111111'::uuid, 'bbbbbbbb-0000-0000-0000-000000000001'::uuid, 'superadmin', 'create', 'organizations', '11111111-1111-1111-1111-111111111112', '{"name":"สำนักปลัดเทศบาล"}'::jsonb, 12, 10, 5),
        ('11111111-1111-1111-1111-111111111111'::uuid, 'bbbbbbbb-0000-0000-0000-000000000004'::uuid, 'staff2',     'login',  'users',         'bbbbbbbb-0000-0000-0000-000000000004', '{}'::jsonb, 11,  8, 20),
        ('11111111-1111-1111-1111-111111111111'::uuid, 'bbbbbbbb-0000-0000-0000-000000000002'::uuid, 'orgadmin',   'create', 'announcements', 'cccccccc-0000-0000-0000-000000000005', '{"title":"แจ้งกำหนดส่งเอกสารเบิกจ่าย"}'::jsonb, 10, 11, 0),
        ('11111111-1111-1111-1111-111111111111'::uuid, 'bbbbbbbb-0000-0000-0000-000000000003'::uuid, 'staff1',     'login',  'users',         'bbbbbbbb-0000-0000-0000-000000000003', '{}'::jsonb,  9,  8, 35),
        ('11111111-1111-1111-1111-111111111111'::uuid, 'bbbbbbbb-0000-0000-0000-000000000001'::uuid, 'superadmin', 'update', 'modules',       'travel', '{"status":"coming_soon"}'::jsonb, 8, 14, 15),
        ('11111111-1111-1111-1111-111111111111'::uuid, 'bbbbbbbb-0000-0000-0000-000000000002'::uuid, 'orgadmin',   'login',  'users',         'bbbbbbbb-0000-0000-0000-000000000002', '{}'::jsonb,  7,  8, 50),
        ('11111111-1111-1111-1111-111111111111'::uuid, 'bbbbbbbb-0000-0000-0000-000000000004'::uuid, 'staff2',     'login',  'users',         'bbbbbbbb-0000-0000-0000-000000000004', '{}'::jsonb,  6,  9,  5),
        ('11111111-1111-1111-1111-111111111111'::uuid, 'bbbbbbbb-0000-0000-0000-000000000002'::uuid, 'orgadmin',   'update', 'users',         'bbbbbbbb-0000-0000-0000-000000000004', '{"field":"position"}'::jsonb, 6, 10, 40),
        ('11111111-1111-1111-1111-111111111111'::uuid, 'bbbbbbbb-0000-0000-0000-000000000003'::uuid, 'staff1',     'login',  'users',         'bbbbbbbb-0000-0000-0000-000000000003', '{}'::jsonb,  5,  8, 15),
        ('11111111-1111-1111-1111-111111111111'::uuid, 'bbbbbbbb-0000-0000-0000-000000000001'::uuid, 'superadmin', 'update_permissions', 'user_permissions', 'bbbbbbbb-0000-0000-0000-000000000003', '{"added":["payroll.view","payroll.print"]}'::jsonb, 4, 13, 20),
        ('11111111-1111-1111-1111-111111111112'::uuid, 'bbbbbbbb-0000-0000-0000-000000000005'::uuid, 'orgadmin2',  'login',  'users',         'bbbbbbbb-0000-0000-0000-000000000005', '{}'::jsonb,  4,  9, 30),
        ('11111111-1111-1111-1111-111111111111'::uuid, 'bbbbbbbb-0000-0000-0000-000000000003'::uuid, 'staff1',     'login',  'users',         'bbbbbbbb-0000-0000-0000-000000000003', '{}'::jsonb,  3,  8, 40),
        ('11111111-1111-1111-1111-111111111111'::uuid, 'bbbbbbbb-0000-0000-0000-000000000002'::uuid, 'orgadmin',   'create', 'announcements', 'cccccccc-0000-0000-0000-000000000006', '{"title":"นัดประชุมเจ้าหน้าที่กองคลัง"}'::jsonb, 2, 15, 10),
        ('11111111-1111-1111-1111-111111111111'::uuid, 'bbbbbbbb-0000-0000-0000-000000000004'::uuid, 'staff2',     'login',  'users',         'bbbbbbbb-0000-0000-0000-000000000004', '{}'::jsonb,  2,  8, 55),
        ('11111111-1111-1111-1111-111111111111'::uuid, 'bbbbbbbb-0000-0000-0000-000000000001'::uuid, 'superadmin', 'login',  'users',         'bbbbbbbb-0000-0000-0000-000000000001', '{}'::jsonb,  1,  9, 0),
        ('11111111-1111-1111-1111-111111111111'::uuid, 'bbbbbbbb-0000-0000-0000-000000000003'::uuid, 'staff1',     'login_failed', 'users',   'bbbbbbbb-0000-0000-0000-000000000003', '{"reason":"wrong_password"}'::jsonb, 0, 7, 50),
        ('11111111-1111-1111-1111-111111111111'::uuid, 'bbbbbbbb-0000-0000-0000-000000000002'::uuid, 'orgadmin',   'login',  'users',         'bbbbbbbb-0000-0000-0000-000000000002', '{}'::jsonb,  0,  8, 5)
      ) as v(org_id, user_id, username, action, tbl, rec, extra, d, h, mi);
  end if;
end $$;


-- =====================================================================
-- 5) VIEW สำหรับข้อมูลสาธารณะ (ฝั่ง Guest อ่านจาก View เหล่านี้เท่านั้น)
-- =====================================================================
drop view if exists public.v_public_announcements;
create view public.v_public_announcements with (security_invoker = on) as
select a.id, a.title, a.content, a.cover_url, a.category, a.is_pinned, a.published_at, a.created_at,
       o.name as org_name, o.short_name as org_short_name
  from public.announcements a
  left join public.organizations o on o.id = a.org_id
 where a.is_public = true
   and a.published_at <= now();

drop view if exists public.v_public_stats;
create view public.v_public_stats with (security_invoker = on) as
select
  (select count(*) from public.organizations where is_active)                               as total_organizations,
  (select count(*) from public.users where is_active)                                       as total_users,
  (select count(*) from public.modules where status = 'active')                             as modules_active,
  (select count(*) from public.modules where status = 'coming_soon')                        as modules_coming_soon,
  (select count(*) from public.modules where status = 'disabled')                           as modules_disabled,
  (select count(*) from public.announcements where is_public and published_at <= now())     as public_announcements,
  now()                                                                                     as generated_at;

drop view if exists public.v_public_settings;
create view public.v_public_settings with (security_invoker = on) as
select setting_key, setting_value
  from public.system_settings
 where org_id is null and is_public = true;


-- =====================================================================
-- 6) RLS + สิทธิ์การเข้าถึง
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['organizations','users','roles','modules','permissions','role_permissions',
                           'user_permissions','menus','system_settings','audit_logs','announcements']
  loop
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

-- user_credentials : เปิด RLS แต่ "ไม่สร้าง Policy" → หน้าเว็บอ่าน/เขียนตรงไม่ได้
alter table public.user_credentials enable row level security;
do $$
declare p record;
begin
  for p in select policyname from pg_policies where schemaname = 'public' and tablename = 'user_credentials' loop
    execute format('drop policy if exists %I on public.user_credentials', p.policyname);
  end loop;
end $$;
revoke all on public.user_credentials from anon, authenticated;

-- View สาธารณะ
grant select on public.v_public_announcements, public.v_public_stats, public.v_public_settings to anon, authenticated;

-- ฟังก์ชัน RPC
revoke execute on function public.sfh_user_payload(uuid) from public, anon, authenticated;
grant execute on function public.sfh_login(text, text)                   to anon, authenticated;
grant execute on function public.sfh_refresh_session(uuid)               to anon, authenticated;
grant execute on function public.sfh_set_password(uuid, text)            to anon, authenticated;
grant execute on function public.sfh_change_password(uuid, text, text)   to anon, authenticated;
grant execute on function public.sfh_guest_menus()                       to anon, authenticated;


-- =====================================================================
-- 7) STORAGE : bucket sfh-files (Public)
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit)
values ('sfh-files', 'sfh-files', true, 5242880)
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit;

drop policy if exists "sfh_files_select" on storage.objects;
drop policy if exists "sfh_files_insert" on storage.objects;
drop policy if exists "sfh_files_update" on storage.objects;
drop policy if exists "sfh_files_delete" on storage.objects;

create policy "sfh_files_select" on storage.objects for select
  using (bucket_id = 'sfh-files');
create policy "sfh_files_insert" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'sfh-files');
create policy "sfh_files_update" on storage.objects for update to anon, authenticated
  using (bucket_id = 'sfh-files') with check (bucket_id = 'sfh-files');
create policy "sfh_files_delete" on storage.objects for delete to anon, authenticated
  using (bucket_id = 'sfh-files');


-- =====================================================================
-- 8) หมายเหตุด้านความปลอดภัย
-- =====================================================================
-- ⚠️ Policy แบบ true ใช้เพื่อการสอน/ทดสอบเท่านั้น
--    ห้ามใช้กับข้อมูลการเงินและข้อมูลส่วนบุคคลจริง (PDPA)
--
-- ทำไม: ระบบนี้ใช้ Custom Login ทุก request จากหน้าเว็บจึงเป็น role "anon"
--       และ Policy USING (true) ทำให้ใครก็ตามที่มี ANON KEY (ซึ่งเปิดเผยอยู่ในหน้าเว็บ)
--       อ่าน/เพิ่ม/แก้/ลบข้อมูลได้โดยตรงผ่าน REST API การซ่อนปุ่มในหน้าเว็บจึงไม่ใช่ความปลอดภัยจริง
--       รวมถึง sfh_set_password ที่ใครรู้ user_id ก็ตั้งรหัสใหม่ได้
--
-- ถ้าจะใช้งานจริงต้องปรับอย่างน้อย:
--  1) ใช้ Supabase Auth (หรือออก JWT ของตนเองที่มี claim user_id / org_id / role)
--     แล้วเขียน Policy ตามสิทธิ์จริง เช่น
--       using (org_id = (auth.jwt() ->> 'org_id')::uuid)
--       using (created_by = auth.uid() or <มีสิทธิ์ view_all>)
--  2) ห้ามให้ anon เขียนข้อมูล: ถอน Policy INSERT/UPDATE/DELETE ของ anon
--     ย้ายงานเขียนไปทำผ่านฟังก์ชัน SECURITY DEFINER ที่ตรวจ Permission ในฐานข้อมูล
--  3) sfh_set_password ต้องตรวจว่าผู้เรียกเป็น Admin ของผู้ใช้นั้นจริง
--  4) audit_logs ให้เขียนได้อย่างเดียว (ห้าม UPDATE/DELETE) และบันทึกจาก Trigger ฝั่งฐานข้อมูล
--  5) Storage: จำกัดการอัปโหลดเฉพาะผู้ Login, จำกัดชนิด/ขนาดไฟล์, แยก bucket ข้อมูลส่วนบุคคลเป็น Private
--  6) เปิด Rate limit / ล็อกบัญชีเมื่อ Login ผิดหลายครั้ง และบังคับรหัสผ่านที่ปลอดภัย
-- =====================================================================
