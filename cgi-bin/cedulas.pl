#!/usr/bin/perl
# ============================================================
# cedulas.pl — Generación de Cédulas de Afiliación.
#
# Regla de negocio: solo se genera para registros que el
# Funcionariado IEEQ ya incluyó en un archivo de compulsa al INE
# (estatus "Compulsa INE") — mientras solo está en "Compulsa IEEQ"
# (validado por la asociación pero aún no enviado a compulsa)
# todavía no se puede ver ni generar su cédula. Disponible para
# el Administrador de Asociación (ESCRITURA) y en consulta para
# SUPERADMIN/Funcionariado IEEQ (LECTURA); las personas auxiliares
# no tienen este permiso (NINGUNO por defecto en este módulo).
#
# La cédula es una vista HTML lista para imprimir (@media print
# en el CSS), no un PDF generado en el servidor: el botón
# "Imprimir" del navegador ya permite guardarla como PDF sin
# sumar dependencias nuevas de Perl.
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

my $POR_PAGINA = 20;

my $cgi = CGI->new;
binmode(STDOUT, ":encoding(UTF-8)");
my $session = iniciar_sesion($cgi);
my $id_usuario = requerir_sesion($session, $cgi);
my $dbh = conectar();
my $rol = $session->param('rol');
my $id_asociacion = $session->param('id_asociacion');

unless (tiene_permiso($dbh, $id_usuario, 'CEDULAS_AFILIACION', 'LECTURA')) {
    denegar_acceso(titulo => 'Generación de Cédulas', usuario_nombre => obtener_texto_sesion($session, 'nombre'),
                    rol => $rol, dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'CEDULAS_AFILIACION',
                    mensaje => 'Acceso no autorizado a este módulo.');
    exit;
}

my $id = $cgi->param('id');

if ($id) {
    mostrar_cedula($dbh, $cgi, $session, $id, $rol, $id_asociacion, $id_usuario);
} else {
    print encabezado(titulo => 'Generación de Cédulas',
                      usuario_nombre => obtener_texto_sesion($session, 'nombre'), rol => $rol,
                      dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'CEDULAS_AFILIACION');
    my $pagina = int($cgi->param('pagina') // 1);
    $pagina = 1 if $pagina < 1;
    mostrar_listado($dbh, $rol, $id_asociacion, $pagina);
    print pie_pagina();
}

# ============================================================
sub mostrar_listado {
    my ($dbh, $rol, $id_asociacion, $pagina) = @_;
    $pagina //= 1;

    my $where = 'a.fecha_eliminacion IS NULL AND a.estatus = "COMPULSA_INE"';
    my @params;
    if ($rol eq 'ADMIN_ASOCIACION') {
        $where .= ' AND u.id_asociacion = ?';
        push @params, $id_asociacion;
    }

    my ($total_filas) = $dbh->selectrow_array(
        "SELECT COUNT(*) FROM afiliaciones a JOIN usuarios u ON u.id_usuario = a.id_registrador WHERE $where",
        undef, @params
    );
    my $total_paginas = $total_filas ? int(($total_filas + $POR_PAGINA - 1) / $POR_PAGINA) : 1;
    $pagina = $total_paginas if $pagina > $total_paginas;
    my $offset = ($pagina - 1) * $POR_PAGINA;

    my $sql = "SELECT a.id_afiliacion,
                 CONCAT(a.nombre, ' ', a.apellido_paterno, IFNULL(CONCAT(' ', a.apellido_materno), '')) AS nombre_completo,
                 a.clave_elector, ap.nombre AS asociacion, m.nombre AS municipio,
                 (SELECT MAX(fecha_verificacion) FROM verificaciones_afiliaciones v
                  WHERE v.id_afiliacion = a.id_afiliacion AND v.decision = 'APROBADO') AS fecha_verificacion
               FROM afiliaciones a
               JOIN municipios m ON m.id_municipio = a.id_municipio_afiliacion
               JOIN usuarios u ON u.id_usuario = a.id_registrador
               JOIN asociaciones_politicas ap ON ap.id_asociacion = u.id_asociacion
               WHERE $where
               ORDER BY fecha_verificacion DESC
               LIMIT $POR_PAGINA OFFSET $offset";

    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);

    print '<p class="text-muted">Afiliaciones ya enviadas a Compulsa INE, listas para emitir su cédula.</p>';
    print '<div class="card border-0 shadow-sm"><div class="card-body p-0">';
    print '<table class="table table-hover align-middle mb-0"><thead><tr>
             <th class="ps-3">Nombre</th><th>Clave de elector</th><th>Asociación</th><th>Municipio</th>
             <th>Verificado el</th><th class="text-end pe-3">Acción</th>
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
          <td>@{[ $r->{fecha_verificacion} // '—' ]}</td>
          <td class="text-end pe-3">
            <a href="cedulas.pl?id=$r->{id_afiliacion}" class="btn btn-sm btn-primary" target="_blank">
              <i class="bi bi-file-earmark-text me-1"></i>Generar cédula
            </a>
          </td>
        </tr>
        );
    }
    if ($filas == 0) {
        print '<tr><td colspan="6" class="text-center text-muted py-4">Todavía no hay afiliaciones en estatus Compulsa INE.</td></tr>';
    }
    print '</tbody></table></div></div>';
    print paginacion(pagina_actual => $pagina, total_paginas => $total_paginas, total_filas => $total_filas, por_pagina => $POR_PAGINA, base_url => 'cedulas.pl');
}

