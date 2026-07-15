#!/usr/bin/perl
# ============================================================
# usuarios.pl — Gestión de Usuarios (manual, Fase 2: pasos 3-6).
#
# Mismo patrón de 5 pasos que asociaciones.pl:
#   1. sesión + permiso
#   2. leer acción
#   3. validar reglas de negocio (aquí la más importante es
#      "quién puede crear a quién")
#   4. ejecutar SQL
#   5. bitácora + HTML
#
# Regla de negocio central (manual, sección 2.1):
#   - SUPERADMIN crea ADMIN_ASOCIACION y FUNCIONARIO_IEEQ
#   - ADMIN_ASOCIACION crea AUXILIAR, siempre en SU PROPIA
#     asociación (no puede elegir otra ni volverse superadmin)
# ============================================================
use strict;
use warnings;
use utf8;                            # el codigo fuente de este archivo esta en UTF-8
use CGI;
use lib './lib';
use DB qw(conectar);
use Auth qw(iniciar_sesion requerir_sesion tiene_permiso obtener_texto_sesion);
use Bitacora qw(registrar);
use Plantilla qw(encabezado pie_pagina);
use Digest::SHA qw(sha256_hex);

my $cgi = CGI->new;
binmode(STDOUT, ":encoding(UTF-8)");   # lo que imprimimos tambien debe salir en UTF-8
my $session = iniciar_sesion($cgi);
my $id_usuario = requerir_sesion($session, $cgi);
my $dbh = conectar();
my $rol_sesion = $session->param('rol');
my $id_asociacion_sesion = $session->param('id_asociacion');

unless (tiene_permiso($dbh, $id_usuario, 'GESTION_USUARIOS', 'LECTURA')) {
    print $cgi->header(-charset => 'utf-8', -status => '403 Forbidden');
    print "Acceso no autorizado a este módulo.";
    exit;
}
my $puede_escribir = tiene_permiso($dbh, $id_usuario, 'GESTION_USUARIOS', 'ESCRITURA');

