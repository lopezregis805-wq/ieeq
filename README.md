# IEEQ · Sistema de Registro de Afiliaciones

Sistema web para captura, verificación y gestión de afiliaciones ciudadanas a
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
│   │   └── Plantilla.pm  ← encabezado()/pie_pagina()/denegar_acceso(): sidebar dinámico
│   │                        y pantalla homologada de acceso denegado
│   ├── login.pl
│   ├── logout.pl
│   ├── dashboard.pl              ← panel distinto por rol (tarjetas, alertas, avance)
│   ├── asociaciones.pl           ← Gestión de Asociaciones Políticas
│   ├── usuarios.pl               ← Gestión de Usuarios
│   ├── permisos.pl               ← Gestión de Permisos
│   ├── padron.pl                 ← Padrón Electoral de Referencia
│   ├── afiliaciones_nueva.pl     ← Registro de Afiliaciones (alta y edición)
│   ├── afiliaciones_listado.pl   ← Consulta y Gestión del Listado
│   ├── afiliaciones_detalle.pl   ← Detalle de solo lectura (con evidencia fotográfica)
│   ├── afiliaciones_verificar.pl ← Verificación de Afiliaciones
│   ├── cedulas.pl                ← Generación de Cédulas de Afiliación (vista imprimible)
│   └── bitacora.pl               ← Bitácora y Auditoría (solo lectura, bajo demanda)
├── public/
│   ├── css/custom.css    ← tokens de diseño IEEQ (colores, tipografía Outfit)
│   └── js/sidebar.js     ← botón hamburguesa para el sidebar en móvil
├── .env.example
├── .gitignore
└── README.md
```

Diez módulos, cada uno con su propio script: dashboard, asociaciones, usuarios,
permisos, padrón electoral, registro de afiliaciones, listado, verificación,
cédulas y bitácora.

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
- Clave de elector y OCR son obligatorios al capturar una afiliación (se
  valida en `afiliaciones_nueva.pl`; la columna no lleva `NOT NULL` en el
  esquema para no romper capturas ya existentes en bases reales). La clave de
  elector debe tener exactamente 18 caracteres alfanuméricos.
- El campo Código CIC ya no se pide en el formulario de captura; la columna
  `cic` se conserva únicamente para no perder el dato de capturas anteriores.
- El domicilio siempre se registra en el estado de Querétaro — el campo no es
  editable en el formulario, y todo el texto capturado se guarda en mayúsculas.

**Ciclo de vida de una afiliación:** cuatro estatus — `NUEVA`, `EN_REVISION`,
`VERIFICADO` y `RECHAZADA`. Las transiciones pasan siempre por procedimientos
almacenados, nunca por `UPDATE` directo desde la aplicación:

- `sp_enviar_a_revision(id_afiliacion, id_usuario)` — Nueva o Rechazada →
  En revisión (lo ejecuta la asociación: auxiliar o administrador).
- `sp_verificar_afiliacion(id_afiliacion, id_verificador, decision, observaciones)`
  — En revisión → Verificado (Aprobado) o → Rechazada (Rechazado). Solo lo
  ejecuta el Funcionariado IEEQ.
- `sp_eliminar_afiliacion(id_afiliacion, id_usuario)` — soft delete, solo si
  el estatus es Nueva o Rechazada.

Una afiliación rechazada queda en su propio estatus (ya no se confunde con una
recién capturada) pero sigue siendo editable: la asociación corrige lo que
falló y vuelve a enviarla a revisión con `sp_enviar_a_revision`. El trigger
`trg_validar_edicion_afiliacion` refuerza del lado de la base de datos que solo
se puede editar el nombre/apellido de un registro en estatus Nueva o Rechazada;
`trg_proteger_afiliacion_verificada` impide borrar un registro ya Verificado.

Cada procedimiento valida su propia condición de entrada (`SIGNAL SQLSTATE`) y
registra su propio movimiento en bitácora — no hay un trigger genérico de
bitácora por cambio de estatus, para evitar registros duplicados.

## 3. Roles y permisos

| Rol | Puede crear | Alcance típico |
|---|---|---|
| `SUPERADMIN` | Admin de Asociación, Funcionariado IEEQ | Todo el sistema |
| `ADMIN_ASOCIACION` | Auxiliares (de su propia asociación) | Su asociación y sus auxiliares |
| `FUNCIONARIO_IEEQ` | — | Lectura global, verificación, cédulas |
| `AUXILIAR` | — | Solo sus propias afiliaciones capturadas |

Los permisos reales se guardan en `permisos_usuario` (nivel `ESCRITURA` /
`LECTURA` / `NINGUNO` por usuario y por módulo) y se ajustan desde
`permisos.pl` sin tocar la base de datos a mano. Al guardar, la pantalla
redirige al listado de usuarios y muestra una confirmación homologada con el
resto de las alertas del sistema (o el detalle del error, si algo falló).

Reglas de alcance notables:

- Solo `SUPERADMIN` puede dar de alta asociaciones nuevas; un
  `ADMIN_ASOCIACION` solo puede editar la suya.
- `FUNCIONARIO_IEEQ` no tiene acceso a Registro de Afiliaciones: solo
  consulta, verificación y generación de cédulas.
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
- La clave de elector se valida contra el formato de 18 caracteres
  alfanuméricos; el mensaje de error indica cuántos caracteres tiene la que se
  capturó.
- Todo el texto se convierte a mayúsculas antes de guardarse, y también se ve
  en mayúsculas mientras se escribe (retroalimentación visual inmediata, sin
  esperar a enviar el formulario).
- Los campos con error se resaltan individualmente (borde e ícono de
  advertencia) en vez de mostrar un solo mensaje genérico; si el formulario se
  rechaza, los datos ya capturados se conservan en pantalla en vez de
  borrarse.
- La captura sigue un patrón de dos fases: primero se valida todo el
  formulario, y solo si no hay ningún error se escriben los archivos subidos a
  disco — así no quedan fotos o firmas huérfanas en el servidor cuando falla
  otro campo.
- La firma se captura directamente en pantalla (`<canvas>`, con mouse o
  touch) y se guarda como PNG en base64, no como archivo subido.
- Los campos de foto (anverso, reverso, selfie) usan `capture` para preferir
  la cámara del dispositivo sobre la galería en celulares.
- El botón "Guardar" se deshabilita en cuanto se envía el formulario, para
  evitar registros duplicados por doble clic.
- Un registro en estatus Rechazada puede editarse igual que uno Nuevo; al
  abrirlo para corregirlo, se muestra el motivo del rechazo capturado por
  Verificación.

**Consulta y Gestión del Listado** (`afiliaciones_listado.pl`)
- Pastillas de filtro por estatus (Todas, Nueva, En revisión, Verificada,
  Rechazada) con su conteo.
- Buscador por nombre o clave de elector.
- Columna de "Flujo": tres puntos que representan el avance del ciclo de
  vida del registro.
- Acciones contextuales (ver, editar, enviar a revisión, eliminar) según el
  estatus del registro y el rol de quien la ve.

**Verificación de Afiliaciones** (`afiliaciones_verificar.pl`)
- Cola de pendientes (estatus En revisión), ordenada por antigüedad.
- Pantalla de decisión con la evidencia completa del registro y un campo de
  observaciones.
- Aprobar deja el registro en Verificado; Rechazar lo deja en Rechazada junto
  con el motivo capturado, que la asociación puede consultar al corregirlo.

**Cédulas de Afiliación** (`cedulas.pl`)
- Vista HTML imprimible (con estilos `@media print`) de un registro ya
  Verificado; el botón "Imprimir" del navegador permite guardarla como PDF sin
  depender de librerías adicionales de Perl.

**Bitácora y Auditoría** (`bitacora.pl`)
- No carga información automáticamente al entrar: se eligen los filtros
  (tipo de acción, rango de fechas) y se presiona "Mostrar registros" para
  desplegarla. Evita consultas pesadas innecesarias en una tabla que puede
  crecer mucho.
- Cada acción relevante del sistema (login, alta/edición/eliminación de
  registros, aprobación/rechazo, asignación de permisos, generación de
  cédulas) se registra con usuario, módulo, fecha e IP de origen.

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
  Apache realmente sirve. Si no defines la variable, el comportamiento es
  igual que antes (usa `$Bin`).
- **Vistas**: `vw_afiliaciones_reporte`, `vw_bitacora_detalle` y
  `vw_estadisticas_afiliaciones` existen para no repetir `JOIN`s en cada
  script. Las columnas de `vw_estadisticas_afiliaciones` que vienen de una
  subconsulta van envueltas en `MAX()` porque MySQL, en modo
  `ONLY_FULL_GROUP_BY` (activo por defecto), lo exige aunque la subconsulta
  siempre regrese una sola fila.
- **Validación defensiva del lado del servidor**: ningún control de acceso o
  regla de negocio depende solo de que el HTML lo oculte o lo marque como
  `disabled` — se vuelve a validar al recibir el `POST`, tanto en Perl como en
  triggers/procedimientos de MySQL.

## 6. Instalación

```bash
# 1. Base de datos (un solo comando, ya trae todo)
mysql -u root -p < sql/ieeq_registro_v5.sql

# 2. Módulos Perl necesarios
sudo apt install libdbi-perl libdbd-mysql-perl libcgi-pm-perl libcgi-session-perl

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

1. **Auxiliar** → *Nueva Afiliación* → captura datos + fotos + firma en pantalla
   → estatus `Nueva afiliación`.
2. **Auxiliar o Admin de Asociación** → *Listado* → botón de enviar →
   estatus `En revisión` → ahora aparece en la cola del Funcionariado.
3. **Funcionariado IEEQ** → *Verificación* → revisa evidencia → Aprobar
   (→ `Verificado`) o Rechazar (→ `Rechazada`, con motivo).
4. Si se rechazó: **Auxiliar o Admin de Asociación** → *Listado* → edita el
   registro rechazado, corrige lo necesario y vuelve a enviarlo a revisión
   (paso 2).
5. **Admin de Asociación o Funcionariado** → *Cédulas* → genera la cédula
   imprimible del registro verificado.
6. Cualquier rol con acceso → *Bitácora* → selecciona filtros y confirma que
   cada paso anterior quedó registrado.

