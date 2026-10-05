-- Me. in-person consumption, configurable points coverage and protected reservations.
alter table public.businesses add column requires_reservation boolean not null default true,
 add column points_coverage_rate numeric not null default .50 check(points_coverage_rate in (.20,.30,.40,.50)),
 add column benefit_version bigint not null default 1;
alter table public.visits add column coverage_rate_snapshot numeric check(coverage_rate_snapshot in (.20,.30,.40,.50)),
 add column benefit_version_snapshot bigint,add column presence_confirmed_at timestamptz,
 add column arrival_origin text check(arrival_origin in ('spontaneous','app','promotion'));
update public.visits v set coverage_rate_snapshot=b.points_coverage_rate,benefit_version_snapshot=b.benefit_version from public.businesses b where b.id=v.business_id and v.kind='appointment';
create table public.business_benefit_history(id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id),version bigint not null,old_rate numeric not null,new_rate numeric not null,requires_reservation boolean not null,actor_id uuid references auth.users(id),created_at timestamptz not null default now(),unique(business_id,version));
create index benefit_history_business_time on public.business_benefit_history(business_id,created_at desc);
alter table public.business_benefit_history enable row level security;
create policy benefits_manager_read on public.business_benefit_history for select to authenticated using(private.is_manager(business_id) or (select private.is_platform_admin()));
grant select on public.business_benefit_history to authenticated;
create function private.business_benefit_audit() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.points_coverage_rate is distinct from old.points_coverage_rate or new.requires_reservation is distinct from old.requires_reservation then
 new.benefit_version=old.benefit_version+1;
 insert into public.business_benefit_history(business_id,version,old_rate,new_rate,requires_reservation,actor_id) values(new.id,new.benefit_version,old.points_coverage_rate,new.points_coverage_rate,new.requires_reservation,auth.uid());
 else new.benefit_version=old.benefit_version;end if;
 return new;
end $$;
revoke all on function private.business_benefit_audit() from public,anon,authenticated;
create trigger business_benefit_audit before update on public.businesses for each row execute function private.business_benefit_audit();
create function private.save_business_benefits(p_business uuid,p_requires boolean,p_rate numeric) returns public.businesses language plpgsql security definer set search_path='' as $$
declare b public.businesses;begin
 if not(private.is_manager(p_business) or private.is_platform_admin()) then raise exception 'ACCESS_DENIED';end if;
 if p_requires is null or p_rate is null or p_rate not in (.20,.30,.40,.50) then raise exception 'INVALID_BENEFIT';end if;
 perform pg_advisory_xact_lock(hashtextextended('booking:'||p_business::text,0));
 update public.businesses set requires_reservation=p_requires,points_coverage_rate=p_rate where id=p_business returning * into b;return b;
end $$;
create function private.visit_benefit_snapshot() returns trigger language plpgsql set search_path='' as $$
begin
 if new.kind='appointment' then
 select b.points_coverage_rate,b.benefit_version into new.coverage_rate_snapshot,new.benefit_version_snapshot from public.businesses b where b.id=new.business_id for share;
 else new.coverage_rate_snapshot=null;new.benefit_version_snapshot=null;end if;return new;