sub mostrar_cedula {
    my ($dbh, $cgi, $session, $id, $rol, $id_asociacion, $id_usuario) = @_;

    my $sth = $dbh->prepare(
        'SELECT a.*, m.nombre AS municipio, ap.nombre AS asociacion, ap.representante_legal, ap.emblema,
             ap.sitio_web AS asociacion_sitio_web, ap.calle AS asociacion_calle, ap.numero AS asociacion_numero,
             ap.colonia AS asociacion_colonia, ap.municipio AS asociacion_municipio, ap.codigo_postal AS asociacion_cp,
             u.id_asociacion AS id_asociacion_registrador,
             (SELECT MAX(fecha_verificacion) FROM verificaciones_afiliaciones v
              WHERE v.id_afiliacion = a.id_afiliacion AND v.decision = "APROBADO") AS fecha_verificacion
         FROM afiliaciones a
         JOIN municipios m ON m.id_municipio = a.id_municipio_afiliacion
         JOIN usuarios u ON u.id_usuario = a.id_registrador
         JOIN asociaciones_politicas ap ON ap.id_asociacion = u.id_asociacion
         WHERE a.id_afiliacion = ? AND a.fecha_eliminacion IS NULL'
    );
    $sth->execute($id);
    my $r = $sth->fetchrow_hashref;

    # --- autorización: debe existir, ya estar en Compulsa INE (mientras
    #     solo está en Compulsa IEEQ todavía no se puede ver su cédula),
    #     y (si es Admin de Asociación) pertenecer a SU asociación ---
    my $autorizado = 0;
    if ($r && $r->{estatus} eq 'COMPULSA_INE') {
        $autorizado = 1 if $rol eq 'SUPERADMIN' || $rol eq 'FUNCIONARIO_IEEQ';
        $autorizado = 1 if $rol eq 'ADMIN_ASOCIACION' && $r->{id_asociacion_registrador} == $id_asociacion;
    }
    unless ($autorizado) {
        print $cgi->header(-charset => 'utf-8');
        print qq(<!DOCTYPE html><html lang="es"><head><meta charset="utf-8">
        <title>Cédula no disponible · IEEQ</title>
        <link href="https://cdn.jsdelivr.net/npm/bootstrap\@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
        </head><body class="p-4">
        <div class="alert alert-danger mb-0">Esta cédula no está disponible: el registro no existe, todavía no se envió a Compulsa INE, o no pertenece a tu asociación.</div>
        </body></html>);
        exit;
    }

    registrar(dbh => $dbh, id_usuario => $id_usuario, accion => 'GENERACION_CEDULA',
              clave_modulo => 'CEDULAS_AFILIACION', id_registro_afectado => $id,
              detalles => "Cédula generada: $r->{nombre} $r->{apellido_paterno}", ip => $cgi->remote_addr);

    my $emblema_html = $r->{emblema} ? qq(<img src="$r->{emblema}" style="height:60px;">) : '';
    my $firma_html = $r->{firma} ? qq(<img src="$r->{firma}" style="max-height:70px;max-width:200px;">) : '<em>(sin firma)</em>';

    # --- datos de la asociación para el aviso de privacidad ---
    my $asociacion_sitio_web = $r->{asociacion_sitio_web} || 'no disponible';
    my $calle_numero = join(' ', grep { length } ($r->{asociacion_calle}, $r->{asociacion_numero}));
    my @partes_domicilio_asociacion = grep { length } (
        $calle_numero, $r->{asociacion_colonia}, $r->{asociacion_municipio}, $r->{asociacion_cp},
    );
    my $domicilio_asociacion = @partes_domicilio_asociacion
        ? join(', ', @partes_domicilio_asociacion)
        : 'domicilio no disponible';

    print $cgi->header(-charset => 'utf-8');
    print <<"HTML";
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <title>Cédula de Afiliación · $r->{nombre} $r->{apellido_paterno}</title>
  <link href="https://cdn.jsdelivr.net/npm/bootstrap\@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
  <style>
    body { font-family: 'Outfit', system-ui, sans-serif; background:#f4f6f9; }
    .hoja { max-width: 800px; margin: 2rem auto; background:#fff; padding: 2.5rem; border-radius: 0.75rem; box-shadow: 0 0 20px rgba(0,0,0,0.08); }
    .linea-firma { border-top: 1px solid #333; width: 250px; margin-top: 3rem; padding-top: 0.25rem; text-align:center; }
    .titulo_aviso { color:#6B2D8B; font-weight:600; font-size:0.85rem; margin-bottom:0.35rem; }
    .contenido_aviso { color:#6c757d; font-size:0.78rem; margin-bottom:0; text-align:justify; }
    \@media print {
      body { background:#fff; }
      .hoja { box-shadow:none; margin:0; padding:0; }
      .no-imprimir { display:none; }
    }
  </style>
</head>
<body>
  <div class="text-center py-3 no-imprimir">
    <button onclick="window.print()" class="btn btn-primary"><i class="bi bi-printer"></i> Imprimir / Guardar como PDF</button>
  </div>

  <div class="hoja">
    <div class="d-flex justify-content-between align-items-center border-bottom pb-3 mb-4">
      <div>
        <h4 class="mb-0 text-ieeq-primary" style="color:#6B2D8B;">Cédula de Afiliación</h4>
        <small class="text-muted">Instituto Electoral del Estado de Querétaro</small>
      </div>
      $emblema_html
    </div>

    <p><strong>Asociación política:</strong> $r->{asociacion}<br>
       <strong>Representante legal:</strong> $r->{representante_legal}</p>

    <hr>

    <h6 style="color:#6B2D8B;">Datos de la persona afiliada</h6>
    <table class="table table-sm">
      <tr><td class="text-muted" style="width:220px;">Nombre completo</td><td>$r->{nombre} $r->{apellido_paterno} @{[ $r->{apellido_materno} // '' ]}</td></tr>
      <tr><td class="text-muted">Clave de elector</td><td>@{[ $r->{clave_elector} // '—' ]}</td></tr>
      <tr><td class="text-muted">OCR</td><td>@{[ $r->{ocr} // '—' ]}</td></tr>
      <tr><td class="text-muted">Domicilio</td><td>@{[ $r->{domicilio_calle} // '' ]} @{[ $r->{domicilio_numero} // '' ]}@{[ $r->{domicilio_numero_interior} ? " Int. $r->{domicilio_numero_interior}" : '' ]}, @{[ $r->{domicilio_colonia} // '' ]}, @{[ $r->{domicilio_municipio} // '' ]}, @{[ $r->{domicilio_estado} // '' ]}</td></tr>
      <tr><td class="text-muted">Municipio de afiliación</td><td>$r->{municipio}</td></tr>
      <tr><td class="text-muted">Fecha de afiliación</td><td>$r->{fecha_hora_afiliacion}</td></tr>
      <tr><td class="text-muted">Fecha de verificación</td><td>@{[ $r->{fecha_verificacion} // '—' ]}</td></tr>
    </table>

    <h6 style="color:#6B2D8B;" class="mt-4">Declaraciones aceptadas</h6>
    <ul class="small">
      <li>@{[ $r->{acepta_afiliacion_libre} ? 'La afiliación fue libre y voluntaria.' : '' ]}</li>
      <li>@{[ $r->{acepta_documentos} ? 'Declaró conocer los documentos básicos de la asociación.' : '' ]}</li>
      <li>@{[ $r->{acepta_no_otro_partido} ? 'Declaró no estar afiliado(a) previamente a otra organización política.' : '' ]}</li>
      <li>@{[ $r->{acepta_aviso_privacidad} ? 'Aceptó el aviso de privacidad.' : '' ]}</li>
    </ul>

    <div class="d-flex justify-content-between mt-5">
      <div>
        <div class="small text-muted mb-1">Firma de la persona afiliada</div>
        $firma_html
        <div class="linea-firma">Firma</div>
      </div>
      <div class="text-center">
        <div class="linea-firma">$r->{representante_legal}<br><small>Representante legal</small></div>
      </div>
    </div>

    <div class="mt-5 border-top pt-3">
      <p class="titulo_aviso">
        Aviso de privacidad simplificado
      </p>
      <p class="contenido_aviso">
        La asociación $r->{asociacion}., es el sujeto obligado y responsable del tratamiento de
        datos personales que se recaban de forma general a través de este formato, lo cuales son
        protegidos conforme a lo dispuesto por la Ley General de Protección de Datos Personales en
        Posesión de Sujetos Obligados, demás normatividad que resulte aplicable y el aviso de
        privacidad correspondiente. Se informa que no se realizarán transferencias de datos
        personales, salvo aquéllas que sean necesarias para atender requerimientos de información
        de una autoridad competente, que estén debidamente fundados y motivados. Si desea conocer
        nuestro aviso de privacidad integral, lo podrá consultar en la página electrónica de la
        organización $asociacion_sitio_web, o bien, en $domicilio_asociacion.
      </p>
    </div>

    <p class="text-muted small mt-3">
      Documento generado por el Sistema de Registro de Afiliaciones del IEEQ.
      Este documento certifica que el registro fue validado por la asociación política.
    </p>
  </div>
</body>
</html>
HTML
}
