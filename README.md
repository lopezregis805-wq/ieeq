# IEEQ · Sistema de Registro de Afiliaciones

Sistema web para captura, validación y compulsa de afiliaciones ciudadanas a
asociaciones políticas estatales.

Stack: **Perl / CGI**, **MySQL 8+**, **Bootstrap 5**, sin frameworks de frontend.

## 1. Estructura del proyecto

```
ieeq-registro/
├── sql/
│   ├── ieeq_registro_v4_3nf.sql   ← versión anterior (histórico, no usar para instalar)
│   └── ieeq_registro_v5.sql       ← base de datos completa (3FN), autocontenida — usar esta
├── cgi-bin/
│   ├── lib/
│   │   ├── DB.pm         ← conexión a MySQL (lee credenciales de variables de entorno)
│   │   ├── Auth.pm       ← login, sesiones, permisos, codificación UTF-8 de sesión
│   │   ├── Bitacora.pm   ← registrar() centralizado
│   │   ├── Rutas.pm      ← ruta base para archivos subidos (fotos, firmas, emblemas)
│   │   ├── Exportar.pm   ← exportar_xlsx(): descarga de listados a Excel
│   │   ├── Correo.pm     ← enviar_correo(): notificaciones por SMTP/STARTTLS
│   │   └── Plantilla.pm  ← encabezado()/pie_pagina()/denegar_acceso()/paginacion():
│   │                        sidebar dinámico, acceso denegado y paginación homologados
│   ├── login.pl
│   ├── logout.pl
│   ├── dashboard.pl                ← panel distinto por rol (tarjetas, alertas, avance)
│   ├── asociaciones.pl             ← Gestión de Asociaciones Políticas
│   ├── usuarios.pl                 ← Gestión de Usuarios (con notificación por correo)
│   ├── permisos.pl                 ← Gestión de Permisos
│   ├── padron.pl                   ← Padrón Electoral de Referencia
│   ├── afiliaciones_nueva.pl       ← Registro de Afiliaciones (alta y edición)
│   ├── afiliaciones_listado.pl     ← Consulta y Gestión del Listado
│   ├── afiliaciones_detalle.pl     ← Detalle de solo lectura (con evidencia fotográfica)
│   ├── afiliaciones_verificar.pl   ← Verificación de Afiliaciones (Admin de Asociación)
│   ├── afiliaciones_compulsa.pl    ← Afiliaciones para Compulsa (Funcionariado IEEQ)
│   ├── cedulas.pl                  ← Generación de Cédulas de Afiliación (vista imprimible)
│   └── bitacora.pl                 ← Bitácora y Auditoría (solo lectura, bajo demanda)
├── public/
│   ├── css/custom.css    ← tokens de diseño IEEQ (colores, tipografía Outfit)
│   └── js/sidebar.js     ← botón hamburguesa para el sidebar en móvil
├── .env.example
├── .gitignore
└── README.md
```

Once módulos, cada uno con su propio script: dashboard, asociaciones, usuarios,
permisos, padrón electoral, registro de afiliaciones, listado, verificación,
compulsa, cédulas y bitácora.

## 2. Base de datos: 3FN

`ieeq_registro_v5.sql` es un script **autocontenido**: crea la base desde cero
(`DROP DATABASE IF EXISTS` + `CREATE DATABASE`), sus tablas, vistas, triggers,
procedimientos almacenados y datos de prueba. No necesita ningún parche adicional.

Puntos de diseño relevantes del esquema:

- `afiliaciones.id_asociacion` no existe como columna — es una dependencia
  transitiva (se deduce de `id_registrador` → `usuarios.id_asociacion`); se
  obtiene siempre por `JOIN`, nunca se duplica.
- No existe una tabla `situacion_padron` en `afiliaciones`: ese dato vive
  únicamente en `verificaciones_afiliaciones`, para no duplicarlo.
