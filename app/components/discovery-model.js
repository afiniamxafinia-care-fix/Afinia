export const categoryIcons={'belleza':'beauty','spa-relajacion':'leaf','fitness':'fitness','salud':'health','restaurantes':'coffee','actividades-experiencias':'sun'};
export function localized(row,base,locale){return row?.[base+'_'+locale]||row?.[base+'_'+(locale==='es'?'en':'es')]||row?.[base]||'';}
export function safeUrl(value){try{const url=new URL(value);return ['https:','http:'].includes(url.protocol)?url.href:null;}catch{return null;}}
export function normalize(text){return String(text||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase();}
export function categoriesFor(b,catalog){return [...new Set([b.category_id,...catalog.business_categories.filter(x=>x.business_id===b.id).map(x=>x.category_id)])];}
export function parentCategory(b,catalog){const c=catalog.categories.find(c=>c.id===b.category_id);return catalog.categories.find(p=>p.id===c?.parent_id)||c;}
export function distanceKm(b,location){if(!location||b.latitude==null||b.longitude==null)return null;const rad=x=>x*Math.PI/180;const a=Math.sin(rad(b.latitude-location.latitude)/2)**2+Math.cos(rad(location.latitude))*Math.cos(rad(b.latitude))*Math.sin(rad(b.longitude-location.longitude)/2)**2;return 6371*2*Math.atan2(Math.sqrt(a),Math.sqrt(1-a));}
export function rankBusinesses(catalog,preferences,favorites,signals){
 const scores=new Map(),seeds=new Map();preferences.forEach(id=>seeds.set(id,{weight:1,reason:'interest'}));
 const favorited=catalog.businesses.filter(b=>favorites.includes(b.id));favorited.forEach(b=>categoriesFor(b,catalog).forEach(id=>{if(!seeds.has(id))seeds.set(id,{weight:.85,reason:'activity'});}));
 Object.entries(signals).forEach(([id,n])=>{if(!seeds.has(id))seeds.set(id,{weight:Math.min(.75,n*.2),reason:'activity'});});
 for(const [id,seed] of seeds){scores.set(id,{score:seed.weight,reason:seed.reason});for(const a of catalog.affinities.filter(a=>a.source_category_id===id&&a.active)){const score=seed.weight*a.weight*.75;if(score>(scores.get(a.target_category_id)?.score||0))scores.set(a.target_category_id,{score,reason:'affinity'});}}
 return catalog.businesses.map(b=>{let match={score:0,reason:null};categoriesFor(b,catalog).forEach(id=>{const s=scores.get(id);if(s&&s.score>match.score)match=s;});return {...b,match};}).sort((a,b)=>b.match.score-a.match.score||Number(catalog.gallery.some(g=>g.business_id===b.id))-Number(catalog.gallery.some(g=>g.business_id===a.id))||a.name.localeCompare(b.name));
}
export function filterBusinesses(rows,catalog,{query='',category='',city='',photoOnly=false,sort='recommended',location=null}){
 let result=rows.filter(b=>{const ids=categoriesFor(b,catalog),catMatch=!category||ids.includes(category)||catalog.categories.some(c=>ids.includes(c.id)&&c.parent_id===category);const texts=[b.name,b.description_es,b.description_en,b.area,b.city,...catalog.offerings.filter(o=>o.business_id===b.id).flatMap(o=>[o.title_es,o.title_en]),...catalog.categories.filter(c=>ids.includes(c.id)).flatMap(c=>[c.name_es,c.name_en])];return catMatch&&(!city||b.city===city)&&(!photoOnly||catalog.gallery.some(g=>g.business_id===b.id))&&(!query||normalize(texts.join(' ')).includes(normalize(query)));});
 if(sort==='name')result.sort((a,b)=>a.name.localeCompare(b.name));if(sort==='near')result.sort((a,b)=>(distanceKm(a,location)??Infinity)-(distanceKm(b,location)??Infinity));return result;
}
