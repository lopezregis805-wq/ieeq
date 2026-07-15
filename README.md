# IEEQ · Sistema de Registro de Afiliaciones

Sistema web para el Instituto Electoral del Estado de Querétaro: captura, verificación
y gestión de afiliaciones ciudadanas a asociaciones políticas estatales, construido
según la Especificación de Requerimientos de Software (manual del proyecto).

Stack: **Perl / CGI**, **MySQL 8+**, **Bootstrap 5**, sin frameworks de frontend.

## 1. Estructura del proyecto

```
ieeq-registro/
├── sql/
│   └── ieeq_registro_v4_3nf.sql   ← base de datos completa (3FN), autocontenida
├── cgi-bin/
│   ├── lib/
│   │   ├── DB.pm         ← conexión a MySQL (lee credenciales de variables de entorno)
│   │   ├── Auth.pm       ← login, sesiones, permisos, codificación UTF-8 de sesión
│   │   ├── Bitacora.pm   ← registrar() centralizado
│   │   └── Plantilla.pm  ← encabezado()/pie_pagina(): sidebar dinámico según permisos
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
│   └── bitacora.pl               ← Bitácora y Auditoría (solo lectura)
├── public/
│   ├── css/custom.css    ← tokens de diseño IEEQ (colores, tipografía Outfit)
│   └── js/sidebar.js     ← botón hamburguesa para el sidebar en móvil
├── .env.example
├── .gitignore
└── README.md
```

Los 10 módulos del Diagrama 3 del manual están completos.

## 2. Base de datos: 3FN

`ieeq_registro_v4_3nf.sql` es un script **autocontenido**: crea la base desde cero
(`DROP DATABASE IF EXISTS` + `CREATE DATABASE`), sus tablas, vistas, triggers,
procedimientos almacenados y datos de prueba. No necesita ningún parche adicional.

Correcciones de normalización respecto a un diseño ingenuo (ver comentarios `[fix]`
dentro del propio archivo):

1. `afiliaciones.id_asociacion` se eliminó — era una dependencia transitiva
   (se deducía de `id_registrador` → `usuarios.id_asociacion`); ahora se obtiene
   siempre por `JOIN`, nunca se duplica.
2. `afiliaciones.situacion_padron` se eliminó — duplicaba lo que ya vive en
   `verificaciones_afiliaciones`.
3. `bitacora.modulo` pasó de texto libre a `id_modulo` (FK a `modulos_sistema`).
4. Se eliminó una tabla `auxiliares` paralela a `usuarios` que duplicaba la
   entidad "persona" completa. Una Persona Auxiliar es un `usuario` con
   `tipo_usuario = 'AUXILIAR'`, no una entidad aparte.
5. Se agregó el rol `ADMIN_ASOCIACION`, que el manual describe (sección 2) pero
   que no existía como rol independiente en un primer borrador.

**Ciclo de vida de una afiliación** (Diagrama 9 del manual): solo existen 3
estatus — `NUEVA`, `EN_REVISION`, `VERIFICADO`. Un rechazo no es un cuarto
estatus: regresa el registro a `NUEVA` para que se corrija y se vuelva a enviar.
Las transiciones pasan por procedimientos almacenados, nunca por `UPDATE`
directo desde la aplicación:

- `sp_enviar_a_revision(id_afiliacion, id_usuario)` — Nueva → En revisión
  (lo ejecuta la asociación: auxiliar o admin).
- `sp_verificar_afiliacion(id_afiliacion, id_verificador, decision, observaciones)`
  — En revisión → Verificado (Aprobado) o → Nueva (Rechazado). Solo lo ejecuta
  el Funcionariado IEEQ.
- `sp_eliminar_afiliacion(id_afiliacion, id_usuario)` — soft delete, solo si
  el estatus es Nueva.

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
`LECTURA` / `NINGUNO` por usuario y por módulo) y se pueden ajustar desde
`permisos.pl` sin tocar la base de datos a mano. Reglas de alcance notables:

- Solo `SUPERADMIN` puede dar de alta asociaciones nuevas; un
  `ADMIN_ASOCIACION` solo puede editar la suya.
- `FUNCIONARIO_IEEQ` no tiene ningún acceso a Registro de Afiliaciones
  ("sin alta ni edición de afiliaciones", manual sección 2).