end $$;
revoke all on function private.visit_benefit_snapshot() from public,anon,authenticated;
create trigger visit_benefit_snapshot before insert on public.visits for each row execute function private.visit_benefit_snapshot();
create table private.visit_presence(visit_id uuid primary key references public.visits(id),code text not null unique,expires_at timestamptz not null);
alter table private.visit_presence enable row level security;
create table private.presence_attempts(actor_id uuid not null,business_id uuid not null,created_at timestamptz not null default now());
create index presence_attempt_actor_time on private.presence_attempts(actor_id,created_at);
alter table private.presence_attempts enable row level security;
create table public.visit_payments(id uuid primary key default gen_random_uuid(),visit_id uuid not null references public.visits(id),business_id uuid not null references public.businesses(id),customer_id uuid not null references auth.users(id),amount_mxn numeric not null check(amount_mxn>=0 and amount_mxn=round(amount_mxn,2)),coverage_rate numeric not null check(coverage_rate in (.20,.30,.40,.50)),policy_version bigint not null,protected boolean not null,state text not null default 'proposed' check(state in ('proposed','confirmed','completed','superseded','declined')),points_mxn numeric not null default 0 check(points_mxn>=0),cash_mxn numeric generated always as(amount_mxn-points_mxn) stored,created_at timestamptz not null default now(),expires_at timestamptz not null default now()+interval '10 minutes',confirmed_at timestamptz,completed_at timestamptz,check(points_mxn<=round(amount_mxn*coverage_rate,2)),unique(id,customer_id));
create unique index visit_one_open_payment on public.visit_payments(visit_id) where state in ('proposed','confirmed');
create unique index visit_one_completed_payment on public.visit_payments(visit_id) where state='completed';
create index payments_customer_state on public.visit_payments(customer_id,state);
create index payments_business_state on public.visit_payments(business_id,state);
alter table public.visit_payments enable row level security;
create policy payment_participants_read on public.visit_payments for select to authenticated using(customer_id=(select auth.uid()) or private.is_manager(business_id) or (select private.is_platform_admin()));
grant select on public.visit_payments to authenticated;
create table public.point_allocations(id uuid primary key default gen_random_uuid(),payment_id uuid not null,customer_id uuid not null,reward_id uuid not null references public.reward_ledger(id),amount_mxn numeric not null check(amount_mxn>0),created_at timestamptz not null default now(),unique(payment_id,reward_id),foreign key(payment_id,customer_id) references public.visit_payments(id,customer_id));
create index point_allocations_reward on public.point_allocations(reward_id);
create index point_allocations_customer on public.point_allocations(customer_id);
alter table public.point_allocations enable row level security;
create policy allocations_owner_read on public.point_allocations for select to authenticated using(customer_id=(select auth.uid()));
grant select on public.point_allocations to authenticated;
-- Direct table writes never create financial events; all changes go through checked RPCs.
revoke all on private.visit_presence,private.presence_attempts from public,anon,authenticated;
revoke insert,update,delete on public.visit_payments,public.point_allocations,public.business_benefit_history from anon,authenticated;
create function private.available_credits(p_customer uuid) returns table(reward_id uuid,business_id uuid,available_mxn numeric,created_at timestamptz) language sql stable set search_path='' as $$
 select r.id,r.business_id,r.credit_mxn-coalesce((select sum(a.amount_mxn) from public.point_allocations a join public.visit_payments p on p.id=a.payment_id where a.reward_id=r.id and (p.state='completed' or (p.state='confirmed' and p.expires_at>now()))),0),r.created_at from public.reward_ledger r where r.customer_id=p_customer
$$;
create function private.affine_businesses(p_source uuid,p_target uuid) returns boolean language sql stable set search_path='' as $$
 with cats as(select b.id business_id,b.category_id from public.businesses b where b.id in (p_source,p_target) union select bc.business_id,bc.category_id from public.business_categories bc where bc.business_id in (p_source,p_target))
 select exists(select 1 from cats s join cats t on t.business_id=p_target where s.business_id=p_source and (s.category_id=t.category_id or exists(select 1 from public.category_affinities a where a.active and a.source_category_id=s.category_id and a.target_category_id=t.category_id)))
$$;
create function private.coverage_budget(p_customer uuid,p_business uuid,p_amount numeric,p_rate numeric) returns jsonb language sql stable set search_path='' as $$
 with balances as(select coalesce(sum(c.available_mxn) filter(where c.business_id=p_business),0) own,coalesce(sum(c.available_mxn) filter(where c.business_id<>p_business and private.affine_businesses(c.business_id,p_business)),0) affiliated from private.available_credits(p_customer) c where c.available_mxn>0)
 select jsonb_build_object('own_balance_mxn',own,'affiliated_balance_mxn',affiliated,'affiliated_limit_mxn',round(p_amount*.20,2),'max_points_mxn',least(round(p_amount*p_rate,2),own+least(affiliated,round(p_amount*.20,2)))) from balances