- `bitacora.id_modulo` es una FK a `modulos_sistema`, no texto libre — evita
  inconsistencias de nombres de módulo entre registros.
- Una Persona Auxiliar es un `usuario` con `tipo_usuario = 'AUXILIAR'`; no hay
  una tabla `auxiliares` aparte duplicando la entidad "persona".
- `afiliaciones.domicilio_numero` es el número exterior; existe además
  `domicilio_numero_interior` (opcional) para departamentos o interiores.
- Clave de elector y OCR son obligatorios al capturar una afiliación y se
  valida su estructura real, no solo su longitud: la clave debe cumplir
  `[A-Z]{6}\d{6}\d{2}[A-Z]\d{3}` (6 letras + fecha de nacimiento AAMMDD + 2
  dígitos + 1 letra + 3 dígitos = 18 caracteres) y el OCR debe ser
  `\d{13}` (13 dígitos). Ninguna de las dos columnas lleva `NOT NULL` en el
  esquema — la regla vive en `afiliaciones_nueva.pl` para no romper capturas
  antiguas de bases reales.
- La clave de elector no puede repetirse en ningún otro registro activo del
  sistema (sin importar la asociación): se valida por aplicación antes de
  guardar, no con un índice `UNIQUE`, para no romper si algún día se necesita
  reactivar un registro histórico con la misma clave.
- El campo Código CIC ya no se pide en el formulario de captura; la columna
  `cic` se conserva únicamente para no perder el dato de capturas anteriores.
- El domicilio siempre se registra en el estado de Querétaro — el campo no es
  editable en el formulario, y todo el texto capturado se guarda en mayúsculas.
- `asociaciones_politicas.sitio_web` guarda la URL de la asociación, usada en
  el aviso de privacidad de la cédula (ver sección 4).

**Ciclo de vida de una afiliación:** cuatro estatus — `REVISION_APE`,
`RECHAZADA`, `COMPULSA_IEEQ` y `COMPULSA_INE`. Las transiciones pasan siempre
por procedimientos almacenados, nunca por `UPDATE` directo desde la aplicación:

- Al capturarse (o corregirse tras un rechazo), una afiliación queda en
  `REVISION_APE` — no hay un paso separado de "enviar a revisión": ya queda
  lista para que el Admin de Asociación la valide.
- `sp_verificar_afiliacion(id_afiliacion, id_verificador, decision, observaciones)`
  — Revisión APE → `COMPULSA_IEEQ` (Aprobado) o → `RECHAZADA` (Rechazado, con
  observaciones obligatorias). Solo lo ejecuta el Admin de Asociación **de la
  misma asociación que el registro** — el procedimiento lo valida internamente,
  no solo la aplicación.
- `sp_regresar_a_revision(id_afiliacion, id_usuario)` — `COMPULSA_IEEQ` →
  `REVISION_APE`, para subsanar antes de la compulsa al INE. Lo ejecuta el
  Admin de Asociación (sobre su propia asociación) o el Funcionariado IEEQ
  (sobre cualquier registro, mientras revisa el lote antes de generar la
  compulsa).
- `sp_marcar_compulsa_ine(id_afiliacion, id_usuario)` — `COMPULSA_IEEQ` →
  `COMPULSA_INE`. Lo ejecuta el Funcionariado IEEQ, uno por uno dentro de una
  transacción Perl (`begin_work`/`commit`) para que un lote completo se marque
  junto o no se marque nada.
- `sp_eliminar_afiliacion(id_afiliacion, id_usuario)` — soft delete, solo si
  el estatus es Revisión APE o Rechazada.

Un registro rechazado queda en su propio estatus (no se confunde con uno
recién capturado) pero sigue siendo editable: la asociación corrige lo que
falló y lo vuelve a enviar a revisión. El trigger `trg_validar_edicion_afiliacion`
refuerza del lado de la base de datos que solo se puede editar el
nombre/apellido de un registro en Revisión APE o Rechazada; `trg_proteger_afiliacion_compulsa`
impide borrar un registro que ya esté en Compulsa IEEQ o Compulsa INE.

