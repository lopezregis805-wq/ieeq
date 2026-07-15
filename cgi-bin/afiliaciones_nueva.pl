#!/usr/bin/perl
# ============================================================
# afiliaciones_nueva.pl — Registro de Afiliaciones (manual,
# sección 5.4 y Diagrama 7). El proceso más complejo del
# sistema: combina datos personales, evidencia fotográfica y
# declaraciones legales.
#
# También maneja la EDICIÓN (?accion=editar&id=N), llamado
# desde afiliaciones_listado.pl, siguiendo el mismo patrón que
# ya usamos en asociaciones.pl y usuarios.pl: un solo script
# para alta y edición, en vez de duplicar el formulario.
#
# Reglas de negocio de esta pantalla (manual, sección 8):
#   - las 4 casillas de aceptación son obligatorias; si falta
#     una, el sistema NO permite guardar el registro
#   - toda afiliación nueva inicia siempre en estatus "Nueva
#     afiliación"
#   - solo se puede editar mientras el estatus sea "Nueva
#     afiliación", y solo quien la capturó o el administrador
#     de su asociación (regla ya aplicada también en la BD
#     mediante el trigger trg_validar_edicion_afiliacion)
#   - el lugar de afiliación debe ser uno de los 18 municipios
#     autorizados del catálogo (no texto libre)
# ============================================================
use strict;
use warnings;
use utf8;                            # el codigo fuente de este archivo esta en UTF-8
use CGI;
use FindBin qw($Bin);
use MIME::Base64 qw(decode_base64);
use lib './lib';
use DB qw(conectar);
use Auth qw(iniciar_sesion requerir_sesion tiene_permiso obtener_texto_sesion);
use Bitacora qw(registrar);
use Plantilla qw(encabezado pie_pagina);

my $cgi = CGI->new;
binmode(STDOUT, ":encoding(UTF-8)");
my $session = iniciar_sesion($cgi);
my $id_usuario = requerir_sesion($session, $cgi);
my $dbh = conectar();
my $rol = $session->param('rol');
my $id_asociacion_sesion = $session->param('id_asociacion');

unless (tiene_permiso($dbh, $id_usuario, 'REGISTRO_AFILIACIONES', 'ESCRITURA')) {
    print $cgi->header(-charset => 'utf-8', -status => '403 Forbidden');
    print "No tienes permiso de captura en este módulo.";
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
    if ($registro_existente && $registro_existente->{estatus} eq 'NUEVA') {
        $autorizado = 1 if $rol eq 'SUPERADMIN';
        $autorizado = 1 if $rol eq 'ADMIN_ASOCIACION' && $registro_existente->{id_asociacion_registrador} == $id_asociacion_sesion;
        $autorizado = 1 if $rol eq 'AUXILIAR' && $registro_existente->{id_registrador} == $id_usuario;
    }
    unless ($autorizado) {
        print $cgi->header(-charset => 'utf-8', -status => '403 Forbidden');
        print "Este registro no existe, ya no está en estatus \"Nueva afiliación\", o no te pertenece.";
        exit;
    }
}

my @errores;
my $guardado_ok = 0;

