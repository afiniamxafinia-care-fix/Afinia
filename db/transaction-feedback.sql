-- Verified transaction ratings. Comment moderation never changes score aggregates.
create table public.feedback_badges(category_slug text not null,badge_key text not null,name_es text not null,name_en text not null,sort_order integer not null,primary key(category_slug,badge_key));
insert into public.feedback_badges values
('belleza','attention','Atención','Service',1),('belleza','detail','Cuidado al detalle','Attention to detail',2),('belleza','hygiene','Higiene','Hygiene',3),('belleza','atmosphere','Ambiente','Atmosphere',4),('belleza','value','Relación calidad-precio','Value',5),
('restaurantes','flavor','Sabor','Flavor',1),('restaurantes','quality','Calidad','Quality',2),('restaurantes','attention','Atención','Service',3),('restaurantes','value','Relación calidad-precio','Value',4),('restaurantes','atmosphere','Ambiente','Atmosphere',5),
('spa-relajacion','relaxation','Relajación','Relaxation',1),('spa-relajacion','attention','Atención','Service',2),('spa-relajacion','hygiene','Higiene','Hygiene',3),('spa-relajacion','atmosphere','Ambiente','Atmosphere',4),('spa-relajacion','comfort','Comodidad','Comfort',5),
('fitness','guidance','Acompañamiento','Guidance',1),('fitness','equipment','Equipamiento','Equipment',2),('fitness','motivation','Motivación','Motivation',3),('fitness','hygiene','Higiene','Hygiene',4),('fitness','atmosphere','Ambiente','Atmosphere',5),
('salud','attention','Trato humano','Personal care',1),('salud','clarity','Explicaciones claras','Clear explanations',2),('salud','punctuality','Puntualidad','Punctuality',3),('salud','hygiene','Higiene','Hygiene',4),('salud','comfort','Comodidad','Comfort',5),
('actividades-experiencias','experience','Experiencia','Experience',1),('actividades-experiencias','organization','Organización','Organization',2),('actividades-experiencias','attention','Atención','Service',3),('actividades-experiencias','atmosphere','Ambiente','Atmosphere',4),('actividades-experiencias','value','Relación calidad-precio','Value',5),
('compras','quality','Calidad','Quality',1),('compras','variety','Variedad','Variety',2),('compras','attention','Atención','Service',3),('compras','value','Relación calidad-precio','Value',4),('compras','comfort','Comodidad','Comfort',5),
('servicios-profesionales','attention','Atención','Service',1),('servicios-profesionales','clarity','Claridad','Clarity',2),('servicios-profesionales','punctuality','Puntualidad','Punctuality',3),('servicios-profesionales','detail','Cuidado al detalle','Attention to detail',4),('servicios-profesionales','value','Relación calidad-precio','Value',5);
alter table public.feedback_badges enable row level security;
create policy badges_read on public.feedback_badges for select to anon,authenticated using(true);
grant select on public.feedback_badges to anon,authenticated;
create function private.feedback_category(p_business uuid) returns text language sql stable security definer set search_path='' as $$
 select coalesce((select coalesce(parent.slug,c.slug) from public.business_categories bc join public.categories c on c.id=bc.category_id left join public.categories parent on parent.id=c.parent_id where bc.business_id=p_business order by c.sort_order,c.slug limit 1),'servicios-profesionales')
$$;
create table public.transaction_feedback(
 id uuid primary key default gen_random_uuid(),visit_id uuid not null unique references public.visits(id),
 business_id uuid not null references public.businesses(id),customer_id uuid not null references auth.users(id),
 rating_kind text not null check(rating_kind in('stars','diamonds')),score smallint not null check(score between 1 and 5),
 badge_key text,badge_es text,badge_en text,comment text not null default '' check(length(comment)<=2000),
 comment_status text not null check(comment_status in('none','pending','approved','archived')),
 created_at timestamptz not null default now(),moderated_at timestamptz,moderated_by uuid references auth.users(id));
