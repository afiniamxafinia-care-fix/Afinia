'use client';
import {useEffect,useMemo,useRef,useState} from 'react';
import Image from 'next/image';
import Icon from './icons';
import {supabase} from '../lib/supabase';
import {localized,safeUrl,parentCategory,categoryIcons} from './discovery-model';
const valid=p=>p.status==='published'&&new Date(p.starts_at)<=Date.now()&&new Date(p.ends_at)>Date.now();
export function useLive({userId,enabled,ready,catalog,home,blocked}){
 const [rows,setRows]=useState([]),[loading,setLoading]=useState(false),[error,setError]=useState(false),[index,setIndex]=useState(0),[capsule,setCapsule]=useState(null),[visible,setVisible]=useState(true);
 const seen=useRef(new Set()),request=useRef(0);
 const offers=useMemo(()=>rows.filter(valid).map(p=>({...p,business:catalog.businesses.find(b=>b.id===p.business_id)})).filter(p=>p.business?.status==='published'),[rows,catalog]);
 async function refresh(){const token=++request.current;if(!userId||!enabled||!ready)return;setLoading(true);try{const result=await supabase.from('promotions').select('*').eq('placement','live').eq('status','published');if(token!==request.current)return;if(result.error)throw result.error;setRows(result.data||[]);setError(false);}catch{if(token===request.current){setRows([]);setError(true);}}finally{if(token===request.current)setLoading(false);}}
 useEffect(()=>{seen.current=new Set();setCapsule(null);},[userId]);
 useEffect(()=>{if(!userId||!enabled||!ready){++request.current;setRows([]);setLoading(false);setError(false);setCapsule(null);return;}refresh();const onVisibility=()=>{setVisible(document.visibilityState==='visible');if(document.visibilityState==='visible')refresh();};const timer=setInterval(()=>{if(document.visibilityState==='visible')refresh();},30000);document.addEventListener('visibilitychange',onVisibility);return()=>{++request.current;clearInterval(timer);document.removeEventListener('visibilitychange',onVisibility);};},[userId,enabled,ready]);
 useEffect(()=>{const ends=rows.filter(valid).map(p=>new Date(p.ends_at).getTime());if(!ends.length)return;const timer=setTimeout(()=>setRows(prev=>prev.filter(valid)),Math.min(2147483647,Math.max(0,Math.min(...ends)-Date.now()+20)));return()=>clearTimeout(timer);},[rows]);
 const ids=offers.map(p=>p.id).join('|');
 useEffect(()=>{if(!home||!enabled||!visible||blocked||!offers.length)return;const pick=()=>setIndex(prev=>offers.length<2?0:(prev+1+Math.floor(Math.random()*(offers.length-1)))%offers.length);pick();const timer=setInterval(pick,6000);return()=>clearInterval(timer);},[home,enabled,visible,blocked,ids]);
 useEffect(()=>{if(!enabled||blocked||!visible||!home){setCapsule(null);return;}const offer=offers.find(p=>!seen.current.has(p.id));if(!offer)return;const timer=setTimeout(()=>{if(!valid(offer))return;seen.current.add(offer.id);setCapsule(offer);},1500);return()=>clearTimeout(timer);},[enabled,blocked,visible,home,ids]);
 useEffect(()=>{if(!capsule)return;const timer=setTimeout(()=>setCapsule(null),4000);return()=>clearTimeout(timer);},[capsule]);
 return {offers,loading,error,refresh,offer:offers[index%offers.length]||null,capsule:enabled&&capsule&&valid(capsule)&&!blocked?capsule:null,dismiss:()=>setCapsule(null)};
}
function LivePhoto({offer,catalog,lang}){
 const images=catalog.gallery.filter(g=>g.business_id===offer.business_id),src=safeUrl(offer.image_url||offer.business.cover_image_url||images.find(g=>g.is_cover)?.image_url||images[0]?.image_url),[failed,setFailed]=useState(false);
 useEffect(()=>setFailed(false),[src]);const category=parentCategory(offer.business,catalog);
 return src&&!failed?<Image src={src} alt={localized(offer,'title',lang)+' · '+offer.business.name} fill sizes="(max-width:600px) 90vw, 600px" unoptimized onError={()=>setFailed(true)}/>:<div className="u-live-art"><Icon name={categoryIcons[category?.slug]||'leaf'} size={38}/></div>;
}
export function LiveBanner({live,enabled,t,lang,catalog,onOpen,onEnable}){
 if(enabled&&live.offer)return <section className="u-live-photo-banner" data-offer={live.offer.id}><LivePhoto offer={live.offer} catalog={catalog} lang={lang}/><div className="u-live-photo-copy"><span><i className="u-live-pulse"/> MI ESPACIO LIVE</span><h3>{t.liveInvite}</h3><p>{live.offer.business.name} · {localized(live.offer,'title',lang)}</p><button onClick={onOpen}>{t.availableLive}<Icon name="arrow" size={16}/></button></div></section>;
 return <section className={'u-live-banner'+(enabled?' enabled':'')}><Icon name="live" size={30}/><div><span>MI ESPACIO LIVE</span><h3>{enabled?t.liveActiveTitle:t.liveTitle}</h3><p>{enabled?(live.loading?t.liveLoading:live.error?t.liveRetry:t.liveActiveSub):t.liveDescription}</p><button onClick={enabled?onOpen:onEnable}>{enabled?t.availableLive:t.activate}<Icon name="arrow" size={16}/></button></div></section>;
}
export function LiveOffers({live,t,lang,catalog,onPlace}){
 if(live.loading&&!live.offers.length)return <p className="u-live-empty" role="status">{t.liveLoading}</p>;
 if(live.error)return <div className="u-live-empty"><p>{t.liveRetry}</p><button className="u-primary" onClick={live.refresh}>{t.retry}</button></div>;
 return live.offers.map(p=><article className="u-live-offer" key={p.id}><div className="u-live-offer-photo"><LivePhoto offer={p} catalog={catalog} lang={lang}/></div><span>LIVE · {p.business.name}</span><h3>{localized(p,'title',lang)}</h3><p>{localized(p,'description',lang)}</p><small>{new Date(p.ends_at).toLocaleString(lang==='es'?'es-MX':'en-US',{timeZone:'America/Mazatlan'})}</small><button className="u-text" onClick={()=>onPlace(p.business)}>{t.viewPlace}<Icon name="arrow" size={16}/></button></article>);
}
export function LiveCapsule({live,t,lang,catalog,onOpen}){
 const p=live.capsule;if(!p)return null;const category=catalog.categories.find(c=>c.id===p.category_id)||parentCategory(p.business,catalog),parent=catalog.categories.find(c=>c.id===category?.parent_id)||category;
 return <aside className="u-live-capsule" aria-label={t.availableLive}><button className="u-live-capsule-open" onClick={()=>{live.dismiss();onOpen();}}><span className="u-live-thumb"><LivePhoto offer={p} catalog={catalog} lang={lang}/></span><span className="u-live-category" title={localized(category,'name',lang)}><Icon name={categoryIcons[parent?.slug]||'leaf'} size={19}/></span><span className="u-live-capsule-text" role="status"><strong>{p.business.name}</strong><span>{localized(p,'title',lang)}{localized(p,'description',lang)?' · '+localized(p,'description',lang):''}</span></span><span className="u-live-badge"><Icon name="live" size={22}/><small>LIVE</small></span></button><button className="u-live-dismiss" onClick={live.dismiss} aria-label={t.close}><Icon name="close" size={12}/></button></aside>;
}