- Un Auxiliar nunca puede recibir permisos de Gestión de Usuarios ni Gestión
  de Permisos, aunque el Admin de su asociación lo intente desde `permisos.pl`
  (se bloquea también del lado del servidor, no solo en el HTML).

El sidebar (`Plantilla::encabezado`) se construye dinámicamente a partir de
estos permisos: un módulo en `NINGUNO` ni siquiera aparece en el menú.

## 4. Detalles de implementación que vale la pena recordar

- **UTF-8**: cada script tiene `use utf8;` (el código fuente está en UTF-8) y
  `binmode(STDOUT, ':encoding(UTF-8)')`. Además, `Auth::guardar_texto_sesion` /
  `obtener_texto_sesion` codifican/decodifican explícitamente los valores con
  acentos antes de guardarlos en la sesión — `CGI::Session` no lo hace solo,
  y sin esto los nombres con tilde se corrompen entre una petición y otra.
- **Firma en pantalla**: `afiliaciones_nueva.pl` no pide subir una foto de la
  firma; usa un `<canvas>` (dibujo con mouse o touch) y manda el resultado como
  PNG en base64 (`MIME::Base64`), tal como lo describe el manual, sección 5.4
  ("firma capturada en pantalla").
- **Rutas de archivos subidos**: se calculan con `FindBin ($Bin)`, nunca con
  una ruta fija — así el proyecto funciona sin importar en qué carpeta lo
  despliegues.
- **Vistas**: `vw_afiliaciones_reporte`, `vw_bitacora_detalle` y
  `vw_estadisticas_afiliaciones` existen para no repetir `JOIN`s en cada
  script. Las columnas de `vw_estadisticas_afiliaciones` que vienen de una
  subconsulta van envueltas en `MAX()` porque MySQL, en modo
  `ONLY_FULL_GROUP_BY` (activo por defecto), lo exige aunque la subconsulta
  siempre regrese una sola fila.
- **Cédulas**: se generan como una vista HTML con estilos `@media print`, no
  como PDF generado en el servidor — el botón "Imprimir" del navegador ya
  permite guardar como PDF sin sumar dependencias de Perl.

## 5. Instalación

```bash
# 1. Base de datos (un solo comando, ya trae todo)
mysql -u root -p < sql/ieeq_registro_v4_3nf.sql

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
    </Directory>
</VirtualHost>
```

```bash
sudo a2ensite ieeq
sudo a2enmod cgi
sudo systemctl reload apache2
echo "127.0.0.1 ieeq.local" | sudo tee -a /etc/hosts
```

## 6. Usuarios de prueba

Contraseña de todos: `12345678`

| Correo | Rol |
|---|---|
| admin@ieeq.mx | SUPERADMIN |
| maria.func@ieeq.mx | FUNCIONARIO_IEEQ |
| admin.rumbo@nuevorumbo.mx | ADMIN_ASOCIACION |
| pedro.aux@nuevorumbo.mx / laura.aux@nuevorumbo.mx | AUXILIAR |

## 7. Flujo de prueba de punta a punta

1. **Auxiliar** → *Nueva Afiliación* → captura datos + fotos + firma en pantalla
   → estatus `Nueva afiliación`.
2. **Auxiliar o Admin de Asociación** → *Listado* → botón de enviar (📤) →
   estatus `En revisión` → ahora aparece en la cola del Funcionariado.
3. **Funcionariado IEEQ** → *Verificación* → revisa evidencia → Aprobar
   (→ `Verificado`) o Rechazar (regresa a `Nueva afiliación`).
4. **Admin de Asociación o Funcionariado** → *Cédulas* → genera la cédula
   imprimible del registro verificado.
5. Cualquier rol con acceso → *Bitácora* → confirma que cada paso anterior
   quedó registrado.

## 8. Verificar que el `.sql` funciona "desde cero"

Antes de compartir el repo o hacer un despliegue nuevo, conviene comprobar
que el script realmente es autocontenido:

```bash
mysql -u root -p < sql/ieeq_registro_v4_3nf.sql
mysql -u root -p -e "SHOW PROCEDURE STATUS WHERE Db='ieeq_registro';"
mysql -u root -p -e "SELECT * FROM ieeq_registro.vw_estadisticas_afiliaciones;"
```

Si los 3 procedimientos aparecen y la vista no da error de
`ONLY_FULL_GROUP_BY`, el script está completo y listo para que cualquiera lo
descargue.
