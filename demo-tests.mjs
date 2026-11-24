const store={}; globalThis.localStorage={getItem:k=>store[k]??null,setItem:(k,v)=>store[k]=v,removeItem:k=>delete store[k]};
globalThis.addEventListener=()=>{}; globalThis.location={pathname:"/"};
const { createDemoClient } = await import("../public/js/config/demo-client.js");
let ok2=true, ok3=true, ok4=true, ok5=true;
const sb=createDemoClient(); let ok=true; const t=(n,c)=>{console.log(c?"PASS":"FAIL",n); ok&&=c;};
t("bad login rejected",(await sb.auth.signInWithPassword({email:"customer@demo.test",password:"x"})).error);
await sb.auth.signInWithPassword({email:"customer@demo.test",password:"demo1234"});
const {data:biz}=await sb.from("businesses").select("id,name").eq("status","approved"); t("customer sees 2 approved businesses",biz.length===2);
const g=biz.find(b=>b.name==="Glow Salon"); const {data:sv}=await sb.from("services").select("*").eq("business_id",g.id); t("services listed",sv.length===2);
const keys=Array.from({length:3},()=>crypto.randomUUID()); const r=[];for(const k of keys)r.push(await sb.rpc("create_booking",{p_business:g.id,p_service:sv[0].id,p_idem:k,p_time:null}));
t("tokens 4,5,6",r.map(x=>x.data.token_number).join()==="4,5,6");
t("4th active booking blocked",(await sb.rpc("create_booking",{p_business:g.id,p_service:sv[0].id,p_idem:crypto.randomUUID(),p_time:null})).error);
t("same idem key returns same booking",(await sb.rpc("create_booking",{p_business:g.id,p_service:sv[0].id,p_idem:keys[0],p_time:null})).data.id===r[0].data.id);
const mine=(await sb.from("bookings").select("*,businesses(name),services(name)")).data; t("customer sees only own bookings with embeds",mine.length===3&&mine[0].businesses.name==="Glow Salon");
const pos=(await sb.rpc("get_my_position",{p_booking:r[0].data.id})).data; t("position: 3 ahead (1 serving, 2 waiting)",pos.ahead===3);
t("customer cannot call",(await sb.rpc("transition_booking",{p_booking:r[0].data.id,p_action:"call"})).error);
t("customer can cancel waiting",!(await sb.rpc("transition_booking",{p_booking:r[2].data.id,p_action:"cancel"})).error);
await sb.auth.signInWithPassword({email:"owner@demo.test",password:"demo1234"});
t("staff: complete on waiting REJECTED",(await sb.rpc("transition_booking",{p_booking:r[0].data.id,p_action:"complete"})).error);
const n=(await sb.rpc("call_next",{p_business:g.id})); t("call_next picks token 2",n.data.token_number===2);
t("start then complete ok",!(await sb.rpc("transition_booking",{p_booking:n.data.id,p_action:"start"})).error&&!(await sb.rpc("transition_booking",{p_booking:n.data.id,p_action:"complete"})).error);
t("public queue summary",(await sb.rpc("get_public_queue",{p_business:g.id})).data.waiting>=2);
t("stats completed=1",(await sb.rpc("business_stats",{p_business:g.id,p_from:"2000-01-01",p_to:"2999-01-01"})).data.completed===1);
t("owner cannot approve own business",(await sb.from("businesses").update({status:"suspended"}).eq("id",g.id)).error);
await sb.auth.signInWithPassword({email:"admin@demo.test",password:"demo1234"});
t("admin stats",(await sb.rpc("admin_stats")).data.pending===1);
const pend=(await sb.from("businesses").select("id").eq("status","pending")).data[0]; t("admin approves",!(await sb.from("businesses").update({status:"approved"}).eq("id",pend.id)).error);
console.log(ok?"ALL PASSED":"SOME FAILED");
// --- review-fix checks ---
{ const sb2=createDemoClient();  const t2=(n,c)=>{console.log(c?"PASS":"FAIL",n); ok2&&=c;};
  await sb2.auth.signInWithPassword({email:"admin@demo.test",password:"demo1234"});
  const ownerId=(await sb2.from("profiles").select("id,full_name").eq("full_name","Demo Owner")).data[0].id;
  await sb2.rpc("admin_set_suspended",{p_user:ownerId,p_suspended:true});
  await sb2.auth.signOut(); t2("suspended user cannot log in",(await sb2.auth.signInWithPassword({email:"owner@demo.test",password:"demo1234"})).error);
  await sb2.auth.signInWithPassword({email:"admin@demo.test",password:"demo1234"}); await sb2.rpc("admin_set_suspended",{p_user:ownerId,p_suspended:false});
  await sb2.auth.signInWithPassword({email:"owner@demo.test",password:"demo1234"});
  const g2=(await sb2.from("businesses").select("id,owner_id").eq("name","Glow Salon")).data[0];
  t2("owner cannot change owner_id",(await sb2.from("businesses").update({owner_id:crypto.randomUUID()}).eq("id",g2.id)).error);
  t2("owner can still edit description",!(await sb2.from("businesses").update({description:"x"}).eq("id",g2.id)).error);
  console.log(ok2?"REVIEW CHECKS PASSED":"REVIEW CHECKS FAILED"); }
