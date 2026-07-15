#!/usr/bin/perl
# ============================================================
# afiliaciones_verificar.pl — Verificación de Afiliaciones
# (manual, sección 5 "Verificación de afiliaciones" y Fase 4,
# paso 10 del flujo operativo completo).
#
# Rol responsable: Funcionariado IEEQ (tabla de roles, sección
# 2 del manual: "Lectura global. Generación de cédulas. Sin
# alta ni edición de afiliaciones" + permiso de escritura
# específico en este módulo para poder decidir).
#
# Dos pantallas en un solo script (mismo patrón ya usado):
#   - accion=listar  (default): cola de pendientes (Nueva y
#     En revisión), de TODO el sistema, sin filtrar por
#     asociación — el Funcionariado ve todo.
#   - accion=revisar&id=N: detalle + formulario de decisión.
#     La decisión real la ejecuta sp_verificar_afiliacion, que
#     ya se encarga de actualizar el estatus Y registrar la
#     verificación en una sola transacción (ver el .sql).
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

unless (tiene_permiso($dbh, $id_usuario, 'VERIFICACION_AFILIACIONES', 'LECTURA')) {
    print $cgi->header(-charset => 'utf-8', -status => '403 Forbidden');
    print "Acceso no autorizado a este módulo.";
    exit;
}
my $puede_decidir = tiene_permiso($dbh, $id_usuario, 'VERIFICACION_AFILIACIONES', 'ESCRITURA');

my $accion = $cgi->param('accion') // 'listar';
my @errores;
my $decidido_ok = 0;

# --- procesar una decisión ---
if ($accion eq 'decidir' && $cgi->request_method eq 'POST') {
    unless ($puede_decidir) {
        print $cgi->header(-charset => 'utf-8', -status => '403 Forbidden');
        print "No tienes permiso para verificar afiliaciones.";
        exit;
    }
    my $id = $cgi->param('id');
    my $decision = $cgi->param('decision') // '';
    my $observaciones = trim($cgi->param('observaciones'));

    unless (grep { $_ eq $decision } qw(APROBADO RECHAZADO)) {
        push @errores, 'Decisión no válida.';
    }

    if (!@errores) {
        eval {
            $dbh->do('CALL sp_verificar_afiliacion(?,?,?,?)', undef, $id, $id_usuario, $decision, $observaciones);
        };
        if ($@) {
            push @errores, 'No se pudo registrar la verificación. Puede que el registro ya no esté en estatus "En revisión".';
        } else {
            $decidido_ok = 1;
            $accion = 'listar'; # después de decidir, regresa a la cola
        }
    }
}

print encabezado(titulo => 'Verificación de Afiliaciones',
                  usuario_nombre => obtener_texto_sesion($session, 'nombre'), rol => $rol,
                  dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'VERIFICACION_AFILIACIONES');

if ($decidido_ok) {
    print '<div class="alert alert-success">Decisión registrada correctamente.</div>';
}
if (@errores) {
    print '<div class="alert alert-danger">';
    print "$_<br>" for @errores;
    print '</div>';
}

if ($accion eq 'revisar' && $cgi->param('id')) {
    mostrar_pantalla_decision($dbh, $cgi->param('id'), $puede_decidir);
} else {
    mostrar_cola_pendientes($dbh);
}

print pie_pagina();