Cada procedimiento valida su propia condición de entrada (`SIGNAL SQLSTATE`) y
registra su propio movimiento en bitácora — no hay un trigger genérico de
bitácora por cambio de estatus, para evitar registros duplicados.

`padron.pl` también usa un procedimiento propio: `sp_eliminar_padron(id_padron, id_usuario)`
borra el registro activo del padrón y promueve a activo el más reciente que
quede, para que siempre exista exactamente uno.

## 3. Roles y permisos

| Rol | Puede crear | Responsabilidad en el proceso de afiliación |
|---|---|---|
| `SUPERADMIN` | Admin de Asociación, Funcionariado IEEQ | Ninguna — control del sistema (usuarios, permisos, asociaciones, padrón, bitácora), solo consulta el proceso operativo |
| `ADMIN_ASOCIACION` | Auxiliares (de su propia asociación) | Captura y **valida** (aprueba/rechaza) las afiliaciones de su propia asociación |
| `FUNCIONARIO_IEEQ` | — | **Genera la compulsa al INE** sobre lo que la asociación ya validó; ya no verifica afiliaciones |
| `AUXILIAR` | — | Captura sus propias afiliaciones |

Los permisos reales se guardan en `permisos_usuario` (nivel `ESCRITURA` /
`LECTURA` / `NINGUNO` por usuario y por módulo) y se ajustan desde
`permisos.pl` sin tocar la base de datos a mano. Al guardar, la pantalla
redirige al listado de usuarios y muestra una confirmación homologada con el
resto de las alertas del sistema (o el detalle del error, si algo falló).

Reglas de alcance notables:

- `SUPERADMIN` tiene control absoluto del sistema, pero **nunca** ESCRITURA en
  Registro, Verificación o Compulsa de Afiliaciones — solo `LECTURA` de
  supervisión. La regla se refuerza también del lado del código: ni
  `afiliaciones_listado.pl` ni `afiliaciones_nueva.pl` le dan un bypass de rol
  para gestionar registros ajenos.
- `ADMIN_ASOCIACION` valida las afiliaciones de su propia asociación
  (`VERIFICACION_AFILIACIONES = ESCRITURA`); no ve el listado de Compulsa
  (`COMPULSA_AFILIACIONES = NINGUNO`), eso es exclusivo de SUPERADMIN
  (consulta) y Funcionariado IEEQ.
- `FUNCIONARIO_IEEQ` ya no tiene acceso a Verificación
  (`VERIFICACION_AFILIACIONES = NINGUNO`); su escritura está en Compulsa
  (`COMPULSA_AFILIACIONES = ESCRITURA`) y en consulta de Cédulas (`LECTURA`,
  ya no genera).
- Un Auxiliar solo puede recibir Escritura/Lectura en Registro de Afiliaciones
  y Lectura en Consulta y Gestión del Listado; cualquier otro módulo queda
  bloqueado (forzado a `NINGUNO`) aunque el Admin de su asociación intente
  otorgarlo desde `permisos.pl` — la restricción se aplica también del lado
  del servidor al guardar, no solo ocultando la opción en el formulario.

El sidebar (`Plantilla::encabezado`) se construye dinámicamente a partir de
estos permisos: un módulo en `NINGUNO` ni siquiera aparece en el menú.

### Acceso denegado homologado

Cuando un usuario intenta entrar a un módulo o a una acción que no le
corresponde, el sistema nunca deja la pantalla en blanco: `Plantilla::denegar_acceso`
dibuja el mismo sidebar de siempre junto con una alerta roja explicando qué
pasó, para que la persona pueda seguir navegando el resto del sistema sin
perder el menú ni tener que usar el botón "atrás" del navegador.

## 4. Funcionalidades por módulo

