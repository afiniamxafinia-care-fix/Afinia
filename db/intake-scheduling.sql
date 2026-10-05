-- Draft schedules are validated before a verification visit can be requested.
create or replace function private.valid_week(p_week jsonb) returns boolean language plpgsql immutable set search_path='' as $$
declare d jsonb;h jsonb;previous_end text;
begin
 if p_week is null or jsonb_typeof(p_week)<>'array' then return false;end if;
 if jsonb_array_length(p_week)<>7 or (select count(distinct value->>'weekday') from jsonb_array_elements(p_week))<>7 then return false;end if;
 for d in select value from jsonb_array_elements(p_week) loop
 if coalesce(d->>'weekday','')!~'^[0-6]$' or jsonb_typeof(d->'enabled') is distinct from 'boolean' or jsonb_typeof(d->'intervals') is distinct from 'array' then return false;end if;
 if jsonb_array_length(d->'intervals')>6 or ((d->>'enabled')::boolean and jsonb_array_length(d->'intervals')=0) then return false;end if;
 previous_end=null;
 if (d->>'enabled')::boolean then
 for h in select value from jsonb_array_elements(d->'intervals') order by value->>'opens_at' loop
 if coalesce(h->>'opens_at','')!~'^([01][0-9]|2[0-3]):[0-5][0-9]$' or coalesce(h->>'closes_at','')!~'^([01][0-9]|2[0-3]):[0-5][0-9]$' or h->>'opens_at'>=h->>'closes_at' or (previous_end is not null and h->>'opens_at'<previous_end) then return false;end if;
 previous_end=h->>'closes_at';end loop;end if;end loop;
 return true;
exception when others then return false;
end $$;
revoke all on function private.valid_week(jsonb) from public,anon;grant execute on function private.valid_week(jsonb) to authenticated;
create or replace function private.book_verification(p_request uuid,p_start timestamptz,p_name text,p_phone text) returns public.business_intake_requests language plpgsql security definer set search_path='' as $$
declare r public.business_intake_requests;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
 perform pg_advisory_xact_lock(hashtextextended('verification-agenda',0));
 select * into r from public.business_intake_requests where id=p_request and user_id=auth.uid() for update;
 if not found then raise exception 'ACCESS_DENIED'; end if;
 if r.status not in ('draft','canceled','scheduled','confirmed') then raise exception 'REQUEST_LOCKED'; end if;
 if r.starts_at=p_start and r.status in ('scheduled','confirmed') then return r; end if;
 if length(trim(p_name))<2 or length(p_name)>120 or length(p_phone)>40 then raise exception 'CONTACT_REQUIRED'; end if;
 if r.kind='new' then
 if length(trim(coalesce(r.draft->>'name','')))<2 or length(trim(coalesce(r.draft->>'address','')))<5 or not private.valid_week(r.draft->'opening_schedule') or not exists(select 1 from jsonb_array_elements(r.draft->'opening_schedule') d where (d->>'enabled')::boolean) then raise exception 'BUSINESS_BASICS_REQUIRED';end if;
 if exists(select 1 from jsonb_array_elements(coalesce(r.draft->'team','[]')) t where length(trim(coalesce(t->>'name','')))<2 or coalesce(t->>'email','')!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or length(trim(coalesce(t->>'phone','')))<7) then raise exception 'WORKER_CONTACT_REQUIRED';end if;
 end if;
 if not exists(select 1 from private.verification_slots() s where s.starts_at=p_start) then raise exception 'SLOT_UNAVAILABLE'; end if;
 update public.business_intake_requests set starts_at=p_start,ends_at=p_start+interval '2 hours',status='scheduled',contact_name=trim(p_name),contact_phone=trim(p_phone),updated_at=now() where id=r.id returning * into r;
 insert into public.verification_events(request_id,actor_id,status) values(r.id,auth.uid(),'scheduled');
 return r;
