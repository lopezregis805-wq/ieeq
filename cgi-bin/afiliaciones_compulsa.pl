#!/usr/bin/perl
# ============================================================
# afiliaciones_compulsa.pl — Afiliaciones para Compulsa.
#
# Muestra las afiliaciones en estatus "Compulsa IEEQ" (ya
# validadas por su asociación). El Funcionariado IEEQ selecciona
# un lote y elige una de dos acciones:
#   - "Generar compulsa": marca cada seleccionado como "Compulsa
#     INE" y entrega, en la misma respuesta, un archivo Excel con
#     todos los datos capturados del lote (sin imágenes).
#   - "Regresar a la asociación": si detecta algo incorrecto antes
#     de mandarlo al INE, regresa el seleccionado a "Revisión APE"
#     (sp_regresar_a_revision) para que la asociación lo subsane,
#     en vez de incluirlo en la compulsa.
# SUPERADMIN solo consulta (LECTURA): ve la tabla y puede descargar
# el Excel de lo que hay, pero no ejecuta ninguna de las dos acciones.
# ============================================================
use strict;
use warnings;
use utf8;                            # el codigo fuente de este archivo esta en UTF-8
use CGI;
use lib './lib';
use DB qw(conectar);
use Auth qw(iniciar_sesion requerir_sesion tiene_permiso obtener_texto_sesion);
use Bitacora qw(registrar);
use Plantilla qw(encabezado pie_pagina denegar_acceso paginacion);
use Exportar qw(exportar_xlsx);

my $POR_PAGINA = 20;

my $cgi = CGI->new;
binmode(STDOUT, ":encoding(UTF-8)");
my $session = iniciar_sesion($cgi);
my $id_usuario = requerir_sesion($session, $cgi);
my $dbh = conectar();
my $rol = $session->param('rol');

unless (tiene_permiso($dbh, $id_usuario, 'COMPULSA_AFILIACIONES', 'LECTURA')) {
    denegar_acceso(titulo => 'Para Compulsa', usuario_nombre => obtener_texto_sesion($session, 'nombre'),
                    rol => $rol, dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'COMPULSA_AFILIACIONES',
                    mensaje => 'Acceso no autorizado a este módulo.');
    exit;
}
my $puede_generar = tiene_permiso($dbh, $id_usuario, 'COMPULSA_AFILIACIONES', 'ESCRITURA');

my $accion = $cgi->param('accion') // '';

if ($accion eq 'exportar') {
    exportar_excel($dbh, [obtener_ids_compulsa_ieeq($dbh)]);
    exit;
}

my @errores;
if ($accion eq 'generar' && $cgi->request_method eq 'POST') {
    unless ($puede_generar) {
        denegar_acceso(titulo => 'Para Compulsa', usuario_nombre => obtener_texto_sesion($session, 'nombre'),
                        rol => $rol, dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'COMPULSA_AFILIACIONES',
                        mensaje => 'No tienes permiso para generar la compulsa.');
        exit;
    }
    my @ids = grep { /^\d+$/ } $cgi->param('seleccion');
    if (!@ids) {
        push @errores, 'Selecciona al menos un registro para generar la compulsa.';
    } else {
        my $ok = eval {
            $dbh->begin_work;
            for my $id (@ids) {
                $dbh->do('CALL sp_marcar_compulsa_ine(?, ?)', undef, $id, $id_usuario);
            }
            $dbh->commit;
            1;
        };
        if ($ok) {
            # el lote completo ya quedó en Compulsa INE: se entrega el
            # Excel en la misma respuesta, como pide el flujo de compulsa.
            exportar_excel($dbh, \@ids);
            exit;
        } else {
            eval { $dbh->rollback };
            push @errores, 'No se pudo generar la compulsa: alguno de los registros seleccionados ya no está en estatus "Compulsa IEEQ". No se marcó ningún registro (se procesa todo el lote o nada).';
        }
    }
}

if ($accion eq 'regresar' && $cgi->request_method eq 'POST') {
    unless ($puede_generar) {
        denegar_acceso(titulo => 'Para Compulsa', usuario_nombre => obtener_texto_sesion($session, 'nombre'),
                        rol => $rol, dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'COMPULSA_AFILIACIONES',
                        mensaje => 'No tienes permiso para regresar afiliaciones a revisión.');
        exit;
    }
    my @ids = grep { /^\d+$/ } $cgi->param('seleccion');
    if (!@ids) {
        push @errores, 'Selecciona al menos un registro para regresarlo a la asociación.';
    } else {
        my $ok = eval {
            $dbh->begin_work;
            for my $id (@ids) {
                $dbh->do('CALL sp_regresar_a_revision(?, ?)', undef, $id, $id_usuario);
            }
            $dbh->commit;
            1;
        };
        if ($ok) {
            print $cgi->redirect('afiliaciones_compulsa.pl?regresado=' . scalar(@ids));
            exit;
        } else {
            eval { $dbh->rollback };
            push @errores, 'No se pudo regresar el lote: alguno de los registros seleccionados ya no está en estatus "Compulsa IEEQ". No se modificó ningún registro (se procesa todo el lote o nada).';
        }
    }
}