**Registro de Afiliaciones** (`afiliaciones_nueva.pl`)
- Formulario de alta y edición en un solo script.
- Todos los campos de identificación y domicilio son obligatorios (excepto
  apellido materno y número interior); la validación se repite en el servidor
  aunque el HTML ya marque los campos como `required`.
- Clave de elector (18 caracteres, estructura real) y OCR (13 dígitos) se
  validan por formato, no solo por longitud; el mensaje de error explica la
  estructura esperada.
- La clave de elector no puede repetirse en ningún otro registro activo del
  sistema — si ya existe, se bloquea el guardado con un mensaje claro.
- Todo el texto se convierte a mayúsculas antes de guardarse, y también se ve
  en mayúsculas mientras se escribe (retroalimentación visual inmediata).
- Los campos con error se resaltan individualmente (borde e ícono de
  advertencia); si el formulario se rechaza, los datos ya capturados se
  conservan en pantalla en vez de borrarse.
- La captura sigue un patrón de dos fases: primero se valida todo el
  formulario, y solo si no hay ningún error se escriben los archivos subidos a
  disco — así no quedan fotos o firmas huérfanas en el servidor.
- La firma se captura directamente en pantalla (`<canvas>`) y se guarda como
  PNG en base64, no como archivo subido.
- Los campos de foto usan `capture` para preferir la cámara del dispositivo
  sobre la galería en celulares.
- El botón "Guardar" se deshabilita en cuanto se envía el formulario, para
  evitar registros duplicados por doble clic.
- Un registro en Revisión APE o Rechazada puede editarse; al abrir uno
  rechazado, se muestra el motivo capturado por el Admin de Asociación al
  validar.

**Consulta y Gestión del Listado** (`afiliaciones_listado.pl`)
- Pastillas de filtro por estatus (Todos, Revisión APE, Rechazada, Compulsa
  IEEQ, Compulsa INE) con su conteo, buscador por nombre o clave de elector,
  paginado (20 por página) y descarga a Excel de lo que coincide con el
  filtro/búsqueda actual.
- Columna de "Flujo": tres puntos que representan el avance del ciclo de vida.
- Acciones contextuales según estatus y rol: editar/eliminar (quien capturó o
  el Admin de su asociación, en Revisión APE/Rechazada) y "regresar a
  revisión" (el Admin de Asociación, sobre un registro propio en Compulsa
  IEEQ, para subsanarlo antes de la compulsa).

**Verificación de Afiliaciones** (`afiliaciones_verificar.pl`)
- Cola de pendientes (estatus Revisión APE) paginada, con descarga a Excel de
  todos los datos capturados (sin imágenes). El Admin de Asociación solo ve
  la cola de su propia asociación; SUPERADMIN ve el sistema completo, en
  consulta.
- Pantalla de decisión con la evidencia completa y un campo de observaciones,
  **obligatorio al rechazar** (validado en el navegador y en el servidor).
- Aprobar envía a Compulsa IEEQ; Rechazar deja el registro en Rechazada con el
  motivo, para que se corrija y se reenvíe.

**Para Compulsa** (`afiliaciones_compulsa.pl`)
- Muestra las afiliaciones en Compulsa IEEQ (ya validadas por su asociación),
  paginado, con selección múltiple y descarga a Excel de todos los datos
  capturados (sin imágenes) del lote completo o de lo seleccionado.
- **Generar compulsa**: marca el lote seleccionado como Compulsa INE y entrega
  el Excel en la misma respuesta.
- **Regresar a la asociación**: si detecta algo incorrecto, regresa el lote
  seleccionado a Revisión APE en vez de incluirlo en la compulsa.
- Exclusivo del Funcionariado IEEQ (ejecuta ambas acciones); SUPERADMIN solo
  consulta y descarga.

