export function civilTime(value,zone='America/Mazatlan'){
 if(!value)return '';const parts=new Intl.DateTimeFormat('en-CA',{timeZone:zone,year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).formatToParts(new Date(value));const p=Object.fromEntries(parts.map(x=>[x.type,x.value]));return `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}`;
}
export function instantFromCivil(value,zone='America/Mazatlan'){
 if(!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(value))throw Error('Invalid date');const target=Date.parse(value+'Z');let instant=target;
 for(let i=0;i<3;i++){const rendered=Date.parse(civilTime(instant,zone)+'Z');instant+=target-rendered;}
 if(civilTime(instant,zone)!==value)throw Error('This local time does not exist');return new Date(instant).toISOString();
}
