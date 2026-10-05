import './globals.css';
export const metadata = { title: 'Mi Espacio · Tu tiempo. Tu lugar.', description: 'Tu tiempo. Tu lugar. Gestiona tu negocio en Mi Espacio.' };
export const viewport={width:'device-width',initialScale:1,viewportFit:'cover',themeColor:'#101828'};
export default function Layout({children}) { return <html lang="es"><body>{children}</body></html>; }