**Cédulas de Afiliación** (`cedulas.pl`)
- Vista HTML imprimible (con estilos `@media print`) de un registro que ya
  llegó a **Compulsa INE** — mientras solo está en Compulsa IEEQ (validado
  pero aún no enviado al INE) todavía no se puede generar ni ver su cédula.
  Listado paginado.
- Incluye un aviso de privacidad simplificado con los datos reales de la
  asociación (nombre, sitio web, domicilio armado desde sus propios campos);
  si la asociación no ha capturado su sitio web, se muestra "no disponible"
  en vez de dejar un campo roto.
- El botón "Imprimir" del navegador permite guardarla como PDF sin depender
  de librerías adicionales de Perl.

**Gestión de Usuarios** (`usuarios.pl`)
- Alta y edición en un solo formulario; los permisos "de fábrica" se asignan
  automáticamente al crear una cuenta, según el rol elegido.
- Notificación por correo (ver sección 5): al crear una cuenta se envía el
  correo y la contraseña asignada; al desactivar una cuenta (desmarcar
  "Cuenta activa") se envía un aviso de baja. Si el correo no se puede
  enviar, el alta/baja se completa igual — solo se muestra una advertencia,
  nunca se bloquea la operación.
- Listado paginado.

**Gestión de Asociaciones** (`asociaciones.pl`)
- Alta y edición del padrón de asociaciones políticas, incluyendo domicilio,
  emblema (JPG, máx. 1 MB) y sitio web.
- Al guardar, notificación de éxito homologada con el resto del sistema.
- Listado paginado.

**Padrón Electoral** (`padron.pl`)
- El Admin de Asociación solo consulta las 3 tarjetas (total del padrón, %
  mínimo, mínimo de afiliados) y la fecha de corte vigente — sin historial ni
  formulario de captura.
- Quien tiene escritura puede editar el registro activo (modal de Bootstrap,
  no ocupa espacio en la página hasta que se abre) o eliminarlo — al
  eliminarlo, el registro más reciente que quede se promueve automáticamente
  a activo.
- Historial paginado.

**Bitácora y Auditoría** (`bitacora.pl`)
- No carga información automáticamente al entrar: se eligen los filtros y se
  presiona "Mostrar registros" para desplegarla, paginada (ya no tiene un
  tope fijo de registros).
- Cada acción relevante del sistema se registra con usuario, módulo, fecha e
  IP de origen.

**Inicio de sesión** (`login.pl`)
- Etiquetas asociadas a sus campos (`for`/`id`), `autocomplete` correcto,
  mensaje de error anunciado con `role="alert"` y `aria-describedby`/
  `aria-invalid` en los campos con error.
- Botón para mostrar/ocultar la contraseña, con su propio `aria-pressed` y
  `aria-label` que cambian según el estado.

## 5. Detalles de implementación que vale la pena recordar

- **UTF-8**: cada script tiene `use utf8;` (el código fuente está en UTF-8) y
  `binmode(STDOUT, ':encoding(UTF-8)')`. Además, `Auth::guardar_texto_sesion` /
  `obtener_texto_sesion` codifican/decodifican explícitamente los valores con
  acentos antes de guardarlos en la sesión — `CGI::Session` no lo hace solo,
  y sin esto los nombres con tilde se corrompen entre una petición y otra. Los
  parámetros que llegan por `CGI.pm` sí necesitan `decode_utf8` explícito; los
  que ya vienen de una consulta con `mysql_enable_utf8mb4` no, porque
  `DBD::mysql` ya los entrega decodificados — aplicarlo dos veces corrompe el
  texto.
- **Rutas de archivos subidos**: `Rutas.pm` expone `$RUTA_UPLOADS`, que por
  defecto usa `FindBin ($Bin)` pero se puede sobreescribir con la variable de
  entorno `IEEQ_RUTA_UPLOADS`. Es necesario en servidores donde el
  `DocumentRoot` de Apache es un symlink hacia otra ruta real: `FindBin`
  resuelve symlinks, así que `$Bin` puede no coincidir con la carpeta que
  Apache realmente sirve.
