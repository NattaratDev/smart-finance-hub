-- =====================================================================
--  ไฟล์     : module_security_saraban.sql  (รันต่อจาก module_security.sql · รันซ้ำได้)
--  เป้าหมาย : งานสารบรรณ + ที่เก็บไฟล์ (Storage) ต้องผ่านฟังก์ชันที่ตรวจ session token + สิทธิ์
--
--  ไฟล์นี้เพิ่มฟังก์ชันใหม่เท่านั้น ไม่เปลี่ยนสิทธิ์ตาราง (ระบบเดิมใช้งานได้ตามปกติ)
--  การปิดการเข้าถึงตรงอยู่ในไฟล์ module_security_saraban_lockdown.sql (รันหลังหน้าเว็บรุ่นใหม่ขึ้นระบบแล้ว)
--
--  สิทธิ์การมองเห็นเอกสาร (เหมือนหน้าเว็บเดิม)
--   - เอกสารสาธารณะ: ทุกคน
--   - Super Admin: ทุกเอกสาร
--   - ผู้มี saraban.view_all: เอกสารทุกระดับของหน่วยงานตนเอง
--   - ผู้มี saraban.view: เอกสาร "ภายใน" ของหน่วยงานตนเอง + เอกสารที่ตนเองบันทึก
--  สิทธิ์แก้ไข/ลบ: Super Admin · Org Admin หรือผู้มี view_all ในหน่วยงานเดียวกัน · ผู้บันทึกเอง
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) ตัวช่วยตรวจสิทธิ์ (ภายใน)
-- ---------------------------------------------------------------------
create or replace function public.sfh_saraban_can_view(p_u public.users, p_d public.saraban_documents)
returns boolean language sql stable security definer set search_path = public as $$
  select p_d.access_level = 'public'
      or public.sfh_is_super(p_u)
      or (public.sfh_has_perm(p_u.id, 'saraban.view')
          and p_d.org_id is not distinct from p_u.org_id
          and (public.sfh_has_perm(p_u.id, 'saraban.view_all') or p_d.access_level = 'internal' or p_d.created_by = p_u.id));
$$;

create or replace function public.sfh_saraban_can_edit(p_u public.users, p_d public.saraban_documents, p_action text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.sfh_has_perm(p_u.id, 'saraban.' || p_action)
     and (public.sfh_is_super(p_u)
          or (p_d.org_id is not null and p_d.org_id = p_u.org_id
              and (exists (select 1 from public.roles r where r.id = p_u.role_id and r.role_key = 'org_admin')
                   or public.sfh_has_perm(p_u.id, 'saraban.view_all')))
          or p_d.created_by = p_u.id);
$$;

create or replace function public.sfh_saraban_files_json(p_doc_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'file_name', f.file_name, 'file_path', f.file_path, 'file_url', f.file_url,
                                               'mime_type', f.mime_type, 'file_size', f.file_size, 'sort_order', f.sort_order) order by f.sort_order), '[]'::jsonb)
    from public.saraban_files f where f.doc_id = p_doc_id;
$$;

-- ---------------------------------------------------------------------
-- 2) อ่านข้อมูล
-- ---------------------------------------------------------------------
/** ประเภทเอกสาร + เอกสารที่ผู้ใช้มีสิทธิ์เห็น (พร้อมประเภท หน่วยงาน ไฟล์แนบ) */
create or replace function public.sfh_saraban_list(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_u public.users%rowtype;
begin
  v_u := public.sfh_payroll_auth(p_token, 'saraban.view');
  return jsonb_build_object(
    'cats', coalesce((select jsonb_agg(to_jsonb(c) order by c.sort_order) from public.saraban_categories c), '[]'::jsonb),
    'docs', coalesce((select jsonb_agg(to_jsonb(d) || jsonb_build_object(
                 'saraban_categories', (select to_jsonb(c) from public.saraban_categories c where c.id = d.category_id),
                 'organizations', (select jsonb_build_object('name', o.name, 'short_name', o.short_name) from public.organizations o where o.id = d.org_id),
                 'saraban_files', public.sfh_saraban_files_json(d.id))
               order by d.created_at desc)
               from public.saraban_documents d where public.sfh_saraban_can_view(v_u, d)), '[]'::jsonb));
end $$;

/** รายการหนังสือให้เลือกเชื่อมโยง (ปฏิทินกองคลัง) – ไม่รวมเอกสารจำกัดสิทธิ์ */
create or replace function public.sfh_saraban_doc_options(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_u public.users%rowtype;
begin
  v_u := public.sfh_payroll_auth(p_token, 'saraban.view');
  return coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'doc_no', x.doc_no, 'title', x.title, 'access_level', x.access_level, 'org_id', x.org_id) order by x.created_at desc)
                     from (select d.* from public.saraban_documents d
                            where d.access_level <> 'restricted' and public.sfh_saraban_can_view(v_u, d)
                            order by d.created_at desc limit 800) x), '[]'::jsonb);