create index feedback_business_status on public.transaction_feedback(business_id,comment_status,created_at desc);
create index feedback_customer on public.transaction_feedback(customer_id);
alter table public.transaction_feedback enable row level security;
create policy feedback_participants on public.transaction_feedback for select to authenticated using(customer_id=(select auth.uid()) or private.is_manager(business_id) or private.is_platform_admin());
grant select on public.transaction_feedback to authenticated;
create table public.feedback_moderation_history(id bigint generated always as identity primary key,feedback_id uuid not null references public.transaction_feedback(id),actor_id uuid not null references auth.users(id),status text not null,created_at timestamptz not null default now());
alter table public.feedback_moderation_history enable row level security;
create policy feedback_audit_admin on public.feedback_moderation_history for select to authenticated using(private.is_platform_admin());
grant select on public.feedback_moderation_history to authenticated;
create function private.submit_feedback(p_visit uuid,p_kind text,p_score integer,p_badge text,p_comment text) returns uuid language plpgsql security definer set search_path='' as $$
declare v public.visits; b public.feedback_badges;result uuid;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED';end if;
 select * into v from public.visits where id=p_visit and customer_id=auth.uid() for update;
 if not found then raise exception 'ACCESS_DENIED';end if;
 if v.status<>'completed' or not exists(select 1 from public.visit_payments p where p.visit_id=v.id and p.customer_id=auth.uid() and p.state='completed') then raise exception 'COMPLETED_PAYMENT_REQUIRED';end if;
 if exists(select 1 from public.transaction_feedback where visit_id=v.id) then raise exception 'ALREADY_RATED';end if;
 if p_kind is null or p_kind not in('stars','diamonds') or p_score is null or p_score not between 1 and 5 then raise exception 'INVALID_SCORE';end if;
 if length(coalesce(p_comment,''))>2000 then raise exception 'TEXT_TOO_LONG';end if;
 if nullif(p_badge,'') is not null then
 select * into b from public.feedback_badges where category_slug=private.feedback_category(v.business_id) and badge_key=p_badge;
 if not found then raise exception 'INVALID_BADGE';end if;
 end if;
 insert into public.transaction_feedback(visit_id,business_id,customer_id,rating_kind,score,badge_key,badge_es,badge_en,comment,comment_status)
 values(v.id,v.business_id,v.customer_id,p_kind,p_score,b.badge_key,b.name_es,b.name_en,trim(coalesce(p_comment,'')),case when trim(coalesce(p_comment,''))='' then 'none' else 'pending' end) returning id into result;
 return result;
end $$;
create function private.moderate_feedback(p_feedback uuid,p_status text) returns void language plpgsql security definer set search_path='' as $$
declare r public.transaction_feedback;
begin
 select * into r from public.transaction_feedback where id=p_feedback for update;
 if r.id is null or not(private.is_manager(r.business_id) or private.is_platform_admin()) then raise exception 'ACCESS_DENIED';end if;
 if p_status is null or p_status not in('approved','archived') or r.comment='' then raise exception 'INVALID_TRANSITION';end if;
 update public.transaction_feedback set comment_status=p_status,moderated_at=now(),moderated_by=auth.uid() where id=r.id;
 insert into public.feedback_moderation_history(feedback_id,actor_id,status) values(r.id,auth.uid(),p_status);
end $$;
create function private.feedback_summary() returns table(business_id uuid,stars numeric,diamonds numeric) language sql stable security definer set search_path='' as $$
 select f.business_id,round(avg(f.score) filter(where f.rating_kind='stars'),1),round(avg(f.score) filter(where f.rating_kind='diamonds'),1)
 from public.transaction_feedback f join public.businesses b on b.id=f.business_id where b.status='published' group by f.business_id
$$;
create function private.public_feedback(p_business uuid) returns table(id uuid,rating_kind text,score smallint,badge_es text,badge_en text,comment text,created_at timestamptz) language sql stable security definer set search_path='' as $$
 select f.id,f.rating_kind,f.score,f.badge_es,f.badge_en,f.comment,f.created_at from public.transaction_feedback f join public.businesses b on b.id=f.business_id where f.business_id=p_business and b.status='published' and f.comment_status='approved' order by f.created_at desc limit 100
$$;
create function public.submit_feedback(p_visit uuid,p_kind text,p_score integer,p_badge text,p_comment text) returns uuid language sql security invoker set search_path='' as $$select private.submit_feedback(p_visit,p_kind,p_score,p_badge,p_comment)$$;
create function public.moderate_feedback(p_feedback uuid,p_status text) returns void language sql security invoker set search_path='' as $$select private.moderate_feedback(p_feedback,p_status)$$;
create function public.feedback_summary() returns table(business_id uuid,stars numeric,diamonds numeric) language sql security invoker set search_path='' as $$select * from private.feedback_summary()$$;
create function public.public_feedback(p_business uuid) returns table(id uuid,rating_kind text,score smallint,badge_es text,badge_en text,comment text,created_at timestamptz) language sql security invoker set search_path='' as $$select * from private.public_feedback(p_business)$$;
create function public.feedback_category(p_business uuid) returns text language sql security invoker set search_path='' as $$select private.feedback_category(p_business)$$;
revoke all on function private.feedback_category(uuid),public.feedback_category(uuid),private.submit_feedback(uuid,text,integer,text,text),public.submit_feedback(uuid,text,integer,text,text),private.moderate_feedback(uuid,text),public.moderate_feedback(uuid,text),private.feedback_summary(),public.feedback_summary(),private.public_feedback(uuid),public.public_feedback(uuid) from public,anon;
grant execute on function private.submit_feedback(uuid,text,integer,text,text),public.submit_feedback(uuid,text,integer,text,text),private.moderate_feedback(uuid,text),public.moderate_feedback(uuid,text),private.feedback_category(uuid),public.feedback_category(uuid) to authenticated;
grant execute on function private.feedback_summary(),public.feedback_summary(),private.public_feedback(uuid),public.public_feedback(uuid) to anon,authenticated;
