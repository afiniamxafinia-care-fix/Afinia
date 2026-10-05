-- Platform-admin business lifecycle controls.
-- Published is the only customer-facing catalog state. Other values are soft states.
alter table public.businesses drop constraint if exists business_status_check;
alter table public.businesses add constraint business_status_check check(status in ('draft','published','hidden','suspended','archived','deleted'));

create or replace function private.publish_approved_business() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.listing_review_status='approved' then
  new.directory_listed:=true;
  new.status:='published';
 end if;
 return new;
end $$;

create or replace function private.publish_approved_intake() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.status='approved' and new.business_id is not null then
  update public.businesses
  set listing_review_status='approved',directory_listed=true,status='published'
  where id=new.business_id;
 end if;
 return new;
end $$;

create or replace function private.admin_business_status(p_business uuid,p_status text)
returns public.businesses language plpgsql security definer set search_path='' as $$
declare b public.businesses;
begin
 if not private.is_platform_admin() then raise exception 'ADMIN_REQUIRED'; end if;
 if p_status not in ('draft','published','hidden','suspended','archived','deleted') then raise exception 'INVALID_BUSINESS_STATUS'; end if;
 update public.businesses set status=p_status where id=p_business returning * into b;
 if not found then raise exception 'BUSINESS_NOT_FOUND'; end if;
 return b;
end $$;

revoke all on function private.admin_business_status(uuid,text) from public,anon,authenticated;
grant execute on function private.admin_business_status(uuid,text) to authenticated;
create or replace function public.admin_business_status(p_business uuid,p_status text)
returns public.businesses language sql security invoker set search_path='' as $$
 select private.admin_business_status(p_business,p_status)
$$;
revoke all on function public.admin_business_status(uuid,text) from public,anon;
grant execute on function public.admin_business_status(uuid,text) to authenticated;

update public.businesses
set status='published'
where listing_review_status='approved' and status='draft';
