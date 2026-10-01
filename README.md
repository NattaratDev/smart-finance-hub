# Smart Finance Hub (SFH) – ศูนย์กลางการเงินการคลังดิจิทัล
กองคลัง เทศบาลเมืองศรีสัชนาลัย · Phase 1 (ระบบแกนกลาง) + โมดูลงานสารบรรณอิเล็กทรอนิกส์

ระบบตัวอย่างสำหรับสอนการสร้าง WebApp แบบ CRUD + Role & Permission ด้วย **HTML + Supabase + GitHub Pages**

| ไฟล์ | หน้าที่ |
|---|---|
| `database.sql` | สร้างตาราง ฟังก์ชัน RLS Storage และข้อมูลตัวอย่าง (รันครั้งเดียวจบ / รันซ้ำได้) |
| `module_saraban.sql` | โมดูลงานสารบรรณอิเล็กทรอนิกส์ (รัน **ต่อจาก** `database.sql` / รันซ้ำได้) |
| `config.js` | ใส่ `SUPABASE_URL` และ `SUPABASE_ANON_KEY` |
| `index.html` | ตัวเว็บทั้งหมด (HTML/CSS/JS ไฟล์เดียว) |

## โมดูลงานสารบรรณอิเล็กทรอนิกส์ (e-Saraban)
คลังเอกสารราชการดิจิทัล: หนังสือราชการ (หนังสือเข้า/หนังสือส่ง), คำสั่ง/ประกาศ, ระเบียบ, บันทึกข้อความ/หนังสือเวียน, คู่มือ/แบบฟอร์ม

- **ติดตั้ง:** SQL Editor › วาง `module_saraban.sql` › Run (หลังจากรัน `database.sql` แล้ว)
- **นำเข้าเอกสารที่มีเลขแล้ว:** อัปโหลดไฟล์ → เลือกประเภท → กรอก **เลขที่หนังสือ, เจ้าของหนังสือ, ชื่อเรื่อง** (ระบบไม่ออกเลขทะเบียนเอง)
  - ชื่อเรื่องเติมให้จากชื่อไฟล์อัตโนมัติ (แก้ไขได้) · เตือนเมื่อเลขที่หนังสือซ้ำกับเอกสารประเภทเดียวกัน
  - เลขที่หนังสือไม่บังคับสำหรับระเบียบ คู่มือ และแบบฟอร์ม · ข้อมูลอื่น (ลงวันที่ ถึง/เรียน ความเร่งด่วน สาระสำคัญ คำค้น) อยู่ในส่วน "ข้อมูลเพิ่มเติม (ไม่บังคับ)"
- **ไฟล์แนบ** ได้หลายไฟล์ต่อเอกสาร (PDF, Word, Excel, PowerPoint, ZIP, รูปภาพ) ไฟล์ละไม่เกิน 20 MB · รูปภาพบีบอัดเป็น WebP อัตโนมัติ · ดาวน์โหลดได้ชื่อไฟล์ภาษาไทยเดิม · ดูตัวอย่าง PDF/รูปได้ในหน้าเว็บ
- **ระดับการเข้าถึงเอกสาร:** `สาธารณะ` (บุคคลทั่วไปดู/ดาวน์โหลดได้) · `ภายในหน่วยงาน` · `ลับ/จำกัดสิทธิ์` (เฉพาะผู้บันทึกและผู้มี `saraban.view_all`)
- **ค้นหา/กรอง** ตามเลขที่หนังสือ ชื่อเรื่อง เจ้าของหนังสือ กลุ่มเอกสาร ประเภท ปีงบประมาณ (คำนวณจากวันที่ในเอกสาร) ความเร่งด่วน · นับจำนวนเข้าชม/ดาวน์โหลด · ส่งออก CSV

| Permission | บุคคลทั่วไป | เจ้าหน้าที่ | Org Admin | Super Admin |
|---|:-:|:-:|:-:|:-:|
| `saraban.view_public` ดู/ดาวน์โหลดเอกสารสาธารณะ | ✅ | ✅ | ✅ | ✅ |
| `saraban.view` ดูเอกสารภายในหน่วยงาน | | ✅ | ✅ | ✅ |
| `saraban.create / update / delete` เพิ่ม/แก้ไข/ลบ (ของตนเอง) | | ✅ | ✅ | ✅ |
| `saraban.view_all` ดู/แก้ไขทุกฉบับในหน่วยงาน (รวมเอกสารลับ) | | | ✅ | ✅ |
| `saraban.export` ส่งออก CSV | | | ✅ | ✅ |
| `saraban.manage_types` จัดการประเภทเอกสาร | | | | ✅ |

