-- Researched, inactive listings can receive genuine interest before launch.
alter table public.businesses add column directory_listed boolean not null default false;
update public.businesses set directory_listed=true where researched_at is not null;
create policy directory_anon_read on public.businesses for select to anon using(status='draft' and directory_listed);
create policy directory_auth_read on public.businesses for select to authenticated using((status='draft' and directory_listed) or (select private.is_platform_admin()));
create function private.can_favorite_business(p_business uuid) returns boolean language sql stable security definer set search_path='' as $$ select auth.uid() is not null and exists(select 1 from public.businesses where id=p_business and (status='published' or (status='draft' and directory_listed))) $$;
revoke all on function private.can_favorite_business(uuid) from public,anon;grant execute on function private.can_favorite_business(uuid) to authenticated;
drop policy favorites_own_insert on public.favorites;
create policy favorites_own_insert on public.favorites for insert to authenticated with check(customer_id=(select auth.uid()) and private.can_favorite_business(business_id));
create index if not exists favorite_business_interest_idx on public.favorites(business_id);
create function private.business_favorite_count(p_business uuid) returns bigint language plpgsql stable security definer set search_path='' as $$
begin
 if not (private.is_platform_admin() or private.is_manager(p_business)) then raise exception 'ACCESS_DENIED'; end if;
 return (select count(*) from public.favorites where business_id=p_business);
end $$;
create function public.business_favorite_count(p_business uuid) returns bigint language sql security invoker set search_path='' as $$select private.business_favorite_count(p_business)$$;
revoke all on function private.business_favorite_count(uuid),public.business_favorite_count(uuid) from public,anon;
grant execute on function private.business_favorite_count(uuid),public.business_favorite_count(uuid) to authenticated;