// --- fixes round 2 ---
{ const sb3=createDemoClient();  const t3=(n,c)=>{console.log(c?"PASS":"FAIL",n); ok3&&=c;};
  await sb3.auth.signInWithPassword({email:"owner@demo.test",password:"demo1234"});
  const gl=(await sb3.from("businesses").select("id").eq("name","Glow Salon")).data[0];
  { const qp=(await sb3.from("queue_public").select("waiting").eq("business_id",gl.id)).data[0], real=(await sb3.from("bookings").select("id").eq("business_id",gl.id).eq("status","waiting")).data.length; t3("queue_public summary exists and matches the real waiting count",qp&&qp.waiting===real); }
  const u1=await sb3.from("businesses").update({description:"y"}).eq("id",gl.id).select("id"); t3("update(...).select('id') returns the changed row",u1.data?.length===1);
  const team=(await sb3.from("business_members").select("user_id,role").eq("business_id",gl.id)).data;
  { const rm=await sb3.from("business_members").delete().eq("business_id",gl.id).eq("user_id",team[0].user_id).select("user_id"); t3("owner cannot remove the owner row (0 rows, like real RLS)",!rm.error&&rm.data.length===0&&(await sb3.from("business_members").select("user_id").eq("business_id",gl.id)).data.length>=1); }
  t3("staff can read names of own team and booked customers",(await sb3.from("profiles").select("id")).data.length>=4);
  await sb3.auth.signInWithPassword({email:"customer@demo.test",password:"demo1234"});
  t3("customer cannot read other people's profiles",(await sb3.from("profiles").select("id")).data.length===1);
  const o=(await sb3.from("services").select("*").order("price")).data; t3("order() with equal values does not crash",Array.isArray(o));
  const b0=(await sb3.rpc("create_booking",{p_business:gl.id,p_service:(await sb3.from("services").select("id").eq("business_id",gl.id)).data[0].id,p_idem:crypto.randomUUID(),p_time:null})).data;
  const before=(await sb3.from("queue_public").select("waiting").eq("business_id",gl.id)).data[0].waiting, mineWaiting=(await sb3.from("bookings").select("id").eq("customer_id",(await sb3.auth.getSession()).data.session.user.id).eq("status","waiting")).data.length;
  await sb3.rpc("delete_my_account"); await sb3.auth.signInWithPassword({email:"owner@demo.test",password:"demo1234"});
  const after=(await sb3.from("queue_public").select("waiting").eq("business_id",gl.id)).data[0].waiting; t3("deleting an account refreshes the queue summary",mineWaiting>=1&&after===before-mineWaiting);
  console.log(ok3?"ROUND2 PASSED":"ROUND2 FAILED"); }