$$;
create function private.register_walk_in(p_business uuid,p_event uuid,p_service uuid default null,p_promotion uuid default null,p_click uuid default null,p_origin text default 'spontaneous') returns public.visits language plpgsql security definer set search_path='' as $$
declare b public.businesses;v public.visits;p public.promotions;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED';end if;
 if p_event is null or p_origin is null or p_origin not in ('spontaneous','app','promotion') then raise exception 'INVALID_ARRIVAL';end if;
 perform pg_advisory_xact_lock(hashtextextended('booking:'||p_business::text,0));
 perform pg_advisory_xact_lock(hashtextextended('walkin:'||auth.uid()::text,0));
 select * into v from public.visits where booking_event_id=p_event;
 if found then if v.customer_id<>auth.uid() or v.business_id<>p_business or v.kind<>'walk_in' or v.service_id is distinct from p_service or v.promotion_id is distinct from p_promotion then raise exception 'INVALID_BOOKING_EVENT';end if;return v;end if;
 select * into b from public.businesses where id=p_business and status='published' and enrollment_status='active';if not found then raise exception 'BUSINESS_UNAVAILABLE';end if;
 if p_service is not null and not exists(select 1 from public.services where id=p_service and business_id=p_business and active) then raise exception 'SERVICE_UNAVAILABLE';end if;
 if exists(select 1 from public.visits where customer_id=auth.uid() and business_id=p_business and kind='walk_in' and status='checked_in' and starts_at>now()-interval '12 hours') then raise exception 'VISIT_ALREADY_OPEN';end if;
 if (select count(*) from public.visits where customer_id=auth.uid() and kind='walk_in' and created_at>now()-interval '1 hour')>=10 then raise exception 'ARRIVAL_LIMIT';end if;
 if p_promotion is not null then
 select * into p from public.promotions where id=p_promotion and business_id=p_business and status='published' and starts_at<=now() and ends_at>now();if not found or p.service_id is distinct from p_service or not exists(select 1 from public.promotion_clicks c where c.id=p_click and c.customer_id=auth.uid() and c.promotion_id=p_promotion and c.service_id=p_service) then raise exception 'INVALID_ATTRIBUTION';end if;
 if p.placement='live' and not exists(select 1 from public.profiles where user_id=auth.uid() and live_enabled) then raise exception 'LIVE_DISABLED';end if;
 p_origin='promotion';
 elsif p_click is not null or p_origin='promotion' then raise exception 'INVALID_ATTRIBUTION';end if;
 insert into public.visits(business_id,customer_id,service_id,kind,source,status,starts_at,ends_at,booking_event_id,arrival_origin,promotion_id,promotion_click_id,booked_price_mxn,promotion_title_es,promotion_title_en)
 values(p_business,auth.uid(),p_service,'walk_in',case when p_origin='spontaneous' then 'business' else 'mi_espacio' end,'checked_in',now(),now()+interval '8 hours',p_event,p_origin,p_promotion,p_click,p.special_price_mxn,p.title_es,p.title_en) returning * into v;return v;
