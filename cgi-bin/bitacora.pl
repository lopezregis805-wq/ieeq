#!/usr/bin/perl
# ============================================================
# bitacora.pl — Bitácora y Auditoría (manual, sección 5.7 y
# Fase 4, paso 12: "Rol responsable: IEEQ o Administrador").
#
# Es de SOLO LECTURA: la bitácora "no puede modificarse ni
# eliminarse" (regla de negocio 8 del manual), así que este
# script ni siquiera tiene una acción de guardar.
#
# Alcance por rol:
#   - SUPERADMIN / FUNCIONARIO_IEEQ: ven toda la bitácora
#   - ADMIN_ASOCIACION: ve solo lo relacionado con su propia
#     asociación (sus auxiliares y él mismo) — no tiene por qué
#     ver la actividad de otras asociaciones
#   - AUXILIAR: sin acceso a este módulo (permiso NINGUNO)
# ============================================================
use strict;
use warnings;
use utf8;                            # el codigo fuente de este archivo esta en UTF-8
use CGI;
use lib './lib';
use DB qw(conectar);
use Auth qw(iniciar_sesion requerir_sesion tiene_permiso obtener_texto_sesion);
use Plantilla qw(encabezado pie_pagina);

my $cgi = CGI->new;
binmode(STDOUT, ":encoding(UTF-8)");
my $session = iniciar_sesion($cgi);
my $id_usuario = requerir_sesion($session, $cgi);
my $dbh = conectar();
my $rol = $session->param('rol');
my $id_asociacion = $session->param('id_asociacion');

unless (tiene_permiso($dbh, $id_usuario, 'BITACORA_AUDITORIA', 'LECTURA')) {
    print $cgi->header(-charset => 'utf-8', -status => '403 Forbidden');
    print "Acceso no autorizado a este módulo.";
    exit;
}

my $filtro_accion = $cgi->param('accion_filtro') // '';
my $desde = $cgi->param('desde') // '';
my $hasta = $cgi->param('hasta') // '';

print encabezado(titulo => 'Bitácora y Auditoría',
                  usuario_nombre => obtener_texto_sesion($session, 'nombre'), rol => $rol,
                  dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'BITACORA_AUDITORIA');

mostrar_filtros($filtro_accion, $desde, $hasta);
mostrar_bitacora($dbh, $rol, $id_asociacion, $filtro_accion, $desde, $hasta);

print pie_pagina();

# ============================================================
sub mostrar_filtros {
    my ($filtro_accion, $desde, $hasta) = @_;
    my @acciones = qw(LOGIN LOGOUT REGISTRO EDICION ELIMINACION APROBACION RECHAZO CONSULTA
                       PERMISO_ASIGNADO CREACION_USUARIO GENERACION_CEDULA);
    my $opciones = '<option value="">Todas las acciones</option>';
    for my $a (@acciones) {
        my $sel = ($filtro_accion eq $a) ? 'selected' : '';
        $opciones .= qq(<option value="$a" $sel>$a</option>);
    }

    print qq(
    <form method="get" action="bitacora.pl" class="card border-0 shadow-sm mb-4">
      <div class="card-body">
        <div class="row g-3 align-items-end">
          <div class="col-md-3">
            <label class="form-label">Tipo de acción</label>
            <select class="form-select" name="accion_filtro">$opciones</select>
          </div>
          <div class="col-md-3">
            <label class="form-label">Desde</label>
            <input class="form-control" type="date" name="desde" value="$desde">
          </div>
          <div class="col-md-3">
            <label class="form-label">Hasta</label>
            <input class="form-control" type="date" name="hasta" value="$hasta">
          </div>
          <div class="col-md-3">
            <button type="submit" class="btn btn-primary w-100"><i class="bi bi-funnel me-1"></i>Filtrar</button>
          </div>
        </div>
      </div>
    </form>
    );
}

sub mostrar_bitacora {
    my ($dbh, $rol, $id_asociacion, $filtro_accion, $desde, $hasta) = @_;

    my $sql = 'SELECT b.id_log, b.fecha, CONCAT(u.nombre, " ", u.apellido_paterno) AS usuario,
                 u.tipo_usuario, b.accion, ms.descripcion AS modulo, b.id_registro_afectado, b.detalles, b.ip_origen
               FROM bitacora b
               LEFT JOIN usuarios u ON u.id_usuario = b.id_usuario
               LEFT JOIN modulos_sistema ms ON ms.id_modulo = b.id_modulo
               WHERE 1=1';
    my @params;

    if ($rol eq 'ADMIN_ASOCIACION') {
        $sql .= ' AND u.id_asociacion = ?';
        push @params, $id_asociacion;
    }
    if (length $filtro_accion) {
        $sql .= ' AND b.accion = ?';
        push @params, $filtro_accion;
    }
    if (length $desde) {
        $sql .= ' AND b.fecha >= ?';
        push @params, "$desde 00:00:00";
    }
    if (length $hasta) {
        $sql .= ' AND b.fecha <= ?';
        push @params, "$hasta 23:59:59";
    }
    $sql .= ' ORDER BY b.fecha DESC LIMIT 200';

    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);

    my %color_accion = (
        LOGIN => 'secondary', LOGOUT => 'secondary',
        REGISTRO => 'primary', EDICION => 'warning', ELIMINACION => 'danger',
        APROBACION => 'success', RECHAZO => 'danger', CONSULTA => 'secondary',
        PERMISO_ASIGNADO => 'info', CREACION_USUARIO => 'primary', GENERACION_CEDULA => 'info',
    );

    print '<div class="card border-0 shadow-sm"><div class="card-body p-0">';
    print '<table class="table table-hover align-middle mb-0"><thead><tr>
             <th class="ps-3">Fecha</th><th>Usuario</th><th>Acción</th><th>Módulo</th><th>Detalles</th><th class="pe-3">IP</th>
           </tr></thead><tbody>';

    my $filas = 0;
    while (my $r = $sth->fetchrow_hashref) {
        $filas++;
        my $color = $color_accion{ $r->{accion} } // 'secondary';
        my $usuario = $r->{usuario} // '<span class="text-muted">(usuario eliminado)</span>';
        print qq(
        <tr>
          <td class="ps-3 text-nowrap">$r->{fecha}</td>
          <td>$usuario</td>
          <td><span class="badge bg-$color-subtle text-$color-emphasis">$r->{accion}</span></td>
          <td>@{[ $r->{modulo} // '—' ]}</td>
          <td class="small">@{[ $r->{detalles} // '—' ]}</td>
          <td class="pe-3 small text-muted">@{[ $r->{ip_origen} // '—' ]}</td>
        </tr>
        );
    }
    if ($filas == 0) {
        print '<tr><td colspan="6" class="text-center text-muted py-4">No hay registros con estos filtros.</td></tr>';
    }
    print '</tbody></table></div></div>';

    print '<p class="text-muted small mt-2">Mostrando los 200 registros más recientes que coinciden con el filtro.</p>' if $filas == 200;
}
