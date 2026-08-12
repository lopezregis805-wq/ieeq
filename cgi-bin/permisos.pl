#!/usr/bin/perl
# ============================================================
# permisos.pl — Gestión de Permisos.
#
# Regla de negocio central:
#   - SUPERADMIN asigna permisos a ADMIN_ASOCIACION y a
#     FUNCIONARIO_IEEQ
#   - ADMIN_ASOCIACION asigna permisos, pero SOLO a sus propios
#     AUXILIARES, y no puede darles acceso a Gestión de Usuarios
#     ni a Gestión de Permisos (evita que un auxiliar termine
#     con más poder del que le corresponde)
# ============================================================
use strict;
use warnings;
use utf8;                            # el codigo fuente de este archivo esta en UTF-8
use CGI;
use lib './lib';
use DB qw(conectar);
use Auth qw(iniciar_sesion requerir_sesion tiene_permiso obtener_texto_sesion);
use Bitacora qw(registrar);
use Plantilla qw(encabezado pie_pagina denegar_acceso);

my $cgi = CGI->new;
binmode(STDOUT, ":encoding(UTF-8)");
my $session = iniciar_sesion($cgi);
my $id_usuario = requerir_sesion($session, $cgi);
my $dbh = conectar();
my $rol_sesion = $session->param('rol');
my $id_asociacion_sesion = $session->param('id_asociacion');

unless (tiene_permiso($dbh, $id_usuario, 'GESTION_PERMISOS', 'LECTURA')) {
    denegar_acceso(titulo => 'Gestión de Permisos', usuario_nombre => obtener_texto_sesion($session, 'nombre'),
                    rol => $rol_sesion, dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'GESTION_PERMISOS',
                    mensaje => 'Acceso no autorizado a este módulo.');
    exit;
}
my $puede_escribir = tiene_permiso($dbh, $id_usuario, 'GESTION_PERMISOS', 'ESCRITURA');

# Módulos que un Auxiliar SÍ puede recibir, y los niveles que se
# le pueden otorgar en cada uno. Cualquier módulo que no aparezca
# aquí queda bloqueado (forzado a NINGUNO) para un Auxiliar, igual
# que ya pasaba con Gestión de Usuarios y Gestión de Permisos —
# evita que un auxiliar termine con más poder del que le corresponde.
my %niveles_permitidos_para_auxiliar = (
    REGISTRO_AFILIACIONES => [qw(ESCRITURA LECTURA NINGUNO)],
    CONSULTA_AFILIACIONES => [qw(LECTURA NINGUNO)],
);

# --- ¿puede $rol_sesion editar los permisos de $usuario_objetivo? ---
sub puede_editar_permisos_de {
    my ($rol_sesion, $id_asociacion_sesion, $usuario_objetivo) = @_;
    return 0 if $usuario_objetivo->{tipo_usuario} eq 'SUPERADMIN'; # nadie edita a un superadmin desde aquí
    return 1 if $rol_sesion eq 'SUPERADMIN';
    return 1 if $rol_sesion eq 'ADMIN_ASOCIACION'
             && $usuario_objetivo->{tipo_usuario} eq 'AUXILIAR'
             && $usuario_objetivo->{id_asociacion} == $id_asociacion_sesion;
    return 0;
}

my $id_objetivo = $cgi->param('id');