end $$;
create function private.customer_presence(p_visit uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.visits;t private.visit_presence;
begin
 select * into v from public.visits where id=p_visit and customer_id=auth.uid() and status in ('scheduled','checked_in');if not found or auth.uid() is null then raise exception 'ACCESS_DENIED';end if;
 if v.starts_at>now()+interval '2 hours' or v.ends_at<now()-interval '2 hours' then raise exception 'PRESENCE_OUT_OF_RANGE';end if;
 insert into private.visit_presence(visit_id,code,expires_at) values(v.id,upper(substr(replace(gen_random_uuid()::text,'-',''),1,12)),now()+interval '2 hours') on conflict(visit_id) do update set code=case when visit_presence.expires_at<=now() then excluded.code else visit_presence.code end,expires_at=case when visit_presence.expires_at<=now() then excluded.expires_at else visit_presence.expires_at end returning * into t;
 return jsonb_build_object('code',t.code,'expires_at',t.expires_at,'confirmed',v.presence_confirmed_at is not null);
end $$;
create function private.verify_presence(p_business uuid,p_code text) returns public.visits language plpgsql security definer set search_path='' as $$
declare v public.visits;
begin
 if not private.is_manager(p_business) then raise exception 'ACCESS_DENIED';end if;
 if (select count(*) from private.presence_attempts where actor_id=auth.uid() and created_at>now()-interval '1 minute')>=30 then raise exception 'PRESENCE_LIMIT';end if;
 insert into private.presence_attempts(actor_id,business_id) values(auth.uid(),p_business);
 select vi.* into v from public.visits vi join private.visit_presence t on t.visit_id=vi.id where vi.business_id=p_business and t.code=upper(regexp_replace(coalesce(p_code,''),'[^a-zA-Z0-9]','','g')) and t.expires_at>now() and vi.status in ('scheduled','checked_in') and vi.starts_at<=now() and vi.ends_at>now()-interval '2 hours' for update of vi;
 if not found then return null;end if;
 update public.visits set presence_confirmed_at=coalesce(presence_confirmed_at,now()),status='checked_in' where id=v.id returning * into v;return v;
end $$;
-- All wallet mutations lock business, then customer, then visit/payment, in that order.
create function private.lock_visit(p_visit uuid) returns public.visits language plpgsql set search_path='' as $$
declare v public.visits;
begin
 select * into v from public.visits where id=p_visit;if not found then raise exception 'VISIT_NOT_FOUND';end if;
 perform pg_advisory_xact_lock(hashtextextended('booking:'||v.business_id::text,0));
 perform pg_advisory_xact_lock(hashtextextended('wallet:'||v.customer_id::text,0));
 select * into v from public.visits where id=p_visit for update;return v;
end $$;
create function private.make_payment(p_visit uuid,p_amount numeric) returns public.visit_payments language plpgsql set search_path='' as $$
declare v public.visits;b public.businesses;p public.visit_payments;
begin
 v=private.lock_visit(p_visit);
 if v.presence_confirmed_at is null or v.status not in ('scheduled','checked_in') or v.starts_at>now() then raise exception 'PRESENCE_REQUIRED';end if;
 if p_amount is null or p_amount<0 or p_amount>1000000 or p_amount<>round(p_amount,2) then raise exception 'INVALID_AMOUNT';end if;
 if v.promotion_id is not null and p_amount<>v.booked_price_mxn then raise exception 'PROMOTION_PRICE_PROTECTED';end if;
 select * into b from public.businesses where id=v.business_id for share;if b.status<>'published' or b.enrollment_status<>'active' then raise exception 'BUSINESS_UNAVAILABLE';end if;
 update public.visit_payments set state='superseded' where visit_id=v.id and state in ('proposed','confirmed');
 insert into public.visit_payments(visit_id,business_id,customer_id,amount_mxn,coverage_rate,policy_version,protected)
 values(v.id,v.business_id,v.customer_id,p_amount,coalesce(v.coverage_rate_snapshot,b.points_coverage_rate),coalesce(v.benefit_version_snapshot,b.benefit_version),v.kind='appointment') returning * into p;return p;
end $$;
create function private.prepare_visit_payment(p_visit uuid,p_amount numeric) returns public.visit_payments language plpgsql security definer set search_path='' as $$
declare bid uuid;
begin
 select business_id into bid from public.visits where id=p_visit;if not private.is_manager(bid) then raise exception 'ACCESS_DENIED';end if;
 return private.make_payment(p_visit,p_amount);
end $$;
create function private.refresh_visit_payment(p_payment uuid) returns public.visit_payments language plpgsql security definer set search_path='' as $$
declare p public.visit_payments;
begin
 select * into p from public.visit_payments where id=p_payment;if not found or auth.uid() is null or not(p.customer_id=auth.uid() or private.is_manager(p.business_id)) then raise exception 'ACCESS_DENIED';end if;
 if p.state not in ('proposed','confirmed') then raise exception 'PAYMENT_CLOSED';end if;return private.make_payment(p.visit_id,p.amount_mxn);
end $$;
create function private.visit_checkout(p_visit uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.visits;p public.visit_payments;b public.businesses;
begin
 select * into v from public.visits where id=p_visit;if not found or auth.uid() is null or not(v.customer_id=auth.uid() or private.is_manager(v.business_id)) then raise exception 'ACCESS_DENIED';end if;
 select * into p from public.visit_payments where visit_id=v.id and state in ('proposed','confirmed','completed') order by created_at desc limit 1;
 select * into b from public.businesses where id=v.business_id;
 return jsonb_build_object('visit',to_jsonb(v),'payment',case when p.id is null then null else to_jsonb(p) end,'current_version',b.benefit_version,'current_rate',b.points_coverage_rate,'budget',case when p.id is null then null else private.coverage_budget(v.customer_id,v.business_id,p.amount_mxn,p.coverage_rate) end);
end $$;
create function private.confirm_visit_payment(p_payment uuid,p_points numeric,p_version bigint) returns public.visit_payments language plpgsql security definer set search_path='' as $$
declare p public.visit_payments;v public.visits;b public.businesses;budget jsonb;leftover numeric;take numeric;c record;affiliate_used numeric:=0;
begin
 select * into p from public.visit_payments where id=p_payment;if not found or p.customer_id is distinct from auth.uid() or auth.uid() is null then raise exception 'ACCESS_DENIED';end if;
 v=private.lock_visit(p.visit_id);select * into p from public.visit_payments where id=p_payment for update;
 if p.state in ('confirmed','completed') then if p.points_mxn is distinct from p_points or p.policy_version is distinct from p_version then raise exception 'PAYMENT_CLOSED';end if;return p;end if;
 if p.state<>'proposed' or v.status not in ('scheduled','checked_in') or p.expires_at<=now() then raise exception 'PAYMENT_EXPIRED';end if;
 select * into b from public.businesses where id=p.business_id for share;
 if p_version is distinct from p.policy_version or (not p.protected and p.policy_version<>b.benefit_version) then raise exception 'BENEFIT_CHANGED';end if;
 if p_points is null or p_points<0 or p_points<>round(p_points,2) then raise exception 'INVALID_AMOUNT';end if;
 budget=private.coverage_budget(p.customer_id,p.business_id,p.amount_mxn,p.coverage_rate);if p_points>(budget->>'max_points_mxn')::numeric then raise exception 'POINTS_UNAVAILABLE';end if;
 leftover=p_points;
 for c in select * from private.available_credits(p.customer_id) cr where cr.available_mxn>0 and (cr.business_id=p.business_id or private.affine_businesses(cr.business_id,p.business_id)) order by (cr.business_id=p.business_id) desc,cr.created_at,cr.reward_id loop
 exit when leftover<=0;take=least(leftover,c.available_mxn);
 if c.business_id<>p.business_id then take=least(take,round(p.amount_mxn*.20,2)-affiliate_used);affiliate_used=affiliate_used+take;end if;
 if take>0 then insert into public.point_allocations(payment_id,customer_id,reward_id,amount_mxn) values(p.id,p.customer_id,c.reward_id,take);leftover=leftover-take;end if;end loop;
 if leftover>0 then raise exception 'POINTS_UNAVAILABLE';end if;
 update public.visit_payments set state='confirmed',points_mxn=p_points,confirmed_at=now() where id=p.id returning * into p;return p;
end $$;
create function private.decline_visit_payment(p_payment uuid) returns void language plpgsql security definer set search_path='' as $$
declare p public.visit_payments;v public.visits;
begin
 select * into p from public.visit_payments where id=p_payment;if not found or p.customer_id is distinct from auth.uid() or auth.uid() is null then raise exception 'ACCESS_DENIED';end if;v=private.lock_visit(p.visit_id);
 update public.visit_payments set state='declined' where id=p.id and state in ('proposed','confirmed');
end $$;
create function private.settle_visit_payment(p_payment uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare p public.visit_payments;v public.visits;b public.businesses;result jsonb;
begin
 select * into p from public.visit_payments where id=p_payment;if not found or not private.is_manager(p.business_id) then raise exception 'ACCESS_DENIED';end if;
 v=private.lock_visit(p.visit_id);select * into p from public.visit_payments where id=p_payment for update;
 if p.state='completed' then return jsonb_build_object('state','completed','payment',to_jsonb(p),'already_completed',true);end if;
 if p.state<>'confirmed' then raise exception 'PAYMENT_CONFIRMATION_REQUIRED';end if;
 select * into b from public.businesses where id=p.business_id for share;
 if p.expires_at<=now() or (not p.protected and p.policy_version<>b.benefit_version) then
 p=private.make_payment(p.visit_id,p.amount_mxn);return jsonb_build_object('state','needs_confirmation','payment',to_jsonb(p));end if;
 update public.visit_payments set state='completed',completed_at=now() where id=p.id returning * into p;
 result=public.complete_visit(v.id,auth.uid(),p.amount_mxn);
 return result||jsonb_build_object('state','completed','payment',to_jsonb(p));
end $$;
-- Preserve the original fee protocol; rewards accrue only on the amount paid without points.
create or replace function public.complete_visit(p_visit uuid,p_actor uuid,p_amount_mxn numeric) returns jsonb language plpgsql set search_path='' as $$
declare v public.visits;b public.businesses;is_first boolean;fee_rate numeric;fee_kind text;redeemed numeric:=0;reward_base numeric;
begin
 if p_actor is distinct from auth.uid() or not private.is_manager((select business_id from public.visits where id=p_visit)) then raise exception 'ACCESS_DENIED';end if;
 if p_amount_mxn is null or p_amount_mxn<0 or p_amount_mxn<>round(p_amount_mxn,2) then raise exception 'INVALID_AMOUNT';end if;
 v=private.lock_visit(p_visit);
 if v.status='completed' then if v.amount_mxn<>p_amount_mxn then raise exception 'Visit already completed with a different amount';end if;return jsonb_build_object('visit_id',v.id,'status','completed','already_completed',true);end if;
 if v.status not in ('scheduled','checked_in') or v.starts_at>now() then raise exception 'Visit cannot be completed';end if;
 if exists(select 1 from public.visit_payments where visit_id=v.id and state in ('proposed','confirmed')) then raise exception 'PAYMENT_CONFIRMATION_REQUIRED';end if;
 if v.kind='walk_in' and (v.presence_confirmed_at is null or not exists(select 1 from public.visit_payments where visit_id=v.id and state='completed')) then raise exception 'PAYMENT_CONFIRMATION_REQUIRED';end if;
 select coalesce(sum(points_mxn),0) into redeemed from public.visit_payments where visit_id=v.id and state='completed';reward_base=p_amount_mxn-redeemed;
 select * into b from public.businesses where id=v.business_id for update;if b.status<>'published' or b.enrollment_status<>'active' then raise exception 'BUSINESS_UNAVAILABLE';end if;
 insert into public.customer_relationships(business_id,customer_id,first_visit_id) values(v.business_id,v.customer_id,v.id) on conflict do nothing;is_first=found;
 if is_first then fee_kind='acquisition';fee_rate=.10;elsif v.source='mi_espacio' then fee_kind='usage';fee_rate=.05;end if;
 if fee_rate is not null then insert into public.fee_ledger(business_id,visit_id,customer_id,kind,base_mxn,rate,amount_mxn) values(v.business_id,v.id,v.customer_id,fee_kind,p_amount_mxn,fee_rate,round(p_amount_mxn*fee_rate,2));end if;
 insert into public.reward_ledger(business_id,visit_id,customer_id,base_mxn,rate,credit_mxn) values(v.business_id,v.id,v.customer_id,reward_base,b.reward_rate,round(reward_base*b.reward_rate,2));
 update public.visits set status='completed',amount_mxn=p_amount_mxn,completed_at=now() where id=v.id;
 return jsonb_build_object('visit_id',v.id,'status','completed','first_visit',is_first,'fee_mxn',coalesce(round(p_amount_mxn*fee_rate,2),0),'points_redeemed_mxn',redeemed,'reward_credit_mxn',round(reward_base*b.reward_rate,2));
end $$;
create function private.wallet_summary() returns jsonb language plpgsql security definer set search_path='' as $$
begin if auth.uid() is null then raise exception 'AUTH_REQUIRED';end if;
 return jsonb_build_object('available_mxn',(select coalesce(sum(available_mxn),0) from private.available_credits(auth.uid())),'earned_mxn',(select coalesce(sum(credit_mxn),0) from public.reward_ledger where customer_id=auth.uid()),'spent_mxn',(select coalesce(sum(points_mxn),0) from public.visit_payments where customer_id=auth.uid() and state='completed'),'held_mxn',(select coalesce(sum(points_mxn),0) from public.visit_payments where customer_id=auth.uid() and state='confirmed' and expires_at>now()));end $$;
create function private.live_benefits() returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where user_id=auth.uid() and live_enabled) then return '[]'::jsonb;end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',h.id,'business_id',h.business_id,'kind','benefit','coverage_rate',h.new_rate,'title_es','Ahora puedes cubrir hasta el '||round(h.new_rate*100)::text||'% con puntos','title_en','Now cover up to '||round(h.new_rate*100)::text||'% with points','description_es','Con saldo aplicable. Puntos de comercios afines: máximo 20%.','description_en','With eligible balance. Points from affiliated businesses: up to 20%.','status','published','starts_at',h.created_at,'ends_at',h.created_at+interval '7 days','version',h.version)) from public.business_benefit_history h join public.businesses b on b.id=h.business_id where h.new_rate>h.old_rate and h.new_rate=b.points_coverage_rate and b.status='published' and b.enrollment_status='active' and h.created_at>now()-interval '7 days' and h.id=(select h2.id from public.business_benefit_history h2 where h2.business_id=h.business_id and h2.new_rate>h2.old_rate order by h2.created_at desc,h2.version desc limit 1) and not exists(select 1 from public.business_benefit_history prior where prior.business_id=h.business_id and prior.new_rate>prior.old_rate and prior.created_at<h.created_at and prior.created_at>h.created_at-interval '24 hours')),'[]'::jsonb);
end $$;
create function private.reward_opportunities() returns jsonb language plpgsql security definer set search_path='' as $$
begin if auth.uid() is null then raise exception 'AUTH_REQUIRED';end if;
 return coalesce((select jsonb_agg(to_jsonb(x)) from(select distinct on(b.id) 'reward:'||b.id::text||':'||b.benefit_version::text as key,'reward_eligible'::text kind,b.id business_id,s.id service_id,b.points_coverage_rate coverage_rate,'Ya puedes cubrir hasta el '||round(b.points_coverage_rate*100)::text||'% con tus puntos' title_es,'You can now cover up to '||round(b.points_coverage_rate*100)::text||'% with your points' title_en,s.name_es body_es,s.name_en body_en,now() created_at,now()+interval '1 day' expires_at from public.favorites f join public.businesses b on b.id=f.business_id join public.services s on s.business_id=b.id and s.active where f.customer_id=auth.uid() and b.status='published' and b.enrollment_status='active' and s.price_mxn>0 and coalesce((private.coverage_budget(auth.uid(),b.id,s.price_mxn,b.points_coverage_rate)->>'own_balance_mxn')::numeric,0)>=round(s.price_mxn*b.points_coverage_rate,2) order by b.id,s.price_mxn,s.id limit 20)x),'[]'::jsonb);end $$;
-- Helpers have no client EXECUTE privilege; exposed wrappers are invokers.
revoke all on function private.available_credits(uuid),private.affine_businesses(uuid,uuid),private.coverage_budget(uuid,uuid,numeric,numeric),private.lock_visit(uuid),private.make_payment(uuid,numeric) from public,anon,authenticated;
create function public.save_business_benefits(p_business uuid,p_requires boolean,p_rate numeric) returns public.businesses language sql security invoker set search_path='' as $$select private.save_business_benefits(p_business,p_requires,p_rate)$$;
create function public.register_walk_in(p_business uuid,p_event uuid,p_service uuid default null,p_promotion uuid default null,p_click uuid default null,p_origin text default 'spontaneous') returns public.visits language sql security invoker set search_path='' as $$select private.register_walk_in(p_business,p_event,p_service,p_promotion,p_click,p_origin)$$;
create function public.customer_presence(p_visit uuid) returns jsonb language sql security invoker set search_path='' as $$select private.customer_presence(p_visit)$$;
create function public.verify_presence(p_business uuid,p_code text) returns public.visits language sql security invoker set search_path='' as $$select private.verify_presence(p_business,p_code)$$;
create function public.prepare_visit_payment(p_visit uuid,p_amount numeric) returns public.visit_payments language sql security invoker set search_path='' as $$select private.prepare_visit_payment(p_visit,p_amount)$$;
create function public.refresh_visit_payment(p_payment uuid) returns public.visit_payments language sql security invoker set search_path='' as $$select private.refresh_visit_payment(p_payment)$$;
create function public.visit_checkout(p_visit uuid) returns jsonb language sql security invoker set search_path='' as $$select private.visit_checkout(p_visit)$$;
create function public.confirm_visit_payment(p_payment uuid,p_points numeric,p_version bigint) returns public.visit_payments language sql security invoker set search_path='' as $$select private.confirm_visit_payment(p_payment,p_points,p_version)$$;
create function public.decline_visit_payment(p_payment uuid) returns void language sql security invoker set search_path='' as $$select private.decline_visit_payment(p_payment)$$;
create function public.settle_visit_payment(p_payment uuid) returns jsonb language sql security invoker set search_path='' as $$select private.settle_visit_payment(p_payment)$$;
create function public.wallet_summary() returns jsonb language sql security invoker set search_path='' as $$select private.wallet_summary()$$;
create function public.live_benefits() returns jsonb language sql security invoker set search_path='' as $$select private.live_benefits()$$;
create function public.reward_opportunities() returns jsonb language sql security invoker set search_path='' as $$select private.reward_opportunities()$$;
do $$declare f record;begin for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','private') and p.proname in ('save_business_benefits','register_walk_in','customer_presence','verify_presence','prepare_visit_payment','refresh_visit_payment','visit_checkout','confirm_visit_payment','decline_visit_payment','settle_visit_payment','wallet_summary','live_benefits','reward_opportunities') loop execute format('revoke all on function %s from public,anon',f.signature);execute format('grant execute on function %s to authenticated',f.signature);end loop;end $$;
-- Replace fixed 50% eligibility checks with the four supported coverage tiers.
do $$declare c record;begin for c in select conname from pg_constraint where conrelid='public.customer_notifications'::regclass and pg_get_constraintdef(oid) like '%coverage_rate = 0.5%' loop execute format('alter table public.customer_notifications drop constraint %I',c.conname);end loop;end $$;
alter table public.customer_notifications add constraint tiered_reward_eligibility check(kind<>'reward_eligible' or coalesce(service_id is not null and benefit_basis='loyalty' and coverage_rate in (.20,.30,.40,.50) and applicable_balance_mxn>=required_mxn and required_mxn>0,false));
do $$begin if exists(select 1 from pg_publication where pubname='supabase_realtime') then
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='businesses') then alter publication supabase_realtime add table public.businesses;end if;
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='visit_payments') then alter publication supabase_realtime add table public.visit_payments;end if;
end if;end $$;
