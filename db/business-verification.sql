-- Afinia: private intake, visit scheduling and owner assignment after verification.
create table public.platform_admins(user_id uuid primary key references auth.users(id),created_at timestamptz not null default now());
alter table public.platform_admins enable row level security;
create policy admin_self_read on public.platform_admins for select to authenticated using(user_id=(select auth.uid()));
grant select on public.platform_admins to authenticated;
create function private.is_platform_admin() returns boolean language sql stable security definer set search_path='' as $$ select auth.uid() is not null and exists(select 1 from public.platform_admins where user_id=auth.uid()) $$;
revoke all on function private.is_platform_admin() from public,anon; grant execute on function private.is_platform_admin() to authenticated;
-- Verified account of the app owner, not user-editable JWT metadata.
insert into public.platform_admins(user_id) select id from auth.users where email='tmmxbs@gmail.com' and email_confirmed_at is not null;
create table public.verification_schedule(weekday smallint primary key check(weekday between 0 and 6),opens_at time not null default '10:00',closes_at time not null default '20:00',enabled boolean not null default true,check(closes_at>=opens_at+interval '2 hours'));
insert into public.verification_schedule(weekday) select generate_series(0,6);
alter table public.verification_schedule enable row level security;
create policy schedule_read on public.verification_schedule for select to authenticated using(true);
grant select on public.verification_schedule to authenticated;
create table public.verification_blocks(id uuid primary key default gen_random_uuid(),starts_at timestamptz not null,ends_at timestamptz not null,reason text not null default '',check(ends_at>starts_at));
alter table public.verification_blocks enable row level security;
create policy block_admin_read on public.verification_blocks for select to authenticated using((select private.is_platform_admin()));
grant select on public.verification_blocks to authenticated;
create table public.business_intake_requests(
 id uuid primary key default gen_random_uuid(),user_id uuid not null references auth.users(id),kind text not null check(kind in ('existing','new')),
 business_id uuid references public.businesses(id),draft jsonb not null default '{}' check(jsonb_typeof(draft)='object'),
 contact_name text not null default '',contact_email text not null,contact_phone text not null default '',
 status text not null default 'draft' check(status in ('draft','scheduled','confirmed','visited','approved','rejected','canceled')),
 starts_at timestamptz,ends_at timestamptz,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 public_message_es text not null default '',public_message_en text not null default '',
 check((starts_at is null)=(ends_at is null)),check(ends_at is null or ends_at=starts_at+interval '2 hours'),
 check(kind='new' or business_id is not null),
 exclude using gist(tstzrange(starts_at,ends_at,'[)') with &&) where(starts_at is not null and status<>'canceled')
);
create index intake_user_idx on public.business_intake_requests(user_id,created_at desc);
create index intake_business_idx on public.business_intake_requests(business_id);
create unique index intake_active_claim on public.business_intake_requests(user_id,business_id) where kind='existing' and status not in ('canceled','rejected');
alter table public.business_intake_requests enable row level security;
create policy intake_read on public.business_intake_requests for select to authenticated using(user_id=(select auth.uid()) or (select private.is_platform_admin()));
grant select on public.business_intake_requests to authenticated;
create table public.verification_events(id uuid primary key default gen_random_uuid(),request_id uuid not null references public.business_intake_requests(id),actor_id uuid not null references auth.users(id),status text not null,notes text not null default '',created_at timestamptz not null default now());
create index verification_events_request_idx on public.verification_events(request_id,created_at);
alter table public.verification_events enable row level security;
create policy verification_event_admin on public.verification_events for select to authenticated using((select private.is_platform_admin()));
grant select on public.verification_events to authenticated;
-- Old claim endpoint cannot bypass the mandatory appointment flow. Legacy rows remain available for review.
revoke insert on public.business_claim_requests from authenticated;
create policy legacy_claim_admin_read on public.business_claim_requests for select to authenticated using((select private.is_platform_admin()));

create function private.search_claimable_businesses(p_query text) returns table(id uuid,name text,address text,city text,area text,owned boolean) language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
 return query select b.id,b.name,b.address,b.city,b.area,exists(select 1 from public.business_members m where m.business_id=b.id and m.role='owner') from public.businesses b where b.status<>'suspended' and (length(trim(p_query))>=2 and (b.name ilike '%'||left(p_query,100)||'%' or b.address ilike '%'||left(p_query,100)||'%')) order by b.name limit 30;