# --- Paso 3a: ¿qué roles puede crear/ver quien está en sesión? ---
# Esto evita, por ejemplo, que un Admin de Asociación cree otro
# SUPERADMIN con solo manipular el formulario HTML.
my %roles_permitidos_por_creador = (
    SUPERADMIN       => ['ADMIN_ASOCIACION', 'FUNCIONARIO_IEEQ'],
    ADMIN_ASOCIACION => ['AUXILIAR'],
);
my @roles_creables = @{ $roles_permitidos_por_creador{$rol_sesion} // [] };

unless (@roles_creables) {
    print $cgi->header(-charset => 'utf-8', -status => '403 Forbidden');
    print "Tu rol no tiene usuarios que pueda dar de alta.";
    exit;
}

my $accion = $cgi->param('accion') // 'listar';
my @errores;

# --- Paso 4: guardar (alta o edición) ---
if ($accion eq 'guardar' && $cgi->request_method eq 'POST') {
    unless ($puede_escribir) {
        print $cgi->header(-charset => 'utf-8', -status => '403 Forbidden');
        print "No tienes permiso de escritura en este módulo.";
        exit;
    }

    my $id                = $cgi->param('id_usuario') || undef;
    my $correo            = trim($cgi->param('correo_electronico'));
    my $contrasena_plana   = $cgi->param('contrasena') // '';
    my $nombre            = trim($cgi->param('nombre'));
    my $apellido_paterno   = trim($cgi->param('apellido_paterno'));
    my $apellido_materno   = trim($cgi->param('apellido_materno'));
    my $telefono           = trim($cgi->param('telefono_movil'));
    my $tipo_usuario       = $cgi->param('tipo_usuario') // '';
    my $activo             = $cgi->param('activo') ? 1 : 0;

    # --- validaciones ---
    push @errores, 'El correo electrónico es obligatorio.' unless length $correo;
    push @errores, 'El nombre es obligatorio.'              unless length $nombre;
    push @errores, 'El apellido paterno es obligatorio.'     unless length $apellido_paterno;

    # el rol elegido debe estar en la lista de roles que ESTE creador puede asignar
    unless (grep { $_ eq $tipo_usuario } @roles_creables) {
        push @errores, 'No tienes permiso para asignar ese rol.';
    }

    if (!$id && length($contrasena_plana) < 8) {
        push @errores, 'La contraseña debe tener al menos 8 caracteres.';
    }

    # correo único (aparte de la restricción UNIQUE de la BD, damos un
    # mensaje amigable en vez de un error 500 de MySQL)
    if (length $correo) {
        my $sth = $dbh->prepare('SELECT id_usuario FROM usuarios WHERE correo_electronico = ? AND id_usuario != ?');
        $sth->execute($correo, $id // 0);
        push @errores, 'Ya existe un usuario con ese correo electrónico.' if $sth->fetchrow_array;
    }

    # --- determinar la asociación según la regla de negocio ---
    my $id_asociacion_final;
    if ($tipo_usuario eq 'AUXILIAR') {
        # un Admin de Asociación SOLO puede crear auxiliares de SU
        # propia asociación; no se toma de un <select> manipulable.
        $id_asociacion_final = $id_asociacion_sesion;
    } elsif ($tipo_usuario eq 'ADMIN_ASOCIACION') {
        # el SUPERADMIN sí elige a qué asociación pertenece
        $id_asociacion_final = $cgi->param('id_asociacion') || undef;
        push @errores, 'Debes seleccionar la asociación para este administrador.' unless $id_asociacion_final;
    } else {
        $id_asociacion_final = undef; # FUNCIONARIO_IEEQ / SUPERADMIN no llevan asociación
    }

    if (!@errores) {
        if ($id) {
            # --- edición: la contraseña solo se cambia si se escribió una nueva ---
            if (length($contrasena_plana) >= 8) {
                $dbh->do(
                    'UPDATE usuarios SET correo_electronico=?, contrasena=?, nombre=?, apellido_paterno=?,
                     apellido_materno=?, telefono_movil=?, activo=? WHERE id_usuario=?',
                    undef, $correo, sha256_hex($contrasena_plana), $nombre, $apellido_paterno,
                    $apellido_materno, $telefono, $activo, $id,
                );
            } else {
                $dbh->do(
                    'UPDATE usuarios SET correo_electronico=?, nombre=?, apellido_paterno=?,
                     apellido_materno=?, telefono_movil=?, activo=? WHERE id_usuario=?',
                    undef, $correo, $nombre, $apellido_paterno, $apellido_materno, $telefono, $activo, $id,
                );
            }
            registrar(dbh => $dbh, id_usuario => $id_usuario, accion => 'EDICION',
                      clave_modulo => 'GESTION_USUARIOS', id_registro_afectado => $id,
                      detalles => "Edición de usuario: $correo", ip => $cgi->remote_addr);
        } else {
            # --- alta ---
            $dbh->do(
                'INSERT INTO usuarios (correo_electronico, contrasena, nombre, apellido_paterno,
                    apellido_materno, telefono_movil, tipo_usuario, id_asociacion, activo)
                 VALUES (?,?,?,?,?,?,?,?,?)',
                undef, $correo, sha256_hex($contrasena_plana), $nombre, $apellido_paterno,
                $apellido_materno, $telefono, $tipo_usuario, $id_asociacion_final, $activo,
            );
            my $nuevo_id = $dbh->last_insert_id(undef, undef, 'usuarios', undef);

            asignar_permisos_por_defecto($dbh, $nuevo_id, $tipo_usuario);

            registrar(dbh => $dbh, id_usuario => $id_usuario, accion => 'CREACION_USUARIO',
                      clave_modulo => 'GESTION_USUARIOS', id_registro_afectado => $nuevo_id,
                      detalles => "Alta de usuario: $correo ($tipo_usuario)", ip => $cgi->remote_addr);
        }
        print $cgi->redirect('usuarios.pl');
        exit;
    }
    $accion = $cgi->param('id_usuario') ? 'editar' : 'nuevo';
}

# --- Paso 5: vista ---
print encabezado(titulo => 'Gestión de Usuarios',
                  usuario_nombre => obtener_texto_sesion($session, 'nombre'), rol => $session->param('rol'),
                  dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'GESTION_USUARIOS');

if (@errores) {
    print '<div class="alert alert-danger"><ul class="mb-0">';
    print "<li>$_</li>" for @errores;
    print '</ul></div>';
}

if ($accion eq 'nuevo' || $accion eq 'editar') {
    mostrar_formulario($dbh, $cgi, \@roles_creables, $rol_sesion);
} else {
    mostrar_listado($dbh, $puede_escribir, $rol_sesion, $id_asociacion_sesion);
}

print pie_pagina();

# ============================================================
# Funciones
# ============================================================

# Permisos "de fábrica" al crear un usuario, siguiendo el mismo
# criterio que ya usamos en los datos de prueba del SQL. Quedan
# editables después desde permisos.pl (Paso 6 del manual).
sub asignar_permisos_por_defecto {
    my ($dbh, $id_usuario_nuevo, $tipo_usuario) = @_;

    my %reglas_por_modulo = (
        FUNCIONARIO_IEEQ => {
            VERIFICACION_AFILIACIONES => 'ESCRITURA',
            CEDULAS_AFILIACION        => 'ESCRITURA',
            GESTION_USUARIOS          => 'NINGUNO',
            GESTION_PERMISOS          => 'NINGUNO',
            REGISTRO_AFILIACIONES     => 'NINGUNO', # el manual: "sin alta ni edición de afiliaciones"
            _default                  => 'LECTURA',
        },
        ADMIN_ASOCIACION => {
            GESTION_PERMISOS          => 'NINGUNO',
            PADRON_ELECTORAL          => 'LECTURA',
            VERIFICACION_AFILIACIONES => 'NINGUNO',
            _default                  => 'ESCRITURA',
        },
        AUXILIAR => {
            REGISTRO_AFILIACIONES => 'ESCRITURA',
            CONSULTA_AFILIACIONES => 'LECTURA',
            _default               => 'NINGUNO',
        },
    );
    my $reglas = $reglas_por_modulo{$tipo_usuario} or return;

    my $sth_modulos = $dbh->prepare('SELECT id_modulo, clave FROM modulos_sistema');
    $sth_modulos->execute;
    my $sth_insertar = $dbh->prepare('INSERT INTO permisos_usuario (id_usuario, id_modulo, nivel) VALUES (?,?,?)');

    while (my ($id_modulo, $clave) = $sth_modulos->fetchrow_array) {
        my $nivel = $reglas->{$clave} // $reglas->{_default};
        $sth_insertar->execute($id_usuario_nuevo, $id_modulo, $nivel);
    }
}

sub mostrar_listado {
    my ($dbh, $puede_escribir, $rol_sesion, $id_asociacion_sesion) = @_;

    my $sql = 'SELECT u.*, ap.nombre AS asociacion_nombre
               FROM usuarios u
               LEFT JOIN asociaciones_politicas ap ON ap.id_asociacion = u.id_asociacion';
    my @params;

    # Un Admin de Asociación solo ve a SUS auxiliares, no a todo el sistema.
    if ($rol_sesion eq 'ADMIN_ASOCIACION') {
        $sql .= ' WHERE u.id_asociacion = ? AND u.tipo_usuario = "AUXILIAR"';
        @params = ($id_asociacion_sesion);
    } else {
        # SUPERADMIN ve los usuarios que él mismo puede crear (no a otros SUPERADMIN)
        $sql .= ' WHERE u.tipo_usuario IN ("ADMIN_ASOCIACION","FUNCIONARIO_IEEQ")';
    }
    $sql .= ' ORDER BY u.tipo_usuario, u.nombre';

    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);

    print '<div class="d-flex justify-content-between align-items-center mb-3">';
    print '<h5 class="mb-0">Usuarios registrados</h5>';
    print '<a href="usuarios.pl?accion=nuevo" class="btn btn-primary"><i class="bi bi-person-plus me-1"></i>Nuevo usuario</a>' if $puede_escribir;
    print '</div>';

    print '<div class="card border-0 shadow-sm"><div class="card-body p-0">';
    print '<table class="table table-hover mb-0"><thead><tr>
             <th class="ps-3">Nombre</th><th>Correo</th><th>Rol</th><th>Asociación</th><th>Estatus</th><th></th>
           </tr></thead><tbody>';
    while (my $u = $sth->fetchrow_hashref) {
        my $color = $u->{activo} ? 'success' : 'secondary';
        my $estatus_txt = $u->{activo} ? 'Activo' : 'Inactivo';
        my $asociacion = $u->{asociacion_nombre} // '—';
        my $celda_accion = $puede_escribir
            ? qq(<a href="usuarios.pl?accion=editar&id=$u->{id_usuario}" class="btn btn-sm btn-outline-secondary">Editar</a>)
            : '';
        print qq(
          <tr>
            <td class="ps-3">$u->{nombre} $u->{apellido_paterno}</td>
            <td>$u->{correo_electronico}</td>
            <td><span class="badge bg-secondary-subtle text-secondary-emphasis">$u->{tipo_usuario}</span></td>
            <td>$asociacion</td>
            <td><span class="badge bg-$color-subtle text-$color-emphasis">$estatus_txt</span></td>
            <td>$celda_accion</td>
          </tr>
        );
    }
    print '</tbody></table></div></div>';
}

