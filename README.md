# Mi Espacio

Portal de comercios con Next.js y Supabase. Paleta Pro por defecto, con Modern Teal y Warm Neutral. Interfaz y fichas bilingües.

`npm install`, `npm run dev`, `npm run build`.

La vista de prueba contiene una copia de la investigación pública y guarda cambios únicamente en este navegador. El acceso autenticado consulta y modifica solamente los negocios asignados mediante `business_members`, bajo RLS. Una solicitud de acceso no concede propiedad. Las fichas requieren aprobación explícita del propietario y revisión administrativa antes de publicarse. Los servicios importados son sugerencias, sin precios ni duraciones inventados.

El directorio de prueba se genera a partir de Supabase. No contiene usuarios ni información privada. La clave publishable es pública; nunca usar claves secret o service_role en el cliente.

## Rutas

- `/`: experiencia del usuario, diseñada primero para móvil; inicio, catálogo, ficha, guardados, citas, recompensas y perfil.
- `/comercio`: portal del comercio existente.

Las fichas publicadas se consultan desde Supabase. Si aún no hay comercios publicados, se muestra una vista previa claramente identificada con la investigación pública. Los visitantes exploran el catálogo y eligen idioma. Maps, tema, intereses y favoritos requieren sesión; las preferencias antiguas de invitado no habilitan estas funciones. Las cuentas autenticadas guardan perfil, exactamente tres intereses, señales de exploración y favoritos de negocios publicados bajo RLS. La UX del cliente no ofrece enlaces al sitio web ni enlaces de fuentes en fotos o reseñas. El campo de sitio web se conserva para gestión interna. Cómo llegar solo admite URLs de Google Maps y nunca usa la web del negocio como destino alternativo. Live está apagado por defecto y requiere elección explícita. Las reseñas editoriales conservan su atribución y no se presentan como calificaciones de clientes. No se inventan distancias, precios, duraciones, reservas ni recompensas.

El diseño soporta áreas seguras del dispositivo, navegación inferior, carruseles táctiles, filtros en panel inferior, galerías, texto ES/EN, tres paletas, geolocalización opcional y estados vacíos. Las reservas permanecen pendientes de habilitar los comercios y completar el flujo transaccional.
