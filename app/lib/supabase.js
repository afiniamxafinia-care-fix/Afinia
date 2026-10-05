import {createClient} from '@supabase/supabase-js';
export const supabase = createClient('https://rmmsgxqfsswukbrdnnuh.supabase.co', 'sb_publishable_xQicalhePP7OuqzNzk06Qg_YO5RppmJ', {auth:{storageKey:'mi-espacio-customer-auth',persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}});

// Must also be allowed in Supabase Auth URL Configuration.
export const authRedirectUrl = 'https://afinia-azure.vercel.app/';
