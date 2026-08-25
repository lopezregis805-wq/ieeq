#!/usr/bin/perl
# ============================================================
# afiliaciones_verificar.pl — Verificación de Afiliaciones.
#
# Rol responsable: Admin de Asociación — valida (o rechaza) las
# afiliaciones de SU PROPIA asociación que estén en Revisión APE.
# SUPERADMIN tiene lectura de todo el sistema para supervisión,
# pero nunca puede decidir (control del sistema, no del proceso).
#
# Dos pantallas en un solo script (mismo patrón ya usado):
#   - accion=listar  (default): cola de pendientes en Revisión
#     APE, paginada; el Admin de Asociación solo ve la suya,
#     SUPERADMIN ve todo el sistema.
#   - accion=revisar&id=N: detalle + formulario de decisión.
#     La decisión real la ejecuta sp_verificar_afiliacion, que
#     ya se encarga de validar que sea de la propia asociación,
#     actualizar el estatus y registrar la verificación en una
#     sola transacción (ver el .sql).
# ============================================================
use strict;
use warnings;
use utf8;                            # el codigo fuente de este archivo esta en UTF-8
use CGI;
use lib './lib';
use DB qw(conectar);
use Auth qw(iniciar_sesion requerir_sesion tiene_permiso obtener_texto_sesion);
use Plantilla qw(encabezado pie_pagina denegar_acceso paginacion);
use Exportar qw(exportar_xlsx);

my $POR_PAGINA = 20;

my $cgi = CGI->new;
binmode(STDOUT, ":encoding(UTF-8)");
my $session = iniciar_sesion($cgi);
my $id_usuario = requerir_sesion($session, $cgi);
my $dbh = conectar();
my $rol = $session->param('rol');
my $id_asociacion = $session->param('id_asociacion');

unless (tiene_permiso($dbh, $id_usuario, 'VERIFICACION_AFILIACIONES', 'LECTURA')) {
    denegar_acceso(titulo => 'Verificación de Afiliaciones', usuario_nombre => obtener_texto_sesion($session, 'nombre'),
                    rol => $rol, dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'VERIFICACION_AFILIACIONES',
                    mensaje => 'Acceso no autorizado a este módulo.');
    exit;
}
my $puede_decidir = tiene_permiso($dbh, $id_usuario, 'VERIFICACION_AFILIACIONES', 'ESCRITURA');

my $accion = $cgi->param('accion') // 'listar';
my @errores;
my $decidido_ok = 0;

if ($accion eq 'exportar') {
    exportar_excel($dbh, $rol, $id_asociacion);
    exit;
}

# --- procesar una decisión ---
if ($accion eq 'decidir' && $cgi->request_method eq 'POST') {
    unless ($puede_decidir) {
        denegar_acceso(titulo => 'Verificación de Afiliaciones', usuario_nombre => obtener_texto_sesion($session, 'nombre'),
                        rol => $rol, dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'VERIFICACION_AFILIACIONES',
                        mensaje => 'No tienes permiso para verificar afiliaciones.');
        exit;
    }
    my $id = $cgi->param('id');
    my $decision = $cgi->param('decision') // '';
    my $observaciones = trim($cgi->param('observaciones'));

    unless (grep { $_ eq $decision } qw(APROBADO RECHAZADO)) {
        push @errores, 'Decisión no válida.';
    }
    if ($decision eq 'RECHAZADO' && !length($observaciones)) {
        push @errores, 'Las observaciones son obligatorias al rechazar una afiliación: la asociación las necesita para saber qué corregir.';
    }

    if (!@errores) {
        eval {
            $dbh->do('CALL sp_verificar_afiliacion(?,?,?,?)', undef, $id, $id_usuario, $decision, $observaciones);
        };
        if ($@) {
            push @errores, 'No se pudo registrar la verificación. Puede que el registro ya no esté en estatus "Revisión APE" o no sea de tu asociación.';
        } else {
            $decidido_ok = 1;
            $accion = 'listar'; # después de decidir, regresa a la cola
        }
    }
}