my $pagina = int($cgi->param('pagina') // 1);
$pagina = 1 if $pagina < 1;

print encabezado(titulo => 'Para Compulsa',
                  usuario_nombre => obtener_texto_sesion($session, 'nombre'), rol => $rol,
                  dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'COMPULSA_AFILIACIONES');

if ($cgi->param('regresado')) {
    my $cantidad = $cgi->param('regresado') + 0;
    my $texto = $cantidad == 1
        ? '1 afiliación regresada a Revisión APE para que la asociación la corrija.'
        : "$cantidad afiliaciones regresadas a Revisión APE para que la asociación las corrija.";
    print qq(<div class="alert alert-success">$texto</div>);
}
if (@errores) {
    print '<div class="alert alert-danger"><ul class="mb-0">';
    print "<li>$_</li>" for @errores;
    print '</ul></div>';
}

mostrar_listado($dbh, $puede_generar, $pagina);
print pie_pagina();

# ============================================================
sub obtener_ids_compulsa_ieeq {
    my ($dbh) = @_;
    my $sth = $dbh->prepare("SELECT id_afiliacion FROM afiliaciones WHERE fecha_eliminacion IS NULL AND estatus = 'COMPULSA_IEEQ'");
    $sth->execute;
    my @ids;
    while (my ($id) = $sth->fetchrow_array) { push @ids, $id; }
    return @ids;
}

sub mostrar_listado {
    my ($dbh, $puede_generar, $pagina) = @_;
    my $where = "a.fecha_eliminacion IS NULL AND a.estatus = 'COMPULSA_IEEQ'";

    my ($total_filas) = $dbh->selectrow_array("SELECT COUNT(*) FROM afiliaciones a WHERE $where");
    my $total_paginas = $total_filas ? int(($total_filas + $POR_PAGINA - 1) / $POR_PAGINA) : 1;
    $pagina = $total_paginas if $pagina > $total_paginas;
    my $offset = ($pagina - 1) * $POR_PAGINA;

    my $sth = $dbh->prepare(
        "SELECT a.id_afiliacion,
             CONCAT(a.nombre, ' ', a.apellido_paterno, IFNULL(CONCAT(' ', a.apellido_materno), '')) AS nombre_completo,
             a.clave_elector, a.fecha_hora_afiliacion,
             m.nombre AS municipio, ap.nombre AS asociacion
         FROM afiliaciones a
         JOIN municipios m ON m.id_municipio = a.id_municipio_afiliacion
         JOIN usuarios u ON u.id_usuario = a.id_registrador
         JOIN asociaciones_politicas ap ON ap.id_asociacion = u.id_asociacion
         WHERE $where
         ORDER BY a.fecha_hora_afiliacion ASC
         LIMIT $POR_PAGINA OFFSET $offset"
    );
    $sth->execute;

    print '<div class="d-flex justify-content-between align-items-center mb-2">';
    print '<p class="text-muted mb-0">Afiliaciones validadas por su asociación, listas para incluirse en el archivo de compulsa al INE.</p>';
    print '<a href="afiliaciones_compulsa.pl?accion=exportar" class="btn btn-sm btn-outline-success"><i class="bi bi-file-earmark-excel me-1"></i>Descargar Excel</a>';
    print '</div>';

    print qq(<form method="post" action="afiliaciones_compulsa.pl">);
    print '<div class="card border-0 shadow-sm"><div class="card-body p-0">';
    print '<table class="table table-hover align-middle mb-0"><thead><tr>';
    print '<th class="ps-3"><input type="checkbox" id="marcar_todos" class="form-check-input"></th>' if $puede_generar;
    print '<th>Nombre</th><th>Clave de elector</th><th>Asociación</th><th>Municipio</th><th>Fecha</th></tr></thead><tbody>';

    my $filas = 0;
    while (my $r = $sth->fetchrow_hashref) {
        $filas++;
        print '<tr>';
        print qq(<td class="ps-3"><input type="checkbox" class="form-check-input" name="seleccion" value="$r->{id_afiliacion}"></td>) if $puede_generar;
        print qq(
          <td>$r->{nombre_completo}</td>
          <td class="font-monospace small">@{[ $r->{clave_elector} // '—' ]}</td>
          <td>$r->{asociacion}</td>
          <td>$r->{municipio}</td>
          <td>$r->{fecha_hora_afiliacion}</td>
        </tr>
        );
    }
    my $colspan = $puede_generar ? 6 : 5;
    if ($filas == 0) {
        print qq(<tr><td colspan="$colspan" class="text-center text-muted py-4">No hay afiliaciones listas para compulsa.</td></tr>);
    }
    print '</tbody></table></div></div>';

    if ($puede_generar) {
        print qq(
        <div class="mt-3 d-flex gap-2">
          <button type="submit" name="accion" value="generar" class="btn btn-primary"
                  onclick="return confirm('¿Generar la compulsa con los registros seleccionados? Cambiarán a estatus Compulsa INE.');">
            <i class="bi bi-file-earmark-arrow-up me-1"></i>Generar compulsa con lo seleccionado
          </button>
          <button type="submit" name="accion" value="regresar" class="btn btn-outline-warning"
                  onclick="return confirm('¿Regresar los registros seleccionados a Revisión APE para que la asociación los corrija?');">
            <i class="bi bi-arrow-counterclockwise me-1"></i>Regresar a la asociación (subsanar)
          </button>
        </div>
        <script>
          document.getElementById('marcar_todos').addEventListener('change', function(ev) {
            document.querySelectorAll('input[name="seleccion"]').forEach(function(c) { c.checked = ev.target.checked; });
          });
        </script>
        );
    }
    print '</form>';

    print paginacion(pagina_actual => $pagina, total_paginas => $total_paginas, total_filas => $total_filas, por_pagina => $POR_PAGINA, base_url => 'afiliaciones_compulsa.pl');
}

# --- Excel con todos los datos capturados (sin imágenes) del lote de ids
#     dado; se usa tanto para "Descargar Excel" (solo consulta) como para
#     el archivo que se entrega justo después de generar la compulsa. ---
sub exportar_excel {
    my ($dbh, $ids) = @_;
    my @encabezados = (
        'Nombre', 'Apellido paterno', 'Apellido materno',
        'Calle', 'Número exterior', 'Número interior', 'Colonia',
        'Municipio (domicilio)', 'Estado', 'Código postal',
        'Clave de elector', 'OCR', 'Fecha de captura',
        'Municipio de afiliación', 'Asociación', 'Registrador', 'Estatus',
    );
    my @filas;
    if (@$ids) {
        my $placeholders = join(',', ('?') x scalar @$ids);
        my $sth = $dbh->prepare(
            "SELECT a.nombre, a.apellido_paterno, a.apellido_materno,
                 a.domicilio_calle, a.domicilio_numero, a.domicilio_numero_interior, a.domicilio_colonia,
                 a.domicilio_municipio, a.domicilio_estado, a.domicilio_cp,
                 a.clave_elector, a.ocr, a.fecha_hora_afiliacion, a.estatus,
                 m.nombre AS municipio, ap.nombre AS asociacion,
                 CONCAT(u.nombre, ' ', u.apellido_paterno) AS registrador
             FROM afiliaciones a
             JOIN municipios m ON m.id_municipio = a.id_municipio_afiliacion
             JOIN usuarios u ON u.id_usuario = a.id_registrador
             JOIN asociaciones_politicas ap ON ap.id_asociacion = u.id_asociacion
             WHERE a.id_afiliacion IN ($placeholders)
             ORDER BY a.fecha_hora_afiliacion ASC"
        );
        $sth->execute(@$ids);
        while (my $r = $sth->fetchrow_hashref) {
            push @filas, [
                $r->{nombre}, $r->{apellido_paterno}, $r->{apellido_materno},
                $r->{domicilio_calle}, $r->{domicilio_numero}, $r->{domicilio_numero_interior}, $r->{domicilio_colonia},
                $r->{domicilio_municipio}, $r->{domicilio_estado}, $r->{domicilio_cp},
                $r->{clave_elector}, $r->{ocr}, $r->{fecha_hora_afiliacion},
                $r->{municipio}, $r->{asociacion}, $r->{registrador}, $r->{estatus},
            ];
        }
    }
    exportar_xlsx($cgi, 'compulsa_afiliaciones.xlsx', \@encabezados, \@filas);
}
