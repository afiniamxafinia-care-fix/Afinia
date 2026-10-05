-- Live promotions, click attribution and verified booking/conversion KPIs.
alter table public.promotions drop constraint promotions_status_check;
alter table public.promotions add constraint promotions_status_check check(status in ('draft','published','hidden','expired'));
alter table public.promotions add column service_id uuid,
 add column special_price_mxn numeric(12,2) check(special_price_mxn>=0),
 add column images jsonb not null default '[]' check(jsonb_typeof(images)='array' and jsonb_array_length(images)<=5),
 add column terms_es text not null default '',add column terms_en text not null default '',
 add column updated_at timestamptz not null default now(),
 add constraint promotions_business_id_id_key unique(business_id,id),
 add constraint promotions_service_fk foreign key(business_id,service_id) references public.services(business_id,id);
create index promotions_service_idx on public.promotions(service_id);
create policy promotion_manager_insert on public.promotions for insert to authenticated with check(private.is_manager(business_id));
create policy promotion_manager_update on public.promotions for update to authenticated using(private.is_manager(business_id)) with check(private.is_manager(business_id));
grant insert,update on public.promotions to authenticated;
create function private.validate_promotion() returns trigger language plpgsql set search_path='' as $$
declare s public.services;
begin
 new.updated_at=now();
 if exists(select 1 from jsonb_array_elements(new.images) i where jsonb_typeof(i)<>'object' or coalesce(i->>'url','')!~'^https://') then raise exception 'Use HTTPS image URLs'; end if;
 if new.status='published' then
  select * into s from public.services where business_id=new.business_id and id=new.service_id and active;
  if not found or new.special_price_mxn is null or new.special_price_mxn>s.price_mxn then raise exception 'Choose an active service and a special price no greater than its regular price'; end if;
  if coalesce(length(trim(new.title_es)),0)=0 or coalesce(length(trim(new.title_en)),0)=0 or length(trim(new.description_es))=0 or length(trim(new.description_en))=0 then raise exception 'Complete title and description in Spanish and English'; end if;
  if new.ends_at<=now() then raise exception 'Promotion has already ended'; end if;
 end if;
 return new;
end $$;
revoke all on function private.validate_promotion() from public,anon,authenticated;
create trigger promotion_validate before insert or update on public.promotions for each row execute function private.validate_promotion();

create table public.promotion_clicks(
 id uuid primary key default gen_random_uuid(), promotion_id uuid not null,
 business_id uuid not null, customer_id uuid not null references auth.users(id),
 service_id uuid not null, source text not null check(source in ('capsule','home_card','live_list','service_cta')),
 created_at timestamptz not null default now(),
 unique(business_id,customer_id,id),
 foreign key(business_id,promotion_id) references public.promotions(business_id,id),
 foreign key(business_id,service_id) references public.services(business_id,id)
);
create index promotion_clicks_promotion_idx on public.promotion_clicks(promotion_id,created_at);
create index promotion_clicks_customer_idx on public.promotion_clicks(customer_id,created_at);
alter table public.promotion_clicks enable row level security;
create policy clicks_read on public.promotion_clicks for select to authenticated using(customer_id=(select auth.uid()) or private.is_manager(business_id));
revoke all on public.promotion_clicks from anon,authenticated;
grant select on public.promotion_clicks to authenticated;

create function private.record_promotion_click(p_promotion uuid,p_event uuid,p_source text) returns uuid language plpgsql security definer set search_path='' as $$
declare p public.promotions; existing public.promotion_clicks;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if p_event is null or p_source not in ('capsule','home_card','live_list','service_cta') then raise exception 'Invalid click'; end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,19));
 select * into existing from public.promotion_clicks where id=p_event;
 if found then
  if existing.customer_id<>auth.uid() or existing.promotion_id<>p_promotion or existing.source<>p_source then raise exception 'Invalid event'; end if;
  return existing.id;
 end if;
 select pr.* into p from public.promotions pr where pr.id=p_promotion and pr.status='published' and pr.starts_at<=now() and pr.ends_at>now();
 if not found or not exists(select 1 from public.businesses where id=p.business_id and status='published') or not exists(select 1 from public.services where id=p.service_id and business_id=p.business_id and active) then raise exception 'Promotion unavailable'; end if;
 if p.placement='live' and not exists(select 1 from public.profiles where user_id=auth.uid() and live_enabled) then raise exception 'Live is off'; end if;
 if (select count(*) from public.promotion_clicks where customer_id=auth.uid() and created_at>now()-interval '1 minute')>=30 then raise exception 'Please wait before trying again'; end if;
 insert into public.promotion_clicks(id,promotion_id,business_id,customer_id,service_id,source) values(p_event,p.id,p.business_id,auth.uid(),p.service_id,p_source);
 return p_event;