# ============================================================
sub mostrar_cola_pendientes {
    my ($dbh) = @_;
    my $sth = $dbh->prepare(
        'SELECT a.id_afiliacion,
             CONCAT(a.nombre, " ", a.apellido_paterno, IFNULL(CONCAT(" ", a.apellido_materno), "")) AS nombre_completo,
             a.clave_elector, a.estatus, a.fecha_hora_afiliacion,
             m.nombre AS municipio, ap.nombre AS asociacion
         FROM afiliaciones a
         JOIN municipios m ON m.id_municipio = a.id_municipio_afiliacion
         JOIN usuarios u ON u.id_usuario = a.id_registrador
         JOIN asociaciones_politicas ap ON ap.id_asociacion = u.id_asociacion
         WHERE a.fecha_eliminacion IS NULL AND a.estatus = "EN_REVISION"
         ORDER BY a.fecha_hora_afiliacion ASC' # las más antiguas primero: cola FIFO
    );
    $sth->execute;

    print '<p class="text-muted">Afiliaciones pendientes de verificar contra el padrón electoral del estado.</p>';
    print '<div class="card border-0 shadow-sm"><div class="card-body p-0">';
    print '<table class="table table-hover align-middle mb-0"><thead><tr>
             <th class="ps-3">Nombre</th><th>Clave de elector</th><th>Asociación</th><th>Municipio</th>
             <th>Fecha</th><th>Estatus</th><th class="text-end pe-3">Acción</th>
           </tr></thead><tbody>';

    my %color_estatus = (EN_REVISION => 'warning');
    my $filas = 0;
    while (my $r = $sth->fetchrow_hashref) {
        $filas++;
        my $color = $color_estatus{ $r->{estatus} } // 'secondary';
        print qq(
        <tr>
          <td class="ps-3">$r->{nombre_completo}</td>
          <td class="font-monospace small">@{[ $r->{clave_elector} // '—' ]}</td>
          <td>$r->{asociacion}</td>
          <td>$r->{municipio}</td>
          <td>$r->{fecha_hora_afiliacion}</td>
          <td><span class="badge bg-$color-subtle text-$color-emphasis">$r->{estatus}</span></td>
          <td class="text-end pe-3">
            <a href="afiliaciones_verificar.pl?accion=revisar&id=$r->{id_afiliacion}" class="btn btn-sm btn-primary">Revisar</a>
          </td>
        </tr>
        );
    }
    if ($filas == 0) {
        print '<tr><td colspan="7" class="text-center text-muted py-4">No hay afiliaciones pendientes.</td></tr>';
    }
    print '</tbody></table></div></div>';
}

sub mostrar_pantalla_decision {
    my ($dbh, $id, $puede_decidir) = @_;
    my $sth = $dbh->prepare(
        'SELECT a.*, m.nombre AS municipio, ap.nombre AS asociacion,
             CONCAT(u.nombre, " ", u.apellido_paterno) AS registrador
         FROM afiliaciones a
         JOIN municipios m ON m.id_municipio = a.id_municipio_afiliacion
         JOIN usuarios u ON u.id_usuario = a.id_registrador
         JOIN asociaciones_politicas ap ON ap.id_asociacion = u.id_asociacion
         WHERE a.id_afiliacion = ? AND a.fecha_eliminacion IS NULL'
    );
    $sth->execute($id);
    my $r = $sth->fetchrow_hashref;
    unless ($r) {
        print '<div class="alert alert-danger">Registro no encontrado.</div>';
        return;
    }

    print qq(
    <div class="row g-3">
      <div class="col-md-7">
        <div class="card border-0 shadow-sm"><div class="card-body">
          <h5 class="mb-3">$r->{nombre} $r->{apellido_paterno} @{[ $r->{apellido_materno} // '' ]}</h5>
          <table class="table table-sm mb-0">
            <tr><td class="text-muted">Clave de elector</td><td>@{[ $r->{clave_elector} // '—' ]}</td></tr>
            <tr><td class="text-muted">OCR / CIC</td><td>@{[ $r->{ocr} // '—' ]} / @{[ $r->{cic} // '—' ]}</td></tr>
            <tr><td class="text-muted">Domicilio</td><td>@{[ $r->{domicilio_calle} // '—' ]} @{[ $r->{domicilio_numero} // '' ]}, @{[ $r->{domicilio_colonia} // '' ]}, @{[ $r->{domicilio_municipio} // '' ]}</td></tr>
            <tr><td class="text-muted">Municipio de afiliación</td><td>$r->{municipio}</td></tr>
            <tr><td class="text-muted">Asociación</td><td>$r->{asociacion}</td></tr>
            <tr><td class="text-muted">Registrado por</td><td>$r->{registrador}</td></tr>
            <tr><td class="text-muted">Fecha de captura</td><td>$r->{fecha_hora_afiliacion}</td></tr>
          </table>
        </div></div>

        <div class="card border-0 shadow-sm mt-3"><div class="card-body">
          <h6 class="text-ieeq-primary mb-3">Evidencia fotográfica</h6>
          <div class="row g-3">
            @{[ bloque_imagen('Anverso INE', $r->{foto_anverso_ine}) ]}
            @{[ bloque_imagen('Reverso INE', $r->{foto_reverso_ine}) ]}
            @{[ bloque_imagen('Fotografía', $r->{foto_persona}) ]}
            @{[ bloque_imagen('Firma', $r->{firma}) ]}
          </div>
        </div></div>
      </div>

      <div class="col-md-5">
        <div class="card border-0 shadow-sm"><div class="card-body">
          <h6 class="mb-3">Decisión</h6>
    );

    if ($puede_decidir) {
        print qq(
          <form method="post" action="afiliaciones_verificar.pl">
            <input type="hidden" name="accion" value="decidir">
            <input type="hidden" name="id" value="$r->{id_afiliacion}">
            <div class="mb-3">
              <label class="form-label">Observaciones</label>
              <textarea class="form-control" name="observaciones" rows="3" placeholder="Notas sobre la verificación (opcional para aprobar, recomendado para rechazar)"></textarea>
            </div>
            <div class="d-grid gap-2">
              <button type="submit" name="decision" value="APROBADO" class="btn btn-success"><i class="bi bi-check-circle me-1"></i>Aprobar — localizado en padrón</button>
              <button type="submit" name="decision" value="RECHAZADO" class="btn btn-outline-danger"><i class="bi bi-x-circle me-1"></i>Rechazar — no localizado</button>
            </div>
          </form>
          <div class="small text-muted mt-3">
            Al rechazar, el registro regresa a estatus "Nueva afiliación" para que la asociación pueda corregirlo y volver a enviarlo.
          </div>
        );
    } else {
        print '<p class="text-muted">Tu cuenta no tiene permiso de escritura en este módulo, solo consulta.</p>';
    }

    print qq(
        </div></div>
        <a href="afiliaciones_verificar.pl" class="btn btn-secondary mt-3">Volver a la cola</a>
      </div>
    </div>
    );
}

sub bloque_imagen {
    my ($etiqueta, $ruta) = @_;
    return qq(<div class="col-md-3 text-center text-muted">$etiqueta<br><em>(sin archivo)</em></div>) unless $ruta;
    return qq(
    <div class="col-md-3">
      <div class="small text-muted mb-1">$etiqueta</div>
      <a href="$ruta" target="_blank"><img src="$ruta" class="img-fluid rounded-3 border" alt="$etiqueta"></a>
    </div>
    );
}

sub trim {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}
