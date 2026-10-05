create or replace function private.refresh_visit_payment(p_payment uuid) returns public.visit_payments language plpgsql security definer set search_path='' as $$
declare p public.visit_payments;
begin
 select * into p from public.visit_payments where id=p_payment;
 if not found or auth.uid() is null or not(p.customer_id=auth.uid() or private.is_manager(p.business_id)) then raise exception 'ACCESS_DENIED';end if;
 perform private.lock_visit(p.visit_id);
 select * into p from public.visit_payments where id=p_payment for update;
 if p.state not in ('proposed','confirmed') then raise exception 'PAYMENT_CLOSED';end if;
 return private.make_payment(p.visit_id,p.amount_mxn);
end $$;
create table public.benefit_clicks(
 id uuid primary key default gen_random_uuid(),benefit_id uuid not null references public.business_benefit_history(id),
 business_id uuid not null references public.businesses(id),customer_id uuid not null references auth.users(id),
 event_id uuid not null,source text not null check(source in('capsule','home_card','service_cta')),
 created_at timestamptz not null default now(),unique(customer_id,event_id));
create index benefit_clicks_business_idx on public.benefit_clicks(business_id,benefit_id,created_at);
alter table public.benefit_clicks enable row level security;
revoke all on public.benefit_clicks from anon,authenticated;
grant select on public.benefit_clicks to authenticated;
create policy benefit_clicks_read on public.benefit_clicks for select to authenticated using(customer_id=(select auth.uid()) or private.is_manager(business_id) or private.is_platform_admin());
create function private.record_benefit_click(p_benefit uuid,p_event uuid,p_source text) returns uuid language plpgsql security definer set search_path='' as $$
declare h public.business_benefit_history;eid uuid;
begin
 if auth.uid() is null or p_event is null or p_source not in('capsule','home_card','service_cta') then raise exception 'ACCESS_DENIED';end if;
 if not exists(select 1 from public.profiles where user_id=auth.uid() and live_enabled) then raise exception 'LIVE_DISABLED';end if;
 select * into h from public.business_benefit_history where id=p_benefit;
 if not found or not exists(select 1 from jsonb_array_elements(private.live_benefits()) x where x->>'id'=h.id::text) then raise exception 'BENEFIT_UNAVAILABLE';end if;
 select id into eid from public.benefit_clicks where customer_id=auth.uid() and event_id=p_event and benefit_id=p_benefit;
 if found then return eid;end if;
 insert into public.benefit_clicks(benefit_id,business_id,customer_id,event_id,source) values(h.id,h.business_id,auth.uid(),p_event,p_source) returning id into eid;return eid;
end $$;
create function public.record_benefit_click(p_benefit uuid,p_event uuid,p_source text) returns uuid language sql security invoker set search_path='' as $$select private.record_benefit_click(p_benefit,p_event,p_source)$$;
revoke all on function public.record_benefit_click(uuid,uuid,text),private.record_benefit_click(uuid,uuid,text) from public,anon;
grant execute on function public.record_benefit_click(uuid,uuid,text),private.record_benefit_click(uuid,uuid,text) to authenticated;