end $$;
create function public.record_promotion_click(p_promotion uuid,p_event uuid,p_source text) returns uuid language sql security invoker set search_path='' as $$ select private.record_promotion_click(p_promotion,p_event,p_source) $$;
revoke all on function private.record_promotion_click(uuid,uuid,text), public.record_promotion_click(uuid,uuid,text) from public,anon,authenticated;
grant execute on function private.record_promotion_click(uuid,uuid,text), public.record_promotion_click(uuid,uuid,text) to authenticated;

alter table public.visits add column promotion_id uuid,add column promotion_click_id uuid,
 add column booked_price_mxn numeric(12,2) check(booked_price_mxn>=0),
 add column promotion_title_es text,add column promotion_title_en text,
 add constraint visit_promotion_fk foreign key(business_id,promotion_id) references public.promotions(business_id,id),
 add constraint visit_click_fk foreign key(business_id,customer_id,promotion_click_id) references public.promotion_clicks(business_id,customer_id,id),
 add constraint visit_promotion_attribution check((promotion_id is null and promotion_click_id is null) or (promotion_id is not null and promotion_click_id is not null));
create unique index visit_click_once_idx on public.visits(promotion_click_id) where promotion_click_id is not null;
create index visits_promotion_idx on public.visits(promotion_id);

create function private.promotion_slots(p_promotion uuid,p_day date)
 returns table(collaborator_id uuid,collaborator_name text,starts_at timestamptz,ends_at timestamptz)
 language plpgsql security definer set search_path='' as $$
declare p public.promotions; b public.businesses; s public.services;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 select pr.* into p from public.promotions pr where pr.id=p_promotion and pr.status='published' and pr.starts_at<=now() and pr.ends_at>now();
 if not found then raise exception 'Promotion unavailable'; end if;
 if p.placement='live' and not exists(select 1 from public.profiles where user_id=auth.uid() and live_enabled) then raise exception 'Live is off'; end if;
 select * into b from public.businesses where id=p.business_id and status='published' and enrollment_status='active' and booking_enabled;
 if not found then return; end if;
 select * into s from public.services where id=p.service_id and business_id=b.id and active;
 if not found then return; end if;
 if p_day<(now() at time zone b.timezone)::date or p_day>(now() at time zone b.timezone)::date+90 then raise exception 'Choose a date in the next 90 days'; end if;
 return query select distinct c.id,c.name,x.slot,x.slot+make_interval(mins=>s.duration_minutes)
 from public.availability a join public.collaborators c on c.id=a.collaborator_id and c.business_id=a.business_id and c.active
 cross join lateral generate_series((p_day+a.opens_at) at time zone b.timezone, ((p_day+a.closes_at) at time zone b.timezone)-make_interval(mins=>s.duration_minutes),interval '15 minutes') x(slot)
 where a.business_id=b.id and a.weekday=extract(dow from p_day)::integer and x.slot>now() and x.slot>=p.starts_at and x.slot+make_interval(mins=>s.duration_minutes)<=p.ends_at
 and not exists(select 1 from public.visits v where v.collaborator_id=c.id and v.status in ('scheduled','checked_in','completed') and tstzrange(v.starts_at,v.ends_at,'[)')&&tstzrange(x.slot,x.slot+make_interval(mins=>s.duration_minutes),'[)'))
 order by 3,2;
end $$;
create function public.promotion_slots(p_promotion uuid,p_day date)
 returns table(collaborator_id uuid,collaborator_name text,starts_at timestamptz,ends_at timestamptz)
 language sql security invoker set search_path='' as $$ select * from private.promotion_slots(p_promotion,p_day) $$;
revoke all on function private.promotion_slots(uuid,date),public.promotion_slots(uuid,date) from public,anon,authenticated;
grant execute on function private.promotion_slots(uuid,date),public.promotion_slots(uuid,date) to authenticated;

