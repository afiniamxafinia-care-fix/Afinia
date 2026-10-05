-- Afinia: public message receipts and five interests.
alter table public.business_intake_requests add column message_version bigint not null default 0;
alter table public.business_intake_requests add column message_read_version bigint not null default 0;
update public.business_intake_requests set message_version=1 where public_message_es<>'' or public_message_en<>'';
create function private.intake_message_version() returns trigger language plpgsql set search_path='' as $$
begin
 if new.public_message_es is distinct from old.public_message_es or new.public_message_en is distinct from old.public_message_en then
 new.message_version:=old.message_version+1;
 end if;
 return new;
end $$;
create trigger intake_message_version before update on public.business_intake_requests for each row execute function private.intake_message_version();
create function private.read_intake_message(p_request uuid,p_version bigint) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
 update public.business_intake_requests set message_read_version=greatest(message_read_version,least(message_version,p_version)) where id=p_request and user_id=auth.uid();
 if not found then raise exception 'NOT_FOUND'; end if;
end $$;
create function public.read_intake_message(p_request uuid,p_version bigint) returns void language sql security invoker set search_path='' as $$select private.read_intake_message(p_request,p_version)$$;
revoke all on function private.intake_message_version(),private.read_intake_message(uuid,bigint),public.read_intake_message(uuid,bigint) from public,anon;
grant execute on function private.read_intake_message(uuid,bigint),public.read_intake_message(uuid,bigint) to authenticated;
alter table public.user_interests drop constraint user_interests_slot_check;
alter table public.user_interests add constraint user_interests_slot_check check(slot>=1 and slot<=5);
create or replace function public.set_interests(p_categories uuid[]) returns void language plpgsql set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if coalesce(cardinality(p_categories),0) not between 1 and 5 or (select count(distinct x) from unnest(p_categories) x)<>cardinality(p_categories) then raise exception 'Select one to five distinct categories'; end if;
 if (select count(*) from public.categories where id=any(p_categories) and active)<>cardinality(p_categories) then raise exception 'Invalid category'; end if;
 perform pg_advisory_xact_lock(hashtextextended('interests:'||auth.uid()::text,0));
 delete from public.user_interests where user_id=auth.uid();
 insert into public.user_interests(user_id,category_id,slot) select auth.uid(),x,ordinality from unnest(p_categories) with ordinality as v(x,ordinality);
end $$;
