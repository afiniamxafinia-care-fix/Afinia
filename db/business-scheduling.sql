-- Structured opening hours, individual capacity and portable worker identity.
create function private.valid_week(p_week jsonb) returns boolean language plpgsql immutable set search_path='' as $$
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
create table public.business_opening_hours(id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id),weekday smallint not null check(weekday between 0 and 6),opens_at time not null,closes_at time not null,check(closes_at>opens_at),unique(business_id,weekday,opens_at),exclude using gist(business_id with =,weekday with =,int4range(extract(epoch from opens_at)::int,extract(epoch from closes_at)::int,'[)') with &&));
alter table public.business_opening_hours enable row level security;
create policy opening_hours_read on public.business_opening_hours for select to anon,authenticated using(exists(select 1 from public.businesses b where b.id=business_id and (b.status='published' or b.directory_listed)));
create policy opening_hours_members on public.business_opening_hours for select to authenticated using(private.is_member(business_id) or (select private.is_platform_admin()));
grant select on public.business_opening_hours to anon,authenticated;
alter table public.services add column inherits_business_hours boolean not null default true;
create table public.service_opening_hours(id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id),service_id uuid not null,weekday smallint not null check(weekday between 0 and 6),opens_at time not null,closes_at time not null,check(closes_at>opens_at),foreign key(business_id,service_id) references public.services(business_id,id),exclude using gist(service_id with =,weekday with =,int4range(extract(epoch from opens_at)::int,extract(epoch from closes_at)::int,'[)') with &&));
create index service_hours_business_idx on public.service_opening_hours(business_id);
alter table public.service_opening_hours enable row level security;
create policy service_hours_read on public.service_opening_hours for select to anon,authenticated using(exists(select 1 from public.businesses b where b.id=business_id and b.status='published'));
create policy service_hours_members on public.service_opening_hours for select to authenticated using(private.is_member(business_id) or (select private.is_platform_admin()));
grant select on public.service_opening_hours to anon,authenticated;
create table public.workers(id uuid primary key default gen_random_uuid(),display_name text not null,email text not null check(email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),phone text not null check(length(phone) between 7 and 40),auth_user_id uuid unique references auth.users(id),created_at timestamptz not null default now());
alter table public.collaborators add column worker_id uuid references public.workers(id),add column is_solo boolean not null default false,add column inherits_business_hours boolean not null default true;
create index collaborators_worker_idx on public.collaborators(worker_id);
create unique index business_solo_capacity on public.collaborators(business_id) where is_solo;
alter table public.workers enable row level security;
create policy worker_manager_read on public.workers for select to authenticated using((select private.is_platform_admin()) or exists(select 1 from public.collaborators c where c.worker_id=workers.id and private.is_manager(c.business_id)));
grant select on public.workers to authenticated;
revoke insert,update,delete on public.collaborators from authenticated;
create table public.collaborator_services(business_id uuid not null,collaborator_id uuid not null,service_id uuid not null,assigned_at timestamptz not null default now(),primary key(collaborator_id,service_id),foreign key(business_id,collaborator_id) references public.collaborators(business_id,id),foreign key(business_id,service_id) references public.services(business_id,id));
create index collaborator_services_service_idx on public.collaborator_services(service_id);
alter table public.collaborator_services enable row level security;
create policy skills_read on public.collaborator_services for select to anon,authenticated using(exists(select 1 from public.businesses b where b.id=business_id and b.status='published'));
create policy skills_member on public.collaborator_services for select to authenticated using(private.is_member(business_id) or (select private.is_platform_admin()));
grant select on public.collaborator_services to anon,authenticated;
create table public.worker_activities(worker_id uuid not null references public.workers(id),business_id uuid not null references public.businesses(id),service_id uuid not null,service_name_es text not null,service_name_en text not null,first_assigned_at timestamptz not null default now(),primary key(worker_id,business_id,service_id),foreign key(business_id,service_id) references public.services(business_id,id));
create index worker_activities_business_idx on public.worker_activities(business_id);
create index worker_activities_service_idx on public.worker_activities(service_id);
alter table public.worker_activities enable row level security;
create policy activities_manager_read on public.worker_activities for select to authenticated using(private.is_manager(business_id) or (select private.is_platform_admin()));
grant select on public.worker_activities to authenticated;
alter table public.visits add column worker_id uuid references public.workers(id),add column worker_name_snapshot text,add column service_name_es text,add column service_name_en text,add column booking_event_id uuid;
create index visits_worker_idx on public.visits(worker_id,service_id,status);
create unique index visits_booking_event_once on public.visits(booking_event_id) where booking_event_id is not null;
create function private.ensure_individual_capacity(p_business uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare cid uuid;
begin
 insert into public.collaborators(business_id,name,is_solo) select id,name,true from public.businesses where id=p_business on conflict(business_id) where is_solo do nothing;
 select id into cid from public.collaborators where business_id=p_business and is_solo;return cid;
end $$;
revoke all on function private.ensure_individual_capacity(uuid) from public,anon,authenticated;
create function private.save_business_hours(p_business uuid,p_schedule jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare d jsonb;h jsonb;weekday integer;es text:='';en text:='';es_days text[]:=array['Domingo','Lunes','Martes','Miércoles','Jueves','Viernes','Sábado'];en_days text[]:=array['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];lines text;
begin
 if not(private.is_manager(p_business) or private.is_platform_admin()) then raise exception 'ACCESS_DENIED';end if;
 perform pg_advisory_xact_lock(hashtextextended('booking:'||p_business::text,0));
 if not private.valid_week(p_schedule) then raise exception 'INVALID_HOURS';end if;
 delete from public.business_opening_hours where business_id=p_business;
 for d in select value from jsonb_array_elements(p_schedule) order by case when (value->>'weekday')::int=0 then 7 else (value->>'weekday')::int end loop
 weekday=(d->>'weekday')::int;if weekday not between 0 and 6 or jsonb_typeof(d->'intervals')<>'array' or jsonb_array_length(d->'intervals')>6 then raise exception 'INVALID_HOURS';end if;
 lines='';
 if (d->>'enabled')::boolean then
 if jsonb_array_length(d->'intervals')=0 then raise exception 'INVALID_HOURS';end if;
 for h in select value from jsonb_array_elements(d->'intervals') order by value->>'opens_at' loop
 if coalesce(h->>'opens_at','')!~'^([01][0-9]|2[0-3]):[0-5][0-9]$' or coalesce(h->>'closes_at','')!~'^([01][0-9]|2[0-3]):[0-5][0-9]$' or h->>'opens_at'>=h->>'closes_at' then raise exception 'INVALID_HOURS';end if;
 insert into public.business_opening_hours(business_id,weekday,opens_at,closes_at) values(p_business,weekday,(h->>'opens_at')::time,(h->>'closes_at')::time);
 lines=lines||case when lines='' then '' else ', ' end||(h->>'opens_at')||'–'||(h->>'closes_at');end loop;
 end if;
 es=es||case when es='' then '' else E'\n' end||es_days[weekday+1]||': '||case when lines='' then 'Cerrado' else lines end;
 en=en||case when en='' then '' else E'\n' end||en_days[weekday+1]||': '||case when lines='' then 'Closed' else lines end;
 end loop;
 perform private.ensure_individual_capacity(p_business);
 update public.businesses set opening_hours_es=es,opening_hours_en=en where id=p_business;
 return jsonb_build_object('opening_hours_es',es,'opening_hours_en',en);
exception when exclusion_violation then raise exception 'HOURS_OVERLAP';
end $$;
create function private.save_team_member(p_business uuid,p_collaborator uuid,p_person jsonb,p_services uuid[]) returns public.collaborators language plpgsql security definer set search_path='' as $$
declare c public.collaborators;w uuid;sid uuid;person_active boolean;person_email text;
begin
 if not(private.is_manager(p_business) or private.is_platform_admin()) then raise exception 'ACCESS_DENIED';end if;
 perform pg_advisory_xact_lock(hashtextextended('booking:'||p_business::text,0));
 if length(trim(coalesce(p_person->>'name','')))<2 or length(trim(coalesce(p_person->>'phone','')))<7 or coalesce(p_person->>'email','')!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'WORKER_CONTACT_REQUIRED';end if;
 if octet_length(p_person::text)>10000 or cardinality(p_services)>100 then raise exception 'INVALID_WORKER';end if;
 if exists(select 1 from unnest(p_services) s where not exists(select 1 from public.services where id=s and business_id=p_business)) then raise exception 'FOREIGN_SERVICE';end if;
 person_email=lower(trim(p_person->>'email'));person_active=coalesce((p_person->>'active')::boolean,true);
 if exists(select 1 from public.collaborators co join public.workers wo on wo.id=co.worker_id where co.business_id=p_business and wo.email=person_email and (p_collaborator is null or co.id<>p_collaborator)) then raise exception 'WORKER_ALREADY_IN_TEAM';end if;
 if p_collaborator is not null then
 select * into c from public.collaborators where id=p_collaborator and business_id=p_business and not is_solo for update;
 if not found then raise exception 'ACCESS_DENIED';end if;
 if not person_active and exists(select 1 from public.visits where collaborator_id=c.id and status in ('scheduled','checked_in') and ends_at>now()) then raise exception 'WORKER_HAS_BOOKINGS';end if;
 w=c.worker_id;
 else w=gen_random_uuid();insert into public.workers(id,display_name,email,phone) values(w,trim(p_person->>'name'),person_email,trim(p_person->>'phone'));end if;
 if w is null then w=gen_random_uuid();insert into public.workers(id,display_name,email,phone) values(w,trim(p_person->>'name'),person_email,trim(p_person->>'phone'));end if;
 update public.workers set display_name=trim(p_person->>'name'),email=person_email,phone=trim(p_person->>'phone') where id=w;
 if p_collaborator is null then insert into public.collaborators(business_id,name,bio_es,bio_en,worker_id,active) values(p_business,trim(p_person->>'name'),coalesce(p_person->>'bio_es',''),coalesce(p_person->>'bio_en',''),w,person_active) returning * into c;
 else update public.collaborators set name=trim(p_person->>'name'),bio_es=coalesce(p_person->>'bio_es',''),bio_en=coalesce(p_person->>'bio_en',''),worker_id=w,active=person_active where id=c.id returning * into c;end if;
 delete from public.collaborator_services where collaborator_id=c.id;
 foreach sid in array coalesce(p_services,array[]::uuid[]) loop
 insert into public.collaborator_services(business_id,collaborator_id,service_id) values(p_business,c.id,sid) on conflict do nothing;
 insert into public.worker_activities(worker_id,business_id,service_id,service_name_es,service_name_en) select w,p_business,id,coalesce(name_es,name),coalesce(name_en,name) from public.services where id=sid on conflict do nothing;
 end loop;
 perform private.save_worker_hours(c.id,coalesce((p_person->>'inherits_business_hours')::boolean,true),coalesce(p_person->'opening_schedule','[]'));
 return c;
end $$;
create function private.visit_worker_snapshot() returns trigger language plpgsql set search_path='' as $$
begin
 if tg_op='INSERT' then
 select c.worker_id,c.name into new.worker_id,new.worker_name_snapshot from public.collaborators c where c.id=new.collaborator_id and c.business_id=new.business_id;
 select coalesce(s.name_es,s.name),coalesce(s.name_en,s.name) into new.service_name_es,new.service_name_en from public.services s where s.id=new.service_id and s.business_id=new.business_id;
 end if;return new;
end $$;
revoke all on function private.visit_worker_snapshot() from public,anon,authenticated;
create trigger visit_worker_snapshot before insert on public.visits for each row execute function private.visit_worker_snapshot();
create view public.worker_service_stats with(security_invoker=true) as select a.*,(select count(*) from public.visits v where v.worker_id=a.worker_id and v.business_id=a.business_id and v.service_id=a.service_id and v.status='completed') completed_services from public.worker_activities a;
grant select on public.worker_service_stats to authenticated;
-- Worker and service overrides use the same strict weekly format as the establishment.
revoke insert,update,delete on public.availability from authenticated;
create function private.save_worker_hours(p_collaborator uuid,p_inherit boolean,p_schedule jsonb) returns void language plpgsql security definer set search_path='' as $$
declare bid uuid;d jsonb;h jsonb;
begin
 select business_id into bid from public.collaborators where id=p_collaborator and not is_solo;
 if bid is null or not(private.is_manager(bid) or private.is_platform_admin()) then raise exception 'ACCESS_DENIED';end if;
 perform pg_advisory_xact_lock(hashtextextended('booking:'||bid::text,0));
 delete from public.availability where collaborator_id=p_collaborator;
 update public.collaborators set inherits_business_hours=p_inherit where id=p_collaborator;
 if p_inherit then return;end if;
 if not private.valid_week(p_schedule) then raise exception 'INVALID_HOURS';end if;
 for d in select value from jsonb_array_elements(p_schedule) loop
 if (d->>'weekday')::int not between 0 and 6 or jsonb_typeof(d->'intervals')<>'array' or jsonb_array_length(d->'intervals')>6 then raise exception 'INVALID_HOURS';end if;
 if (d->>'enabled')::boolean then
 if jsonb_array_length(d->'intervals')=0 then raise exception 'INVALID_HOURS';end if;
 for h in select value from jsonb_array_elements(d->'intervals') loop
 if coalesce(h->>'opens_at','')!~'^([01][0-9]|2[0-3]):[0-5][0-9]$' or coalesce(h->>'closes_at','')!~'^([01][0-9]|2[0-3]):[0-5][0-9]$' or h->>'opens_at'>=h->>'closes_at' then raise exception 'INVALID_HOURS';end if;
 insert into public.availability(business_id,collaborator_id,weekday,opens_at,closes_at) values(bid,p_collaborator,(d->>'weekday')::int,(h->>'opens_at')::time,(h->>'closes_at')::time);
 end loop;end if;end loop;
end $$;
revoke all on function private.save_worker_hours(uuid,boolean,jsonb) from public,anon,authenticated;
create function private.save_service_hours(p_service uuid,p_inherit boolean,p_schedule jsonb) returns void language plpgsql security definer set search_path='' as $$
declare bid uuid;d jsonb;h jsonb;
begin
 select business_id into bid from public.services where id=p_service;
 if bid is null or not(private.is_manager(bid) or private.is_platform_admin()) then raise exception 'ACCESS_DENIED';end if;
 perform pg_advisory_xact_lock(hashtextextended('booking:'||bid::text,0));
 delete from public.service_opening_hours where service_id=p_service;
 update public.services set inherits_business_hours=p_inherit where id=p_service;
 if p_inherit then return;end if;
 if not private.valid_week(p_schedule) then raise exception 'INVALID_HOURS';end if;
 for d in select value from jsonb_array_elements(p_schedule) loop
 if (d->>'weekday')::int not between 0 and 6 or jsonb_typeof(d->'intervals')<>'array' or jsonb_array_length(d->'intervals')>6 then raise exception 'INVALID_HOURS';end if;
 if (d->>'enabled')::boolean then
 if jsonb_array_length(d->'intervals')=0 then raise exception 'INVALID_HOURS';end if;
 for h in select value from jsonb_array_elements(d->'intervals') loop
 if coalesce(h->>'opens_at','')!~'^([01][0-9]|2[0-3]):[0-5][0-9]$' or coalesce(h->>'closes_at','')!~'^([01][0-9]|2[0-3]):[0-5][0-9]$' or h->>'opens_at'>=h->>'closes_at' then raise exception 'INVALID_HOURS';end if;
 insert into public.service_opening_hours(business_id,service_id,weekday,opens_at,closes_at) values(bid,p_service,(d->>'weekday')::int,(h->>'opens_at')::time,(h->>'closes_at')::time);
 end loop;end if;end loop;
exception when exclusion_violation then raise exception 'HOURS_OVERLAP';
end $$;
create function public.save_service_hours(p_service uuid,p_inherit boolean,p_schedule jsonb) returns void language sql security invoker set search_path='' as $$select private.save_service_hours(p_service,p_inherit,p_schedule)$$;
-- One engine shared by regular service bookings and promotions.
create function private.service_slots(p_service uuid,p_day date,p_collaborator uuid default null) returns table(collaborator_id uuid,collaborator_name text,starts_at timestamptz,ends_at timestamptz) language plpgsql security definer set search_path='' as $$
declare b public.businesses;s public.services;has_team boolean;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED';end if;
 select * into s from public.services where id=p_service and active;if not found then return;end if;
 select * into b from public.businesses where id=s.business_id and status='published' and enrollment_status='active' and booking_enabled;if not found then return;end if;
 if p_day<(now() at time zone b.timezone)::date or p_day>(now() at time zone b.timezone)::date+90 then raise exception 'DATE_OUT_OF_RANGE';end if;
 has_team=exists(select 1 from public.collaborators where business_id=b.id and active and not is_solo);
 return query select distinct c.id,case when c.is_solo then b.name else c.name end,x.slot,x.slot+make_interval(mins=>s.duration_minutes)
 from public.business_opening_hours h join public.collaborators c on c.business_id=h.business_id and c.active and ((not has_team and c.is_solo) or (has_team and not c.is_solo and exists(select 1 from public.collaborator_services cs where cs.collaborator_id=c.id and cs.service_id=s.id)))
 left join public.availability a on has_team and not c.inherits_business_hours and a.collaborator_id=c.id and a.weekday=h.weekday
 left join public.service_opening_hours sh on not s.inherits_business_hours and sh.service_id=s.id and sh.weekday=h.weekday
 cross join lateral generate_series((p_day+greatest(h.opens_at,case when has_team and not c.inherits_business_hours then a.opens_at else h.opens_at end,case when s.inherits_business_hours then h.opens_at else sh.opens_at end)) at time zone b.timezone,((p_day+least(h.closes_at,case when has_team and not c.inherits_business_hours then a.closes_at else h.closes_at end,case when s.inherits_business_hours then h.closes_at else sh.closes_at end)) at time zone b.timezone)-make_interval(mins=>s.duration_minutes),interval '15 minutes') x(slot)
 where h.business_id=b.id and h.weekday=extract(dow from p_day)::int and (not has_team or c.inherits_business_hours or a.id is not null) and (s.inherits_business_hours or sh.id is not null) and (p_collaborator is null or c.id=p_collaborator) and x.slot>now()
 and not exists(select 1 from public.visits v left join public.collaborators vc on vc.id=v.collaborator_id where v.business_id=b.id and v.status in ('scheduled','checked_in','completed') and (v.collaborator_id=c.id or vc.is_solo or v.collaborator_id is null) and tstzrange(v.starts_at,v.ends_at,'[)')&&tstzrange(x.slot,x.slot+make_interval(mins=>s.duration_minutes),'[)')) order by 3,2;
end $$;
create or replace function private.promotion_slots(p_promotion uuid,p_day date) returns table(collaborator_id uuid,collaborator_name text,starts_at timestamptz,ends_at timestamptz) language plpgsql security definer set search_path='' as $$
declare p public.promotions;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED';end if;
 select promo.* into p from public.promotions promo where promo.id=p_promotion and promo.status='published' and promo.starts_at<=now() and promo.ends_at>now();if not found then raise exception 'Promotion unavailable';end if;
 if p.placement='live' and not exists(select 1 from public.profiles where user_id=auth.uid() and live_enabled) then raise exception 'Live is off';end if;
 return query select slot.* from private.service_slots(p.service_id,p_day,null) slot where slot.starts_at>=p.starts_at and slot.ends_at<=p.ends_at;
end $$;
create function private.bookable_staff(p_service uuid) returns table(collaborator_id uuid,collaborator_name text,is_solo boolean) language plpgsql security definer set search_path='' as $$
declare bid uuid;has_team boolean;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED';end if;
 select b.id into bid from public.businesses b join public.services s on s.business_id=b.id where s.id=p_service and s.active and b.status='published' and b.booking_enabled and b.enrollment_status='active';if bid is null then return;end if;
 has_team=exists(select 1 from public.collaborators co where co.business_id=bid and co.active and not co.is_solo);
 return query select c.id,c.name,c.is_solo from public.collaborators c where c.business_id=bid and c.active and ((not has_team and c.is_solo) or (has_team and not c.is_solo and exists(select 1 from public.collaborator_services cs where cs.collaborator_id=c.id and cs.service_id=p_service))) order by c.name;
end $$;
create function private.next_service_day(p_service uuid,p_collaborator uuid,p_after date,p_promotion uuid default null) returns date language plpgsql security definer set search_path='' as $$
declare d date;tz text;limit_day date;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED';end if;
 select b.timezone into tz from public.businesses b join public.services s on s.business_id=b.id where s.id=p_service;
 if tz is null then return null;end if;limit_day=(now() at time zone tz)::date+90;
 if p_after<(now() at time zone tz)::date or p_after>limit_day then raise exception 'DATE_OUT_OF_RANGE';end if;
 for d in select p_after+i from generate_series(0,limit_day-p_after) i loop
 if p_promotion is null then
 if exists(select 1 from private.service_slots(p_service,d,p_collaborator)) then return d;end if;
 else
 if not exists(select 1 from public.promotions where id=p_promotion and service_id=p_service and ends_at>((d)::timestamp at time zone tz)) then return null;end if;
 if exists(select 1 from private.promotion_slots(p_promotion,d) s where p_collaborator is null or s.collaborator_id=p_collaborator) then return d;end if;
 end if;
 end loop;return null;
end $$;
create function private.book_service(p_service uuid,p_collaborator uuid,p_start timestamptz,p_event uuid) returns public.visits language plpgsql security definer set search_path='' as $$
declare s public.services;v public.visits;finish timestamptz;tz text;
begin
 if auth.uid() is null or p_event is null then raise exception 'AUTH_REQUIRED';end if;
 perform pg_advisory_xact_lock(hashtextextended('event:'||p_event::text,0));
 select * into v from public.visits where booking_event_id=p_event;
 if found then if v.customer_id<>auth.uid() or v.service_id<>p_service or v.collaborator_id<>p_collaborator or v.starts_at<>p_start then raise exception 'INVALID_BOOKING_EVENT';end if;return v;end if;
 select * into s from public.services where id=p_service and active for share;if not found then raise exception 'SERVICE_UNAVAILABLE';end if;
 perform pg_advisory_xact_lock(hashtextextended('booking:'||s.business_id::text,0));
 select timezone into tz from public.businesses where id=s.business_id;
 select slot.ends_at into finish from private.service_slots(p_service,(p_start at time zone tz)::date,p_collaborator) slot where slot.starts_at=p_start limit 1;
 if finish is null then raise exception 'SLOT_UNAVAILABLE';end if;
 insert into public.visits(business_id,customer_id,service_id,collaborator_id,kind,source,status,starts_at,ends_at,booked_price_mxn,booking_event_id) values(s.business_id,auth.uid(),s.id,p_collaborator,'appointment','mi_espacio','scheduled',p_start,finish,s.price_mxn,p_event) returning * into v;return v;
end $$;
create function private.complete_service_visit(p_visit uuid,p_amount numeric) returns jsonb language plpgsql security definer set search_path='' as $$
declare bid uuid;
begin select business_id into bid from public.visits where id=p_visit;if not private.is_manager(bid) then raise exception 'ACCESS_DENIED';end if;return public.complete_visit(p_visit,auth.uid(),p_amount);end $$;
create function public.save_business_hours(p_business uuid,p_schedule jsonb) returns jsonb language sql security invoker set search_path='' as $$select private.save_business_hours(p_business,p_schedule)$$;
create function public.save_team_member(p_business uuid,p_collaborator uuid,p_person jsonb,p_services uuid[]) returns public.collaborators language sql security invoker set search_path='' as $$select private.save_team_member(p_business,p_collaborator,p_person,p_services)$$;
create function public.service_slots(p_service uuid,p_day date,p_collaborator uuid default null) returns table(collaborator_id uuid,collaborator_name text,starts_at timestamptz,ends_at timestamptz) language sql security invoker set search_path='' as $$select * from private.service_slots(p_service,p_day,p_collaborator)$$;
create function public.bookable_staff(p_service uuid) returns table(collaborator_id uuid,collaborator_name text,is_solo boolean) language sql security invoker set search_path='' as $$select * from private.bookable_staff(p_service)$$;
create function public.next_service_day(p_service uuid,p_collaborator uuid,p_after date,p_promotion uuid default null) returns date language sql security invoker set search_path='' as $$select private.next_service_day(p_service,p_collaborator,p_after,p_promotion)$$;
create function public.book_service(p_service uuid,p_collaborator uuid,p_start timestamptz,p_event uuid) returns public.visits language sql security invoker set search_path='' as $$select private.book_service(p_service,p_collaborator,p_start,p_event)$$;
create function public.complete_service_visit(p_visit uuid,p_amount numeric) returns jsonb language sql security invoker set search_path='' as $$select private.complete_service_visit(p_visit,p_amount)$$;
do $$declare f record;begin for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','private') and p.proname in ('save_business_hours','save_team_member','service_slots','bookable_staff','next_service_day','book_service','complete_service_visit','save_service_hours') loop execute format('revoke all on function %s from public,anon',f.signature);execute format('grant execute on function %s to authenticated',f.signature);end loop;end $$;

alter table public.availability add constraint worker_hours_no_overlap exclude using gist(collaborator_id with =,weekday with =,int4range(extract(epoch from opens_at)::int,extract(epoch from closes_at)::int,'[)') with &&);
