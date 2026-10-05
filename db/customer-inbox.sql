create table public.customer_notifications (
 id uuid primary key default gen_random_uuid(),
 customer_id uuid not null references auth.users(id) on delete cascade,
 business_id uuid not null references public.businesses(id) on delete cascade,
 service_id uuid references public.services(id) on delete cascade,
 kind text not null check(kind in ('promotion','reward_eligible')),
 title_es text not null, title_en text not null,
 body_es text not null, body_en text not null,
 coverage_rate numeric,
 benefit_basis text check(benefit_basis in ('loyalty','acquisition')),
 applicable_balance_mxn numeric,
 required_mxn numeric,
 created_at timestamptz not null default now(),
 expires_at timestamptz not null,
 check(expires_at>created_at),
 check(kind<>'reward_eligible' or (service_id is not null and benefit_basis='loyalty' and coverage_rate=0.5 and applicable_balance_mxn>=required_mxn and required_mxn>0)),
 check(benefit_basis<>'acquisition' or coverage_rate<=0.2)
);
create index customer_notifications_inbox_idx on public.customer_notifications(customer_id,created_at desc);
alter table public.customer_notifications enable row level security;
create policy customer_notifications_read on public.customer_notifications for select to authenticated using (
 customer_id=(select auth.uid()) and expires_at>now() and
 exists(select 1 from public.favorites f where f.customer_id=(select auth.uid()) and f.business_id=customer_notifications.business_id) and
 exists(select 1 from public.businesses b where b.id=customer_notifications.business_id and b.status='published')
);
grant select on public.customer_notifications to authenticated;
revoke all on public.customer_notifications from anon;
create table public.notification_receipts (
 customer_id uuid not null references auth.users(id) on delete cascade,
 notification_key text not null check(length(notification_key) between 1 and 150),
 read_at timestamptz not null default now(),
 primary key(customer_id,notification_key)
);
alter table public.notification_receipts enable row level security;
create policy notification_receipts_read on public.notification_receipts for select to authenticated using(customer_id=(select auth.uid()));
create policy notification_receipts_insert on public.notification_receipts for insert to authenticated with check(customer_id=(select auth.uid()));
grant select,insert on public.notification_receipts to authenticated;
revoke all on public.notification_receipts from anon;
alter table public.customer_notifications add constraint verified_reward_fields check(kind<>'reward_eligible' or coalesce(service_id is not null and benefit_basis='loyalty' and coverage_rate=0.5 and applicable_balance_mxn>=required_mxn and required_mxn>0,false));
revoke all on public.customer_notifications from authenticated;
grant select on public.customer_notifications to authenticated;
revoke all on public.notification_receipts from authenticated;
grant select,insert on public.notification_receipts to authenticated;