end $$;

/** หนังสือ 1 ฉบับ + ไฟล์แนบ (ถ้ามีสิทธิ์เห็น) – ใช้แสดงหนังสือที่เกี่ยวข้องในปฏิทิน */
create or replace function public.sfh_saraban_doc_get(p_token text, p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_u public.users%rowtype; v_d public.saraban_documents%rowtype;
begin
  v_u := public.sfh_payroll_auth(p_token, 'saraban.view');
  select * into v_d from public.saraban_documents where id = p_id;
  if not found or not public.sfh_saraban_can_view(v_u, v_d) then return null; end if;
  return jsonb_build_object('doc', jsonb_build_object('id', v_d.id, 'doc_no', v_d.doc_no, 'title', v_d.title), 'files', public.sfh_saraban_files_json(v_d.id));
end $$;

-- ---------------------------------------------------------------------
-- 3) บันทึก / ลบเอกสาร
-- ---------------------------------------------------------------------
/** เพิ่ม (p_id = null) / แก้ไขเอกสาร + เพิ่มไฟล์แนบ (p_files_add) + นำไฟล์ออก (p_files_remove)
 *  คืน { doc, removed_paths } – removed_paths = ไฟล์ใน Storage ที่หน้าเว็บควรลบต่อ */
create or replace function public.sfh_saraban_save(p_token text, p_id uuid, p_data jsonb, p_files_add jsonb default '[]'::jsonb, p_files_remove uuid[] default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_u public.users%rowtype; v_d public.saraban_documents%rowtype; v_super boolean; v_paths text[]; v_f jsonb; v_n int := 0;
begin
  v_u := public.sfh_payroll_auth(p_token, case when p_id is null then 'saraban.create' else 'saraban.update' end);
  v_super := public.sfh_is_super(v_u);
  if nullif(btrim(p_data->>'title'), '') is null then raise exception 'กรุณากรอกชื่อเรื่อง'; end if;
  if not exists (select 1 from public.saraban_categories where id = nullif(p_data->>'category_id', '')::uuid) then raise exception 'ไม่พบประเภทเอกสาร'; end if;

  if p_id is null then
    insert into public.saraban_documents (org_id, category_id, doc_no, doc_date, received_date, title, from_org, to_org, summary, keywords, urgency, access_level, created_by)
    values (case when v_super and p_data ? 'org_id' then nullif(p_data->>'org_id', '')::uuid else v_u.org_id end,
            (p_data->>'category_id')::uuid, nullif(btrim(p_data->>'doc_no'), ''), nullif(p_data->>'doc_date', '')::date, nullif(p_data->>'received_date', '')::date,
            btrim(p_data->>'title'), nullif(btrim(p_data->>'from_org'), ''), nullif(btrim(p_data->>'to_org'), ''), nullif(btrim(p_data->>'summary'), ''),
            nullif(btrim(p_data->>'keywords'), ''), coalesce(nullif(p_data->>'urgency', ''), 'normal'), coalesce(nullif(p_data->>'access_level', ''), 'internal'), v_u.id)
    returning * into v_d;
  else
    select * into v_d from public.saraban_documents where id = p_id;
    if not found then raise exception 'ไม่พบเอกสาร'; end if;
    if not public.sfh_saraban_can_edit(v_u, v_d, 'update') then raise exception 'FORBIDDEN: แก้ไขได้เฉพาะเอกสารที่ตนเองบันทึก'; end if;
    update public.saraban_documents set
      category_id = (p_data->>'category_id')::uuid, doc_no = nullif(btrim(p_data->>'doc_no'), ''),
      doc_date = nullif(p_data->>'doc_date', '')::date, received_date = nullif(p_data->>'received_date', '')::date,
      title = btrim(p_data->>'title'), from_org = nullif(btrim(p_data->>'from_org'), ''), to_org = nullif(btrim(p_data->>'to_org'), ''),
      summary = nullif(btrim(p_data->>'summary'), ''), keywords = nullif(btrim(p_data->>'keywords'), ''),
      urgency = coalesce(nullif(p_data->>'urgency', ''), urgency), access_level = coalesce(nullif(p_data->>'access_level', ''), access_level),
      org_id = case when v_super and p_data ? 'org_id' then nullif(p_data->>'org_id', '')::uuid else org_id end,
      reg_year = coalesce(nullif(p_data->>'reg_year', '')::int, reg_year)
     where id = p_id returning * into v_d;
  end if;

  for v_f in select * from jsonb_array_elements(coalesce(p_files_add, '[]'::jsonb)) loop
    if coalesce(v_f->>'file_path', '') !~ '^saraban/' then raise exception 'ไฟล์แนบไม่ถูกต้อง'; end if;
    insert into public.saraban_files (doc_id, org_id, file_name, file_path, file_url, mime_type, file_size, sort_order, created_by)
    values (v_d.id, v_d.org_id, coalesce(nullif(btrim(v_f->>'file_name'), ''), 'file'), v_f->>'file_path', coalesce(v_f->>'file_url', ''),
            nullif(v_f->>'mime_type', ''), coalesce((v_f->>'file_size')::bigint, 0), coalesce((v_f->>'sort_order')::int, 0), v_u.id);
    v_n := v_n + 1;
  end loop;
  with x as (delete from public.saraban_files where doc_id = v_d.id and id = any(coalesce(p_files_remove, '{}')) returning file_path)
  select coalesce(array_agg(file_path), '{}') into v_paths from x;

  perform public.sfh_rent_audit(v_u, case when p_id is null then 'create' else 'update' end, 'saraban_documents', v_d.id::text,
    jsonb_build_object('title', v_d.title, 'doc_no', v_d.doc_no, 'files_added', v_n, 'files_removed', coalesce(array_length(v_paths, 1), 0)));
  return jsonb_build_object('doc', to_jsonb(v_d), 'removed_paths', to_jsonb(v_paths));
end $$;

/** ลบเอกสาร (ไฟล์แนบในตารางถูกลบตาม) – คืน path ไฟล์ใน Storage ที่หน้าเว็บควรลบต่อ */
create or replace function public.sfh_saraban_delete(p_token text, p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_u public.users%rowtype; v_d public.saraban_documents%rowtype; v_paths text[];
begin
  v_u := public.sfh_payroll_auth(p_token, 'saraban.delete');
  select * into v_d from public.saraban_documents where id = p_id;
  if not found then return jsonb_build_object('removed_paths', '[]'::jsonb); end if;
  if not public.sfh_saraban_can_edit(v_u, v_d, 'delete') then raise exception 'FORBIDDEN: ลบได้เฉพาะเอกสารที่ตนเองบันทึก'; end if;
  select coalesce(array_agg(file_path), '{}') into v_paths from public.saraban_files where doc_id = p_id;
  delete from public.saraban_documents where id = p_id;
  perform public.sfh_rent_audit(v_u, 'delete', 'saraban_documents', p_id::text, jsonb_build_object('title', v_d.title, 'doc_no', v_d.doc_no, 'files', coalesce(array_length(v_paths, 1), 0)));
  return jsonb_build_object('removed_paths', to_jsonb(v_paths));
end $$;

-- ---------------------------------------------------------------------
-- 4) ประเภทเอกสาร (saraban.manage_types)
-- ---------------------------------------------------------------------
create or replace function public.sfh_saraban_cat_save(p_token text, p_id uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_u public.users%rowtype; v_c public.saraban_categories%rowtype; v_key text;
begin
  v_u := public.sfh_payroll_auth(p_token, 'saraban.manage_types');
  if nullif(btrim(p_data->>'name'), '') is null then raise exception 'กรุณากรอกชื่อประเภท'; end if;
  if p_id is null then
    v_key := lower(btrim(coalesce(p_data->>'cat_key', '')));
    if v_key !~ '^[a-z_]{2,30}$' then raise exception 'รหัสประเภทใช้ได้เฉพาะ a-z และ _'; end if;
    insert into public.saraban_categories (cat_key, name, group_key, group_name, icon, color, sort_order, created_by)
    values (v_key, btrim(p_data->>'name'), p_data->>'group_key', p_data->>'group_name', coalesce(nullif(btrim(p_data->>'icon'), ''), 'file-text'),
            coalesce(nullif(p_data->>'color', ''), '#5AA9E6'), coalesce((p_data->>'sort_order')::int, 100), v_u.id)
    returning * into v_c;
    perform public.sfh_rent_audit(v_u, 'create', 'saraban_categories', v_c.id::text, jsonb_build_object('cat_key', v_key));
  else
    update public.saraban_categories set name = btrim(p_data->>'name'), icon = coalesce(nullif(btrim(p_data->>'icon'), ''), 'file-text'),
           color = coalesce(nullif(p_data->>'color', ''), color), is_active = coalesce((p_data->>'is_active')::boolean, is_active)
     where id = p_id returning * into v_c;
    if not found then raise exception 'ไม่พบประเภทเอกสาร'; end if;
    perform public.sfh_rent_audit(v_u, 'update', 'saraban_categories', p_id::text, jsonb_build_object('name', v_c.name, 'is_active', v_c.is_active));
  end if;
  return to_jsonb(v_c);
end $$;

create or replace function public.sfh_saraban_cat_delete(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_u public.users%rowtype; v_c public.saraban_categories%rowtype;
begin
  v_u := public.sfh_payroll_auth(p_token, 'saraban.manage_types');
  if exists (select 1 from public.saraban_documents where category_id = p_id) then raise exception 'ไม่สามารถลบได้ เนื่องจากมีเอกสารในประเภทนี้ (ให้ปิด "ใช้งาน" แทน)'; end if;
  delete from public.saraban_categories where id = p_id returning * into v_c;
  if found then perform public.sfh_rent_audit(v_u, 'delete', 'saraban_categories', p_id::text, jsonb_build_object('cat_key', v_c.cat_key)); end if;
end $$;

-- ---------------------------------------------------------------------
-- 5) ที่เก็บไฟล์ (Storage) – เรียกจาก Edge Function "sfh-storage" เท่านั้น (service_role)
--    sign   : ตรวจสิทธิ์ตามโฟลเดอร์ แล้วกำหนด path ไฟล์ใหม่ (Edge Function ออกลิงก์อัปโหลดครั้งเดียว)
--    delete : คืนเฉพาะ path ที่ไม่มีข้อมูลใดอ้างอิงแล้ว (กันลบไฟล์ที่ยังใช้งานอยู่)
-- ---------------------------------------------------------------------
create or replace function public.sfh_storage_path_in_use(p_path text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.saraban_files where file_path = p_path)
      or exists (select 1 from public.users where avatar_url like '%/' || p_path)
      or exists (select 1 from public.announcements where cover_path = p_path or cover_url like '%/' || p_path)
      or exists (select 1 from public.system_settings where setting_value = p_path or setting_value like '%/' || p_path);
$$;

create or replace function public.sfh_storage_auth(p_token text, p_action text, p_folder text default null, p_ext text default null, p_paths text[] default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_u public.users%rowtype; v_root text; v_ext text; v_ok boolean;
begin
  v_u := public.sfh_payroll_auth(p_token, null);
  if p_action = 'sign' then
    if coalesce(p_folder, '') !~ '^[a-z0-9_-]+(/[a-zA-Z0-9_-]+){0,3}$' then raise exception 'FORBIDDEN: โฟลเดอร์ไม่ถูกต้อง'; end if;
    v_root := split_part(p_folder, '/', 1);
    v_ok := case v_root
      when 'avatars' then true
      when 'logos' then public.sfh_has_perm(v_u.id, 'settings.manage')
      when 'announcements' then public.sfh_has_perm(v_u.id, 'announcements.create') or public.sfh_has_perm(v_u.id, 'announcements.update')
      when 'saraban' then (public.sfh_has_perm(v_u.id, 'saraban.create') or public.sfh_has_perm(v_u.id, 'saraban.update'))
                          and (public.sfh_is_super(v_u) or split_part(p_folder, '/', 2) in (coalesce(v_u.org_id::text, 'common'), 'common'))
      else false end;
    if not v_ok then raise exception 'FORBIDDEN: ไม่มีสิทธิ์อัปโหลดไฟล์ในส่วนนี้'; end if;
    v_ext := left(lower(regexp_replace(coalesce(p_ext, ''), '[^a-zA-Z0-9]', '', 'g')), 8);
    if v_ext = '' then v_ext := 'bin'; end if;
    if v_ext in ('html', 'htm', 'xhtml', 'svg', 'js', 'mjs', 'xml', 'php') then raise exception 'FORBIDDEN: ไม่อนุญาตไฟล์ชนิดนี้'; end if;
    return jsonb_build_object('path', p_folder || '/' || to_char(now() at time zone 'Asia/Bangkok', 'YYYY-MM-DD') || '/'
                                      || (extract(epoch from clock_timestamp()) * 1000)::bigint || '-' || substr(md5(gen_random_uuid()::text), 1, 12) || '.' || v_ext);
  elsif p_action = 'delete' then
    return jsonb_build_object('paths', coalesce((select jsonb_agg(p) from unnest(coalesce(p_paths, '{}')) p
                                                  where p ~ '^(avatars|logos|announcements|saraban|uploads)/[A-Za-z0-9/_.-]+$' and p !~ '\.\.'
                                                    and not public.sfh_storage_path_in_use(p)), '[]'::jsonb));
  end if;
  raise exception 'FORBIDDEN: action';
end $$;

-- ---------------------------------------------------------------------
-- 6) สิทธิ์เรียกใช้
-- ---------------------------------------------------------------------
grant execute on function public.sfh_saraban_list(text) to anon, authenticated;
grant execute on function public.sfh_saraban_doc_options(text) to anon, authenticated;
grant execute on function public.sfh_saraban_doc_get(text, uuid) to anon, authenticated;
grant execute on function public.sfh_saraban_save(text, uuid, jsonb, jsonb, uuid[]) to anon, authenticated;
grant execute on function public.sfh_saraban_delete(text, uuid) to anon, authenticated;
grant execute on function public.sfh_saraban_cat_save(text, uuid, jsonb) to anon, authenticated;
grant execute on function public.sfh_saraban_cat_delete(text, uuid) to anon, authenticated;
-- ตัวช่วยภายใน + ฟังก์ชันของ Edge Function: หน้าเว็บเรียกไม่ได้
revoke execute on function public.sfh_saraban_can_view(public.users, public.saraban_documents) from public, anon, authenticated;
revoke execute on function public.sfh_saraban_can_edit(public.users, public.saraban_documents, text) from public, anon, authenticated;
revoke execute on function public.sfh_saraban_files_json(uuid) from public, anon, authenticated;
revoke execute on function public.sfh_storage_path_in_use(text) from public, anon, authenticated;
revoke execute on function public.sfh_storage_auth(text, text, text, text, text[]) from public, anon, authenticated;
grant execute on function public.sfh_storage_auth(text, text, text, text, text[]) to service_role;

select 'ติดตั้งฟังก์ชันงานสารบรรณ + Storage เรียบร้อย' as result;