if ($cgi->request_method eq 'POST') {
    my $id_municipio = $cgi->param('id_municipio_afiliacion') || undef;
    my $nombre             = trim($cgi->param('nombre'));
    my $apellido_paterno   = trim($cgi->param('apellido_paterno'));
    my $apellido_materno   = trim($cgi->param('apellido_materno'));
    my $domicilio_calle    = trim($cgi->param('domicilio_calle'));
    my $domicilio_numero   = trim($cgi->param('domicilio_numero'));
    my $domicilio_colonia  = trim($cgi->param('domicilio_colonia'));
    my $domicilio_municipio= trim($cgi->param('domicilio_municipio'));
    my $domicilio_estado   = trim($cgi->param('domicilio_estado'));
    my $domicilio_cp       = trim($cgi->param('domicilio_cp'));
    my $clave_elector      = trim($cgi->param('clave_elector'));
    my $ocr                = trim($cgi->param('ocr'));
    my $cic                = trim($cgi->param('cic'));

    # --- las 4 casillas obligatorias (regla critica del manual) ---
    my $acepta_libre      = $cgi->param('acepta_afiliacion_libre') ? 1 : 0;
    my $acepta_documentos = $cgi->param('acepta_documentos')       ? 1 : 0;
    my $acepta_no_otro    = $cgi->param('acepta_no_otro_partido')  ? 1 : 0;
    my $acepta_aviso      = $cgi->param('acepta_aviso_privacidad') ? 1 : 0;

    push @errores, 'El municipio de afiliación es obligatorio.' unless $id_municipio;
    push @errores, 'El nombre es obligatorio.'                   unless length $nombre;
    push @errores, 'El apellido paterno es obligatorio.'          unless length $apellido_paterno;

    unless ($acepta_libre && $acepta_documentos && $acepta_no_otro && $acepta_aviso) {
        push @errores, 'Debes marcar las 4 casillas de aceptación para poder guardar el registro.';
    }

    # --- evidencia: en alta los 3 archivos (fotos) son
    #     obligatorios; en edición son OPCIONALES (si no se sube
    #     uno nuevo, se conserva el que ya estaba guardado). La
    #     firma se maneja aparte, más abajo: viene de un <canvas>
    #     donde la persona firma en pantalla, no de un archivo. ---
    my %rutas;
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
            }
            next;
        }
        my $tipo = $cgi->uploadInfo($archivo)->{'Content-Type'};
        unless ($tipo eq 'image/jpeg' || $tipo eq 'image/png') {
            push @errores, "$info->{etiqueta} debe ser una imagen JPG o PNG.";
            next;
        }
        my $tamano = -s $archivo;
        if ($tamano > 5_242_880) { # 5 MB, tope razonable para evitar archivos enormes
            push @errores, "$info->{etiqueta} no puede superar 5 MB.";
            next;
        }
        my $extension = ($tipo eq 'image/png') ? 'png' : 'jpg';
        my $nombre_archivo = "${campo}_" . time() . "_$$.${extension}";
        my $ruta_relativa = "$info->{carpeta}/$nombre_archivo";
        open(my $fh, '>', "$Bin/$ruta_relativa") or do {
            push @errores, "No se pudo guardar $info->{etiqueta}: $!";
            next;
        };
        binmode $fh;
        binmode $archivo;
        print {$fh} $_ while <$archivo>;
        close $fh;
        $rutas{$campo} = $ruta_relativa;
    }

    # --- firma: llega como PNG en base64 desde el <canvas> del
    #     formulario (campo oculto "firma_datos"), no como archivo ---
    my $firma_datos = $cgi->param('firma_datos') // '';
    if ($firma_datos =~ /^data:image\/png;base64,(.+)$/) {
        my $bytes = decode_base64($1);
        if (length($bytes) > 5_242_880) {
            push @errores, 'La firma no puede superar 5 MB.';
        } else {
            my $nombre_archivo = "firma_" . time() . "_$$.png";
            my $ruta_relativa = "uploads/firmas/$nombre_archivo";
            my $abierto = open(my $fh, '>', "$Bin/$ruta_relativa");
            if (!$abierto) {
                push @errores, "No se pudo guardar la firma: $!";
            } else {
                binmode $fh;
                print {$fh} $bytes;
                close $fh;
                $rutas{firma} = $ruta_relativa;
            }
        }
    } elsif ($id_edicion) {
        $rutas{firma} = $registro_existente->{firma}; # no volvió a firmar: conservar la anterior
    } else {
        push @errores, 'La firma en pantalla es obligatoria.';
    }

    if (!@errores) {
        if ($id_edicion) {
            $dbh->do(
                'UPDATE afiliaciones SET
                    id_municipio_afiliacion=?, nombre=?, apellido_paterno=?, apellido_materno=?,
                    domicilio_calle=?, domicilio_numero=?, domicilio_colonia=?, domicilio_municipio=?,
                    domicilio_estado=?, domicilio_cp=?, clave_elector=?, ocr=?, cic=?,
                    foto_anverso_ine=?, foto_reverso_ine=?, foto_persona=?, firma=?,
                    acepta_afiliacion_libre=?, acepta_documentos=?, acepta_no_otro_partido=?, acepta_aviso_privacidad=?,
                    id_usuario_actualizacion=?
                 WHERE id_afiliacion=?',
                undef,
                $id_municipio, $nombre, $apellido_paterno, $apellido_materno,
                $domicilio_calle, $domicilio_numero, $domicilio_colonia, $domicilio_municipio,
                $domicilio_estado, $domicilio_cp, $clave_elector, $ocr, $cic,
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
                    domicilio_calle, domicilio_numero, domicilio_colonia, domicilio_municipio,
                    domicilio_estado, domicilio_cp, clave_elector, ocr, cic,
                    foto_anverso_ine, foto_reverso_ine, foto_persona, firma,
                    acepta_afiliacion_libre, acepta_documentos, acepta_no_otro_partido, acepta_aviso_privacidad,
                    estatus, id_registrador
                 ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,\'NUEVA\',?)',
                undef,
                $id_municipio, $nombre, $apellido_paterno, $apellido_materno,
                $domicilio_calle, $domicilio_numero, $domicilio_colonia, $domicilio_municipio,
                $domicilio_estado, $domicilio_cp, $clave_elector, $ocr, $cic,
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
}

if (@errores) {
    print '<div class="alert alert-danger"><ul class="mb-0">';
    print "<li>$_</li>" for @errores;
    print '</ul></div>';
}

mostrar_formulario($dbh, $registro_existente);
print pie_pagina();

# ============================================================
sub mostrar_formulario {
    my ($dbh, $r) = @_;
    $r //= {}; # sin registro previo = formulario vacío (alta)

    my $sth = $dbh->prepare('SELECT id_municipio, nombre FROM municipios ORDER BY nombre');
    $sth->execute;
    my $opciones_municipio = '<option value="">Selecciona un municipio</option>';
    while (my ($id, $nombre) = $sth->fetchrow_array) {
        my $sel = ($r->{id_municipio_afiliacion} && $r->{id_municipio_afiliacion} == $id) ? 'selected' : '';
        $opciones_municipio .= qq(<option value="$id" $sel>$nombre</option>);
    }

    my $requerido_archivos = $r->{id_afiliacion} ? '' : 'required'; # opcional solo en edición
    my $nota_archivos = $r->{id_afiliacion} ? '<small class="text-muted d-block">Deja en blanco para conservar el archivo actual.</small>' : '';
    my $nota_firma_existente = ($r->{id_afiliacion} && $r->{firma})
        ? qq(<div class="mb-2"><div class="small text-muted">Firma actual:</div><img src="$r->{firma}" style="max-height:80px;" class="border rounded-3 p-1"></div>)
        : '';

    print qq(
    <div class="card border-0 shadow-sm"><div class="card-body">
    <form method="post" action="afiliaciones_nueva.pl@{[ $r->{id_afiliacion} ? qq(?accion=editar&id=$r->{id_afiliacion}) : '' ]}" enctype="multipart/form-data">

      <h6 class="text-ieeq-primary mb-3">Identificación</h6>
      <div class="row g-3 mb-4">
        <div class="col-md-4">
          <label class="form-label">Nombre(s)</label>
          <input class="form-control" name="nombre" value="@{[ $r->{nombre} // '' ]}" required>
        </div>
        <div class="col-md-4">
          <label class="form-label">Apellido paterno</label>
          <input class="form-control" name="apellido_paterno" value="@{[ $r->{apellido_paterno} // '' ]}" required>
        </div>
        <div class="col-md-4">
          <label class="form-label">Apellido materno</label>
          <input class="form-control" name="apellido_materno" value="@{[ $r->{apellido_materno} // '' ]}">
        </div>
        <div class="col-md-4">
          <label class="form-label">Clave de elector</label>
          <input class="form-control" name="clave_elector" maxlength="18" value="@{[ $r->{clave_elector} // '' ]}">
        </div>
        <div class="col-md-4">
          <label class="form-label">Número OCR</label>
          <input class="form-control" name="ocr" maxlength="18" value="@{[ $r->{ocr} // '' ]}">
        </div>
        <div class="col-md-4">
          <label class="form-label">Código CIC</label>
          <input class="form-control" name="cic" maxlength="18" value="@{[ $r->{cic} // '' ]}">
        </div>
      </div>

      <h6 class="text-ieeq-primary mb-3">Domicilio (según la credencial para votar)</h6>
      <div class="row g-3 mb-4">
        <div class="col-md-4"><label class="form-label">Calle</label><input class="form-control" name="domicilio_calle" value="@{[ $r->{domicilio_calle} // '' ]}"></div>
        <div class="col-md-2"><label class="form-label">Número</label><input class="form-control" name="domicilio_numero" value="@{[ $r->{domicilio_numero} // '' ]}"></div>
        <div class="col-md-3"><label class="form-label">Colonia</label><input class="form-control" name="domicilio_colonia" value="@{[ $r->{domicilio_colonia} // '' ]}"></div>
        <div class="col-md-3"><label class="form-label">Municipio</label><input class="form-control" name="domicilio_municipio" value="@{[ $r->{domicilio_municipio} // '' ]}"></div>
        <div class="col-md-3"><label class="form-label">Estado</label><input class="form-control" name="domicilio_estado" value="@{[ $r->{domicilio_estado} // 'Querétaro' ]}"></div>
        <div class="col-md-3"><label class="form-label">Código postal</label><input class="form-control" name="domicilio_cp" value="@{[ $r->{domicilio_cp} // '' ]}"></div>
      </div>

      <h6 class="text-ieeq-primary mb-3">Contexto de la afiliación</h6>
      <div class="row g-3 mb-4">
        <div class="col-md-6">
          <label class="form-label">Municipio de afiliación</label>
          <select class="form-select" name="id_municipio_afiliacion" required>$opciones_municipio</select>
          <small class="text-muted">Debe ser uno de los 18 municipios autorizados del estado.</small>
        </div>
      </div>

      <h6 class="text-ieeq-primary mb-3">Evidencia fotográfica</h6>
      <div class="row g-3 mb-4">
        <div class="col-md-4">
          <label class="form-label">Anverso de la credencial</label>
          <input class="form-control" type="file" name="foto_anverso_ine" accept="image/jpeg,image/png" $requerido_archivos>
          $nota_archivos
        </div>
        <div class="col-md-4">
          <label class="form-label">Reverso de la credencial</label>
          <input class="form-control" type="file" name="foto_reverso_ine" accept="image/jpeg,image/png" $requerido_archivos>
          $nota_archivos
        </div>
        <div class="col-md-4">
          <label class="form-label">Fotografía de la persona (selfie)</label>
          <input class="form-control" type="file" name="foto_persona" accept="image/jpeg,image/png" $requerido_archivos>
          $nota_archivos
        </div>
      </div>

      <h6 class="text-ieeq-primary mb-3">Firma en pantalla</h6>
      <div class="row g-3 mb-4">
        <div class="col-md-6">
          $nota_firma_existente
          <canvas id="lienzo_firma" width="500" height="180" class="border rounded-3 w-100" style="touch-action:none; background:#fff; max-width:500px;"></canvas>
          <input type="hidden" name="firma_datos" id="firma_datos">
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
        <div class="form-check mb-2">
          <input class="form-check-input" type="checkbox" name="acepta_afiliacion_libre" value="1" id="c1" @{[ $r->{acepta_afiliacion_libre} ? 'checked' : '' ]} required>
          <label class="form-check-label" for="c1">La afiliación es libre y voluntaria.</label>
        </div>
        <div class="form-check mb-2">
          <input class="form-check-input" type="checkbox" name="acepta_documentos" value="1" id="c2" @{[ $r->{acepta_documentos} ? 'checked' : '' ]} required>
          <label class="form-check-label" for="c2">Declaro conocer los documentos básicos de la asociación.</label>
        </div>
        <div class="form-check mb-2">
          <input class="form-check-input" type="checkbox" name="acepta_no_otro_partido" value="1" id="c3" @{[ $r->{acepta_no_otro_partido} ? 'checked' : '' ]} required>
          <label class="form-check-label" for="c3">No estoy afiliado(a) previamente a otra organización política.</label>
        </div>
        <div class="form-check mb-2">
          <input class="form-check-input" type="checkbox" name="acepta_aviso_privacidad" value="1" id="c4" @{[ $r->{acepta_aviso_privacidad} ? 'checked' : '' ]} required>
          <label class="form-check-label" for="c4">Acepto el aviso de privacidad.</label>
        </div>
      </div>

      <button type="submit" class="btn btn-primary">@{[ $r->{id_afiliacion} ? 'Guardar cambios' : 'Guardar afiliación' ]}</button>
      <a href="afiliaciones_listado.pl" class="btn btn-secondary">Cancelar</a>
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