create function private.book_promotion(p_promotion uuid,p_click uuid,p_collaborator uuid,p_start timestamptz)
 returns public.visits language plpgsql security definer set search_path='' as $$
declare p public.promotions; v public.visits; c public.promotion_clicks; tz text; finish timestamptz;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 select * into c from public.promotion_clicks where id=p_click and customer_id=auth.uid() and promotion_id=p_promotion;
 if not found then raise exception 'Valid promotion click required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_click::text,20));
 select * into v from public.visits where promotion_click_id=p_click and customer_id=auth.uid();
 if found then return v; end if;
 select * into p from public.promotions where id=p_promotion for share;
 if c.service_id<>p.service_id then raise exception 'Promotion service changed; open it again'; end if;
 if p.status<>'published' or p.starts_at>now() or p.ends_at<=now() then raise exception 'Promotion unavailable'; end if;
 perform pg_advisory_xact_lock(hashtextextended('booking:'||p.business_id::text,0));
 select timezone into tz from public.businesses where id=p.business_id;
 select slot.ends_at into finish from private.promotion_slots(p.id,(p_start at time zone tz)::date) slot where slot.collaborator_id=p_collaborator and slot.starts_at=p_start;
 if finish is null then raise exception 'This time is no longer available'; end if;
 insert into public.visits(business_id,customer_id,service_id,collaborator_id,kind,source,status,starts_at,ends_at,promotion_id,promotion_click_id,booked_price_mxn,promotion_title_es,promotion_title_en)
 values(p.business_id,auth.uid(),p.service_id,p_collaborator,'appointment','mi_espacio','scheduled',p_start,finish,p.id,c.id,p.special_price_mxn,p.title_es,p.title_en) returning * into v;
 return v;
end $$;
create function public.book_promotion(p_promotion uuid,p_click uuid,p_collaborator uuid,p_start timestamptz)
 returns public.visits language sql security invoker set search_path='' as $$ select private.book_promotion(p_promotion,p_click,p_collaborator,p_start) $$;
revoke all on function private.book_promotion(uuid,uuid,uuid,timestamptz),public.book_promotion(uuid,uuid,uuid,timestamptz) from public,anon,authenticated;
grant execute on function private.book_promotion(uuid,uuid,uuid,timestamptz),public.book_promotion(uuid,uuid,uuid,timestamptz) to authenticated;

create function private.complete_promotion_visit(p_visit uuid,p_amount_mxn numeric) returns jsonb language plpgsql security definer set search_path='' as $$
declare b uuid;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 select business_id into b from public.visits where id=p_visit and promotion_id is not null;
 if b is null or not private.is_manager(b) then raise exception 'Manager access required'; end if;
 return public.complete_visit(p_visit,auth.uid(),p_amount_mxn);
end $$;
create function public.complete_promotion_visit(p_visit uuid,p_amount_mxn numeric) returns jsonb language sql security invoker set search_path='' as $$ select private.complete_promotion_visit(p_visit,p_amount_mxn) $$;
revoke all on function private.complete_promotion_visit(uuid,numeric),public.complete_promotion_visit(uuid,numeric) from public,anon,authenticated;
grant execute on function private.complete_promotion_visit(uuid,numeric),public.complete_promotion_visit(uuid,numeric) to authenticated;

create view public.promotion_metrics with (security_invoker=true) as
 select p.id promotion_id,p.business_id,
 (select count(*) from public.promotion_clicks c where c.promotion_id=p.id) clicks,
 (select count(distinct customer_id) from public.promotion_clicks c where c.promotion_id=p.id) unique_customers,
 (select count(*) from public.visits v where v.promotion_id=p.id) bookings,
 (select count(*) from public.visits v where v.promotion_id=p.id and v.status='completed') completed,
 (select count(*) from public.visits v where v.promotion_id=p.id and v.status='cancelled') cancelled,
 (select coalesce(sum(amount_mxn),0) from public.visits v where v.promotion_id=p.id and v.status='completed') revenue_mxn
,
 (select count(*) from public.visits v join public.customer_relationships r on r.business_id=v.business_id and r.customer_id=v.customer_id and r.first_visit_id=v.id where v.promotion_id=p.id and v.status='completed') new_acquisitions
 from public.promotions p where private.is_manager(p.business_id);
revoke all on public.promotion_metrics from anon,authenticated;
grant select on public.promotion_metrics to authenticated;