> เจ้าหน้าที่แก้ไข/ลบได้เฉพาะเอกสารที่ตนเองบันทึก (`created_by`) ตามหลักการของระบบ หากต้องการให้แก้ไขของผู้อื่นได้ ให้มอบสิทธิ์ `saraban.view_all` รายบุคคลที่หน้า "จัดการผู้ใช้งาน"
> ⚠️ bucket `sfh-files` เป็น Public: ไฟล์ของเอกสาร "ภายใน/ลับ" เปิดได้ถ้ารู้ URL – ใช้งานจริงควรแยก bucket แบบ Private + Signed URL

---

## 1) ตั้งค่า Supabase
1. สมัคร/เข้าสู่ระบบที่ https://supabase.com แล้วกด **New project**
2. เมนู **SQL Editor › New query** วางเนื้อหาทั้งหมดของ `database.sql` แล้วกด **Run**
   - ควรเห็น `Success. No rows returned`
   - รันซ้ำได้ ไม่ error และไม่ลบข้อมูลที่แก้ไขไว้
3. ตรวจที่ **Table Editor**: ต้องมี 12 ตาราง และ **Storage** ต้องมี bucket `sfh-files` (Public)

## 2) ใส่ Key
เปิด **Project Settings › API** (หรือ **Connect**) แล้วคัดลอก 2 ค่ามาใส่ใน `config.js`

```js
const SUPABASE_URL = 'https://xxxxxxxx.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOi...';   // anon public key (หรือ publishable key)
```

> ห้ามใช้ `service_role` key ในหน้าเว็บเด็ดขาด

ทดสอบบนเครื่อง: เปิดโฟลเดอร์ใน VS Code แล้วใช้ Live Server (หรือ `npx http-server`) แล้วเปิด `http://localhost:xxxx`
(การดับเบิลคลิกเปิด `index.html` ตรง ๆ ก็ใช้ได้ แต่แนะนำให้เปิดผ่าน server)

## 3) Deploy บน GitHub Pages
1. สร้าง Repository ใหม่ (Public) แล้วอัปโหลด `index.html`, `config.js` (และ `README.md`)
2. **Settings › Pages › Build and deployment** เลือก Source = `Deploy from a branch`, Branch = `main` / `(root)` แล้ว Save
3. รอ 1–2 นาที เปิดลิงก์ `https://<username>.github.io/<repo>/`

> anon key เป็นค่าสาธารณะ (อยู่ในหน้าเว็บอยู่แล้ว) ความปลอดภัยจริงต้องมาจาก RLS Policy – ดูหัวข้อ "ข้อควรระวัง"

## 4) บัญชีทดสอบ
| บัญชี | รหัสผ่าน | Role | สิ่งที่เห็น |
|---|---|---|---|
| `superadmin` | `admin1234` | Super Admin | ทุกเมนู |
| `orgadmin` | `org1234` | Organization Admin (กองคลัง) | ผู้ใช้/ตั้งค่า/Audit ของหน่วยงาน, ทะเบียนคุม, สลิป |
| `staff1` | `staff1234` | เจ้าหน้าที่ | ทะเบียนคุม **+ สลิปเงินเดือน** (ได้สิทธิ์รายบุคคลเพิ่ม) |
| `staff2` | `staff1234` | เจ้าหน้าที่ | ทะเบียนคุมเท่านั้น (Role เดียวกับ staff1) |
| `orgadmin2` | `org1234` | Organization Admin (สำนักปลัด) | ข้อมูลเฉพาะสำนักปลัด |
| `staff3` | `staff1234` | เจ้าหน้าที่ (บัญชีถูกปิด) | Login ไม่ได้ – ใช้สาธิต `is_active = false` |

บุคคลทั่วไป (ไม่ Login) เห็นเมนู: หน้าแรก, ข่าวสาร/ประกาศ, โปรแกรมคำนวณค่าใช้จ่ายไปราชการ