- **Un script `.pl` nuevo necesita permiso de ejecución**: Apache/`mod_cgid`
  falla con "Permission denied" (500, sin ningún mensaje de Perl en el log de
  error salvo el `exec` fallido) si un script no tiene el bit `+x`, sin
  importar que la sintaxis esté perfecta. `git` también rastrea ese bit —
  después de copiar o generar un script nuevo, `chmod +x` tanto en el
  servidor como en el archivo que se sube al repo.
- **Paginación homologada**: `Plantilla::paginacion(pagina_actual, total_paginas, base_url)`
  dibuja los mismos controles Bootstrap en los ocho listados del sistema (20
  registros por página). Cada script arma su propio `WHERE`/`COUNT(*)` y le
  agrega `LIMIT ? OFFSET ?`; `paginacion()` solo se encarga del HTML de los
  controles, agregando `pagina=N` a `base_url`.
- **Exportar a Excel**: `Exportar::exportar_xlsx($cgi, $nombre, \@encabezados, \@filas)`
  centraliza la generación de `.xlsx` (usa `Excel::Writer::XLSX`) para los
  tres listados que lo ofrecen. Usa `require` en vez de `use` a propósito: si
  el módulo no está instalado, solo falla el botón de exportar (con un
  mensaje claro) en vez de tumbar toda la aplicación.
- **Notificaciones por correo**: `Correo::enviar_correo(%args)` centraliza el
  envío por SMTP con `Net::SMTPS` (STARTTLS). Mismo patrón defensivo que
  `Exportar.pm`: `require` en vez de `use`, y si las variables de entorno
  `IEEQ_SMTP_*` no están configuradas, devuelve un error controlado en vez de
  intentar conectarse. El envío nunca bloquea la operación que lo dispara
  (alta o baja de un usuario) — un fallo de correo se muestra como advertencia,
  no impide guardar.
- **Vistas**: `vw_afiliaciones_reporte`, `vw_bitacora_detalle` y
  `vw_estadisticas_afiliaciones` existen para no repetir `JOIN`s en cada
  script. Las columnas de `vw_estadisticas_afiliaciones` que vienen de una
  subconsulta van envueltas en `MAX()` porque MySQL, en modo
  `ONLY_FULL_GROUP_BY` (activo por defecto), lo exige aunque la subconsulta
  siempre regrese una sola fila.
- **Validación defensiva del lado del servidor**: ningún control de acceso o
  regla de negocio depende solo de que el HTML lo oculte o lo marque como
  `disabled` — se vuelve a validar al recibir el `POST`, tanto en Perl como en
  triggers/procedimientos de MySQL (incluida la asociación de quien ejecuta
  la acción, no solo el estatus del registro).

## 6. Instalación

```bash
# 1. Base de datos (un solo comando, ya trae todo)
mysql -u root -p < sql/ieeq_registro_v5.sql

# 2. Módulos Perl necesarios
sudo apt install libdbi-perl libdbd-mysql-perl libcgi-pm-perl libcgi-session-perl \
                  libexcel-writer-xlsx-perl libnet-smtps-perl libmime-lite-perl

# 3. Copiar al DocumentRoot de Apache — los .pl van DIRECTO en la raíz,
#    NO dentro de una carpeta "cgi-bin/" (ese nombre choca con el alias
#    global ScriptAlias /cgi-bin/ que trae Apache por defecto)
sudo mkdir -p /var/www/html/ieeq
sudo cp cgi-bin/*.pl /var/www/html/ieeq/
sudo cp -r cgi-bin/lib /var/www/html/ieeq/
sudo cp -r public /var/www/html/ieeq/
sudo mkdir -p /var/www/html/ieeq/uploads/{emblemas,ine/anverso,ine/reverso,fotos,firmas}
sudo mkdir -p /tmp/ieeq_sesiones
sudo chown -R www-data:www-data /var/www/html/ieeq /tmp/ieeq_sesiones
sudo chmod +x /var/www/html/ieeq/*.pl
```