// --- final review fixes ---
{ const sb=createDemoClient(), sbN=createDemoClient();  const t=(n,c)=>{console.log(c?"PASS":"FAIL",n); ok4&&=c;};
  const login=(c,e)=>c.auth.signInWithPassword({email:e,password:"demo1234"});
  await sbN.auth.signUp({email:"new@demo.test",password:"demo1234",options:{data:{full_name:"New Staff"}}});
  await login(sb,"admin@demo.test");
  const own=(await sb.from("businesses").select("id,name,profiles!businesses_owner_id_fkey(full_name)").eq("name","Glow Salon")).data[0];
  t("admin embed with FK hint returns the owner profile",own.profiles?.full_name==="Demo Owner");
  await login(sb,"owner@demo.test"); const gl=own.id;
  t("half-filled opening hours rejected",(await sb.from("businesses").update({opening_hours:{daily:["10:00",""]}}).eq("id",gl)).error);
  t("open >= close rejected",(await sb.from("businesses").update({opening_hours:{daily:["10:00","09:00"]}}).eq("id",gl)).error);
  t("bad HH:MM rejected",(await sb.from("businesses").update({opening_hours:{daily:["9am","5pm"]}}).eq("id",gl)).error);
  t("valid hours accepted",!(await sb.from("businesses").update({opening_hours:{daily:["09:00","21:00"]}}).eq("id",gl)).error);
  // invitations
  t("inviting yourself is silent (no error, no invite)",!(await sb.rpc("add_staff_by_email",{p_business:gl,p_email:"owner@demo.test",p_role:"staff"})).error);
  t("inviting an unknown email gives the SAME silent result",!(await sb.rpc("add_staff_by_email",{p_business:gl,p_email:"nobody@x.test",p_role:"staff"})).error);
  t("role 'owner' cannot be invited",(await sb.rpc("add_staff_by_email",{p_business:gl,p_email:"new@demo.test",p_role:"owner"})).error);
  t("valid invite sends no error",!(await sb.rpc("add_staff_by_email",{p_business:gl,p_email:"new@demo.test",p_role:"staff"})).error);
  t("owner CANNOT read invites",(await sb.from("staff_invites").select("*")).data.length===0);
  const mem0=(await sb.from("business_members").select("user_id").eq("business_id",gl)).data.length;
  t("invite alone does not add a member",mem0===1);
  await login(sbN,"new@demo.test"); const inv=(await sbN.from("staff_invites").select("id,role,businesses(name)")).data;
  t("invitee sees exactly their invite with business name",inv.length===1&&inv[0].businesses.name==="Glow Salon");
  t("invitee cannot accept someone else's/unknown invite",(await sbN.rpc("accept_staff_invite",{p_invite:crypto.randomUUID()})).error);
  t("accept works",!(await sbN.rpc("accept_staff_invite",{p_invite:inv[0].id})).error);
  t("invite is consumed",(await sbN.from("staff_invites").select("id")).data.length===0);
  const newId=(await sbN.auth.getSession()).data.session.user.id;
  await login(sb,"owner@demo.test");   // one browser = one session: switch back to the owner
  t("new staff is now a member (role staff)",(await sb.from("business_members").select("role").eq("business_id",gl).eq("user_id",newId)).data[0]?.role==="staff");
  // removing the member frees their counter
  const ctr=(await sb.from("counters").select("id").eq("business_id",gl)).data[0].id;
  await sb.from("counters").update({staff_id:newId}).eq("id",ctr).select("id");
  t("owner removes member",(await sb.from("business_members").delete().eq("business_id",gl).eq("user_id",newId).select("user_id")).data.length===1);
  t("removed staff is cleared from counters",(await sb.from("counters").select("staff_id").eq("id",ctr)).data[0].staff_id===null);
  // ordering: owner first
  const ord=(await sb.from("business_members").select("role").eq("user_id",(await sb.auth.getSession()).data.session.user.id).order("role").order("business_id")).data;
  t("order('role') is owner-first",ord[0].role==="owner");
  // suspended user cannot delete their account (ban evasion)
  await login(sb,"admin@demo.test"); await sb.rpc("admin_set_suspended",{p_user:newId,p_suspended:true});
  localStorage.setItem("qf_demo_session",newId);   // simulate a session that was already open when the suspension happened
  const del=await sb.rpc("delete_my_account"); t("suspended user cannot self-delete",del.error&&/Suspended/.test(del.error.message));
  // recall must fail if the appointment slot was re-booked while the booking was skipped
  const dh=new Date(Date.now()+30*60000).toLocaleTimeString("en-GB",{timeZone:"Asia/Dhaka",hour12:false}).slice(0,5);
  if(dh<"09:00"||dh>"20:59") console.log("SKIP recall-conflict test (needs Bangladesh time between 08:30 and 20:29)");
  else { const svc=(await sb.from("services").select("id").eq("business_id",gl)).data[0].id;
    for(const e of ["c1@demo.test","c2@demo.test"]) await sbN.auth.signUp({email:e,password:"demo1234",options:{data:{full_name:e}}});
    await login(sbN,"c1@demo.test"); const b1=(await sbN.rpc("create_booking",{p_business:gl,p_service:svc,p_idem:crypto.randomUUID(),p_time:dh})).data;
    await login(sb,"owner@demo.test"); await sb.rpc("transition_booking",{p_booking:b1.id,p_action:"skip"});
    await login(sbN,"c2@demo.test"); const b2=await sbN.rpc("create_booking",{p_business:gl,p_service:svc,p_idem:crypto.randomUUID(),p_time:dh});
    t("slot can be re-booked after the first booking was skipped",!b2.error);
    await login(sb,"owner@demo.test"); const rec=await sb.rpc("transition_booking",{p_booking:b1.id,p_action:"recall"});
    t("recall refused while another active booking holds the slot",rec.error&&/Cannot recall/.test(rec.error.message)); }
  console.log(ok4?"FINAL FIXES PASSED":"FINAL FIXES FAILED"); }

