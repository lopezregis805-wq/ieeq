# IEEQ · Sistema de Registro de Afiliaciones — base reconstruida

Este paquete contiene:

```
ieeq-registro/
├── sql/
│   └── ieeq_registro_v4_3nf.sql   ← base de datos corregida (3FN)
├── cgi-bin/
│   ├── lib/
│   │   ├── DB.pm         ← conexión a MySQL (equivalente al db.pl del manual)
│   │   ├── Auth.pm       ← login, sesiones, permisos
│   │   ├── Bitacora.pm   ← registrar() centralizado
│   │   └── Plantilla.pm  ← encabezado()/pie_pagina() con Bootstrap 5
│   ├── login.pl
│   ├── logout.pl
│   ├── dashboard.pl      ← menú dinámico según permisos_usuario
│   └── asociaciones.pl   ← módulo COMPLETO de referencia (5.2 del manual)
└── README.md
```

## 1. Qué cambió en la base de datos y por qué

Ya viste el detalle en el chat, pero en resumen, `ieeq_registro_v4_3nf.sql`:

1. Quita `afiliaciones.id_asociacion` (se deducía de `id_registrador`) → ahora se obtiene con `JOIN usuarios`.
2. Quita `afiliaciones.situacion_padron` (dato duplicado con `verificaciones_afiliaciones`).
3. Cambia `bitacora.modulo` (texto libre) por `bitacora.id_modulo` (FK a `modulos_sistema`).
4. Elimina las tablas `auxiliares` y `verificaciones_auxiliares` (duplicaban a la persona que ya existe en `usuarios` con rol `AUXILIAR`, y ese módulo no está en el manual).
5. Agrega el rol `ADMIN_ASOCIACION` que faltaba en el catálogo de roles.

Todo lo que antes se "recuperaba" de las columnas eliminadas ahora vive en las vistas `vw_afiliaciones_reporte`, `vw_bitacora_detalle` y `vw_estadisticas_afiliaciones` — ya las puedes usar directamente en tus `SELECT` en vez de repetir los `JOIN` en cada script.

**Para cargarla:**
```bash
mysql -u root -p < sql/ieeq_registro_v4_3nf.sql
```

## 2. Por qué el código Perl se organiza así

Un problema típico en proyectos CGI sin framework es que cada script termina con su propio "copy-paste" de la conexión a la BD, del login, del HTML del encabezado, etc. Aquí separamos eso en módulos (`.pm`) dentro de `cgi-bin/lib/`, y cada script `.pl` los importa con `use lib './lib'; use DB qw(conectar);`.

Ventaja concreta: si mañana cambia la contraseña de MySQL, editas **un** archivo (`DB.pm`), no diez.

`asociaciones.pl` es el módulo que dejo 100% terminado y funcional, porque sirve de **plantilla** para construir el resto. Su estructura (que vas a repetir en cada módulo nuevo) es siempre:

1. Sesión + verificación de permiso (`tiene_permiso`).
2. Leer qué acción pidió el usuario (`listar`, `nuevo`, `guardar`, `editar`).
3. Validar las reglas de negocio del manual (ahí vive la lógica, no en la base de datos ni en el HTML).
4. Ejecutar el SQL con parámetros (`?`) — nunca concatenar variables directo en el SQL, para evitar inyección SQL.
5. Registrar en bitácora con `Bitacora::registrar(...)` y mostrar el HTML con `Plantilla::encabezado()` / `pie_pagina()`.

## 3. Cómo desplegarlo en tu Apache (Ubuntu)

Usa el mismo patrón que ya tienes funcionando para `ieeq-registro` actual:

1. Copia `cgi-bin/` y su contenido a `/var/www/html/IEEQ/cgi-bin/` (o donde apunte tu VirtualHost).
2. Da permisos de ejecución: `chmod +x cgi-bin/*.pl`
3. Instala los módulos Perl que faltan (ya los usé y probé en este entorno):
   ```bash
   sudo apt install libdbi-perl libdbd-mysql-perl libcgi-pm-perl libcgi-session-perl
   ```
4. Define las credenciales de BD como variables de entorno (no en el código — recuerda el incidente de credenciales en el historial de Git):
   ```
   SetEnv IEEQ_DB_HOST localhost
   SetEnv IEEQ_DB_NAME ieeq_registro
   SetEnv IEEQ_DB_USER ieeq_app
   SetEnv IEEQ_DB_PASS "tu_password_aqui"
   ```
   (esto va en el VirtualHost o en un `.htaccess` con `mod_env`, **nunca** en el `.pl`).
5. Crea la carpeta de subidas: `mkdir -p /var/www/html/IEEQ/uploads/{emblemas,ine/anverso,ine/reverso,fotos,firmas}` y dale permisos de escritura al usuario de Apache (`www-data`).

## 4. Usuarios de prueba (todos con contraseña `12345678`)

| Correo | Rol |
|---|---|
| admin@ieeq.mx | SUPERADMIN |
| maria.func@ieeq.mx | FUNCIONARIO_IEEQ |
| admin.rumbo@nuevorumbo.mx | ADMIN_ASOCIACION |
| pedro.aux@nuevorumbo.mx | AUXILIAR |

## 5. Hoja de ruta — módulos que faltan por construir

Con `asociaciones.pl` como plantilla, el orden recomendado (siguiendo el flujo del Diagrama 12 del manual) es:

1. **`usuarios.pl` + `permisos.pl`** — alta de Admin de Asociación / Auxiliares y asignación de permisos (Fase 2, pasos 3-6).
2. **`padron.pl`** — captura del padrón electoral (Fase 3, paso 7). Es el más sencillo: un solo registro activo a la vez.
3. **`afiliaciones_nueva.pl`** — el formulario de captura en campo (paso 8). Es el más complejo: reutiliza la subida de archivos que ya viste en `asociaciones.pl` (emblema), pero con 4 archivos (anverso, reverso, foto, firma) y las 4 casillas de aceptación obligatorias.
4. **`afiliaciones_listado.pl`** — consulta filtrada por rol (paso 9): un auxiliar solo ve `WHERE id_registrador = <su id>`; el admin de asociación ve `WHERE id_registrador IN (SELECT id_usuario FROM usuarios WHERE id_asociacion = <su asociación>)`; el IEEQ ve todo.
5. **`afiliaciones_verificar.pl`** — llama al procedimiento `sp_verificar_afiliacion` que ya está en el SQL (paso 10).
6. **`cedulas.pl`** — genera el PDF/vista de impresión (paso 11). Aquí conviene usar `PDF::API2` o simplemente una vista HTML lista para imprimir con `@media print` en CSS, que es más simple que generar un PDF real desde Perl.
7. **`bitacora.pl`** — solo lectura sobre `vw_bitacora_detalle` (paso 12).

Si quieres, en la siguiente sesión seguimos con `usuarios.pl` y `afiliaciones_nueva.pl` (son los dos que le dan más funcionalidad real al sistema) usando exactamente este mismo patrón.
