#!/usr/bin/perl
# ============================================================
# afiliaciones_nueva.pl — Registro de Afiliaciones. El proceso más complejo del
# sistema: combina datos personales, evidencia fotográfica y
# declaraciones legales.
# ============================================================
use strict;
use warnings;
use utf8;                            # el codigo fuente de este archivo esta en UTF-8
use CGI;
use Encode qw(decode_utf8);
use MIME::Base64 qw(decode_base64);
use lib './lib';
use DB qw(conectar);
use Rutas qw($RUTA_UPLOADS);
use Auth qw(iniciar_sesion requerir_sesion tiene_permiso obtener_texto_sesion);
use Bitacora qw(registrar);
use Plantilla qw(encabezado pie_pagina denegar_acceso);

my $cgi = CGI->new;
binmode(STDOUT, ":encoding(UTF-8)");
my $session = iniciar_sesion($cgi);
my $id_usuario = requerir_sesion($session, $cgi);
my $dbh = conectar();
my $rol = $session->param('rol');
my $id_asociacion_sesion = $session->param('id_asociacion');

unless (tiene_permiso($dbh, $id_usuario, 'REGISTRO_AFILIACIONES', 'ESCRITURA')) {
    denegar_acceso(titulo => 'Registro de Afiliaciones', usuario_nombre => obtener_texto_sesion($session, 'nombre'),
                    rol => $rol, dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'REGISTRO_AFILIACIONES',
                    mensaje => 'No tienes permiso de captura en este módulo.');
    exit;
}

my $id_edicion = $cgi->param('id');
my $registro_existente;

# --- si es edición: cargar el registro y validar que SÍ se puede tocar ---
if ($id_edicion) {
    my $sth = $dbh->prepare(
        'SELECT a.*, u.id_asociacion AS id_asociacion_registrador
         FROM afiliaciones a JOIN usuarios u ON u.id_usuario = a.id_registrador
         WHERE a.id_afiliacion = ? AND a.fecha_eliminacion IS NULL'
    );
    $sth->execute($id_edicion);
    $registro_existente = $sth->fetchrow_hashref;

    my $autorizado = 0;
    if ($registro_existente && ($registro_existente->{estatus} eq 'NUEVA' || $registro_existente->{estatus} eq 'RECHAZADA')) {
        $autorizado = 1 if $rol eq 'SUPERADMIN';
        $autorizado = 1 if $rol eq 'ADMIN_ASOCIACION' && $registro_existente->{id_asociacion_registrador} == $id_asociacion_sesion;
        $autorizado = 1 if $rol eq 'AUXILIAR' && $registro_existente->{id_registrador} == $id_usuario;
    }
    unless ($autorizado) {
        denegar_acceso(titulo => 'Registro de Afiliaciones', usuario_nombre => obtener_texto_sesion($session, 'nombre'),
                        rol => $rol, dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'REGISTRO_AFILIACIONES',
                        mensaje => 'Este registro no existe, ya no está en estatus "Nueva afiliación" o "Rechazada", o no te pertenece.');
        exit;
    }
}

my @errores;
my %campo_invalido; # campo => mensaje específico, para resaltar justo ese campo en el formulario
my %valores_formulario; # lo que el usuario ya había escrito, para no perderlo si falla la validación
my $guardado_ok = 0;