my $pagina = int($cgi->param('pagina') // 1);
$pagina = 1 if $pagina < 1;

print encabezado(titulo => 'Verificación de Afiliaciones',
                  usuario_nombre => obtener_texto_sesion($session, 'nombre'), rol => $rol,
                  dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'VERIFICACION_AFILIACIONES');

if ($decidido_ok) {
    print '<div class="alert alert-success">Decisión registrada correctamente.</div>';
}
if (@errores) {
    print '<div class="alert alert-danger"><ul class="mb-0">';
    print "<li>$_</li>" for @errores;
    print '</ul></div>';
}

if (($accion eq 'revisar' || ($accion eq 'decidir' && @errores)) && $cgi->param('id')) {
    mostrar_pantalla_decision($dbh, $cgi->param('id'), $rol, $id_asociacion, $puede_decidir);
} else {
    mostrar_cola_pendientes($dbh, $rol, $id_asociacion, $pagina);
}

print pie_pagina();

# ============================================================
# Alcance por rol: el Admin de Asociación solo ve la cola de SU
# propia asociación; SUPERADMIN ve todo el sistema (solo consulta,
# nunca decide — $puede_decidir ya lo bloquea aparte).
# ============================================================
sub alcance_por_rol {
    my ($rol, $id_asociacion) = @_;
    return ('u.id_asociacion = ?', [$id_asociacion]) if $rol eq 'ADMIN_ASOCIACION';
    return ('1=1', []); # SUPERADMIN
}

sub mostrar_cola_pendientes {
    my ($dbh, $rol, $id_asociacion, $pagina) = @_;
    my ($condicion_alcance, $params_alcance) = alcance_por_rol($rol, $id_asociacion);
    my $where = "a.fecha_eliminacion IS NULL AND a.estatus = 'REVISION_APE' AND $condicion_alcance";

    my $sth_total = $dbh->prepare("SELECT COUNT(*) FROM afiliaciones a JOIN usuarios u ON u.id_usuario = a.id_registrador WHERE $where");
    $sth_total->execute(@$params_alcance);
    my ($total_filas) = $sth_total->fetchrow_array;
    my $total_paginas = $total_filas ? int(($total_filas + $POR_PAGINA - 1) / $POR_PAGINA) : 1;
    $pagina = $total_paginas if $pagina > $total_paginas;
    my $offset = ($pagina - 1) * $POR_PAGINA;

    my $sth = $dbh->prepare(
        "SELECT a.id_afiliacion,
             CONCAT(a.nombre, ' ', a.apellido_paterno, IFNULL(CONCAT(' ', a.apellido_materno), '')) AS nombre_completo,
             a.clave_elector, a.estatus, a.fecha_hora_afiliacion,
             m.nombre AS municipio, ap.nombre AS asociacion
         FROM afiliaciones a
         JOIN municipios m ON m.id_municipio = a.id_municipio_afiliacion
         JOIN usuarios u ON u.id_usuario = a.id_registrador
         JOIN asociaciones_politicas ap ON ap.id_asociacion = u.id_asociacion
         WHERE $where
         ORDER BY a.fecha_hora_afiliacion ASC
         LIMIT $POR_PAGINA OFFSET $offset" # las más antiguas primero: cola FIFO
    );
    $sth->execute(@$params_alcance);

    print '<div class="d-flex justify-content-between align-items-center mb-2">';
    print '<p class="text-muted mb-0">Afiliaciones pendientes de validar.</p>';
    print '<a href="afiliaciones_verificar.pl?accion=exportar" class="btn btn-sm btn-outline-success"><i class="bi bi-file-earmark-excel me-1"></i>Descargar Excel</a>';
    print '</div>';
    print '<div class="card border-0 shadow-sm"><div class="card-body p-0">';
    print '<table class="table table-hover align-middle mb-0"><thead><tr>
             <th class="ps-3">Nombre</th><th>Clave de elector</th><th>Asociación</th><th>Municipio</th>
             <th>Fecha</th><th>Estatus</th><th class="text-end pe-3">Acción</th>
           </tr></thead><tbody>';

    my $filas = 0;
    while (my $r = $sth->fetchrow_hashref) {
        $filas++;
        print qq(
        <tr>
          <td class="ps-3">$r->{nombre_completo}</td>
          <td class="font-monospace small">@{[ $r->{clave_elector} // '—' ]}</td>
          <td>$r->{asociacion}</td>
          <td>$r->{municipio}</td>
          <td>$r->{fecha_hora_afiliacion}</td>
          <td><span class="badge bg-warning-subtle text-warning-emphasis">Revisión APE</span></td>
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
    print paginacion(pagina_actual => $pagina, total_paginas => $total_paginas, total_filas => $total_filas, por_pagina => $POR_PAGINA, base_url => 'afiliaciones_verificar.pl');
}

sub mostrar_pantalla_decision {
    my ($dbh, $id, $rol, $id_asociacion, $puede_decidir) = @_;
    my $sth = $dbh->prepare(
        'SELECT a.*, m.nombre AS municipio, ap.nombre AS asociacion, u.id_asociacion AS id_asociacion_registrador,
             CONCAT(u.nombre, " ", u.apellido_paterno) AS registrador
         FROM afiliaciones a
         JOIN municipios m ON m.id_municipio = a.id_municipio_afiliacion
         JOIN usuarios u ON u.id_usuario = a.id_registrador
         JOIN asociaciones_politicas ap ON ap.id_asociacion = u.id_asociacion
         WHERE a.id_afiliacion = ? AND a.fecha_eliminacion IS NULL'
    );
    $sth->execute($id);
    my $r = $sth->fetchrow_hashref;

    # un Admin de Asociación no puede ni ver el detalle de una afiliación
    # de otra asociación adivinando el id — mismo alcance que la cola.
    my $autorizado = $r && ($rol ne 'ADMIN_ASOCIACION' || $r->{id_asociacion_registrador} == $id_asociacion);
    unless ($autorizado) {
        print '<div class="alert alert-danger">Registro no encontrado o no autorizado.</div>';
        mostrar_cola_pendientes($dbh, $rol, $id_asociacion, 1);
        return;
    }

    print qq(
    <div class="row g-3">
      <div class="col-md-7">
        <div class="card border-0 shadow-sm"><div class="card-body">
          <h5 class="mb-3">$r->{nombre} $r->{apellido_paterno} @{[ $r->{apellido_materno} // '' ]}</h5>
          <table class="table table-sm mb-0">
            <tr><td class="text-muted">Clave de elector</td><td>@{[ $r->{clave_elector} // '—' ]}</td></tr>
            <tr><td class="text-muted">OCR</td><td>@{[ $r->{ocr} // '—' ]}</td></tr>
            <tr><td class="text-muted">Domicilio</td><td>@{[ $r->{domicilio_calle} // '—' ]} @{[ $r->{domicilio_numero} // '' ]}@{[ $r->{domicilio_numero_interior} ? " Int. $r->{domicilio_numero_interior}" : '' ]}, @{[ $r->{domicilio_colonia} // '' ]}, @{[ $r->{domicilio_municipio} // '' ]}</td></tr>
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
        my $observaciones_previas = $cgi->escapeHTML($cgi->param('observaciones') // '');
        print qq(
          <form id="form_decision" method="post" action="afiliaciones_verificar.pl">
            <input type="hidden" name="accion" value="decidir">
            <input type="hidden" name="id" value="$r->{id_afiliacion}">
            <div class="mb-3">
              <label class="form-label">Observaciones</label>
              <textarea id="campo_observaciones" class="form-control" name="observaciones" rows="3" placeholder="Notas sobre la verificación (opcional para aprobar, obligatorio para rechazar)">$observaciones_previas</textarea>
              <div class="invalid-feedback d-block d-none" id="error_observaciones">Las observaciones son obligatorias al rechazar una afiliación.</div>
            </div>
            <div class="d-grid gap-2">
              <button type="submit" name="decision" value="APROBADO" class="btn btn-success"><i class="bi bi-check-circle me-1"></i>Aprobar — enviar a Compulsa IEEQ</button>
              <button type="submit" name="decision" value="RECHAZADO" id="btn_rechazar" class="btn btn-outline-danger"><i class="bi bi-x-circle me-1"></i>Rechazar — hay errores que corregir</button>
            </div>
          </form>
          <div class="small text-muted mt-3">
            Al rechazar, el registro queda en estatus "Rechazada" para que se corrija y se vuelva a enviar a revisión.
          </div>
          <script>
            (function() {
              var boton = document.getElementById('btn_rechazar');
              var campo = document.getElementById('campo_observaciones');
              var error = document.getElementById('error_observaciones');
              boton.addEventListener('click', function(ev) {
                if (!campo.value.trim()) {
                  ev.preventDefault();
                  error.classList.remove('d-none');
                  campo.classList.add('is-invalid');
                  campo.focus();
                }
              });
              campo.addEventListener('input', function() {
                error.classList.add('d-none');
                campo.classList.remove('is-invalid');
              });
            })();
          </script>
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

# --- descarga en Excel: todos los datos capturados, sin imágenes ---
sub exportar_excel {
    my ($dbh, $rol, $id_asociacion) = @_;
    my ($condicion_alcance, $params_alcance) = alcance_por_rol($rol, $id_asociacion);
    my $where = "a.fecha_eliminacion IS NULL AND a.estatus = 'REVISION_APE' AND $condicion_alcance";

    my $sth = $dbh->prepare(
        "SELECT a.nombre, a.apellido_paterno, a.apellido_materno,
             a.domicilio_calle, a.domicilio_numero, a.domicilio_numero_interior, a.domicilio_colonia,
             a.domicilio_municipio, a.domicilio_estado, a.domicilio_cp,
             a.clave_elector, a.ocr, a.fecha_hora_afiliacion,
             m.nombre AS municipio, ap.nombre AS asociacion,
             CONCAT(u.nombre, ' ', u.apellido_paterno) AS registrador
         FROM afiliaciones a
         JOIN municipios m ON m.id_municipio = a.id_municipio_afiliacion
         JOIN usuarios u ON u.id_usuario = a.id_registrador
         JOIN asociaciones_politicas ap ON ap.id_asociacion = u.id_asociacion
         WHERE $where
         ORDER BY a.fecha_hora_afiliacion ASC"
    );
    $sth->execute(@$params_alcance);

    my @encabezados = (
        'Nombre', 'Apellido paterno', 'Apellido materno',
        'Calle', 'Número exterior', 'Número interior', 'Colonia',
        'Municipio (domicilio)', 'Estado', 'Código postal',
        'Clave de elector', 'OCR', 'Fecha de captura',
        'Municipio de afiliación', 'Asociación', 'Registrador',
    );
    my @filas;
    while (my $r = $sth->fetchrow_hashref) {
        push @filas, [
            $r->{nombre}, $r->{apellido_paterno}, $r->{apellido_materno},
            $r->{domicilio_calle}, $r->{domicilio_numero}, $r->{domicilio_numero_interior}, $r->{domicilio_colonia},
            $r->{domicilio_municipio}, $r->{domicilio_estado}, $r->{domicilio_cp},
            $r->{clave_elector}, $r->{ocr}, $r->{fecha_hora_afiliacion},
            $r->{municipio}, $r->{asociacion}, $r->{registrador},
        ];
    }
    exportar_xlsx($cgi, 'verificacion_afiliaciones.xlsx', \@encabezados, \@filas);
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
