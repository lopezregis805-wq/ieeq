#!/usr/bin/perl
# ============================================================
# afiliaciones_detalle.pl — vista de solo lectura de un
# registro, con su evidencia fotográfica y su historial de
# verificación. La usa el listado (botón "Ver") y la va a
# reutilizar afiliaciones_verificar.pl pere que el funcionario pueda ver las fotos antes de decidir.
# ============================================================
use strict;
use warnings;
use utf8;                          
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

unless (tiene_permiso($dbh, $id_usuario, 'CONSULTA_AFILIACIONES', 'LECTURA')) {
    print $cgi->header(-charset => 'utf-8', -status => '403 Forbidden');
    print "Acceso no autorizado a este módulo.";
    exit;
}

my $id = $cgi->param('id');
my $sth = $dbh->prepare(
    'SELECT a.*, m.nombre AS municipio, u.id_asociacion AS id_asociacion_registrador,
            CONCAT(u.nombre, " ", u.apellido_paterno) AS registrador, ap.nombre AS asociacion
     FROM afiliaciones a
     JOIN municipios m ON m.id_municipio = a.id_municipio_afiliacion
     JOIN usuarios u ON u.id_usuario = a.id_registrador
     JOIN asociaciones_politicas ap ON ap.id_asociacion = u.id_asociacion
     WHERE a.id_afiliacion = ? AND a.fecha_eliminacion IS NULL'
);
$sth->execute($id);
my $r = $sth->fetchrow_hashref;

# --- alcance por rol: nadie ve registros fuera de lo que le corresponde ---
my $autorizado = 0;
if ($r) {
    $autorizado = 1 if $rol eq 'SUPERADMIN' || $rol eq 'FUNCIONARIO_IEEQ';
    $autorizado = 1 if $rol eq 'ADMIN_ASOCIACION' && $r->{id_asociacion_registrador} == $id_asociacion;
    $autorizado = 1 if $rol eq 'AUXILIAR' && $r->{id_registrador} == $id_usuario;
}

print encabezado(titulo => 'Detalle de Afiliación',
                  usuario_nombre => obtener_texto_sesion($session, 'nombre'), rol => $rol,
                  dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'CONSULTA_AFILIACIONES');

unless ($r && $autorizado) {
    print '<div class="alert alert-danger">Registro no encontrado o no autorizado.</div>';
    print pie_pagina();
    exit;
}

my %color_estatus = (NUEVA => 'secondary', EN_REVISION => 'warning', VERIFICADO => 'success');
my $color = $color_estatus{ $r->{estatus} } // 'secondary';

print qq(
<div class="d-flex justify-content-between align-items-center mb-3">
  <h5 class="mb-0">$r->{nombre} $r->{apellido_paterno} @{[ $r->{apellido_materno} // '' ]}</h5>
  <span class="badge bg-$color-subtle text-$color-emphasis fs-6">$r->{estatus}</span>
</div>

<div class="row g-3">
  <div class="col-md-6">
    <div class="card border-0 shadow-sm h-100"><div class="card-body">
      <h6 class="text-ieeq-primary mb-3">Identificación</h6>
      <table class="table table-sm mb-0">
        <tr><td class="text-muted">Clave de elector</td><td>@{[ $r->{clave_elector} // '—' ]}</td></tr>
        <tr><td class="text-muted">OCR</td><td>@{[ $r->{ocr} // '—' ]}</td></tr>
        <tr><td class="text-muted">CIC</td><td>@{[ $r->{cic} // '—' ]}</td></tr>
        <tr><td class="text-muted">Municipio de afiliación</td><td>$r->{municipio}</td></tr>
        <tr><td class="text-muted">Asociación</td><td>$r->{asociacion}</td></tr>
        <tr><td class="text-muted">Registrado por</td><td>$r->{registrador}</td></tr>
        <tr><td class="text-muted">Fecha</td><td>$r->{fecha_hora_afiliacion}</td></tr>
      </table>
    </div></div>
  </div>
  <div class="col-md-6">
    <div class="card border-0 shadow-sm h-100"><div class="card-body">
      <h6 class="text-ieeq-primary mb-3">Domicilio</h6>
      <table class="table table-sm mb-0">
        <tr><td class="text-muted">Calle y número</td><td>@{[ $r->{domicilio_calle} // '—' ]} @{[ $r->{domicilio_numero} // '' ]}</td></tr>
        <tr><td class="text-muted">Colonia</td><td>@{[ $r->{domicilio_colonia} // '—' ]}</td></tr>
        <tr><td class="text-muted">Municipio / Estado</td><td>@{[ $r->{domicilio_municipio} // '—' ]}, @{[ $r->{domicilio_estado} // '—' ]}</td></tr>
        <tr><td class="text-muted">Código postal</td><td>@{[ $r->{domicilio_cp} // '—' ]}</td></tr>
      </table>
      <h6 class="text-ieeq-primary mt-3 mb-2">Declaraciones aceptadas</h6>
      <div class="small">
        @{[ $r->{acepta_afiliacion_libre} ? '/' : 'x' ]} Afiliación libre y voluntaria<br>
        @{[ $r->{acepta_documentos} ? '/' : 'x' ]} Conocimiento de documentos básicos<br>
        @{[ $r->{acepta_no_otro_partido} ? '/' : 'x' ]} No afiliación previa a otra organización<br>
        @{[ $r->{acepta_aviso_privacidad} ? '/' : 'x' ]} Aviso de privacidad
      </div>
    </div></div>
  </div>

  <div class="col-12">
    <div class="card border-0 shadow-sm"><div class="card-body">
      <h6 class="text-ieeq-primary mb-3">Evidencia fotográfica</h6>
      <div class="row g-3">
        @{[ bloque_imagen('Anverso INE', $r->{foto_anverso_ine}) ]}
        @{[ bloque_imagen('Reverso INE', $r->{foto_reverso_ine}) ]}
        @{[ bloque_imagen('Fotografía', $r->{foto_persona}) ]}
        @{[ bloque_imagen('Firma', $r->{firma}) ]}
      </div>
    </div></div>
  </div>
);

mostrar_historial_verificacion($dbh, $id);

print qq(
</div>
<div class="mt-3">
  <a href="afiliaciones_listado.pl" class="btn btn-secondary">Volver al listado</a>
</div>
);

print pie_pagina();

# ============================================================
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

sub mostrar_historial_verificacion {
    my ($dbh, $id) = @_;
    my $sth = $dbh->prepare(
        'SELECT v.decision, v.observaciones, v.fecha_verificacion, CONCAT(u.nombre, " ", u.apellido_paterno) AS verificador
         FROM verificaciones_afiliaciones v
         JOIN usuarios u ON u.id_usuario = v.id_verificador
         WHERE v.id_afiliacion = ? ORDER BY v.fecha_verificacion DESC'
    );
    $sth->execute($id);
    my @filas;
    while (my $v = $sth->fetchrow_hashref) { push @filas, $v; }
    return unless @filas;

    print '<div class="col-12"><div class="card border-0 shadow-sm"><div class="card-body">';
    print '<h6 class="text-ieeq-primary mb-3">Historial de verificación</h6>';
    print '<table class="table table-sm mb-0"><thead><tr><th>Fecha</th><th>Verificador</th><th>Decisión</th><th>Observaciones</th></tr></thead><tbody>';
    for my $v (@filas) {
        print "<tr><td>$v->{fecha_verificacion}</td><td>$v->{verificador}</td><td>$v->{decision}</td><td>@{[ $v->{observaciones} // '—' ]}</td></tr>";
    }
    print '</tbody></table></div></div></div>';
}