## 5) หลักการสิทธิ์ (สรุปสำหรับสอน)
- **Role** = กลุ่มผู้ใช้ · **Permission** = สิ่งที่ทำได้ รูปแบบ `<module>.<action>` เช่น `register.create`
- สิทธิ์ของผู้ใช้ = สิทธิ์ของ Role **+** สิทธิ์รายบุคคล (`user_permissions`)
- Role `guest` ใช้กับผู้ไม่ Login ได้เฉพาะ `.view_public` / `.use_public` (มี Trigger ในฐานข้อมูลบังคับอีกชั้น)
- โมดูล `register`, `payroll` ตั้ง `guest_locked = true` จึงเปิดให้ Guest ไม่ได้
- Sidebar / Bottom Nav สร้างจากตาราง `menus` + `modules` กรองด้วย Permission (ไม่ hardcode ใน HTML)
- ฟังก์ชัน RPC: `sfh_login`, `sfh_refresh_session`, `sfh_set_password`, `sfh_change_password`, `sfh_guest_menus`

## 6) วิธีเพิ่มโมดูลใหม่ในอนาคต (ตัวอย่าง: travel)
1. **SQL** – สร้างไฟล์ `module_travel.sql` (รันต่อจาก `database.sql`) ที่มี
   - ตารางข้อมูลของโมดูล (มี `org_id`, `created_by`, `created_at`, `updated_at`) + RLS 4 Policy
   - Permission ใหม่ (ถ้ามี) `insert into permissions ... on conflict (perm_key) do nothing`
   - `update modules set status = 'active', version = '1.0.0' where module_key = 'travel';`
2. **index.html** – เขียนฟังก์ชันในบล็อก `/* ===== MODULE: travel ===== */`
   ```js
   async function renderTravel(el, mod, menu) {
     if (!requirePermission('travel.use_public')) return;
     el.innerHTML = pageHeader({ title: mod.name, icon: 'plane' }) + '...';
     // ใช้ฟังก์ชันกลาง: db, logAudit, formatMoney, bahtText, formatThaiDate,
     // createDataTable, downloadCSV, compressImage, uploadFile, confirmModal, showToast
   }
   ```
3. เปลี่ยน Registry เพียงบรรทัดเดียว (ไม่ต้องแก้ Router/Sidebar)
   ```js
   travel: { render: renderTravel },
   ```
4. เพิ่มโมดูลใหม่ที่ยังไม่มีในระบบ: เพิ่มแถวใน `modules`, `menus` (menu_group = 'module') และ `permissions`
   แล้วเพิ่ม key ใน `MODULES` → เมนูจะขึ้นเองตามสิทธิ์

## 7) ข้อควรระวัง (PDPA)
Policy แบบ `USING (true)` ใช้เพื่อ **การสอน/ทดสอบเท่านั้น** ใครมี anon key ก็อ่าน/แก้ข้อมูลผ่าน REST API ได้โดยตรง
การซ่อนปุ่มในหน้าเว็บไม่ใช่ความปลอดภัยจริง ห้ามใช้กับข้อมูลการเงินและข้อมูลส่วนบุคคลจริง
หากจะใช้งานจริงให้ย้ายไปใช้ Supabase Auth/JWT + Policy ตาม `org_id`/`created_by` และทำงานเขียนผ่านฟังก์ชันที่ตรวจสิทธิ์ในฐานข้อมูล
(รายละเอียดอยู่ท้ายไฟล์ `database.sql`) และควรลบกล่อง "บัญชีทดสอบ" ในหน้า Login ออก

## 8) แก้ปัญหาที่พบบ่อย
| อาการ | สาเหตุ / วิธีแก้ |
|---|---|
| ขึ้น "ยังไม่ได้เชื่อมต่อฐานข้อมูล" | ยังไม่ได้แก้ `config.js` หรือใส่ค่าผิด |
| "ไม่พบตาราง/ฟังก์ชันในฐานข้อมูล" | ยังไม่ได้รัน `database.sql` หรือรันไม่ครบ |
| อัปโหลดรูปไม่ได้ | ตรวจ bucket `sfh-files` และ Storage Policy ในส่วนที่ 7 ของ SQL |
| Login ถูกแต่เข้าไม่ได้ | บัญชีหรือหน่วยงานถูกปิด (`is_active = false`) |