sub mostrar_formulario {
    my ($dbh, $cgi, $roles_creables, $rol_sesion) = @_;
    my $id = $cgi->param('id') || $cgi->param('id_usuario');
    my $u = {};
    if ($id) {
        my $sth = $dbh->prepare('SELECT * FROM usuarios WHERE id_usuario=?');
        $sth->execute($id);
        $u = $sth->fetchrow_hashref;
    }

    # <select> de rol: solo lo que este creador puede asignar
    my $opciones_rol = '';
    for my $r (@$roles_creables) {
        my $sel = ($u->{tipo_usuario} && $u->{tipo_usuario} eq $r) ? 'selected' : '';
        $opciones_rol .= qq(<option value="$r" $sel>$r</option>);
    }

    # <select> de asociación: solo se muestra si el creador es SUPERADMIN
    # (un Admin de Asociación nunca elige, siempre es la suya propia)
    my $selector_asociacion = '';
    if ($rol_sesion eq 'SUPERADMIN') {
        my $sth = $dbh->prepare('SELECT id_asociacion, nombre FROM asociaciones_politicas ORDER BY nombre');
        $sth->execute;
        my $opciones = '';
        while (my ($id_a, $nombre_a) = $sth->fetchrow_array) {
            my $sel = ($u->{id_asociacion} && $u->{id_asociacion} == $id_a) ? 'selected' : '';
            $opciones .= qq(<option value="$id_a" $sel>$nombre_a</option>);
        }
        $selector_asociacion = qq(
        <div class="col-md-6" id="grupo_asociacion">
          <label class="form-label">Asociación (solo aplica para Admin de Asociación)</label>
          <select class="form-select" name="id_asociacion"><option value="">—</option>$opciones</select>
        </div>);
    }

    my $activo_checked = (!$id || $u->{activo}) ? 'checked' : '';
    my $nota_password = $id ? '<small class="text-muted">Deja en blanco para no cambiar la contraseña actual.</small>' : '';

    print qq(
    <h5 class="mb-3">@{[ $id ? 'Editar' : 'Nuevo' ]} usuario</h5>
    <div class="card border-0 shadow-sm"><div class="card-body">
    <form method="post" action="usuarios.pl">
      <input type="hidden" name="accion" value="guardar">
      <input type="hidden" name="id_usuario" value="@{[ $id // '' ]}">
      <div class="row g-3">
        <div class="col-md-6">
          <label class="form-label">Correo electrónico</label>
          <input class="form-control" type="email" name="correo_electronico" value="@{[ $u->{correo_electronico} // '' ]}" required>
        </div>
        <div class="col-md-6">
          <label class="form-label">Contraseña</label>
          <input class="form-control" type="password" name="contrasena">
          $nota_password
        </div>
        <div class="col-md-4">
          <label class="form-label">Nombre</label>
          <input class="form-control" name="nombre" value="@{[ $u->{nombre} // '' ]}" required>
        </div>
        <div class="col-md-4">
          <label class="form-label">Apellido paterno</label>
          <input class="form-control" name="apellido_paterno" value="@{[ $u->{apellido_paterno} // '' ]}" required>
        </div>
        <div class="col-md-4">
          <label class="form-label">Apellido materno</label>
          <input class="form-control" name="apellido_materno" value="@{[ $u->{apellido_materno} // '' ]}">
        </div>
        <div class="col-md-6">
          <label class="form-label">Teléfono móvil</label>
          <input class="form-control" name="telefono_movil" value="@{[ $u->{telefono_movil} // '' ]}">
        </div>
        <div class="col-md-6">
          <label class="form-label">Rol</label>
          <select class="form-select" name="tipo_usuario" required>$opciones_rol</select>
        </div>
        $selector_asociacion
        <div class="col-md-6 d-flex align-items-end">
          <div class="form-check">
            <input class="form-check-input" type="checkbox" name="activo" value="1" id="activo" $activo_checked>
            <label class="form-check-label" for="activo">Cuenta activa</label>
          </div>
        </div>
      </div>
      <div class="mt-4">
        <button type="submit" class="btn btn-primary">Guardar</button>
        <a href="usuarios.pl" class="btn btn-secondary">Cancelar</a>
      </div>
    </form>
    </div></div>
    );
}

sub trim {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}