end $$;
create function private.save_business_intake(p_id uuid,p_business uuid,p_draft jsonb) returns public.business_intake_requests language plpgsql security definer set search_path='' as $$
declare r public.business_intake_requests; em text;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
 select email into em from auth.users where id=auth.uid() and email_confirmed_at is not null;
 if em is null then raise exception 'CONFIRM_EMAIL'; end if;
 if p_id is not null then
 select * into r from public.business_intake_requests where id=p_id and user_id=auth.uid() for update;
 if not found then raise exception 'ACCESS_DENIED'; end if;
 if r.status not in ('draft','canceled') then raise exception 'REQUEST_LOCKED'; end if;
 if r.kind='existing' then return r; end if;
 else
 perform pg_advisory_xact_lock(hashtextextended('intake:'||auth.uid()::text,0));
 if (select count(*) from public.business_intake_requests where user_id=auth.uid() and status not in ('approved','rejected','canceled'))>=5 then raise exception 'REQUEST_LIMIT'; end if;
 if p_business is not null then
 if not exists(select 1 from public.businesses where id=p_business and status<>'suspended') then raise exception 'BUSINESS_UNAVAILABLE'; end if;
 if exists(select 1 from public.business_members where business_id=p_business and role='owner') then raise exception 'BUSINESS_OWNED'; end if;
 select * into r from public.business_intake_requests where user_id=auth.uid() and business_id=p_business and kind='existing' and status not in ('canceled','rejected');
 if found then return r; end if;
 end if;
 insert into public.business_intake_requests(user_id,kind,business_id,contact_email) values(auth.uid(),case when p_business is null then 'new' else 'existing' end,p_business,em) returning * into r;
 end if;
 if r.kind='new' then
 if jsonb_typeof(p_draft)<>'object' or octet_length(p_draft::text)>200000 then raise exception 'INVALID_DRAFT'; end if;
 if exists(select 1 from jsonb_each(p_draft) x where x.key in ('gallery','services','team','availability') and (jsonb_typeof(x.value)<>'array' or jsonb_array_length(x.value)>100)) then raise exception 'INVALID_ITEMS'; end if;
 update public.business_intake_requests set draft=p_draft,updated_at=now() where id=r.id returning * into r;
 end if;
 return r;
end $$;
create function private.verification_slots() returns table(starts_at timestamptz,ends_at timestamptz) language plpgsql security definer set search_path='' as $$
declare horizon integer:=3; last_day date; today date:=(now() at time zone 'America/Mazatlan')::date; candidates jsonb;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
 if not exists(select 1 from public.verification_schedule where enabled) then return; end if;
 -- The farthest busy day bounds the search; two-day increments continue until availability.
 select greatest(today+3,coalesce(max(d),today))+7 into last_day from(select (r.ends_at at time zone 'America/Mazatlan')::date d from public.business_intake_requests r where r.starts_at is not null and r.status<>'canceled' union all select (b.ends_at at time zone 'America/Mazatlan')::date from public.verification_blocks b) busy;
 loop
 with days as(select today+n d from generate_series(0,horizon) n), slots as(
 select x at time zone 'America/Mazatlan' s,(x+interval '2 hours') at time zone 'America/Mazatlan' e from days join public.verification_schedule w on w.weekday=extract(dow from d)::int and w.enabled cross join lateral generate_series(d+w.opens_at,d+w.closes_at-interval '2 hours',interval '1 hour') x)
 select coalesce(jsonb_agg(jsonb_build_object('starts_at',s,'ends_at',e) order by s),'[]'::jsonb) into candidates from slots where s>now() and not exists(select 1 from public.business_intake_requests r where r.starts_at is not null and r.status<>'canceled' and tstzrange(r.starts_at,r.ends_at,'[)')&&tstzrange(s,e,'[)')) and not exists(select 1 from public.verification_blocks b where tstzrange(b.starts_at,b.ends_at,'[)')&&tstzrange(s,e,'[)'));
 if jsonb_array_length(candidates)>0 or today+horizon>=last_day then exit; end if;
 horizon:=horizon+2;
 end loop;
 return query select (v->>'starts_at')::timestamptz,(v->>'ends_at')::timestamptz from jsonb_array_elements(candidates) v;
end $$;
create function private.book_verification(p_request uuid,p_start timestamptz,p_name text,p_phone text) returns public.business_intake_requests language plpgsql security definer set search_path='' as $$
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
create function private.cancel_verification(p_request uuid) returns public.business_intake_requests language plpgsql security definer set search_path='' as $$
declare r public.business_intake_requests;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
 select * into r from public.business_intake_requests where id=p_request and user_id=auth.uid() for update;
 if not found or r.status not in ('draft','scheduled','confirmed') then raise exception 'ACCESS_DENIED'; end if;
 update public.business_intake_requests set status='canceled',updated_at=now() where id=r.id returning * into r;
 insert into public.verification_events(request_id,actor_id,status) values(r.id,auth.uid(),'canceled');return r;