if ($cgi->request_method eq 'POST') {
    my $id_municipio = $cgi->param('id_municipio_afiliacion') || undef;
    # --- todos los datos capturados se guardan en mayúsculas (regla de negocio) ---
    my $nombre                    = mayus($cgi->param('nombre'));
    my $apellido_paterno          = mayus($cgi->param('apellido_paterno'));
    my $apellido_materno          = mayus($cgi->param('apellido_materno'));
    my $domicilio_calle           = mayus($cgi->param('domicilio_calle'));
    my $domicilio_numero          = mayus($cgi->param('domicilio_numero'));
    my $domicilio_numero_interior = mayus($cgi->param('domicilio_numero_interior'));
    my $domicilio_colonia         = mayus($cgi->param('domicilio_colonia'));
    my $domicilio_municipio       = mayus($cgi->param('domicilio_municipio'));
    my $domicilio_estado          = 'QUERÉTARO'; # fijo: todas las afiliaciones son del estado de Querétaro, no es editable
    my $domicilio_cp              = trim($cgi->param('domicilio_cp'));
    my $clave_elector             = mayus($cgi->param('clave_elector'));
    my $ocr                       = mayus($cgi->param('ocr'));

    # --- las 4 casillas obligatorias (regla critica del manual) ---
    my $acepta_libre      = $cgi->param('acepta_afiliacion_libre') ? 1 : 0;
    my $acepta_documentos = $cgi->param('acepta_documentos')       ? 1 : 0;
    my $acepta_no_otro    = $cgi->param('acepta_no_otro_partido')  ? 1 : 0;
    my $acepta_aviso      = $cgi->param('acepta_aviso_privacidad') ? 1 : 0;

    # si algo falla más abajo, esto es lo que se le regresa al usuario
    # en el formulario: NO queremos que tenga que volver a escribir
    # todo solo porque, por ejemplo, le faltó una casilla por marcar.
    %valores_formulario = (
        id_afiliacion             => $id_edicion,
        id_municipio_afiliacion   => $id_municipio,
        nombre                    => $nombre,
        apellido_paterno          => $apellido_paterno,
        apellido_materno          => $apellido_materno,
        domicilio_calle           => $domicilio_calle,
        domicilio_numero          => $domicilio_numero,
        domicilio_numero_interior => $domicilio_numero_interior,
        domicilio_colonia         => $domicilio_colonia,
        domicilio_municipio       => $domicilio_municipio,
        domicilio_estado          => $domicilio_estado,
        domicilio_cp              => $domicilio_cp,
        clave_elector             => $clave_elector,
        ocr                       => $ocr,
        acepta_afiliacion_libre   => $acepta_libre,
        acepta_documentos         => $acepta_documentos,
        acepta_no_otro_partido    => $acepta_no_otro,
        acepta_aviso_privacidad   => $acepta_aviso,
        firma                     => $registro_existente ? $registro_existente->{firma} : undef,
    );

    unless ($id_municipio) {
        push @errores, 'El municipio de afiliación es obligatorio.';
        $campo_invalido{id_municipio_afiliacion} = 'Selecciona el municipio de afiliación.';
    }
    unless (length $nombre) {
        push @errores, 'El nombre es obligatorio.';
        $campo_invalido{nombre} = 'El nombre es obligatorio.';
    }
    unless (length $apellido_paterno) {
        push @errores, 'El apellido paterno es obligatorio.';
        $campo_invalido{apellido_paterno} = 'El apellido paterno es obligatorio.';
    }
    if (!length $clave_elector) {
        push @errores, 'La clave de elector es obligatoria.';
        $campo_invalido{clave_elector} = 'La clave de elector es obligatoria.';
    } elsif ($clave_elector !~ /^[A-Z0-9]{18}$/) {
        push @errores, 'La clave de elector debe tener exactamente 18 caracteres (solo letras y números).';
        $campo_invalido{clave_elector} = 'Debe tener exactamente 18 caracteres, solo letras y números (verifica en la credencial). Tiene ' . length($clave_elector) . '.';
    }
    unless (length $ocr) {
        push @errores, 'El número OCR es obligatorio.';
        $campo_invalido{ocr} = 'El número OCR es obligatorio.';
    }

    unless (length $domicilio_calle) {
        push @errores, 'La calle es obligatoria.';
        $campo_invalido{domicilio_calle} = 'La calle es obligatoria.';
    }
    unless (length $domicilio_numero) {
        push @errores, 'El número exterior es obligatorio.';
        $campo_invalido{domicilio_numero} = 'El número exterior es obligatorio.';
    }
    unless (length $domicilio_colonia) {
        push @errores, 'La colonia es obligatoria.';
        $campo_invalido{domicilio_colonia} = 'La colonia es obligatoria.';
    }
    unless (length $domicilio_municipio) {
        push @errores, 'El municipio del domicilio es obligatorio.';
        $campo_invalido{domicilio_municipio} = 'Selecciona el municipio del domicilio.';
    }
    unless (length $domicilio_cp) {
        push @errores, 'El código postal es obligatorio.';
        $campo_invalido{domicilio_cp} = 'El código postal es obligatorio.';
    }

    unless ($acepta_libre) {
        push @errores, 'Debes aceptar que la afiliación es libre y voluntaria.';
        $campo_invalido{acepta_afiliacion_libre} = 'Debes aceptar esta declaración para continuar.';
    }
    unless ($acepta_documentos) {
        push @errores, 'Debes declarar que conoces los documentos básicos de la asociación.';
        $campo_invalido{acepta_documentos} = 'Debes aceptar esta declaración para continuar.';
    }
    unless ($acepta_no_otro) {
        push @errores, 'Debes declarar que no estás afiliado(a) previamente a otra organización política.';
        $campo_invalido{acepta_no_otro_partido} = 'Debes aceptar esta declaración para continuar.';
    }
    unless ($acepta_aviso) {
        push @errores, 'Debes aceptar el aviso de privacidad.';
        $campo_invalido{acepta_aviso_privacidad} = 'Debes aceptar esta declaración para continuar.';
    }

    # --- evidencia: en alta los 3 archivos (fotos) son
    #     obligatorios; en edición son OPCIONALES (si no se sube
    #     uno nuevo, se conserva el que ya estaba guardado). La
    #     firma se maneja aparte, más abajo: viene de un <canvas>
    #     donde la persona firma en pantalla, no de un archivo. ---
    # nada de esto se escribe a disco todavía: si falta cualquier otro
    # dato en el formulario.
    # 
    # Solo se valida aquí; el guardado real ocurre más abajo, una vez
    # confirmado que el resto del formulario también es válido.
    my %rutas;
    my %pendientes_archivo;
    my %campos_archivo = (
        foto_anverso_ine => { param => 'foto_anverso_ine', carpeta => 'uploads/ine/anverso', etiqueta => 'Foto del anverso de la credencial' },
        foto_reverso_ine => { param => 'foto_reverso_ine', carpeta => 'uploads/ine/reverso',  etiqueta => 'Foto del reverso de la credencial' },
        foto_persona     => { param => 'foto_persona',     carpeta => 'uploads/fotos',        etiqueta => 'Fotografía de la persona (selfie)' },
    );

    for my $campo (keys %campos_archivo) {
        my $info = $campos_archivo{$campo};
        my $archivo = $cgi->upload($info->{param});

        if (!$archivo) {
            if ($id_edicion) {
                $rutas{$campo} = $registro_existente->{$campo}; # conservar el archivo anterior
            } else {
                push @errores, "$info->{etiqueta} es obligatoria.";
                $campo_invalido{$campo} = "$info->{etiqueta} es obligatoria.";
            }
            next;
        }
        my $tipo = $cgi->uploadInfo($archivo)->{'Content-Type'};
        unless ($tipo eq 'image/jpeg' || $tipo eq 'image/png') {
            push @errores, "$info->{etiqueta} debe ser una imagen JPG o PNG.";
            $campo_invalido{$campo} = "$info->{etiqueta} debe ser una imagen JPG o PNG.";
            next;
        }
        my $tamano = -s $archivo;
        if ($tamano > 5_242_880) { # 5 MB, tope razonable para evitar archivos enormes
            push @errores, "$info->{etiqueta} no puede superar 5 MB.";
            $campo_invalido{$campo} = "$info->{etiqueta} no puede superar 5 MB.";
            next;
        }
        my $extension = ($tipo eq 'image/png') ? 'png' : 'jpg';
        my $nombre_archivo = "${campo}_" . time() . "_$$.${extension}";
        my $ruta_relativa = "$info->{carpeta}/$nombre_archivo";
        $pendientes_archivo{$campo} = { archivo => $archivo, ruta_relativa => $ruta_relativa, etiqueta => $info->{etiqueta} };
        $rutas{$campo} = $ruta_relativa;
    }

    # --- firma: llega como PNG en base64 desde el <canvas> del
    #     formulario (campo oculto "firma_datos"), no como archivo.
    #     Tampoco se decodifica a disco todavía, mismo motivo que las
    #     fotos de arriba. ---
    my $firma_datos = $cgi->param('firma_datos') // '';
    my $firma_pendiente;
    if ($firma_datos =~ /^data:image\/png;base64,(.+)$/) {
        my $bytes = decode_base64($1);
        if (length($bytes) > 5_242_880) {
            push @errores, 'La firma no puede superar 5 MB.';
            $campo_invalido{firma_datos} = 'La firma no puede superar 5 MB. Límpiala e inténtalo de nuevo.';
        } else {
            my $nombre_archivo = "firma_" . time() . "_$$.png";
            my $ruta_relativa = "uploads/firmas/$nombre_archivo";
            $firma_pendiente = { bytes => $bytes, ruta_relativa => $ruta_relativa };
            $rutas{firma} = $ruta_relativa;
        }
    } elsif ($id_edicion) {
        $rutas{firma} = $registro_existente->{firma}; # no volvió a firmar: conservar la anterior
    } else {
        push @errores, 'La firma en pantalla es obligatoria.';
        $campo_invalido{firma_datos} = 'La firma en pantalla es obligatoria: firma dentro del recuadro antes de guardar.';
    }

    # --- solo si TODO el formulario es válido escribimos las fotos y
    #     la firma a disco; si algo falla aquí (raro: problema de
    #     permisos/disco), se cancela el guardado en la base de datos
    #     también, para no dejar una afiliación con archivos rotos ---
    if (!@errores) {
        for my $campo (keys %pendientes_archivo) {
            my $p = $pendientes_archivo{$campo};
            my $archivo = $p->{archivo};
            if (open(my $fh, '>', "$RUTA_UPLOADS/$p->{ruta_relativa}")) {
                binmode $fh;
                binmode $archivo;
                print {$fh} $_ while <$archivo>;
                close $fh;
            } else {
                push @errores, "No se pudo guardar $p->{etiqueta}: $!";
                $campo_invalido{$campo} = "No se pudo guardar $p->{etiqueta}. Intenta de nuevo.";
            }
        }
        if ($firma_pendiente && !@errores) {
            if (open(my $fh, '>', "$RUTA_UPLOADS/$firma_pendiente->{ruta_relativa}")) {
                binmode $fh;
                print {$fh} $firma_pendiente->{bytes};
                close $fh;
            } else {
                push @errores, "No se pudo guardar la firma: $!";
                $campo_invalido{firma_datos} = 'No se pudo guardar la firma. Intenta de nuevo.';
            }
        }
    }

    if (!@errores) {
        if ($id_edicion) {
            $dbh->do(
                'UPDATE afiliaciones SET
                    id_municipio_afiliacion=?, nombre=?, apellido_paterno=?, apellido_materno=?,
                    domicilio_calle=?, domicilio_numero=?, domicilio_numero_interior=?, domicilio_colonia=?, domicilio_municipio=?,
                    domicilio_estado=?, domicilio_cp=?, clave_elector=?, ocr=?,
                    foto_anverso_ine=?, foto_reverso_ine=?, foto_persona=?, firma=?,
                    acepta_afiliacion_libre=?, acepta_documentos=?, acepta_no_otro_partido=?, acepta_aviso_privacidad=?,
                    id_usuario_actualizacion=?
                 WHERE id_afiliacion=?',
                undef,
                $id_municipio, $nombre, $apellido_paterno, $apellido_materno,
                $domicilio_calle, $domicilio_numero, $domicilio_numero_interior, $domicilio_colonia, $domicilio_municipio,
                $domicilio_estado, $domicilio_cp, $clave_elector, $ocr,
                $rutas{foto_anverso_ine}, $rutas{foto_reverso_ine}, $rutas{foto_persona}, $rutas{firma},
                $acepta_libre, $acepta_documentos, $acepta_no_otro, $acepta_aviso,
                $id_usuario, $id_edicion,
            );
            registrar(dbh => $dbh, id_usuario => $id_usuario, accion => 'EDICION',
                      clave_modulo => 'REGISTRO_AFILIACIONES', id_registro_afectado => $id_edicion,
                      detalles => "Edición de afiliación: $nombre $apellido_paterno", ip => $cgi->remote_addr);
        } else {
            $dbh->do(
                'INSERT INTO afiliaciones (
                    id_municipio_afiliacion, nombre, apellido_paterno, apellido_materno,
                    domicilio_calle, domicilio_numero, domicilio_numero_interior, domicilio_colonia, domicilio_municipio,
                    domicilio_estado, domicilio_cp, clave_elector, ocr,
                    foto_anverso_ine, foto_reverso_ine, foto_persona, firma,
                    acepta_afiliacion_libre, acepta_documentos, acepta_no_otro_partido, acepta_aviso_privacidad,
                    estatus, id_registrador
                 ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,\'NUEVA\',?)',
                undef,
                $id_municipio, $nombre, $apellido_paterno, $apellido_materno,
                $domicilio_calle, $domicilio_numero, $domicilio_numero_interior, $domicilio_colonia, $domicilio_municipio,
                $domicilio_estado, $domicilio_cp, $clave_elector, $ocr,
                $rutas{foto_anverso_ine}, $rutas{foto_reverso_ine}, $rutas{foto_persona}, $rutas{firma},
                $acepta_libre, $acepta_documentos, $acepta_no_otro, $acepta_aviso,
                $id_usuario,
            );
            my $nuevo_id = $dbh->last_insert_id(undef, undef, 'afiliaciones', undef);
            registrar(dbh => $dbh, id_usuario => $id_usuario, accion => 'REGISTRO',
                      clave_modulo => 'REGISTRO_AFILIACIONES', id_registro_afectado => $nuevo_id,
                      detalles => "Nueva afiliación: $nombre $apellido_paterno", ip => $cgi->remote_addr);
        }
        $guardado_ok = 1;
    }
}

