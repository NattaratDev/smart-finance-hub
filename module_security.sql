-- =====================================================================
--  ไฟล์     : module_security.sql  (รันต่อจากไฟล์ module_*.sql ทั้งหมด / รันซ้ำได้)
--  เป้าหมาย : ปิดช่องโหว่ระบบแกนกลาง – ทุกการจัดการผู้ใช้ / Role / สิทธิ์ / หน่วยงาน /
--             โมดูล / เมนู / ตั้งค่า / Audit Log ต้องผ่านฟังก์ชันที่ตรวจ session token + สิทธิ์
--             (แบบเดียวกับสลิปเงินเดือน · sfh_payroll_auth)
--
--  ขั้นที่ 1 (ไฟล์นี้ส่วนที่ 1–9): เพิ่มฟังก์ชันใหม่เท่านั้น – ไม่เปลี่ยนสิทธิ์ตาราง ระบบเดิมใช้งานได้ตามปกติ
--  ขั้นที่ 3 (ส่วนที่ 10 ท้ายไฟล์ – ยังเป็นคอมเมนต์): ปิดการเขียนตารางตรง / ปิดการอ่านตารางที่มีข้อมูลบุคคล
--            ทำหลังจากหน้าเว็บเปลี่ยนมาใช้ฟังก์ชันใหม่ครบแล้วเท่านั้น
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) ตัวช่วย
-- ---------------------------------------------------------------------
create or replace function public.sfh_role_level(p_role_id uuid)
returns int language sql stable security definer set search_path = public as $$
  select coalesce((select level from public.roles where id = p_role_id), 0);
$$;

/** ผู้ทำรายการจัดการบัญชีเป้าหมายได้หรือไม่: Super Admin ได้ทุกบัญชี ·
 *  อื่น ๆ ต้องมี users.manage + หน่วยงานเดียวกัน + Role ของเป้าหมายต่ำกว่าตนเอง */
create or replace function public.sfh_can_manage_user(p_actor public.users, p_target_id uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare v_t public.users%rowtype;
begin
  if public.sfh_is_super(p_actor) then return true; end if;
  if not public.sfh_has_perm(p_actor.id, 'users.manage') then return false; end if;
  select * into v_t from public.users where id = p_target_id;
  if not found then return false; end if;
  return v_t.org_id is not distinct from p_actor.org_id
     and public.sfh_role_level(v_t.role_id) < public.sfh_role_level(p_actor.role_id);
end $$;

/** บันทึก Audit Log จากหน้าเว็บ (แทนการ insert ตาราง audit_logs ตรง)
 *  ผู้ใช้ระบุจาก token เท่านั้น (ปลอมชื่อผู้ใช้ไม่ได้) · ไม่มี token = guest */
create or replace function public.sfh_log(p_token text, p_action text, p_table text default null, p_record text default null,
                                          p_details jsonb default '{}'::jsonb, p_user_agent text default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_uid uuid := public.sfh_session_user(p_token); v_user public.users%rowtype;
begin
  if coalesce(btrim(p_action), '') = '' or length(p_action) > 60 then return; end if;
  if v_uid is not null then select * into v_user from public.users where id = v_uid; end if;
  insert into public.audit_logs (action, table_name, record_id, details, user_id, username, org_id, created_by, user_agent)
  values (left(p_action, 60), left(p_table, 60), left(p_record, 120),
          case when octet_length(coalesce(p_details, '{}'::jsonb)::text) > 8000 then jsonb_build_object('truncated', true) else coalesce(p_details, '{}'::jsonb) end,
          v_user.id, coalesce(v_user.username, 'guest'), v_user.org_id, v_user.id, left(p_user_agent, 250));
end $$;

-- ---------------------------------------------------------------------
-- 2) รหัสผ่าน (ช่องโหว่ร้ายแรง: sfh_set_password เดิมไม่ตรวจผู้เรียก)
-- ---------------------------------------------------------------------
create or replace function public.sfh_admin_set_password(p_token text, p_user_id uuid, p_new_password text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_actor public.users%rowtype; v_res jsonb; v_t public.users%rowtype;
begin
  v_actor := public.sfh_payroll_auth(p_token, 'users.manage');
  if not public.sfh_can_manage_user(v_actor, p_user_id) then raise exception 'FORBIDDEN: ไม่มีสิทธิ์ตั้งรหัสผ่านให้บัญชีนี้'; end if;
  v_res := public.sfh_set_password(p_user_id, p_new_password);
  if coalesce((v_res->>'success')::boolean, false) then
    select * into v_t from public.users where id = p_user_id;
    update public.sfh_sessions set revoked_at = now() where user_id = p_user_id and revoked_at is null and p_user_id <> v_actor.id;   -- ให้เข้าสู่ระบบใหม่
    perform public.sfh_rent_audit(v_actor, 'reset_password', 'users', p_user_id::text, jsonb_build_object('username', v_t.username));
  end if;
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- 3) ผู้ใช้งาน
-- ---------------------------------------------------------------------
create or replace function public.sfh_admin_users_list(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_actor public.users%rowtype; v_super boolean;
begin
  v_actor := public.sfh_payroll_auth(p_token, 'users.view');
  v_super := public.sfh_is_super(v_actor);
  return jsonb_build_object(
    'users', coalesce((select jsonb_agg(to_jsonb(u) || jsonb_build_object(
                 'roles', (select jsonb_build_object('id', r.id, 'role_key', r.role_key, 'name', r.name, 'color', r.color, 'level', r.level) from public.roles r where r.id = u.role_id),
                 'organizations', (select jsonb_build_object('id', o.id, 'name', o.name, 'short_name', o.short_name) from public.organizations o where o.id = u.org_id))
               order by u.created_at)
               from public.users u join public.roles ur on ur.id = u.role_id
              where v_super or (u.org_id is not distinct from v_actor.org_id and ur.role_key <> 'super_admin')), '[]'::jsonb),
    'roles', coalesce((select jsonb_agg(to_jsonb(r) order by r.level desc) from public.roles r
                        where r.role_key <> 'guest' and (v_super or r.role_key <> 'super_admin')), '[]'::jsonb),
    'orgs', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'short_name', o.short_name, 'is_active', o.is_active) order by o.name)
                        from public.organizations o), '[]'::jsonb));