end $$;
create function private.admin_verification(p_request uuid,p_status text,p_notes text,p_message_es text,p_message_en text) returns public.business_intake_requests language plpgsql security definer set search_path='' as $$
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
create function private.admin_verification_schedule(p_week jsonb) returns void language plpgsql security definer set search_path='' as $$
declare item jsonb;
begin
 if not private.is_platform_admin() then raise exception 'ADMIN_REQUIRED'; end if;
 if jsonb_typeof(p_week)<>'array' or jsonb_array_length(p_week)<>7 or (select count(distinct value->>'weekday') from jsonb_array_elements(p_week))<>7 then raise exception 'INVALID_SCHEDULE'; end if;
 perform pg_advisory_xact_lock(hashtextextended('verification-agenda',0));
 for item in select value from jsonb_array_elements(p_week) loop
 update public.verification_schedule set opens_at=(item->>'opens_at')::time,closes_at=(item->>'closes_at')::time,enabled=(item->>'enabled')::boolean where weekday=(item->>'weekday')::int;
 if not found then raise exception 'INVALID_SCHEDULE'; end if;
 end loop;
end $$;
create function private.admin_verification_block(p_id uuid,p_start timestamptz,p_end timestamptz,p_reason text,p_remove boolean) returns void language plpgsql security definer set search_path='' as $$
begin
 if not private.is_platform_admin() then raise exception 'ADMIN_REQUIRED'; end if;
 perform pg_advisory_xact_lock(hashtextextended('verification-agenda',0));
 if p_remove then delete from public.verification_blocks where id=p_id;return;end if;
 if p_start is null or p_end is null or p_end<=p_start or length(p_reason)>200 then raise exception 'INVALID_BLOCK'; end if;
 if exists(select 1 from public.business_intake_requests r where r.starts_at is not null and r.status<>'canceled' and tstzrange(r.starts_at,r.ends_at,'[)')&&tstzrange(p_start,p_end,'[)')) then raise exception 'BLOCK_HAS_APPOINTMENT'; end if;
 insert into public.verification_blocks(starts_at,ends_at,reason) values(p_start,p_end,coalesce(p_reason,''));
end $$;
-- Only safe summaries are exposed for directory search, and all writes go through checked RPCs.
create function public.search_claimable_businesses(p_query text) returns table(id uuid,name text,address text,city text,area text,owned boolean) language sql security invoker set search_path='' as $$ select * from private.search_claimable_businesses(p_query) $$;
create function public.save_business_intake(p_id uuid,p_business uuid,p_draft jsonb) returns public.business_intake_requests language sql security invoker set search_path='' as $$ select private.save_business_intake(p_id,p_business,p_draft) $$;
create function public.verification_slots() returns table(starts_at timestamptz,ends_at timestamptz) language sql security invoker set search_path='' as $$ select * from private.verification_slots() $$;
create function public.book_verification(p_request uuid,p_start timestamptz,p_name text,p_phone text) returns public.business_intake_requests language sql security invoker set search_path='' as $$ select private.book_verification(p_request,p_start,p_name,p_phone) $$;
create function public.cancel_verification(p_request uuid) returns public.business_intake_requests language sql security invoker set search_path='' as $$ select private.cancel_verification(p_request) $$;
create function public.admin_verification(p_request uuid,p_status text,p_notes text,p_message_es text,p_message_en text) returns public.business_intake_requests language sql security invoker set search_path='' as $$ select private.admin_verification(p_request,p_status,p_notes,p_message_es,p_message_en) $$;
create function public.admin_verification_schedule(p_week jsonb) returns void language sql security invoker set search_path='' as $$ select private.admin_verification_schedule(p_week) $$;
create function public.admin_verification_block(p_id uuid,p_start timestamptz,p_end timestamptz,p_reason text,p_remove boolean) returns void language sql security invoker set search_path='' as $$ select private.admin_verification_block(p_id,p_start,p_end,p_reason,p_remove) $$;
do $$ declare f record;begin for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','private') and p.proname in ('search_claimable_businesses','save_business_intake','verification_slots','book_verification','cancel_verification','admin_verification','admin_verification_schedule','admin_verification_block') loop execute format('revoke all on function %s from public,anon',f.signature);execute format('grant execute on function %s to authenticated',f.signature);end loop;end $$;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('business-intake-photos','business-intake-photos',true,5242880,array['image/jpeg','image/png','image/webp','image/avif']);
create policy intake_photo_insert on storage.objects for insert to authenticated with check(bucket_id='business-intake-photos' and (storage.foldername(name))[1]=(select auth.uid())::text);
create policy intake_photo_read on storage.objects for select to authenticated using(bucket_id='business-intake-photos' and ((storage.foldername(name))[1]=(select auth.uid())::text or (select private.is_platform_admin())));
create policy membership_admin_read on public.business_members for select to authenticated using((select private.is_platform_admin()));
create policy verification_admin_read on public.services for select to authenticated using((select private.is_platform_admin()));
create policy verification_admin_read on public.business_gallery for select to authenticated using((select private.is_platform_admin()));
create policy verification_admin_read on public.collaborators for select to authenticated using((select private.is_platform_admin()));
create policy verification_admin_read on public.availability for select to authenticated using((select private.is_platform_admin()));