if ($cgi->request_method eq 'POST' && ($cgi->param('accion') // '') eq 'guardar') {
    guardar_permisos($dbh, $cgi, $session, $id_usuario, $rol_sesion, $id_asociacion_sesion, $puede_escribir);
    exit; # guardar_permisos ya redirige
}

print encabezado(titulo => 'Gestión de Permisos',
                  usuario_nombre => obtener_texto_sesion($session, 'nombre'), rol => $rol_sesion,
                  dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'GESTION_PERMISOS');

if ($id_objetivo) {
    mostrar_edicion($dbh, $id_objetivo, $rol_sesion, $id_asociacion_sesion, $puede_escribir);
} else {
    mostrar_listado($dbh, $rol_sesion, $id_asociacion_sesion);
}

print pie_pagina();

# ============================================================
sub mostrar_listado {
    my ($dbh, $rol_sesion, $id_asociacion_sesion) = @_;

    if ($cgi->param('guardado')) {
        my $usuario_guardado = $cgi->escapeHTML($cgi->param('usuario') // '');
        my $detalle = length($usuario_guardado) ? " de $usuario_guardado" : '';
        print qq(<div class="alert alert-success">Permisos$detalle actualizados correctamente.</div>);
    }

    my $sql = 'SELECT u.id_usuario, u.nombre, u.apellido_paterno, u.correo_electronico, u.tipo_usuario,
                      ap.nombre AS asociacion
               FROM usuarios u
               LEFT JOIN asociaciones_politicas ap ON ap.id_asociacion = u.id_asociacion
               WHERE u.tipo_usuario != "SUPERADMIN"';
    my @params;
    if ($rol_sesion eq 'ADMIN_ASOCIACION') {
        $sql .= ' AND u.tipo_usuario = "AUXILIAR" AND u.id_asociacion = ?';
        push @params, $id_asociacion_sesion;
    }
    $sql .= ' ORDER BY u.tipo_usuario, u.nombre';

    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);

    print '<p class="text-muted">Ajusta el nivel de acceso (Escritura / Lectura / Ninguno) de cada usuario, módulo por módulo.</p>';
    print '<div class="card border-0 shadow-sm"><div class="card-body p-0">';
    print '<table class="table table-hover align-middle mb-0"><thead><tr>
             <th class="ps-3">Nombre</th><th>Correo</th><th>Rol</th><th>Asociación</th><th class="text-end pe-3">Acción</th>
           </tr></thead><tbody>';

    my $filas = 0;
    while (my $u = $sth->fetchrow_hashref) {
        $filas++;
        my $asociacion = $u->{asociacion} // '—';
        print qq(
        <tr>
          <td class="ps-3">$u->{nombre} $u->{apellido_paterno}</td>
          <td>$u->{correo_electronico}</td>
          <td><span class="badge bg-secondary-subtle text-secondary-emphasis">$u->{tipo_usuario}</span></td>
          <td>$asociacion</td>
          <td class="text-end pe-3">
            <a href="permisos.pl?id=$u->{id_usuario}" class="btn btn-sm btn-outline-secondary"><i class="bi bi-shield-lock me-1"></i>Permisos</a>
          </td>
        </tr>
        );
    }
    if ($filas == 0) {
        print '<tr><td colspan="5" class="text-center text-muted py-4">No hay usuarios para gestionar.</td></tr>';
    }
    print '</tbody></table></div></div>';
}

sub mostrar_edicion {
    my ($dbh, $id_objetivo, $rol_sesion, $id_asociacion_sesion, $puede_escribir) = @_;

    my $sth = $dbh->prepare('SELECT * FROM usuarios WHERE id_usuario = ?');
    $sth->execute($id_objetivo);
    my $usuario_objetivo = $sth->fetchrow_hashref;

    unless ($usuario_objetivo && puede_editar_permisos_de($rol_sesion, $id_asociacion_sesion, $usuario_objetivo)) {
        print '<div class="alert alert-danger">No puedes gestionar los permisos de este usuario.</div>';
        mostrar_listado($dbh, $rol_sesion, $id_asociacion_sesion);
        return;
    }

    my $es_auxiliar_ajeno_bloqueo = ($usuario_objetivo->{tipo_usuario} eq 'AUXILIAR'); # aplica el bloqueo de módulos

    if ($cgi->param('error')) {
        print '<div class="alert alert-danger">No se pudieron guardar los permisos. Intenta de nuevo; si el problema continúa, avisa al administrador del sistema.</div>';
    }

    my $sth_mod = $dbh->prepare(
        'SELECT m.id_modulo, m.clave, m.descripcion, IFNULL(p.nivel, "NINGUNO") AS nivel
         FROM modulos_sistema m
         LEFT JOIN permisos_usuario p ON p.id_modulo = m.id_modulo AND p.id_usuario = ?
         ORDER BY m.orden'
    );
    $sth_mod->execute($id_objetivo);

    print qq(
    <div class="d-flex align-items-center gap-2 mb-3">
      <a href="permisos.pl" class="btn btn-sm btn-outline-secondary"><i class="bi bi-arrow-left"></i></a>
      <h5 class="mb-0">Permisos de $usuario_objetivo->{nombre} $usuario_objetivo->{apellido_paterno}</h5>
    </div>
    <p class="text-muted">$usuario_objetivo->{correo_electronico} · $usuario_objetivo->{tipo_usuario}</p>

    <div class="card border-0 shadow-sm"><div class="card-body">
    <form method="post" action="permisos.pl">
      <input type="hidden" name="accion" value="guardar">
      <input type="hidden" name="id" value="$id_objetivo">
      <table class="table table-sm">
        <thead><tr><th>Módulo</th><th style="width:280px;">Nivel de acceso</th></tr></thead>
        <tbody>
    );

    while (my $m = $sth_mod->fetchrow_hashref) {
        my $niveles_permitidos = $niveles_permitidos_para_auxiliar{ $m->{clave} };
        my $bloqueado = $es_auxiliar_ajeno_bloqueo && !$niveles_permitidos;
        my $disabled = ($puede_escribir && !$bloqueado) ? '' : 'disabled';

        print qq(<tr><td>$m->{descripcion}</td><td>);
        if ($bloqueado) {
            print qq(<span class="badge bg-secondary-subtle text-secondary-emphasis">Ninguno (no permitido para Auxiliares)</span>
                     <input type="hidden" name="nivel_$m->{id_modulo}" value="NINGUNO">);
        } else {
            my @niveles = ($es_auxiliar_ajeno_bloqueo ? @$niveles_permitidos : qw(ESCRITURA LECTURA NINGUNO));
            print qq(<select class="form-select form-select-sm" name="nivel_$m->{id_modulo}" $disabled>);
            for my $nivel (@niveles) {
                my $sel = ($m->{nivel} eq $nivel) ? 'selected' : '';
                print qq(<option value="$nivel" $sel>$nivel</option>);
            }
            print '</select>';
        }
        print '</td></tr>';
    }

    print '</tbody></table>';
    print '<button type="submit" class="btn btn-primary mt-2"><i class="bi bi-check-lg me-1"></i>Guardar permisos</button>' if $puede_escribir;
    print '</form></div></div>';
}

sub guardar_permisos {
    my ($dbh, $cgi, $session, $id_usuario, $rol_sesion, $id_asociacion_sesion, $puede_escribir) = @_;
    my $id_objetivo = $cgi->param('id');

    unless ($puede_escribir) {
        denegar_acceso(titulo => 'Gestión de Permisos', usuario_nombre => obtener_texto_sesion($session, 'nombre'),
                        rol => $rol_sesion, dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'GESTION_PERMISOS',
                        mensaje => 'No tienes permiso de escritura en este módulo.');
        return;
    }

    my $sth = $dbh->prepare('SELECT * FROM usuarios WHERE id_usuario = ?');
    $sth->execute($id_objetivo);
    my $usuario_objetivo = $sth->fetchrow_hashref;

    unless ($usuario_objetivo && puede_editar_permisos_de($rol_sesion, $id_asociacion_sesion, $usuario_objetivo)) {
        denegar_acceso(titulo => 'Gestión de Permisos', usuario_nombre => obtener_texto_sesion($session, 'nombre'),
                        rol => $rol_sesion, dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'GESTION_PERMISOS',
                        mensaje => 'No puedes gestionar los permisos de este usuario.');
        return;
    }

    my $es_auxiliar = ($usuario_objetivo->{tipo_usuario} eq 'AUXILIAR');
    my $sth_mod = $dbh->prepare('SELECT id_modulo, clave FROM modulos_sistema');
    $sth_mod->execute;
    my $sth_upsert = $dbh->prepare(
        'INSERT INTO permisos_usuario (id_usuario, id_modulo, nivel) VALUES (?,?,?)
         ON DUPLICATE KEY UPDATE nivel = VALUES(nivel)'
    );

    my $guardado_ok = eval {
        while (my ($id_modulo, $clave) = $sth_mod->fetchrow_array) {
            my $nivel = $cgi->param("nivel_$id_modulo") // 'NINGUNO';
            $nivel = 'NINGUNO' unless grep { $_ eq $nivel } qw(ESCRITURA LECTURA NINGUNO);
            # nunca confiar solo en el disabled/las opciones del HTML: se
            # vuelve a forzar aquí el nivel máximo permitido para Auxiliares
            if ($es_auxiliar) {
                my $niveles_permitidos = $niveles_permitidos_para_auxiliar{$clave};
                $nivel = 'NINGUNO' unless $niveles_permitidos && grep { $_ eq $nivel } @$niveles_permitidos;
            }
            $sth_upsert->execute($id_objetivo, $id_modulo, $nivel);
        }

        registrar(dbh => $dbh, id_usuario => $id_usuario, accion => 'PERMISO_ASIGNADO',
                  clave_modulo => 'GESTION_PERMISOS', id_registro_afectado => $id_objetivo,
                  detalles => "Permisos actualizados para $usuario_objetivo->{correo_electronico}",
                  ip => $cgi->remote_addr);
        1;
    };

    # si algo falló (ej. la base de datos rechazó un valor), se lo
    # avisamos al usuario en vez de dejar que la petición truene con un
    # error 500 sin explicación
    # al guardar con éxito se regresa al listado (con la confirmación
    # visible ahí); si algo falla, se regresa a la misma pantalla de
    # edición para que se pueda corregir e intentar de nuevo
    if ($guardado_ok) {
        my $nombre_completo = "$usuario_objetivo->{nombre} $usuario_objetivo->{apellido_paterno}";
        print $cgi->redirect("permisos.pl?guardado=1&usuario=" . $cgi->escape($nombre_completo));
    } else {
        print $cgi->redirect("permisos.pl?id=$id_objetivo&error=1");
    }
}
