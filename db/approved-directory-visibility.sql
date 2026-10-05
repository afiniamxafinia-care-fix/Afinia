create or replace function private.publish_approved_business() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.listing_review_status='approved' then new.directory_listed:=true; end if;
 return new;
end $$;
drop trigger if exists publish_approved_business on public.businesses;
create trigger publish_approved_business before insert or update of listing_review_status on public.businesses for each row execute function private.publish_approved_business();
create or replace function private.publish_approved_intake() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status='approved' and new.business_id is not null then
  update public.businesses set listing_review_status='approved',directory_listed=true where id=new.business_id;
 end if;
 return new;
end $$;
drop trigger if exists publish_approved_intake on public.business_intake_requests;
create trigger publish_approved_intake after update of status,business_id on public.business_intake_requests for each row when (new.status='approved') execute function private.publish_approved_intake();
update public.businesses set directory_listed=true where listing_review_status='approved';