end $$;

/** เพิ่ม (p_id = null) / แก้ไขผู้ใช้ · p_password ใช้เฉพาะตอนเพิ่ม */
create or replace function public.sfh_admin_user_save(p_token text, p_id uuid, p_data jsonb, p_password text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_actor public.users%rowtype; v_super boolean; v_t public.users%rowtype; v_self boolean;
        v_role uuid; v_org uuid; v_username text; v_id uuid; v_pw jsonb; v_my_level int;
begin
  v_actor := public.sfh_payroll_auth(p_token, 'users.manage');
  v_super := public.sfh_is_super(v_actor);
  v_my_level := public.sfh_role_level(v_actor.role_id);
  if nullif(btrim(p_data->>'full_name'), '') is null then raise exception 'กรุณากรอกชื่อ-นามสกุล'; end if;
  v_role := nullif(p_data->>'role_id', '')::uuid;
  v_org := case when v_super then nullif(p_data->>'org_id', '')::uuid else v_actor.org_id end;

  if p_id is null then
    v_username := lower(btrim(coalesce(p_data->>'username', '')));
    if v_username !~ '^[a-z0-9._-]{3,30}$' then raise exception 'username ต้องเป็น a-z, 0-9, . _ - ยาว 3–30 ตัวอักษร'; end if;
    if exists (select 1 from public.users where username = v_username) then raise exception 'มี username นี้แล้ว'; end if;
    if coalesce(length(p_password), 0) < 6 then raise exception 'รหัสผ่านต้องมีอย่างน้อย 6 ตัวอักษร'; end if;
    if v_role is null then raise exception 'กรุณาเลือก Role'; end if;
    if not v_super and public.sfh_role_level(v_role) >= v_my_level then raise exception 'FORBIDDEN: กำหนด Role นี้ไม่ได้'; end if;
    insert into public.users (org_id, role_id, username, full_name, position, email, phone, is_active, created_by)
    values (v_org, v_role, v_username, btrim(p_data->>'full_name'), nullif(btrim(p_data->>'position'), ''), nullif(btrim(p_data->>'email'), ''),
            nullif(btrim(p_data->>'phone'), ''), coalesce((p_data->>'is_active')::boolean, true), v_actor.id)
    returning id into v_id;
    v_pw := public.sfh_set_password(v_id, p_password);
    if not coalesce((v_pw->>'success')::boolean, false) then raise exception '%', v_pw->>'message'; end if;
    perform public.sfh_rent_audit(v_actor, 'create', 'users', v_id::text, jsonb_build_object('username', v_username, 'full_name', btrim(p_data->>'full_name')));
    return jsonb_build_object('id', v_id);
  end if;

  select * into v_t from public.users where id = p_id;
  if not found then raise exception 'ไม่พบผู้ใช้งาน'; end if;
  v_self := p_id = v_actor.id;
  if not v_self and not public.sfh_can_manage_user(v_actor, p_id) then raise exception 'FORBIDDEN: คุณไม่มีสิทธิ์แก้ไขบัญชีนี้'; end if;
  if not v_self and v_role is not null and not v_super and public.sfh_role_level(v_role) >= v_my_level then raise exception 'FORBIDDEN: กำหนด Role นี้ไม่ได้'; end if;
  update public.users set
    full_name = btrim(p_data->>'full_name'),
    position = nullif(btrim(p_data->>'position'), ''), email = nullif(btrim(p_data->>'email'), ''), phone = nullif(btrim(p_data->>'phone'), ''),
    org_id = case when v_super and p_data ? 'org_id' then v_org else org_id end,
    role_id = case when v_self or v_role is null then role_id else v_role end,
    is_active = case when v_self or not (p_data ? 'is_active') then is_active else (p_data->>'is_active')::boolean end
   where id = p_id;
  if not v_self and v_t.is_active and not coalesce((p_data->>'is_active')::boolean, true) then
    update public.sfh_sessions set revoked_at = now() where user_id = p_id and revoked_at is null;
  end if;
  perform public.sfh_rent_audit(v_actor, 'update', 'users', p_id::text, jsonb_build_object('username', v_t.username));
  return jsonb_build_object('id', p_id);
end $$;

create or replace function public.sfh_admin_user_set_active(p_token text, p_id uuid, p_active boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_actor public.users%rowtype; v_t public.users%rowtype;
begin
  v_actor := public.sfh_payroll_auth(p_token, 'users.manage');
  if p_id = v_actor.id then raise exception 'ไม่สามารถเปิด/ปิดบัญชีของตนเองได้'; end if;
  if not public.sfh_can_manage_user(v_actor, p_id) then raise exception 'FORBIDDEN: คุณไม่มีสิทธิ์แก้ไขบัญชีนี้'; end if;
  update public.users set is_active = p_active where id = p_id returning * into v_t;
  if not p_active then update public.sfh_sessions set revoked_at = now() where user_id = p_id and revoked_at is null; end if;
  perform public.sfh_rent_audit(v_actor, case when p_active then 'activate' else 'deactivate' end, 'users', p_id::text, jsonb_build_object('username', v_t.username));
end $$;

create or replace function public.sfh_admin_user_delete(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_actor public.users%rowtype; v_t public.users%rowtype;
begin
  v_actor := public.sfh_payroll_auth(p_token, 'users.manage');
  if not public.sfh_is_super(v_actor) then raise exception 'FORBIDDEN: ลบผู้ใช้ได้เฉพาะ Super Admin'; end if;
  if p_id = v_actor.id then raise exception 'ไม่สามารถลบบัญชีของตนเองได้'; end if;
  delete from public.users where id = p_id returning * into v_t;
  if found then perform public.sfh_rent_audit(v_actor, 'delete', 'users', p_id::text, jsonb_build_object('username', v_t.username, 'full_name', v_t.full_name)); end if;
end $$;

/** แก้ไขข้อมูลส่วนตัวของตนเอง (โปรไฟล์) */
create or replace function public.sfh_profile_save(p_token text, p_data jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_actor public.users%rowtype;
begin
  v_actor := public.sfh_payroll_auth(p_token, null);
  if nullif(btrim(p_data->>'full_name'), '') is null then raise exception 'กรุณากรอกชื่อ-นามสกุล'; end if;
  update public.users set full_name = btrim(p_data->>'full_name'),
         position = nullif(btrim(p_data->>'position'), ''), email = nullif(btrim(p_data->>'email'), ''), phone = nullif(btrim(p_data->>'phone'), ''),
         avatar_url = case when p_data ? 'avatar_url' then nullif(p_data->>'avatar_url', '') else avatar_url end
   where id = v_actor.id;
  perform public.sfh_rent_audit(v_actor, 'update', 'users', v_actor.id::text, jsonb_build_object('self', true, 'fields', (select jsonb_agg(k) from jsonb_object_keys(p_data) k)));
end $$;

/** รายชื่อผู้ใช้ที่ใช้งานอยู่ (ชื่อ/ตำแหน่ง) สำหรับเลือกผู้รับผิดชอบ เช่น ปฏิทินกองคลัง */
create or replace function public.sfh_user_directory(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_actor public.users%rowtype;
begin
  v_actor := public.sfh_payroll_auth(p_token, null);
  return coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'full_name', u.full_name, 'position', u.position, 'org_id', u.org_id) order by u.full_name)
                     from public.users u where u.is_active and (public.sfh_is_super(v_actor) or u.org_id is not distinct from v_actor.org_id)), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------
-- 4) สิทธิ์รายบุคคล
-- ---------------------------------------------------------------------
create or replace function public.sfh_admin_user_perms(p_token text, p_user_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_actor public.users%rowtype; v_t public.users%rowtype;
begin
  v_actor := public.sfh_payroll_auth(p_token, 'users.manage');
  if not public.sfh_can_manage_user(v_actor, p_user_id) then raise exception 'FORBIDDEN: คุณไม่มีสิทธิ์จัดการบัญชีนี้'; end if;
  select * into v_t from public.users where id = p_user_id;
  return jsonb_build_object(
    'perms', coalesce((select jsonb_agg(to_jsonb(p) order by p.sort_order) from public.permissions p), '[]'::jsonb),
    'role_perm_ids', coalesce((select jsonb_agg(permission_id) from public.role_permissions where role_id = v_t.role_id), '[]'::jsonb),
    'user_perm_ids', coalesce((select jsonb_agg(permission_id) from public.user_permissions where user_id = p_user_id), '[]'::jsonb),
    'modules', coalesce((select jsonb_agg(jsonb_build_object('module_key', m.module_key, 'name', m.name, 'status', m.status, 'allow_guest', m.allow_guest)) from public.modules m), '[]'::jsonb));
end $$;

create or replace function public.sfh_admin_user_perms_save(p_token text, p_user_id uuid, p_add uuid[], p_remove uuid[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_actor public.users%rowtype; v_t public.users%rowtype; v_super boolean; v_add uuid[]; v_rm uuid[];
begin
  v_actor := public.sfh_payroll_auth(p_token, 'users.manage');
  v_super := public.sfh_is_super(v_actor);
  if not public.sfh_can_manage_user(v_actor, p_user_id) then raise exception 'FORBIDDEN: คุณไม่มีสิทธิ์จัดการบัญชีนี้'; end if;
  select * into v_t from public.users where id = p_user_id;
  if exists (select 1 from public.roles where id = v_t.role_id and role_key = 'super_admin') then raise exception 'Super Admin ได้รับทุกสิทธิ์อยู่แล้ว'; end if;
  -- มอบได้: ไม่ใช่สิทธิ์จาก Role · Org Admin มอบได้เฉพาะ org_admin_grantable
  select coalesce(array_agg(p.id), '{}') into v_add from public.permissions p
   where p.id = any(coalesce(p_add, '{}')) and (v_super or p.org_admin_grantable)
     and not exists (select 1 from public.role_permissions rp where rp.role_id = v_t.role_id and rp.permission_id = p.id);
  select coalesce(array_agg(p.id), '{}') into v_rm from public.permissions p
   where p.id = any(coalesce(p_remove, '{}')) and (v_super or p.org_admin_grantable);
  insert into public.user_permissions (user_id, permission_id, org_id, created_by)
  select p_user_id, x, v_t.org_id, v_actor.id from unnest(v_add) x on conflict (user_id, permission_id) do nothing;
  delete from public.user_permissions where user_id = p_user_id and permission_id = any(v_rm);
  perform public.sfh_rent_audit(v_actor, 'update_permissions', 'user_permissions', p_user_id::text, jsonb_build_object('username', v_t.username,
    'added', (select coalesce(jsonb_agg(perm_key), '[]'::jsonb) from public.permissions where id = any(v_add)),
    'removed', (select coalesce(jsonb_agg(perm_key), '[]'::jsonb) from public.permissions where id = any(v_rm))));
  return jsonb_build_object('added', coalesce(array_length(v_add, 1), 0), 'removed', coalesce(array_length(v_rm, 1), 0));
end $$;

-- ---------------------------------------------------------------------
-- 5) Role & Permission
-- ---------------------------------------------------------------------
create or replace function public.sfh_admin_roles_data(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.sfh_payroll_auth(p_token, 'roles.manage');
  return jsonb_build_object(
    'roles', coalesce((select jsonb_agg(to_jsonb(r) order by r.level desc) from public.roles r), '[]'::jsonb),
    'perms', coalesce((select jsonb_agg(to_jsonb(p) order by p.sort_order) from public.permissions p), '[]'::jsonb),
    'rps', coalesce((select jsonb_agg(jsonb_build_object('role_id', role_id, 'permission_id', permission_id)) from public.role_permissions), '[]'::jsonb),
    'users', coalesce((select jsonb_agg(jsonb_build_object('role_id', role_id)) from public.users), '[]'::jsonb),   -- นับจำนวนผู้ใช้ต่อ Role (ไม่มีข้อมูลบุคคล)
    'mods', coalesce((select jsonb_agg(to_jsonb(m) order by m.sort_order) from public.modules m), '[]'::jsonb));
end $$;

create or replace function public.sfh_admin_role_save(p_token text, p_id uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_actor public.users%rowtype; v_r public.roles%rowtype; v_key text;
begin
  v_actor := public.sfh_payroll_auth(p_token, 'roles.manage');
  if p_id is null then
    v_key := lower(btrim(coalesce(p_data->>'role_key', '')));
    if v_key !~ '^[a-z][a-z0-9_]{2,29}$' then raise exception 'รหัส Role ต้องขึ้นต้นด้วย a-z แล้วตามด้วย a-z, 0-9 หรือ _ (3–30 ตัว)'; end if;
    if nullif(btrim(p_data->>'name'), '') is null then raise exception 'กรุณากรอกชื่อ Role'; end if;
    insert into public.roles (role_key, name, description, level, color)
    values (v_key, btrim(p_data->>'name'), nullif(btrim(p_data->>'description'), ''), least(99, greatest(1, coalesce((p_data->>'level')::int, 10))), coalesce(p_data->>'color', '#5AA9E6'))
    returning * into v_r;
    perform public.sfh_rent_audit(v_actor, 'create', 'roles', v_r.id::text, jsonb_build_object('role_key', v_key));
  else
    select * into v_r from public.roles where id = p_id;
    if not found then raise exception 'ไม่พบ Role'; end if;
    update public.roles set description = nullif(btrim(p_data->>'description'), ''), color = coalesce(p_data->>'color', color),
           name = case when is_system or nullif(btrim(p_data->>'name'), '') is null then name else btrim(p_data->>'name') end,
           level = case when is_system or not (p_data ? 'level') then level else least(99, greatest(1, (p_data->>'level')::int)) end
     where id = p_id returning * into v_r;
    perform public.sfh_rent_audit(v_actor, 'update', 'roles', p_id::text, jsonb_build_object('role_key', v_r.role_key));
  end if;
  return to_jsonb(v_r);
end $$;

create or replace function public.sfh_admin_role_delete(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_actor public.users%rowtype; v_r public.roles%rowtype;
begin
  v_actor := public.sfh_payroll_auth(p_token, 'roles.manage');
  if exists (select 1 from public.users where role_id = p_id) then raise exception 'ไม่สามารถลบได้ เนื่องจากยังมีผู้ใช้งานใน Role นี้'; end if;
  delete from public.roles where id = p_id returning * into v_r;   -- trigger กัน Role ระบบ
  if found then perform public.sfh_rent_audit(v_actor, 'delete', 'roles', p_id::text, jsonb_build_object('role_key', v_r.role_key)); end if;
end $$;

/** แก้สิทธิ์ของ Role · Role guest แก้ได้ทั้งผู้มี roles.manage และ public_menu.manage (หน้าเมนูสาธารณะ) */
create or replace function public.sfh_admin_role_perms_save(p_token text, p_role_id uuid, p_add uuid[], p_remove uuid[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_actor public.users%rowtype; v_r public.roles%rowtype;
begin
  v_actor := public.sfh_payroll_auth(p_token, null);
  select * into v_r from public.roles where id = p_role_id;
  if not found then raise exception 'ไม่พบ Role'; end if;
  if not (public.sfh_has_perm(v_actor.id, 'roles.manage') or (v_r.role_key = 'guest' and public.sfh_has_perm(v_actor.id, 'public_menu.manage'))) then
    raise exception 'FORBIDDEN: roles.manage' using hint = 'ไม่มีสิทธิ์ทำรายการนี้';
  end if;
  if v_r.role_key = 'super_admin' then raise exception 'Super Admin ได้รับทุกสิทธิ์อยู่แล้ว'; end if;
  insert into public.role_permissions (role_id, permission_id, created_by)
  select p_role_id, x, v_actor.id from unnest(coalesce(p_add, '{}')) x on conflict (role_id, permission_id) do nothing;   -- trigger ตรวจสิทธิ์ guest
  delete from public.role_permissions where role_id = p_role_id and permission_id = any(coalesce(p_remove, '{}'));
  perform public.sfh_rent_audit(v_actor, 'update_permissions', 'role_permissions', p_role_id::text, jsonb_build_object('role_key', v_r.role_key,
    'added', (select coalesce(jsonb_agg(perm_key), '[]'::jsonb) from public.permissions where id = any(coalesce(p_add, '{}'))),
    'removed', (select coalesce(jsonb_agg(perm_key), '[]'::jsonb) from public.permissions where id = any(coalesce(p_remove, '{}')))));
  return jsonb_build_object('ok', true);
end $$;

/** เพิ่ม Permission (p_id = null: module_key, action, name) / แก้ org_admin_grantable */
create or replace function public.sfh_admin_perm_save(p_token text, p_id uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_actor public.users%rowtype; v_p public.permissions%rowtype; v_action text; v_mod text;
begin
  v_actor := public.sfh_payroll_auth(p_token, 'roles.manage');
  if p_id is null then
    v_action := lower(btrim(coalesce(p_data->>'action', ''))); v_mod := btrim(coalesce(p_data->>'module_key', ''));
    if v_action !~ '^[a-z_]{2,30}$' then raise exception 'action ใช้ได้เฉพาะ a-z และ _'; end if;
    if not exists (select 1 from public.modules where module_key = v_mod) then raise exception 'ไม่พบโมดูล'; end if;
    insert into public.permissions (module_key, action, perm_key, name, sort_order)
    values (v_mod, v_action, v_mod || '.' || v_action, coalesce(nullif(btrim(p_data->>'name'), ''), v_mod || '.' || v_action), 500)
    returning * into v_p;
    perform public.sfh_rent_audit(v_actor, 'create', 'permissions', v_p.id::text, jsonb_build_object('perm_key', v_p.perm_key));
  else
    update public.permissions set org_admin_grantable = coalesce((p_data->>'org_admin_grantable')::boolean, org_admin_grantable)
     where id = p_id returning * into v_p;
    if not found then raise exception 'ไม่พบ Permission'; end if;
    perform public.sfh_rent_audit(v_actor, 'update', 'permissions', p_id::text, jsonb_build_object('perm_key', v_p.perm_key, 'org_admin_grantable', v_p.org_admin_grantable));
  end if;
  return to_jsonb(v_p);
end $$;

create or replace function public.sfh_admin_perm_delete(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_actor public.users%rowtype; v_p public.permissions%rowtype;
begin
  v_actor := public.sfh_payroll_auth(p_token, 'roles.manage');
  delete from public.permissions where id = p_id returning * into v_p;
  if found then perform public.sfh_rent_audit(v_actor, 'delete', 'permissions', p_id::text, jsonb_build_object('perm_key', v_p.perm_key)); end if;
end $$;

-- ---------------------------------------------------------------------
-- 6) หน่วยงาน
-- ---------------------------------------------------------------------
create or replace function public.sfh_admin_orgs_list(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.sfh_payroll_auth(p_token, 'organizations.manage');
  return coalesce((select jsonb_agg(to_jsonb(o) || jsonb_build_object('user_count', (select count(*) from public.users u where u.org_id = o.id)) order by o.code)
                     from public.organizations o), '[]'::jsonb);
end $$;

create or replace function public.sfh_admin_org_save(p_token text, p_id uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_actor public.users%rowtype; v_o public.organizations%rowtype;
begin
  v_actor := public.sfh_payroll_auth(p_token, 'organizations.manage');
  if nullif(btrim(p_data->>'code'), '') is null or nullif(btrim(p_data->>'name'), '') is null then raise exception 'กรุณากรอกรหัสและชื่อหน่วยงาน'; end if;
  if p_id is null then
    insert into public.organizations (code, name, short_name, phone, email, address, description, is_active, created_by)
    values (upper(btrim(p_data->>'code')), btrim(p_data->>'name'), nullif(btrim(p_data->>'short_name'), ''), nullif(btrim(p_data->>'phone'), ''),
            nullif(btrim(p_data->>'email'), ''), nullif(btrim(p_data->>'address'), ''), nullif(btrim(p_data->>'description'), ''),
            coalesce((p_data->>'is_active')::boolean, true), v_actor.id)
    returning * into v_o;
  else
    update public.organizations set code = upper(btrim(p_data->>'code')), name = btrim(p_data->>'name'), short_name = nullif(btrim(p_data->>'short_name'), ''),
           phone = nullif(btrim(p_data->>'phone'), ''), email = nullif(btrim(p_data->>'email'), ''), address = nullif(btrim(p_data->>'address'), ''),
           description = nullif(btrim(p_data->>'description'), ''), is_active = coalesce((p_data->>'is_active')::boolean, is_active)
     where id = p_id returning * into v_o;
    if not found then raise exception 'ไม่พบหน่วยงาน'; end if;
  end if;
  perform public.sfh_rent_audit(v_actor, case when p_id is null then 'create' else 'update' end, 'organizations', v_o.id::text, jsonb_build_object('code', v_o.code, 'name', v_o.name));
  return to_jsonb(v_o);
end $$;

create or replace function public.sfh_admin_org_delete(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_actor public.users%rowtype; v_o public.organizations%rowtype;
begin
  v_actor := public.sfh_payroll_auth(p_token, 'organizations.manage');
  if exists (select 1 from public.users where org_id = p_id) then raise exception 'ไม่สามารถลบได้ เนื่องจากมีผู้ใช้งานในหน่วยงานนี้ (แนะนำให้ปิดใช้งานแทน)'; end if;
  delete from public.organizations where id = p_id returning * into v_o;
  if found then perform public.sfh_rent_audit(v_actor, 'delete', 'organizations', p_id::text, jsonb_build_object('code', v_o.code, 'name', v_o.name)); end if;
end $$;

/** ข้อมูลติดต่อหน่วยงาน (หน้าตั้งค่าหน่วยงาน) · settings.org แก้ได้เฉพาะหน่วยงานตนเอง */
create or replace function public.sfh_org_profile_save(p_token text, p_org_id uuid, p_data jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_actor public.users%rowtype;
begin
  v_actor := public.sfh_payroll_auth(p_token, 'settings.org');
  if not public.sfh_is_super(v_actor) and p_org_id is distinct from v_actor.org_id then raise exception 'FORBIDDEN: แก้ไขได้เฉพาะหน่วยงานของตนเอง'; end if;
  update public.organizations set phone = nullif(btrim(p_data->>'phone'), ''), email = nullif(btrim(p_data->>'email'), ''),
         address = nullif(btrim(p_data->>'address'), ''), description = nullif(btrim(p_data->>'description'), '')
   where id = p_org_id;
end $$;

-- ---------------------------------------------------------------------
-- 7) โมดูล / เมนูสาธารณะ
-- ---------------------------------------------------------------------
/** แก้ไขโมดูล: ส่งเฉพาะฟิลด์ที่ต้องการเปลี่ยน (name, description, icon, color, version, sort_order, planned_features, status, allow_guest) */
create or replace function public.sfh_admin_module_save(p_token text, p_id uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_actor public.users%rowtype; v_m public.modules%rowtype; v_old public.modules%rowtype;
begin
  v_actor := public.sfh_payroll_auth(p_token, 'modules.manage');
  select * into v_old from public.modules where id = p_id;
  if not found then raise exception 'ไม่พบโมดูล'; end if;
  if p_data ? 'status' and p_data->>'status' not in ('active', 'coming_soon', 'disabled') then raise exception 'สถานะไม่ถูกต้อง'; end if;
  if p_data ? 'name' and nullif(btrim(p_data->>'name'), '') is null then raise exception 'กรุณากรอกชื่อโมดูล'; end if;
  update public.modules set
    name = case when p_data ? 'name' then btrim(p_data->>'name') else name end,
    description = case when p_data ? 'description' then nullif(btrim(p_data->>'description'), '') else description end,
    icon = case when p_data ? 'icon' then coalesce(nullif(btrim(p_data->>'icon'), ''), 'box') else icon end,
    color = case when p_data ? 'color' then p_data->>'color' else color end,
    version = case when p_data ? 'version' then coalesce(nullif(btrim(p_data->>'version'), ''), '0.1.0') else version end,
    sort_order = case when p_data ? 'sort_order' then coalesce((p_data->>'sort_order')::int, 100) else sort_order end,
    planned_features = case when p_data ? 'planned_features' then coalesce(p_data->'planned_features', '[]'::jsonb) else planned_features end,
    status = case when p_data ? 'status' then p_data->>'status' else status end,
    allow_guest = case when p_data ? 'allow_guest' then (p_data->>'allow_guest')::boolean else allow_guest end   -- trigger กันโมดูลที่ล็อก
   where id = p_id returning * into v_m;
  perform public.sfh_rent_audit(v_actor, case when p_data ? 'status' then 'update_status' else 'update' end, 'modules', v_m.module_key,
    case when p_data ? 'status' then jsonb_build_object('from', v_old.status, 'to', v_m.status) else (select jsonb_object_agg(k, p_data->k) from jsonb_object_keys(p_data) k where k in ('name', 'allow_guest')) end);
  return to_jsonb(v_m);
end $$;

/** บันทึกเมนูสาธารณะ: ชื่อ/ไอคอน/ลำดับเมนู + เปิด/ปิดสิทธิ์ guest
 *  p_menus = [{ id, label, icon, sort_order }] */
create or replace function public.sfh_admin_public_menu_save(p_token text, p_menus jsonb, p_guest_add uuid[], p_guest_remove uuid[], p_details jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_actor public.users%rowtype; v_guest uuid; v_m jsonb;
begin
  v_actor := public.sfh_payroll_auth(p_token, 'public_menu.manage');
  for v_m in select * from jsonb_array_elements(coalesce(p_menus, '[]'::jsonb)) loop
    if nullif(btrim(v_m->>'label'), '') is null then raise exception 'กรุณากรอกชื่อเมนูให้ครบ'; end if;
    update public.menus set label = btrim(v_m->>'label'), icon = coalesce(nullif(btrim(v_m->>'icon'), ''), 'circle'), sort_order = (v_m->>'sort_order')::int
     where id = (v_m->>'id')::uuid;
  end loop;
  select id into v_guest from public.roles where role_key = 'guest';
  insert into public.role_permissions (role_id, permission_id, created_by)
  select v_guest, x, v_actor.id from unnest(coalesce(p_guest_add, '{}')) x on conflict (role_id, permission_id) do nothing;   -- trigger ตรวจ view_public/use_public
  delete from public.role_permissions where role_id = v_guest and permission_id = any(coalesce(p_guest_remove, '{}'));
  perform public.sfh_rent_audit(v_actor, 'update_public_menu', 'menus', null, coalesce(p_details, '{}'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 8) ตั้งค่าระบบ
-- ---------------------------------------------------------------------
/** อ่านค่าตั้ง: settings.manage = ทั้งหมด · settings.org = ระดับ Platform ที่เป็นสาธารณะ + หน่วยงานตนเอง */
create or replace function public.sfh_settings_list(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_actor public.users%rowtype; v_all boolean;
begin
  v_actor := public.sfh_payroll_auth(p_token, null);
  v_all := public.sfh_has_perm(v_actor.id, 'settings.manage');
  if not v_all and not public.sfh_has_perm(v_actor.id, 'settings.org') then raise exception 'FORBIDDEN: settings.org' using hint = 'ไม่มีสิทธิ์ทำรายการนี้'; end if;
  return coalesce((select jsonb_agg(to_jsonb(s)) from public.system_settings s
                    where v_all or (s.org_id is null and s.is_public) or s.org_id is not distinct from v_actor.org_id), '[]'::jsonb);
end $$;

/** บันทึกค่าตั้ง (upsert ตาม org_id + setting_key) · p_org_id null = ระดับ Platform (settings.manage) */
create or replace function public.sfh_settings_save(p_token text, p_org_id uuid, p_values jsonb, p_public boolean default false, p_details jsonb default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_actor public.users%rowtype; v_k text; v_v text;
begin
  v_actor := public.sfh_payroll_auth(p_token, case when p_org_id is null then 'settings.manage' else 'settings.org' end);
  if p_org_id is not null and not public.sfh_is_super(v_actor) and p_org_id is distinct from v_actor.org_id then
    raise exception 'FORBIDDEN: แก้ไขได้เฉพาะหน่วยงานของตนเอง';
  end if;
  for v_k, v_v in select key, value from jsonb_each_text(coalesce(p_values, '{}'::jsonb)) loop
    if v_k !~ '^[a-z0-9_]{2,60}$' then continue; end if;
    update public.system_settings set setting_value = v_v where org_id is not distinct from p_org_id and setting_key = v_k;
    if not found then
      insert into public.system_settings (org_id, setting_key, setting_value, is_public, created_by) values (p_org_id, v_k, v_v, coalesce(p_public, false), v_actor.id);
    end if;
  end loop;
  perform public.sfh_rent_audit(v_actor, 'update_settings', 'system_settings', coalesce(p_org_id::text, 'platform'),
    coalesce(p_details, jsonb_build_object('scope', case when p_org_id is null then 'platform' else 'organization' end, 'keys', (select jsonb_agg(k) from jsonb_object_keys(coalesce(p_values, '{}'::jsonb)) k))));
end $$;

/** ค่าตั้งของหน่วยงานตนเองที่ใช้ในเอกสาร (เช่น ผู้ลงนาม) – ผู้ใช้ที่เข้าสู่ระบบอ่านได้ */
create or replace function public.sfh_org_settings_get(p_token text, p_keys text[])
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_actor public.users%rowtype;
begin
  v_actor := public.sfh_payroll_auth(p_token, null);
  return coalesce((select jsonb_object_agg(setting_key, setting_value) from public.system_settings
                    where org_id is not distinct from v_actor.org_id
                      and setting_key = any(p_keys) and setting_key in ('signer_name', 'signer_position', 'doc_footer')), '{}'::jsonb);
end $$;

-- ---------------------------------------------------------------------
-- 9) Audit Log / แดชบอร์ด
-- ---------------------------------------------------------------------
/** Audit Log: audit.view · Super Admin เห็นทั้งระบบ อื่น ๆ เห็นเฉพาะหน่วยงานตนเอง (สูงสุด 1,000 รายการ) */
create or replace function public.sfh_audit_list(p_token text, p_limit int default 1000)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_actor public.users%rowtype; v_super boolean;
begin
  v_actor := public.sfh_payroll_auth(p_token, 'audit.view');
  v_super := public.sfh_is_super(v_actor);
  return coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at desc) from (
            select * from public.audit_logs where v_super or org_id is not distinct from v_actor.org_id
             order by created_at desc limit least(greatest(coalesce(p_limit, 1000), 1), 1000)) a), '[]'::jsonb);
end $$;

/** ข้อมูลแดชบอร์ด · super: ภาพรวมทั้งระบบ · users.view: เฉพาะหน่วยงานตนเอง · อื่น ๆ: ว่าง */
create or replace function public.sfh_dashboard_data(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_actor public.users%rowtype; v_since timestamptz := date_trunc('day', now()) - interval '13 days';
begin
  v_actor := public.sfh_payroll_auth(p_token, null);
  if public.sfh_is_super(v_actor) then
    return jsonb_build_object('scope', 'super',
      'users', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'is_active', is_active, 'role_id', role_id, 'org_id', org_id)) from public.users), '[]'::jsonb),
      'logins', coalesce((select jsonb_agg(jsonb_build_object('created_at', created_at)) from public.audit_logs where action = 'login' and created_at >= v_since), '[]'::jsonb),
      'logs', coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at desc) from (select * from public.audit_logs order by created_at desc limit 8) a), '[]'::jsonb));
  elsif public.sfh_has_perm(v_actor.id, 'users.view') then
    return jsonb_build_object('scope', 'org',
      'users', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'is_active', u.is_active, 'full_name', u.full_name, 'position', u.position,
                  'last_login_at', u.last_login_at, 'avatar_url', u.avatar_url, 'roles', jsonb_build_object('name', r.name, 'color', r.color, 'role_key', r.role_key)))
                  from public.users u join public.roles r on r.id = u.role_id where u.org_id is not distinct from v_actor.org_id), '[]'::jsonb),
      'logins', coalesce((select jsonb_agg(jsonb_build_object('created_at', created_at)) from public.audit_logs
                  where org_id is not distinct from v_actor.org_id and action = 'login' and created_at >= v_since), '[]'::jsonb),
      'logs', coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at desc) from (select * from public.audit_logs
                  where org_id is not distinct from v_actor.org_id order by created_at desc limit 8) a), '[]'::jsonb));
  end if;
  return jsonb_build_object('scope', 'none', 'users', '[]'::jsonb, 'logins', '[]'::jsonb, 'logs', '[]'::jsonb);