end $$;
create or replace function private.admin_verification(p_request uuid,p_status text,p_notes text,p_message_es text,p_message_en text) returns public.business_intake_requests language plpgsql security definer set search_path='' as $$
declare r public.business_intake_requests; bid uuid; d jsonb; item jsonb; ord integer:=0; tid uuid;sid uuid;service_map jsonb:='{}';service_index integer:=0;worker_services uuid[];
begin
 if not private.is_platform_admin() then raise exception 'ADMIN_REQUIRED'; end if;
 select * into r from public.business_intake_requests where id=p_request for update;
 if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
 if length(p_notes)>5000 or length(p_message_es)>2000 or length(p_message_en)>2000 then raise exception 'TEXT_TOO_LONG'; end if;
 if p_status not in ('scheduled','confirmed','visited','approved','rejected','canceled') or r.status in ('draft','approved','rejected','canceled') or (p_status='approved' and r.status<>'visited') or (p_status='visited' and (r.status not in ('scheduled','confirmed','visited') or r.starts_at>now())) then raise exception 'INVALID_TRANSITION'; end if;
 if p_status='approved' then
 bid=r.business_id;d=r.draft;
 if r.kind='existing' then
 perform pg_advisory_xact_lock(hashtextextended('claim:'||bid::text,0));
 if exists(select 1 from public.business_members where business_id=bid and role='owner' and user_id<>r.user_id) then raise exception 'BUSINESS_OWNED'; end if;
 else
 insert into public.businesses(slug,name,description_es,description_en,short_description_es,short_description_en,address,city,area,phone,public_email,website_url,maps_url,directions_es,directions_en,opening_hours_es,opening_hours_en,theme,enrollment_status)
 values('espacio-'||replace(r.id::text,'-',''),d->>'name',coalesce(d->>'description_es',''),coalesce(d->>'description_en',''),coalesce(d->>'short_description_es',''),coalesce(d->>'short_description_en',''),d->>'address',d->>'city',d->>'area',d->>'phone',d->>'public_email',d->>'website_url',d->>'maps_url',coalesce(d->>'directions_es',''),coalesce(d->>'directions_en',''),coalesce(d->>'opening_hours_es',''),coalesce(d->>'opening_hours_en',''),jsonb_build_object('layout','navy','palette',case when d->>'palette' in ('pro','modern_teal','warm_neutral') then d->>'palette' else 'pro' end),'contacted') returning id into bid;
 for item in select value from jsonb_array_elements(coalesce(d->'gallery','[]')) loop
 if coalesce(item->>'image_url','') ~ '^https://' then
 insert into public.business_gallery(business_id,image_url,caption_es,caption_en,alt_es,alt_en,sort_order) values(bid,item->>'image_url',coalesce(item->>'caption_es',''),coalesce(item->>'caption_en',''),coalesce(item->>'alt_es',''),coalesce(item->>'alt_en',''),ord);ord:=ord+1;end if;
 end loop;
 for item in select value from jsonb_array_elements(coalesce(d->'services','[]')) loop
 if coalesce(nullif(item->>'name_es',''),item->>'name_en','')<>'' and coalesce(item->>'price_mxn','') ~ '^\d+(\.\d{1,2})?$' and coalesce(item->>'duration_minutes','') ~ '^\d{1,4}$' then
 if (item->>'duration_minutes')::int between 5 and 1440 then
 insert into public.services(business_id,name,name_es,name_en,description_es,description_en,duration_minutes,price_mxn,active) values(bid,coalesce(nullif(item->>'name_es',''),item->>'name_en'),item->>'name_es',item->>'name_en',coalesce(item->>'description_es',''),coalesce(item->>'description_en',''),(item->>'duration_minutes')::int,(item->>'price_mxn')::numeric,false) returning id into sid;
 service_map=service_map||jsonb_build_object(coalesce(nullif(item->>'client_id',''),service_index::text),sid::text);
 if item->>'inherits_business_hours'='false' then perform private.save_service_hours(sid,false,item->'opening_schedule');end if;
 end if;end if;
 service_index=service_index+1;
 end loop;
 if private.valid_week(d->'opening_schedule') then perform private.save_business_hours(bid,d->'opening_schedule');end if;
 for item in select value from jsonb_array_elements(coalesce(d->'team','[]')) loop
 if length(trim(coalesce(item->>'name','')))>1 and coalesce(item->>'email','')~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' and length(trim(coalesce(item->>'phone','')))>6 then
 select coalesce(array_agg((service_map->>key)::uuid) filter(where service_map->>key is not null),array[]::uuid[]) into worker_services from jsonb_array_elements_text(coalesce(item->'service_ids','[]')) key;
 perform private.save_team_member(bid,null,item,worker_services);
 end if;end loop;

 end if;
 insert into public.business_members(business_id,user_id,role) values(bid,r.user_id,'owner') on conflict(business_id,user_id) do update set role='owner';
 end if;
 update public.business_intake_requests set business_id=coalesce(bid,business_id),status=p_status,public_message_es=coalesce(p_message_es,''),public_message_en=coalesce(p_message_en,''),updated_at=now() where id=r.id returning * into r;
 insert into public.verification_events(request_id,actor_id,status,notes) values(r.id,auth.uid(),p_status,coalesce(p_notes,''));return r;
end $$;
