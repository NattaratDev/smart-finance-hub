-- =====================================================================
--  ไฟล์     : module_security_calendar_news.sql  (รันต่อจาก module_security_saraban.sql · รันซ้ำได้)
--  เป้าหมาย : ปฏิทินกองคลัง / ข่าวประกาศ / ชุดอัตราค่าใช้จ่ายไปราชการ
--             ต้องบันทึกผ่านฟังก์ชันที่ตรวจ session token + สิทธิ์ (เหมือนหน้าเว็บเดิม)
--
--  ไฟล์นี้เพิ่ม/ปรับฟังก์ชันเท่านั้น ไม่เปลี่ยนสิทธิ์ตาราง (ระบบเดิมใช้งานได้ตามปกติ)
--  การปิดการเข้าถึงตรงอยู่ในไฟล์ module_security_calendar_news_lockdown.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0) ตัวช่วย: แก้ไข/ลบรายการได้หรือไม่ (เหมือน canEditRecord ในหน้าเว็บ)
--    Super Admin · Org Admin ในหน่วยงานเดียวกัน · ผู้มีสิทธิ์ "ทั้งหน่วยงาน" ในหน่วยงานเดียวกัน · ผู้บันทึกเอง
-- ---------------------------------------------------------------------
create or replace function public.sfh_can_edit_record(p_u public.users, p_org uuid, p_created_by uuid, p_all_perm text default null)
returns boolean language sql stable security definer set search_path = public as $$
  select public.sfh_is_super(p_u)
      or (p_org is not null and p_org = p_u.org_id
          and (exists (select 1 from public.roles r where r.id = p_u.role_id and r.role_key = 'org_admin')
               or (p_all_perm is not null and public.sfh_has_perm(p_u.id, p_all_perm))))
      or (p_created_by is not null and p_created_by = p_u.id);
$$;

-- ---------------------------------------------------------------------
-- 1) ปฏิทินกองคลัง
-- ---------------------------------------------------------------------
create or replace function public.sfh_cal_table(p_type text)
returns text language sql immutable set search_path = public as $$
  select case p_type when 'event' then 'cal_events' when 'task' then 'cal_tasks' when 'acting' then 'cal_acting' when 'absence' then 'cal_absences' end;
$$;