print encabezado(titulo => ($id_edicion ? 'Editar Afiliación' : 'Registro de Afiliaciones'),
                  usuario_nombre => obtener_texto_sesion($session, 'nombre'), rol => $rol,
                  dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'REGISTRO_AFILIACIONES');

if ($guardado_ok) {
    my $mensaje = $id_edicion ? '¡Afiliación actualizada!' : '¡Afiliación registrada!';
    print qq(<div class="alert alert-success">
             <strong>$mensaje</strong>
             <a href="afiliaciones_nueva.pl" class="alert-link">Capturar otra</a> ·
             <a href="afiliaciones_listado.pl" class="alert-link">Ver el listado</a>
           </div>);
} elsif ($registro_existente && $registro_existente->{estatus} eq 'RECHAZADA') {
    # este registro fue rechazado: mostrar el motivo para que se
    # corrija con seguimiento puntual antes de reenviarlo a revisión
    my $sth_motivo = $dbh->prepare(
        'SELECT observaciones FROM verificaciones_afiliaciones
         WHERE id_afiliacion = ? AND decision = "RECHAZADO"
         ORDER BY fecha_verificacion DESC LIMIT 1'
    );
    $sth_motivo->execute($id_edicion);
    my ($motivo_rechazo) = $sth_motivo->fetchrow_array;
    print '<div class="alert alert-danger"><strong>Este registro fue rechazado.</strong> Corrige lo necesario y vuelve a enviarlo a revisión desde el listado.';
    print qq(<div class="mt-1">Motivo: $motivo_rechazo</div>) if length($motivo_rechazo // '');
    print '</div>';
}

my $datos_para_formulario = ($cgi->request_method eq 'POST' && !$guardado_ok) ? \%valores_formulario : $registro_existente;
mostrar_formulario($dbh, $datos_para_formulario, \%campo_invalido);
print pie_pagina();

# ============================================================
sub mostrar_formulario {
    my ($dbh, $r, $campo_invalido) = @_;
    $r //= {}; # sin registro previo = formulario vacío (alta)
    $campo_invalido //= {};

    # clase, mensaje y resaltado de fondo para un campo con error. No
    # dependemos solo de "is-invalid" para que el error sea imposible de ignorar y quede visible hasta
    # que se vuelva a enviar el formulario corregido.
    my $clase_error = sub { $campo_invalido->{ $_[0] } ? 'is-invalid' : '' };
    my $mensaje_error = sub {
        $campo_invalido->{ $_[0] }
            ? qq(<div class="invalid-feedback d-block fw-semibold"><i class="bi bi-exclamation-triangle-fill me-1"></i>$campo_invalido->{ $_[0] }</div>)
            : '';
    };
    my $grupo_error = sub {
        $campo_invalido->{ $_[0] } ? 'bg-danger-subtle border border-danger rounded-3 p-2' : '';
    };

    my $sth = $dbh->prepare('SELECT id_municipio, nombre FROM municipios ORDER BY nombre');
    $sth->execute;
    my $opciones_municipio = '<option value="">Selecciona un municipio</option>';
    my $opciones_municipio_domicilio = '<option value="">Selecciona un municipio</option>';
    while (my ($id, $nombre) = $sth->fetchrow_array) {
        my $sel = ($r->{id_municipio_afiliacion} && $r->{id_municipio_afiliacion} == $id) ? 'selected' : '';
        $opciones_municipio .= qq(<option value="$id" $sel>$nombre</option>);

        my $nombre_mayus = uc($nombre); # DBD::mysql (mysql_enable_utf8mb4) ya entrega el texto decodificado
        my $sel_domicilio = (($r->{domicilio_municipio} // '') eq $nombre_mayus) ? 'selected' : '';
        $opciones_municipio_domicilio .= qq(<option value="$nombre_mayus" $sel_domicilio>$nombre</option>);
    }

    my $requerido_archivos = $r->{id_afiliacion} ? '' : 'required'; # opcional solo en edición
    my $nota_archivos = $r->{id_afiliacion} ? '<small class="text-muted d-block">Deja en blanco para conservar el archivo actual.</small>' : '';
    my $nota_firma_existente = ($r->{id_afiliacion} && $r->{firma})
        ? qq(<div class="mb-2"><div class="small text-muted">Firma actual:</div><img src="$r->{firma}" style="max-height:80px;" class="border rounded-3 p-1"></div>)
        : '';

    print qq(
    <div class="card border-0 shadow-sm"><div class="card-body">
    <form id="form_afiliacion" method="post" action="afiliaciones_nueva.pl@{[ $r->{id_afiliacion} ? qq(?accion=editar&id=$r->{id_afiliacion}) : '' ]}" enctype="multipart/form-data" novalidate autocomplete="off">

      <h6 class="text-ieeq-primary mb-3">Identificación</h6>
      <div class="row g-3 mb-4">
        <div class="col-md-4 @{[ $grupo_error->('nombre') ]}">
          <label class="form-label">Nombre(s)</label>
          <input class="form-control text-uppercase @{[ $clase_error->('nombre') ]}" name="nombre" value="@{[ $r->{nombre} // '' ]}" required>
          @{[ $mensaje_error->('nombre') ]}
        </div>
        <div class="col-md-4 @{[ $grupo_error->('apellido_paterno') ]}">
          <label class="form-label">Apellido paterno</label>
          <input class="form-control text-uppercase @{[ $clase_error->('apellido_paterno') ]}" name="apellido_paterno" value="@{[ $r->{apellido_paterno} // '' ]}" required>
          @{[ $mensaje_error->('apellido_paterno') ]}
        </div>
        <div class="col-md-4">
          <label class="form-label">Apellido materno</label>
          <input class="form-control text-uppercase" name="apellido_materno" value="@{[ $r->{apellido_materno} // '' ]}">
        </div>
        <div class="col-md-4 @{[ $grupo_error->('clave_elector') ]}">
          <label class="form-label">Clave de elector</label>
          <input class="form-control text-uppercase @{[ $clase_error->('clave_elector') ]}" name="clave_elector" maxlength="18" minlength="18" value="@{[ $r->{clave_elector} // '' ]}" required>
          <small class="text-muted">Debe tener exactamente 18 caracteres, tal como aparece en la credencial.</small>
          @{[ $mensaje_error->('clave_elector') ]}
        </div>
        <div class="col-md-4 @{[ $grupo_error->('ocr') ]}">
          <label class="form-label">Número OCR</label>
          <input class="form-control text-uppercase @{[ $clase_error->('ocr') ]}" name="ocr" maxlength="18" value="@{[ $r->{ocr} // '' ]}" required>
          @{[ $mensaje_error->('ocr') ]}
        </div>
      </div>

      <h6 class="text-ieeq-primary mb-3">Domicilio (según la credencial para votar)</h6>
      <div class="row g-3 mb-4">
        <div class="col-md-4 @{[ $grupo_error->('domicilio_calle') ]}">
          <label class="form-label">Calle</label>
          <input class="form-control text-uppercase @{[ $clase_error->('domicilio_calle') ]}" name="domicilio_calle" value="@{[ $r->{domicilio_calle} // '' ]}" required>
          @{[ $mensaje_error->('domicilio_calle') ]}
        </div>
        <div class="col-md-2 @{[ $grupo_error->('domicilio_numero') ]}">
          <label class="form-label">Número exterior</label>
          <input class="form-control text-uppercase @{[ $clase_error->('domicilio_numero') ]}" name="domicilio_numero" value="@{[ $r->{domicilio_numero} // '' ]}" required>
          @{[ $mensaje_error->('domicilio_numero') ]}
        </div>
        <div class="col-md-2"><label class="form-label">Número interior</label><input class="form-control text-uppercase" name="domicilio_numero_interior" value="@{[ $r->{domicilio_numero_interior} // '' ]}"></div>
        <div class="col-md-3 @{[ $grupo_error->('domicilio_colonia') ]}">
          <label class="form-label">Colonia</label>
          <input class="form-control text-uppercase @{[ $clase_error->('domicilio_colonia') ]}" name="domicilio_colonia" value="@{[ $r->{domicilio_colonia} // '' ]}" required>
          @{[ $mensaje_error->('domicilio_colonia') ]}
        </div>
        <div class="col-md-3 @{[ $grupo_error->('domicilio_municipio') ]}">
          <label class="form-label">Municipio</label>
          <select class="form-select @{[ $clase_error->('domicilio_municipio') ]}" name="domicilio_municipio" required>$opciones_municipio_domicilio</select>
          @{[ $mensaje_error->('domicilio_municipio') ]}
        </div>
        <div class="col-md-3">
          <label class="form-label">Estado</label>
          <input class="form-control" value="QUERÉTARO" readonly>
        </div>
        <div class="col-md-3 @{[ $grupo_error->('domicilio_cp') ]}">
          <label class="form-label">Código postal</label>
          <input class="form-control" name="domicilio_cp" value="@{[ $r->{domicilio_cp} // '' ]}" required>
          @{[ $mensaje_error->('domicilio_cp') ]}
        </div>
      </div>

      <h6 class="text-ieeq-primary mb-3">Contexto de la afiliación</h6>
      <div class="row g-3 mb-4">
        <div class="col-md-6 @{[ $grupo_error->('id_municipio_afiliacion') ]}">
          <label class="form-label">Municipio de afiliación</label>
          <select class="form-select @{[ $clase_error->('id_municipio_afiliacion') ]}" name="id_municipio_afiliacion" required>$opciones_municipio</select>
          @{[ $mensaje_error->('id_municipio_afiliacion') ]}
          <small class="text-muted">Debe ser uno de los 18 municipios autorizados del estado.</small>
        </div>
      </div>

      <h6 class="text-ieeq-primary mb-3">Evidencia fotográfica</h6>
      <div class="row g-3 mb-4">
        <div class="col-md-4 @{[ $grupo_error->('foto_anverso_ine') ]}">
          <label class="form-label">Anverso de la credencial</label>
          <input class="form-control @{[ $clase_error->('foto_anverso_ine') ]}" type="file" name="foto_anverso_ine" accept="image/jpeg,image/png" capture="environment" $requerido_archivos>
          @{[ $mensaje_error->('foto_anverso_ine') ]}
          $nota_archivos
        </div>
        <div class="col-md-4 @{[ $grupo_error->('foto_reverso_ine') ]}">
          <label class="form-label">Reverso de la credencial</label>
          <input class="form-control @{[ $clase_error->('foto_reverso_ine') ]}" type="file" name="foto_reverso_ine" accept="image/jpeg,image/png" capture="environment" $requerido_archivos>
          @{[ $mensaje_error->('foto_reverso_ine') ]}
          $nota_archivos
        </div>
        <div class="col-md-4 @{[ $grupo_error->('foto_persona') ]}">
          <label class="form-label">Fotografía de la persona (selfie)</label>
          <input class="form-control @{[ $clase_error->('foto_persona') ]}" type="file" name="foto_persona" accept="image/jpeg,image/png" capture="user" $requerido_archivos>
          @{[ $mensaje_error->('foto_persona') ]}
          $nota_archivos
        </div>
      </div>

      <h6 class="text-ieeq-primary mb-3">Firma en pantalla</h6>
      <div class="row g-3 mb-4">
        <div class="col-md-6 @{[ $grupo_error->('firma_datos') ]}">
          $nota_firma_existente
          <canvas id="lienzo_firma" width="500" height="180" class="border rounded-3 w-100 @{[ $campo_invalido->{firma_datos} ? 'border-danger border-2' : '' ]}" style="touch-action:none; background:#fff; max-width:500px;"></canvas>
          <input type="hidden" name="firma_datos" id="firma_datos">
          @{[ $campo_invalido->{firma_datos} ? qq(<div class="invalid-feedback d-block fw-semibold"><i class="bi bi-exclamation-triangle-fill me-1"></i>$campo_invalido->{firma_datos}</div>) : '' ]}
          <div class="mt-2">
            <button type="button" class="btn btn-sm btn-outline-secondary" onclick="limpiarFirma()"><i class="bi bi-eraser me-1"></i>Limpiar</button>
          </div>
          <small class="text-muted d-block mt-1">Firma con el dedo (en pantalla táctil) o con el mouse, dentro del recuadro.@{[ $r->{id_afiliacion} ? ' Si no vuelves a firmar aquí, se conserva la firma que ya estaba guardada.' : '' ]}</small>
        </div>
      </div>

      <script>
        (function() {
          const canvas = document.getElementById('lienzo_firma');
          const ctx = canvas.getContext('2d');
          ctx.lineWidth = 2;
          ctx.lineCap = 'round';
          ctx.strokeStyle = '#212529';
          let dibujando = false;
          let firmoAlgo = false;

          function posicion(evento) {
            const rect = canvas.getBoundingClientRect();
            const escalaX = canvas.width / rect.width;
            const escalaY = canvas.height / rect.height;
            const punto = evento.touches ? evento.touches[0] : evento;
            return {
              x: (punto.clientX - rect.left) * escalaX,
              y: (punto.clientY - rect.top) * escalaY,
            };
          }
          function iniciar(evento) {
            evento.preventDefault();
            dibujando = true;
            firmoAlgo = true;
            const p = posicion(evento);
            ctx.beginPath();
            ctx.moveTo(p.x, p.y);
          }
          function mover(evento) {
            if (!dibujando) return;
            evento.preventDefault();
            const p = posicion(evento);
            ctx.lineTo(p.x, p.y);
            ctx.stroke();
          }
          function soltar() { dibujando = false; }

          canvas.addEventListener('mousedown', iniciar);
          canvas.addEventListener('mousemove', mover);
          canvas.addEventListener('mouseup', soltar);
          canvas.addEventListener('mouseleave', soltar);
          canvas.addEventListener('touchstart', iniciar);
          canvas.addEventListener('touchmove', mover);
          canvas.addEventListener('touchend', soltar);

          window.limpiarFirma = function() {
            ctx.clearRect(0, 0, canvas.width, canvas.height);
            firmoAlgo = false;
          };

          canvas.closest('form').addEventListener('submit', function() {
            if (firmoAlgo) {
              document.getElementById('firma_datos').value = canvas.toDataURL('image/png');
            }
          });
        })();
      </script>

      <h6 class="text-ieeq-primary mb-3">Declaraciones (las 4 son obligatorias)</h6>
      <div class="mb-4">
        <div class="form-check mb-2 p-2 @{[ $grupo_error->('acepta_afiliacion_libre') ]}">
          <input class="form-check-input @{[ $clase_error->('acepta_afiliacion_libre') ]}" type="checkbox" name="acepta_afiliacion_libre" value="1" id="c1" @{[ $r->{acepta_afiliacion_libre} ? 'checked' : '' ]} required>
          <label class="form-check-label" for="c1">La afiliación es libre y voluntaria.</label>
          @{[ $mensaje_error->('acepta_afiliacion_libre') ]}
        </div>
        <div class="form-check mb-2 p-2 @{[ $grupo_error->('acepta_documentos') ]}">
          <input class="form-check-input @{[ $clase_error->('acepta_documentos') ]}" type="checkbox" name="acepta_documentos" value="1" id="c2" @{[ $r->{acepta_documentos} ? 'checked' : '' ]} required>
          <label class="form-check-label" for="c2">Declaro conocer los documentos básicos de la asociación.</label>
          @{[ $mensaje_error->('acepta_documentos') ]}
        </div>
        <div class="form-check mb-2 p-2 @{[ $grupo_error->('acepta_no_otro_partido') ]}">
          <input class="form-check-input @{[ $clase_error->('acepta_no_otro_partido') ]}" type="checkbox" name="acepta_no_otro_partido" value="1" id="c3" @{[ $r->{acepta_no_otro_partido} ? 'checked' : '' ]} required>
          <label class="form-check-label" for="c3">No estoy afiliado(a) previamente a otra organización política.</label>
          @{[ $mensaje_error->('acepta_no_otro_partido') ]}
        </div>
        <div class="form-check mb-2 p-2 @{[ $grupo_error->('acepta_aviso_privacidad') ]}">
          <input class="form-check-input @{[ $clase_error->('acepta_aviso_privacidad') ]}" type="checkbox" name="acepta_aviso_privacidad" value="1" id="c4" @{[ $r->{acepta_aviso_privacidad} ? 'checked' : '' ]} required>
          <label class="form-check-label" for="c4">Acepto el aviso de privacidad.</label>
          @{[ $mensaje_error->('acepta_aviso_privacidad') ]}
        </div>
      </div>

      <button type="submit" class="btn btn-primary" id="btn_guardar">@{[ $r->{id_afiliacion} ? 'Guardar cambios' : 'Guardar afiliación' ]}</button>
      <a href="afiliaciones_listado.pl" class="btn btn-secondary">Cancelar</a>
    </form>
    </div></div>

    <script>
      // evita el doble clic / doble envío (que crearía afiliaciones
      // duplicadas): en cuanto se envía el formulario, se bloquea el
      // botón. Si el servidor responde con errores de validación, la
      // página se recarga completa y el botón vuelve a su estado normal.
      (function() {
        const form = document.getElementById('form_afiliacion');
        const boton = document.getElementById('btn_guardar');
        form.addEventListener('submit', function() {
          boton.disabled = true;
          boton.textContent = 'Guardando...';
        });
      })();
    </script>
    );
}

sub trim {
    my ($s) = @_;
    return '' unless defined $s;
    $s = decode_utf8($s);
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

# --- todos los datos capturados en este formulario se guardan en
#     mayúsculas (regla de negocio); decode_utf8 en trim() asegura
#     que uc() también convierta correctamente letras acentuadas ---
sub mayus {
    return uc(trim($_[0]));
}