`libexcel-writer-xlsx-perl`, `libnet-smtps-perl` y `libmime-lite-perl` son
opcionales en el sentido de que el sistema arranca sin ellos — solo fallan
(con un mensaje claro) los botones de "Descargar Excel" y las notificaciones
por correo hasta que se instalen.

VirtualHost mínimo:

```apache
<VirtualHost *:80>
    ServerName ieeq.local
    DocumentRoot /var/www/html/ieeq
    <Directory /var/www/html/ieeq>
        Options +ExecCGI
        AddHandler cgi-script .pl
        DirectoryIndex login.pl
        AllowOverride None
        Require all granted
        SetEnv IEEQ_DB_HOST localhost
        SetEnv IEEQ_DB_NAME ieeq_registro
        SetEnv IEEQ_DB_USER root
        SetEnv IEEQ_DB_PASS "tu_password_aqui"
        # Opcional: solo necesario si el DocumentRoot de arriba es un
        # symlink hacia otra ruta real (ver Rutas.pm en la sección 5).
        # SetEnv IEEQ_RUTA_UPLOADS /var/www/html/ieeq

        # Opcional: notificaciones por correo (alta/baja de usuarios).
        # Sin esto configurado, el sistema funciona igual — solo no
        # se envían los correos (ver sección 5).
        # SetEnv IEEQ_URL_SISTEMA https://afiliaciones.ieeq.mx
        # SetEnv IEEQ_SMTP_HOST smtp.office365.com
        # SetEnv IEEQ_SMTP_PORT 587
        # SetEnv IEEQ_SMTP_USER correo@dominio.mx
        # SetEnv IEEQ_SMTP_PASS "contraseña_del_correo"
        # SetEnv IEEQ_SMTP_NOMBRE "Sistema de Registro IEEQ"
    </Directory>
</VirtualHost>
```

```bash
sudo a2ensite ieeq
sudo a2enmod cgi
sudo systemctl reload apache2
echo "127.0.0.1 ieeq.local" | sudo tee -a /etc/hosts
```

## 7. Usuarios de prueba

Contraseña de todos: `12345678`

| Correo | Rol |
|---|---|
| admin@ieeq.mx | SUPERADMIN |
| maria.func@ieeq.mx | FUNCIONARIO_IEEQ |
| admin.rumbo@nuevorumbo.mx | ADMIN_ASOCIACION |
| pedro.aux@nuevorumbo.mx / laura.aux@nuevorumbo.mx | AUXILIAR |

## 8. Flujo de prueba de punta a punta

1. **Auxiliar** → *Nueva Afiliación* → captura datos + fotos + firma en
   pantalla → estatus `Revisión APE`.
2. **Admin de Asociación** → *Verificación* → revisa la evidencia de su
   propia asociación → Aprobar (→ `Compulsa IEEQ`) o Rechazar (→ `Rechazada`,
   con observaciones obligatorias).
3. Si se rechazó: **Auxiliar o Admin de Asociación** → *Listado* → edita el
   registro, corrige lo necesario; al guardar vuelve a quedar en `Revisión
   APE` para que se valide otra vez (paso 2).
4. **Funcionariado IEEQ** → *Para Compulsa* → selecciona el lote en `Compulsa
   IEEQ` → "Generar compulsa" (→ `Compulsa INE`, descarga el Excel) o
   "Regresar a la asociación" si detecta algo incorrecto (→ vuelve a
   `Revisión APE`, paso 2).
5. **Admin de Asociación o Funcionariado** → *Cédulas* → genera la cédula
   imprimible del registro ya en `Compulsa INE`.
6. Cualquier rol con acceso → *Bitácora* → selecciona filtros y confirma que
   cada paso anterior quedó registrado.