/** เพิ่ม (p_id = null) / แก้ไขรายการปฏิทิน · p_assignees ใช้กับงานมอบหมาย · p_title = ชื่อที่แสดงในความเคลื่อนไหว */
create or replace function public.sfh_cal_save(p_token text, p_type text, p_id uuid, p_data jsonb, p_assignees jsonb default null, p_title text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_u public.users%rowtype; v_table text := public.sfh_cal_table(p_type); v_cols text[]; v_use text[]; v_old jsonb; v_row jsonb; v_list text; v_a jsonb; v_i int := 0;
begin
  if v_table is null then raise exception 'ประเภทรายการไม่ถูกต้อง'; end if;
  v_u := public.sfh_payroll_auth(p_token, case when p_id is null then 'calendar.create' else 'calendar.update' end);
  v_cols := case p_type
    when 'event'   then array['title','category','start_date','end_date','all_day','start_time','end_time','location','attendees','description','saraban_doc_id']
    when 'task'    then array['title','detail','assigned_by','assign_date','due_date','priority','status','saraban_doc_id']
    when 'acting'  then array['position_title','holder_user_id','holder_name','acting_user_id','acting_name','acting_position','start_date','end_date','order_no','note','saraban_doc_id']
    when 'absence' then array['person_name','user_id','person_position','kind','start_date','end_date','period','place'] end;
  select array_agg(c) into v_use from unnest(v_cols) c where p_data ? c;
  if v_use is null then raise exception 'ไม่มีข้อมูลที่จะบันทึก'; end if;
  v_list := array_to_string(array(select format('%I', c) from unnest(v_use) c), ', ');

  if p_id is null then
    execute format('insert into public.%I (%s, org_id, created_by, created_by_name) select %s, $2, $3, $4 from jsonb_populate_record(null::public.%I, $1) r returning to_jsonb(%I.*)',
                   v_table, v_list, array_to_string(array(select format('r.%I', c) from unnest(v_use) c), ', '), v_table, v_table)
      into v_row using p_data, v_u.org_id, v_u.id, v_u.full_name;
  else
    execute format('select to_jsonb(t) from public.%I t where id = $1', v_table) into v_old using p_id;
    if v_old is null then raise exception 'ไม่พบรายการ'; end if;
    if not public.sfh_can_edit_record(v_u, (v_old->>'org_id')::uuid, (v_old->>'created_by')::uuid, 'calendar.manage_all') then
      raise exception 'FORBIDDEN: แก้ไขได้เฉพาะรายการที่ตนเองบันทึก';
    end if;
    execute format('update public.%I t set (%s, updated_by_name) = (select %s, $2 from jsonb_populate_record(null::public.%I, $1) r) where t.id = $3 returning to_jsonb(t.*)',
                   v_table, v_list, array_to_string(array(select format('r.%I', c) from unnest(v_use) c), ', '), v_table)
      into v_row using p_data, v_u.full_name, p_id;
  end if;

  if p_type = 'task' and p_assignees is not null then
    delete from public.cal_task_assignees where task_id = (v_row->>'id')::uuid;
    for v_a in select * from jsonb_array_elements(p_assignees) loop
      if nullif(btrim(v_a->>'name'), '') is null then continue; end if;
      insert into public.cal_task_assignees (task_id, user_id, name, position, sort_order)
      values ((v_row->>'id')::uuid, nullif(v_a->>'user_id', '')::uuid, btrim(v_a->>'name'), nullif(btrim(v_a->>'position'), ''), v_i);
      v_i := v_i + 1;
    end loop;
  end if;

  if p_type = 'task' and p_id is not null and (v_old->>'status') is distinct from (v_row->>'status') then
    insert into public.cal_activity (org_id, item_type, item_id, action, title, from_status, to_status, by_user_id, by_name)
    values ((v_row->>'org_id')::uuid, 'task', (v_row->>'id')::uuid, 'status', coalesce(nullif(p_title, ''), v_row->>'title', '-'), v_old->>'status', v_row->>'status', v_u.id, v_u.full_name);
  end if;
  insert into public.cal_activity (org_id, item_type, item_id, action, title, by_user_id, by_name)
  values (coalesce((v_row->>'org_id')::uuid, v_u.org_id), p_type, (v_row->>'id')::uuid, case when p_id is null then 'create' else 'update' end,
          coalesce(nullif(p_title, ''), v_row->>'title', '-'), v_u.id, v_u.full_name);
  perform public.sfh_rent_audit(v_u, case when p_id is null then 'create' else 'update' end, v_table, v_row->>'id', jsonb_build_object('title', coalesce(p_title, v_row->>'title')));
  return v_row;
end $$;

create or replace function public.sfh_cal_delete(p_token text, p_type text, p_id uuid, p_title text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_u public.users%rowtype; v_table text := public.sfh_cal_table(p_type); v_old jsonb;
begin
  if v_table is null then raise exception 'ประเภทรายการไม่ถูกต้อง'; end if;
  v_u := public.sfh_payroll_auth(p_token, 'calendar.delete');
  execute format('select to_jsonb(t) from public.%I t where id = $1', v_table) into v_old using p_id;
  if v_old is null then return; end if;
  if not public.sfh_can_edit_record(v_u, (v_old->>'org_id')::uuid, (v_old->>'created_by')::uuid, 'calendar.manage_all') then
    raise exception 'FORBIDDEN: ลบได้เฉพาะรายการที่ตนเองบันทึก';
  end if;
  execute format('delete from public.%I where id = $1', v_table) using p_id;
  insert into public.cal_activity (org_id, item_type, item_id, action, title, by_user_id, by_name)
  values (coalesce((v_old->>'org_id')::uuid, v_u.org_id), p_type, p_id, 'delete', coalesce(nullif(p_title, ''), v_old->>'title', '-'), v_u.id, v_u.full_name);
  perform public.sfh_rent_audit(v_u, 'delete', v_table, p_id::text, jsonb_build_object('title', coalesce(p_title, v_old->>'title')));
end $$;

/** อัปเดตสถานะ/บันทึกความคืบหน้างานมอบหมาย: ผู้บันทึก/ผู้มีสิทธิ์ทั้งหน่วยงาน หรือผู้รับผิดชอบงาน */
create or replace function public.sfh_cal_task_status(p_token text, p_id uuid, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_u public.users%rowtype; v_t public.cal_tasks%rowtype;
begin
  v_u := public.sfh_payroll_auth(p_token, 'calendar.update');
  select * into v_t from public.cal_tasks where id = p_id;
  if not found then raise exception 'ไม่พบงาน'; end if;
  if not (public.sfh_can_edit_record(v_u, v_t.org_id, v_t.created_by, 'calendar.manage_all')
          or exists (select 1 from public.cal_task_assignees a where a.task_id = p_id and a.user_id = v_u.id)) then
    raise exception 'FORBIDDEN: อัปเดตได้เฉพาะผู้บันทึกหรือผู้รับผิดชอบงาน';
  end if;
  if p_status is not null and p_status is distinct from v_t.status then
    update public.cal_tasks set status = p_status, updated_by_name = v_u.full_name where id = p_id;
    insert into public.cal_activity (org_id, item_type, item_id, action, title, detail, from_status, to_status, by_user_id, by_name)
    values (v_t.org_id, 'task', p_id, 'status', v_t.title, nullif(btrim(p_note), ''), v_t.status, p_status, v_u.id, v_u.full_name);
    perform public.sfh_rent_audit(v_u, 'update_status', 'cal_tasks', p_id::text, jsonb_build_object('from', v_t.status, 'to', p_status));
  elsif nullif(btrim(p_note), '') is not null then
    insert into public.cal_activity (org_id, item_type, item_id, action, title, detail, by_user_id, by_name)
    values (v_t.org_id, 'task', p_id, 'comment', v_t.title, btrim(p_note), v_u.id, v_u.full_name);
  else
    raise exception 'กรุณาเลือกสถานะใหม่หรือบันทึกความคืบหน้า';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 2) ข่าวประกาศ
-- ---------------------------------------------------------------------
/** ข่าวที่ผู้ใช้เห็นได้: Super Admin ทุกข่าว · ผู้มี announcements.view = ข่าวสาธารณะ + ข่าวในหน่วยงาน · อื่น ๆ = ข่าวสาธารณะ
 *  ข่าวที่ตั้งเวลาเผยแพร่ล่วงหน้า แสดงเฉพาะผู้มี announcements.manage (หรือ p_published_only = false ไม่มีผลกับผู้ไม่มีสิทธิ์) */
create or replace function public.sfh_news_list(p_token text, p_limit int default null, p_published_only boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_u public.users%rowtype; v_super boolean; v_view boolean; v_pub_only boolean;
begin
  v_u := public.sfh_payroll_auth(p_token, null);
  v_super := public.sfh_is_super(v_u);
  v_view := public.sfh_has_perm(v_u.id, 'announcements.view');
  v_pub_only := p_published_only or not public.sfh_has_perm(v_u.id, 'announcements.manage');
  return coalesce((select jsonb_agg(x.j order by x.is_pinned desc, x.published_at desc) from (
      select a.is_pinned, a.published_at, to_jsonb(a) || jsonb_build_object('org_name', o.name, 'org_short_name', o.short_name,
             'organizations', case when o.id is null then null else jsonb_build_object('name', o.name, 'short_name', o.short_name) end) j
        from public.announcements a left join public.organizations o on o.id = a.org_id
       where (v_super or a.is_public or (v_view and a.org_id is not distinct from v_u.org_id and v_u.org_id is not null))
         and (not v_pub_only or a.published_at <= now())
       order by a.is_pinned desc, a.published_at desc
       limit least(greatest(coalesce(p_limit, 1000), 1), 1000)) x), '[]'::jsonb);
end $$;

create or replace function public.sfh_news_save(p_token text, p_id uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_u public.users%rowtype; v_a public.announcements%rowtype;
begin
  v_u := public.sfh_payroll_auth(p_token, 'announcements.manage');
  if nullif(btrim(p_data->>'title'), '') is null or nullif(btrim(p_data->>'content'), '') is null then raise exception 'กรุณากรอกหัวข้อและเนื้อหา'; end if;
  if p_id is null then
    insert into public.announcements (org_id, title, content, category, is_public, is_pinned, published_at, cover_url, cover_path, created_by)
    values (v_u.org_id, btrim(p_data->>'title'), p_data->>'content', coalesce(nullif(p_data->>'category', ''), 'general'),
            coalesce((p_data->>'is_public')::boolean, true), coalesce((p_data->>'is_pinned')::boolean, false),
            coalesce(nullif(p_data->>'published_at', '')::timestamptz, now()), nullif(p_data->>'cover_url', ''), nullif(p_data->>'cover_path', ''), v_u.id)
    returning * into v_a;
  else
    select * into v_a from public.announcements where id = p_id;
    if not found then raise exception 'ไม่พบข่าว'; end if;
    if not public.sfh_can_edit_record(v_u, v_a.org_id, v_a.created_by, null) then raise exception 'FORBIDDEN: แก้ไขได้เฉพาะข่าวที่ตนเองบันทึก'; end if;
    update public.announcements set title = btrim(p_data->>'title'), content = p_data->>'content',
           category = coalesce(nullif(p_data->>'category', ''), category),
           is_public = coalesce((p_data->>'is_public')::boolean, is_public), is_pinned = coalesce((p_data->>'is_pinned')::boolean, is_pinned),
           published_at = coalesce(nullif(p_data->>'published_at', '')::timestamptz, published_at),
           cover_url = case when p_data ? 'cover_url' then nullif(p_data->>'cover_url', '') else cover_url end,
           cover_path = case when p_data ? 'cover_path' then nullif(p_data->>'cover_path', '') else cover_path end
     where id = p_id returning * into v_a;
  end if;
  perform public.sfh_rent_audit(v_u, case when p_id is null then 'create' else 'update' end, 'announcements', v_a.id::text,
    jsonb_build_object('title', v_a.title, 'is_public', v_a.is_public, 'cover_changed', p_data ? 'cover_url'));
  return to_jsonb(v_a);
end $$;

create or replace function public.sfh_news_delete(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_u public.users%rowtype; v_a public.announcements%rowtype;
begin
  v_u := public.sfh_payroll_auth(p_token, 'announcements.manage');
  select * into v_a from public.announcements where id = p_id;
  if not found then return; end if;
  if not public.sfh_can_edit_record(v_u, v_a.org_id, v_a.created_by, null) then raise exception 'FORBIDDEN: ลบได้เฉพาะข่าวที่ตนเองบันทึก'; end if;
  delete from public.announcements where id = p_id;
  perform public.sfh_rent_audit(v_u, 'delete', 'announcements', p_id::text, jsonb_build_object('title', v_a.title));
end $$;

-- ---------------------------------------------------------------------
-- 3) ชุดอัตราค่าใช้จ่ายไปราชการ (travel.manage_rates) – การอ่านยังเปิดให้ทุกคนตามเดิม (ใช้คำนวณ)
-- ---------------------------------------------------------------------
create or replace function public.sfh_travel_rate_save(p_token text, p_id uuid, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_u public.users%rowtype; v_s public.travel_rate_sets%rowtype;
begin
  v_u := public.sfh_payroll_auth(p_token, 'travel.manage_rates');
  if nullif(btrim(p_data->>'name'), '') is null then raise exception 'กรุณากรอกชื่อชุดอัตรา'; end if;
  if jsonb_typeof(p_data->'config') is distinct from 'object' then raise exception 'ข้อมูลอัตราไม่ถูกต้อง'; end if;
  if p_id is null then
    insert into public.travel_rate_sets (name, reference, effective_from, is_active, note, config, created_by, created_by_name)
    values (btrim(p_data->>'name'), nullif(btrim(p_data->>'reference'), ''), nullif(p_data->>'effective_from', '')::date,
            coalesce((p_data->>'is_active')::boolean, true), nullif(btrim(p_data->>'note'), ''), p_data->'config', v_u.id, v_u.full_name)
    returning * into v_s;
  else
    update public.travel_rate_sets set name = btrim(p_data->>'name'), reference = nullif(btrim(p_data->>'reference'), ''),
           effective_from = nullif(p_data->>'effective_from', '')::date, is_active = coalesce((p_data->>'is_active')::boolean, is_active),
           note = nullif(btrim(p_data->>'note'), ''), config = p_data->'config', updated_by_name = v_u.full_name
     where id = p_id returning * into v_s;
    if not found then raise exception 'ไม่พบชุดอัตรา'; end if;
  end if;
  perform public.sfh_rent_audit(v_u, case when p_id is null then 'create' else 'update' end, 'travel_rate_sets', v_s.id::text, jsonb_build_object('name', v_s.name));
  return to_jsonb(v_s);
end $$;

create or replace function public.sfh_travel_rate_delete(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_u public.users%rowtype; v_s public.travel_rate_sets%rowtype;
begin
  v_u := public.sfh_payroll_auth(p_token, 'travel.manage_rates');
  if (select count(*) from public.travel_rate_sets) <= 1 then raise exception 'ต้องมีชุดอัตราอย่างน้อย 1 ชุด'; end if;
  delete from public.travel_rate_sets where id = p_id returning * into v_s;
  if found then perform public.sfh_rent_audit(v_u, 'delete', 'travel_rate_sets', p_id::text, jsonb_build_object('name', v_s.name)); end if;
end $$;

-- ---------------------------------------------------------------------
-- 4) แก้ไขสิทธิ์อัปโหลดภาพปกข่าวใน Storage ให้ตรงกับสิทธิ์จริง (announcements.manage)
-- ---------------------------------------------------------------------
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
      when 'announcements' then public.sfh_has_perm(v_u.id, 'announcements.manage')
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
-- 5) สิทธิ์เรียกใช้
-- ---------------------------------------------------------------------
grant execute on function public.sfh_cal_save(text, text, uuid, jsonb, jsonb, text) to anon, authenticated;
grant execute on function public.sfh_cal_delete(text, text, uuid, text) to anon, authenticated;
grant execute on function public.sfh_cal_task_status(text, uuid, text, text) to anon, authenticated;
grant execute on function public.sfh_news_list(text, int, boolean) to anon, authenticated;
grant execute on function public.sfh_news_save(text, uuid, jsonb) to anon, authenticated;
grant execute on function public.sfh_news_delete(text, uuid) to anon, authenticated;
grant execute on function public.sfh_travel_rate_save(text, uuid, jsonb) to anon, authenticated;
grant execute on function public.sfh_travel_rate_delete(text, uuid) to anon, authenticated;
revoke execute on function public.sfh_can_edit_record(public.users, uuid, uuid, text) from public, anon, authenticated;
revoke execute on function public.sfh_storage_auth(text, text, text, text, text[]) from public, anon, authenticated;
grant execute on function public.sfh_storage_auth(text, text, text, text, text[]) to service_role;

select 'ติดตั้งฟังก์ชันปฏิทิน + ข่าวประกาศ + อัตราไปราชการ เรียบร้อย' as result;
