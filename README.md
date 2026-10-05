# Mi Espacio

Portal de comercios con Next.js y Supabase. Paleta Pro por defecto, con Modern Teal y Warm Neutral. Interfaz y fichas bilingües.

`npm install`, `npm run dev`, `npm run build`.

La vista de prueba contiene una copia de la investigación pública y guarda cambios únicamente en este navegador. El acceso autenticado consulta y modifica solamente los negocios asignados mediante `business_members`, bajo RLS. Una solicitud de acceso no concede propiedad. Las fichas requieren aprobación explícita del propietario y revisión administrativa antes de publicarse. Los servicios importados son sugerencias, sin precios ni duraciones inventados.

El directorio de prueba se genera a partir de Supabase. No contiene usuarios ni información privada. La clave publishable es pública; nunca usar claves secret o service_role en el cliente.