// --- round 3 (migration 008) ---
{ const sb=createDemoClient(), sbN=createDemoClient(); const t=(n,c)=>{console.log(c?"PASS":"FAIL",n); ok5&&=!!c;};
  const login=(c,e)=>c.auth.signInWithPassword({email:e,password:"demo1234"}), raw=()=>JSON.parse(localStorage.getItem("qf_demo_db"));
  await login(sb,"owner@demo.test"); const gl=(await sb.from("businesses").select("id").eq("name","Glow Salon")).data[0].id, ownerId=(await sb.auth.getSession()).data.session.user.id;
  await sbN.auth.signUp({email:"late@demo.test",password:"demo1234",options:{data:{full_name:"Late Staff"}}});
  const invite=role=>sb.rpc("add_staff_by_email",{p_business:gl,p_email:"  LATE@Demo.Test ",p_role:role});
  t("NULL role is rejected",(await sb.rpc("add_staff_by_email",{p_business:gl,p_email:"late@demo.test",p_role:null})).error);
  t("email is trimmed and case-insensitive",!(await invite("staff")).error);
  await login(sbN,"late@demo.test"); const cnt=async()=>(await sbN.from("notifications").select("title")).data.filter(n=>n.title==="Staff invitation").length;
  t("invitee sees the invite and gets one notification",(await sbN.from("staff_invites").select("id")).data.length===1&&await cnt()===1);
  await login(sb,"owner@demo.test"); await invite("manager"); await login(sbN,"late@demo.test");
  t("re-invite within an hour: no second notification",await cnt()===1);
  t("re-invite still updates the role",(await sbN.from("staff_invites").select("role")).data[0].role==="manager");
  { const d=raw(); d.staff_invites.forEach(i=>i.created_at=new Date(Date.now()-8*864e5).toISOString()); localStorage.setItem("qf_demo_db",JSON.stringify(d)); await sbN.rpc("accept_staff_invite",{p_invite:crypto.randomUUID()}); }   // age the invite 8 days; the failing call forces a reload
  t("invite older than 7 days is invisible",(await sbN.from("staff_invites").select("id")).data.length===0);
  await login(sb,"owner@demo.test"); await invite("staff"); const invId=raw().staff_invites[0].id;
  t("a fresh invite after expiry sends a notification again",await (async()=>{await login(sbN,"late@demo.test");return await cnt()===2;})());
  await login(sb,"admin@demo.test"); await sb.from("businesses").update({status:"suspended"}).eq("id",gl).select("id");
  await login(sbN,"late@demo.test"); t("invite of a suspended business is hidden",(await sbN.from("staff_invites").select("id")).data.length===0);
  { const e=(await sbN.rpc("accept_staff_invite",{p_invite:invId})).error; t("accepting for a suspended business fails",e&&/no longer active/.test(e.message)); }
  await login(sb,"admin@demo.test"); await sb.from("businesses").update({status:"approved"}).eq("id",gl).select("id");
  await login(sbN,"late@demo.test"); t("accepting after re-approval works",!(await sbN.rpc("accept_staff_invite",{p_invite:invId})).error);
  // business insert/delete rules
  await login(sb,"owner@demo.test");
  t("business INSERT with half-filled hours rejected",(await sb.from("businesses").insert({owner_id:ownerId,name:"Hours Test",opening_hours:{daily:["10:00",""]}})).error);
  t("business INSERT with valid hours ok",!(await sb.from("businesses").insert({owner_id:ownerId,name:"Hours Ok",opening_hours:{daily:["09:00","18:00"]}})).error);
  { const del=await sb.from("businesses").delete().eq("id",gl).select("id"); t("owner cannot delete a business (0 rows)",!del.error&&del.data.length===0&&(await sb.from("businesses").select("id").eq("id",gl)).data.length===1); }
  t("queue_sequences is not readable",(await sb.from("queue_sequences").select("*")).data.length===0);
  // public queue + position rules
  await login(sb,"admin@demo.test"); const pend=(await sb.from("businesses").select("id").eq("status","pending")).data[0].id;
  { const q=(await sb.rpc("get_public_queue",{p_business:pend})).data; t("unapproved business reveals nothing",q.business===null&&q.waiting===0&&q.serving===null); }
  await sbN.auth.signUp({email:"pos@demo.test",password:"demo1234",options:{data:{full_name:"Pos"}}}); await login(sbN,"pos@demo.test");
  const svc=(await sbN.from("services").select("id").eq("business_id",gl)).data[0].id, bk=(await sbN.rpc("create_booking",{p_business:gl,p_service:svc,p_idem:crypto.randomUUID(),p_time:null})).data;
  await login(sb,"owner@demo.test"); for(const a of ["call","start","complete"]) await sb.rpc("transition_booking",{p_booking:bk.id,p_action:a});
  await login(sbN,"pos@demo.test"); { const pos=(await sbN.rpc("get_my_position",{p_booking:bk.id})).data; t("position after completion is 0 ahead / 0 min",pos.ahead===0&&pos.est_minutes===0&&pos.status==="completed"); }
  console.log(ok5?"ROUND3 PASSED":"ROUND3 FAILED"); }
process.exit(ok&&ok2&&ok3&&ok4&&ok5?0:1);