end $$;

-- สิทธิ์เรียกใช้ฟังก์ชันใหม่ (ทุกฟังก์ชันตรวจ token/สิทธิ์ภายในเอง)
do $$
declare f text;
begin
  foreach f in array array[
    'sfh_log(text, text, text, text, jsonb, text)', 'sfh_admin_set_password(text, uuid, text)',
    'sfh_admin_users_list(text)', 'sfh_admin_user_save(text, uuid, jsonb, text)', 'sfh_admin_user_set_active(text, uuid, boolean)',
    'sfh_admin_user_delete(text, uuid)', 'sfh_profile_save(text, jsonb)', 'sfh_user_directory(text)',
    'sfh_admin_user_perms(text, uuid)', 'sfh_admin_user_perms_save(text, uuid, uuid[], uuid[])',
    'sfh_admin_roles_data(text)', 'sfh_admin_role_save(text, uuid, jsonb)', 'sfh_admin_role_delete(text, uuid)',
    'sfh_admin_role_perms_save(text, uuid, uuid[], uuid[])', 'sfh_admin_perm_save(text, uuid, jsonb)', 'sfh_admin_perm_delete(text, uuid)',
    'sfh_admin_orgs_list(text)', 'sfh_admin_org_save(text, uuid, jsonb)', 'sfh_admin_org_delete(text, uuid)', 'sfh_org_profile_save(text, uuid, jsonb)',
    'sfh_admin_module_save(text, uuid, jsonb)', 'sfh_admin_public_menu_save(text, jsonb, uuid[], uuid[], jsonb)',
    'sfh_settings_list(text)', 'sfh_settings_save(text, uuid, jsonb, boolean, jsonb)', 'sfh_org_settings_get(text, text[])',
    'sfh_audit_list(text, integer)', 'sfh_dashboard_data(text)'] loop
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
  -- ตัวช่วยภายใน: เรียกจากหน้าเว็บไม่ได้
  revoke execute on function public.sfh_role_level(uuid) from public, anon, authenticated;
  revoke execute on function public.sfh_can_manage_user(public.users, uuid) from public, anon, authenticated;
end $$;

-- =====================================================================
-- 10) ขั้นที่ 3 – ปิดการเข้าถึงตารางตรง (ยังไม่รัน · รันหลังหน้าเว็บใช้ฟังก์ชันใหม่ครบแล้ว)
-- =====================================================================
-- revoke execute on function public.sfh_set_password(uuid, text) from public, anon, authenticated;   -- ใช้ผ่าน sfh_admin_set_password / sfh_change_password เท่านั้น
-- ... (ปิด insert/update/delete ตารางแกนกลาง · ปิดการอ่าน users/user_permissions/audit_logs/system_settings
--      · ปรับ view สาธารณะที่อ่าน system_settings/users ให้ไม่พึ่งสิทธิ์ผู้เรียก) – จะเพิ่มในขั้นที่ 3
