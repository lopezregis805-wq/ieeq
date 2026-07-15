#!/usr/bin/perl
# ============================================================
# asociaciones.pl — Gestión de Asociaciones Políticas Estatales.
#
# Este script es el "patrón de referencia": los demás módulos
# (padron.pl, usuarios.pl, etc.) se construyen copiando esta
# misma estructura de 5 pasos:
#   1. sesión + permiso
#   2. leer acción (listar / nuevo / guardar / editar)
#   3. validar reglas de negocio del manual
#   4. ejecutar el SQL correspondiente
#   5. registrar en bitácora y mostrar HTML
#
# Reglas de negocio de esta pantalla (manual, Diagrama 5 y
# regla crítica de la sección 8):
#   - la fecha de pérdida de registro es obligatoria SOLO si
#     el estatus se marca como "Sin registro"
#   - el emblema debe ser JPG y no superar 1 MB
# ============================================================
use strict;
use warnings;
use utf8;                            # el codigo fuente de este archivo esta en UTF-8
use CGI;
use FindBin qw($Bin);
use lib './lib';
use DB qw(conectar);
use Auth qw(iniciar_sesion requerir_sesion tiene_permiso obtener_texto_sesion);
use Bitacora qw(registrar);
use Plantilla qw(encabezado pie_pagina);

my $cgi = CGI->new;
binmode(STDOUT, ":encoding(UTF-8)");   # lo que imprimimos tambien debe salir en UTF-8
my $session = iniciar_sesion($cgi);
my $id_usuario = requerir_sesion($session, $cgi);
my $dbh = conectar();
my $rol_sesion = $session->param('rol');
my $id_asociacion_sesion = $session->param('id_asociacion');

# --- ¿este usuario puede editar la asociación $id_objetivo? ---
# SUPERADMIN: cualquiera. ADMIN_ASOCIACION: SOLO la suya propia.
# Nadie más (Funcionariado IEEQ, Auxiliares) tiene escritura aquí.
sub puede_editar_asociacion {
    my ($rol, $id_asociacion_sesion, $id_objetivo) = @_;
    return 1 if $rol eq 'SUPERADMIN';
    return 1 if $rol eq 'ADMIN_ASOCIACION' && $id_asociacion_sesion && $id_objetivo && $id_asociacion_sesion == $id_objetivo;
    return 0;
}

# --- Paso 1: control de acceso a este módulo -----------------
# Si el usuario no tiene ni siquiera LECTURA, no debería haber
# llegado aquí (el menú no le hubiera mostrado el enlace), pero
# igual lo validamos: nunca hay que confiar solo en que el menú
# "no lo muestre".
unless (tiene_permiso($dbh, $id_usuario, 'GESTION_ASOCIACIONES', 'LECTURA')) {
    print $cgi->header(-charset => 'utf-8', -status => '403 Forbidden');
    print "Acceso no autorizado a este módulo.";
    exit;
}

my $accion = $cgi->param('accion') // 'listar';
my @errores;

# --- Paso 2 y 3: procesar el guardado ---------------------------
if ($accion eq 'guardar' && $cgi->request_method eq 'POST') {
    my $id_objetivo = $cgi->param('id_asociacion') || undef;

    # Alta (sin id): SOLO SUPERADMIN. Edición (con id): SUPERADMIN,
    # o ADMIN_ASOCIACION únicamente si es SU PROPIA asociación.
    my $autorizado = $id_objetivo
        ? puede_editar_asociacion($rol_sesion, $id_asociacion_sesion, $id_objetivo)
        : ($rol_sesion eq 'SUPERADMIN');

    unless ($autorizado) {
        print $cgi->header(-charset => 'utf-8', -status => '403 Forbidden');
        print $id_objetivo
            ? "Solo puedes editar la información de tu propia asociación."
            : "Solo el Administrador del Sistema puede dar de alta nuevas asociaciones.";
        exit;
    }

    my $id           = $id_objetivo; # ya lo obtuvimos y validamos arriba
    my $nombre       = trim($cgi->param('nombre'));
    my $representante= trim($cgi->param('representante_legal'));
    my $calle        = trim($cgi->param('calle'));
    my $numero       = trim($cgi->param('numero'));
    my $colonia      = trim($cgi->param('colonia'));
    my $municipio    = trim($cgi->param('municipio'));
    my $cp           = trim($cgi->param('codigo_postal'));
    my $correo       = trim($cgi->param('correo_electronico'));
    my $telefono     = trim($cgi->param('telefono'));
    my $fecha_aprob  = $cgi->param('fecha_aprobacion') || undef;
    my $estatus      = $cgi->param('estatus') || 'VIGENTE';
    my $fecha_perdida= $cgi->param('fecha_perdida_registro') || undef;

    push @errores, 'El nombre de la asociación es obligatorio.' unless length $nombre;
    push @errores, 'El representante legal es obligatorio.'     unless length $representante;

    # --- regla crítica del manual: fecha obligatoria si "Sin registro" ---
    if ($estatus eq 'SIN_REGISTRO' && !$fecha_perdida) {
        push @errores, 'La fecha de pérdida de registro es obligatoria cuando el estatus es "Sin registro".';
    }
    # Si el estatus vuelve a ser VIGENTE, no tiene sentido conservar la fecha.
    $fecha_perdida = undef if $estatus eq 'VIGENTE';

    # --- validación del emblema: JPG y máximo 1 MB ---
    my $ruta_emblema;
    my $archivo = $cgi->upload('emblema');
    if ($archivo) {
        my $info = $cgi->uploadInfo($archivo)->{'Content-Type'};
        my $tamano = -s $archivo;
        if ($info ne 'image/jpeg') {
            push @errores, 'El emblema debe ser un archivo JPG.';
        } elsif ($tamano > 1_048_576) {
            push @errores, 'El emblema no puede superar 1 MB.';
        } else {
            my $nombre_archivo = "asociacion_" . ($id // 'nueva') . "_" . time() . ".jpg";
            $ruta_emblema = "uploads/emblemas/$nombre_archivo";
            open(my $fh, '>', "$Bin/$ruta_emblema")
                or push @errores, "No se pudo guardar el emblema: $!";
            if (!@errores) {
                binmode $fh;
                print {$fh} $_ while <$archivo>;
                close $fh;
            }
        }
    }

    if (!@errores) {
        if ($id) {
            # --- edición ---
            my @campos = (
                $nombre, $representante, $calle, $numero, $colonia, $municipio, $cp,
                $correo, $telefono, $fecha_aprob, $estatus, $fecha_perdida,
            );
            my $sql = 'UPDATE asociaciones_politicas SET
                        nombre=?, representante_legal=?, calle=?, numero=?, colonia=?,
                        municipio=?, codigo_postal=?, correo_electronico=?, telefono=?,
                        fecha_aprobacion=?, estatus=?, fecha_perdida_registro=?';
            if ($ruta_emblema) { $sql .= ', emblema=?'; push @campos, $ruta_emblema; }
            $sql .= ' WHERE id_asociacion=?';
            push @campos, $id;

            $dbh->do($sql, undef, @campos);

            registrar(dbh => $dbh, id_usuario => $id_usuario, accion => 'EDICION',
                      clave_modulo => 'GESTION_ASOCIACIONES', id_registro_afectado => $id,
                      detalles => "Edición de asociación: $nombre", ip => $cgi->remote_addr);
        } else {
            # --- alta ---
            $dbh->do(
                'INSERT INTO asociaciones_politicas
                    (nombre, representante_legal, calle, numero, colonia, municipio,
                     codigo_postal, correo_electronico, telefono, fecha_aprobacion,
                     estatus, fecha_perdida_registro, emblema)
                 VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)',
                undef,
                $nombre, $representante, $calle, $numero, $colonia, $municipio, $cp,
                $correo, $telefono, $fecha_aprob, $estatus, $fecha_perdida, $ruta_emblema,
            );
            my $nuevo_id = $dbh->last_insert_id(undef, undef, 'asociaciones_politicas', undef);

            registrar(dbh => $dbh, id_usuario => $id_usuario, accion => 'REGISTRO',
                      clave_modulo => 'GESTION_ASOCIACIONES', id_registro_afectado => $nuevo_id,
                      detalles => "Alta de asociación: $nombre", ip => $cgi->remote_addr);
        }
        print $cgi->redirect('asociaciones.pl');
        exit;
    }
    $accion = $cgi->param('id_asociacion') ? 'editar' : 'nuevo'; # regresa al formulario con errores
}

# --- Paso 4 y 5: construir la vista ---------------------------
if ($accion eq 'nuevo' && $rol_sesion ne 'SUPERADMIN') {
    print $cgi->header(-charset => 'utf-8', -status => '403 Forbidden');
    print "Solo el Administrador del Sistema puede dar de alta nuevas asociaciones.";
    exit;
}
if ($accion eq 'editar') {
    my $id_objetivo = $cgi->param('id') || $cgi->param('id_asociacion');
    unless (puede_editar_asociacion($rol_sesion, $id_asociacion_sesion, $id_objetivo)) {
        print $cgi->header(-charset => 'utf-8', -status => '403 Forbidden');
        print "Solo puedes editar la información de tu propia asociación.";
        exit;
    }
}

print encabezado(titulo => 'Gestión de Asociaciones',
                 usuario_nombre => obtener_texto_sesion($session, 'nombre'), rol => $session->param('rol'),
                 dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'GESTION_ASOCIACIONES');

if (@errores) {
    print '<div class="alert alert-danger"><ul class="mb-0">';
    print "<li>$_</li>" for @errores;
    print '</ul></div>';
}

if ($accion eq 'nuevo' || $accion eq 'editar') {
    mostrar_formulario($dbh, $cgi);
} else {
    mostrar_listado($dbh, $rol_sesion, $id_asociacion_sesion);
}

print pie_pagina();

# ============================================================
# Funciones de vista
# ============================================================

sub mostrar_listado {
    my ($dbh, $rol_sesion, $id_asociacion_sesion) = @_;

    my $sql = 'SELECT * FROM asociaciones_politicas';
    my @params;
    if ($rol_sesion eq 'ADMIN_ASOCIACION') {
        $sql .= ' WHERE id_asociacion = ?';
        push @params, $id_asociacion_sesion;
    }
    $sql .= ' ORDER BY nombre';

    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);

    my $titulo = $rol_sesion eq 'ADMIN_ASOCIACION' ? 'Mi asociación' : 'Asociaciones políticas registradas';
    print qq(
    <div class="d-flex justify-content-between align-items-center mb-3">
      <div>
        <h5 class="mb-0">$titulo</h5>
        <small class="text-muted">Registro de asociaciones políticas aprobadas por el Consejo General</small>
      </div>
    );
    print '<a href="asociaciones.pl?accion=nuevo" class="btn btn-primary"><i class="bi bi-plus-lg me-1"></i>Nueva asociación</a>' if $rol_sesion eq 'SUPERADMIN';
    print '</div>';

    print '<div class="card border-0 shadow-sm"><div class="card-body p-0">';
    print '<table class="table table-hover align-middle mb-0"><thead><tr>
             <th class="ps-3">Asociación</th><th>Representante legal</th><th>Municipio</th>
             <th>Estatus</th><th class="text-end pe-3">Acciones</th>
           </tr></thead><tbody>';

    my @colores_avatar = qw(morado azul verde naranja rojo);
    my $fila = 0;
    while (my $a = $sth->fetchrow_hashref) {
        $fila++;
        my $color = $a->{estatus} eq 'VIGENTE' ? 'success' : 'danger';
        my $puede_editar_esta = puede_editar_asociacion($rol_sesion, $id_asociacion_sesion, $a->{id_asociacion});
        my $iniciales = uc(substr($a->{nombre}, 0, 2));
        my $color_avatar = $colores_avatar[$fila % scalar @colores_avatar];
        my $emblema_html = $a->{emblema}
            ? qq(<img src="$a->{emblema}" class="rounded-circle" style="width:32px;height:32px;object-fit:cover;" alt="Emblema">)
            : qq(<span class="ieeq-avatar $color_avatar">$iniciales</span>);

        print qq(
        <tr>
          <td class="ps-3">
            <div class="d-flex align-items-center gap-2">
              $emblema_html
              <div>
                <div class="fw-semibold">$a->{nombre}</div>
                <div class="text-muted small">@{[ $a->{municipio} ? "$a->{colonia}, $a->{municipio}" : '—' ]}</div>
              </div>
            </div>
          </td>
          <td>$a->{representante_legal}</td>
          <td>@{[ $a->{municipio} // '—' ]}</td>
          <td><span class="badge bg-$color-subtle text-$color-emphasis">@{[ $a->{estatus} eq 'VIGENTE' ? 'Vigente' : 'Sin registro' ]}</span></td>
          <td class="text-end pe-3">
        );
        if ($puede_editar_esta) {
            print qq(<a href="asociaciones.pl?accion=editar&id=$a->{id_asociacion}" class="btn btn-sm btn-outline-secondary" title="Editar"><i class="bi bi-pencil"></i></a>);
        }
        print '</td></tr>';
    }
    if ($fila == 0) {
        print '<tr><td colspan="5" class="text-center text-muted py-4">No hay asociaciones registradas.</td></tr>';
    }
    print '</tbody></table></div></div>';
}

sub mostrar_formulario {
    my ($dbh, $cgi) = @_;
    my $id = $cgi->param('id') || $cgi->param('id_asociacion');
    my $a = {};
    if ($id) {
        my $sth = $dbh->prepare('SELECT * FROM asociaciones_politicas WHERE id_asociacion=?');
        $sth->execute($id);
        $a = $sth->fetchrow_hashref;
    }
    my $vigente_sel = (!$a->{estatus} || $a->{estatus} eq 'VIGENTE') ? 'selected' : '';
    my $sinreg_sel  = ($a->{estatus} && $a->{estatus} eq 'SIN_REGISTRO') ? 'selected' : '';
    my $emblema_actual = $a->{emblema}
        ? qq(<div class="mt-2"><img src="$a->{emblema}" style="max-height:60px;" class="rounded border p-1" alt="Emblema actual"><div class="small text-muted">Emblema actual</div></div>)
        : '';

    print qq(
    <div class="d-flex align-items-center gap-2 mb-3">
      <a href="asociaciones.pl" class="btn btn-sm btn-outline-secondary"><i class="bi bi-arrow-left"></i></a>
      <h5 class="mb-0">@{[ $id ? 'Editar asociación' : 'Nueva asociación política' ]}</h5>
    </div>

    <div class="card border-0 shadow-sm"><div class="card-body">
    <form method="post" action="asociaciones.pl" enctype="multipart/form-data">
      <input type="hidden" name="accion" value="guardar">
      <input type="hidden" name="id_asociacion" value="@{[ $id // '' ]}">

      <h6 class="text-ieeq-primary mb-3">Datos generales</h6>
      <div class="row g-3 mb-4">
        <div class="col-md-6">
          <label class="form-label">Nombre de la asociación</label>
          <input class="form-control" name="nombre" value="@{[ $a->{nombre} // '' ]}" required>
        </div>
        <div class="col-md-6">
          <label class="form-label">Representante legal</label>
          <input class="form-control" name="representante_legal" value="@{[ $a->{representante_legal} // '' ]}" required>
        </div>
        <div class="col-md-3">
          <label class="form-label">Correo de contacto</label>
          <input class="form-control" type="email" name="correo_electronico" value="@{[ $a->{correo_electronico} // '' ]}">
        </div>
        <div class="col-md-3">
          <label class="form-label">Teléfono</label>
          <input class="form-control" name="telefono" value="@{[ $a->{telefono} // '' ]}">
        </div>
        <div class="col-md-3">
          <label class="form-label">Fecha de aprobación</label>
          <input class="form-control" type="date" name="fecha_aprobacion" value="@{[ $a->{fecha_aprobacion} // '' ]}">
        </div>
        <div class="col-md-3">
          <label class="form-label">Estatus</label>
          <select class="form-select" name="estatus" id="estatus" onchange="document.getElementById('grupo_fecha_perdida').style.display = this.value==='SIN_REGISTRO' ? 'block' : 'none';">
            <option value="VIGENTE" $vigente_sel>Vigente</option>
            <option value="SIN_REGISTRO" $sinreg_sel>Sin registro</option>
          </select>
        </div>
        <div class="col-md-4" id="grupo_fecha_perdida" style="display:@{[ $sinreg_sel ? 'block' : 'none' ]};">
          <label class="form-label">Fecha de pérdida de registro</label>
          <input class="form-control" type="date" name="fecha_perdida_registro" value="@{[ $a->{fecha_perdida_registro} // '' ]}">
          <small class="text-muted">Obligatoria si el estatus es "Sin registro".</small>
        </div>
      </div>

      <h6 class="text-ieeq-primary mb-3">Domicilio</h6>
      <div class="row g-3 mb-4">
        <div class="col-md-4"><label class="form-label">Calle</label><input class="form-control" name="calle" value="@{[ $a->{calle} // '' ]}"></div>
        <div class="col-md-2"><label class="form-label">Número</label><input class="form-control" name="numero" value="@{[ $a->{numero} // '' ]}"></div>
        <div class="col-md-3"><label class="form-label">Colonia</label><input class="form-control" name="colonia" value="@{[ $a->{colonia} // '' ]}"></div>
        <div class="col-md-3"><label class="form-label">Municipio</label><input class="form-control" name="municipio" value="@{[ $a->{municipio} // '' ]}"></div>
        <div class="col-md-3"><label class="form-label">Código postal</label><input class="form-control" name="codigo_postal" value="@{[ $a->{codigo_postal} // '' ]}"></div>
      </div>

      <h6 class="text-ieeq-primary mb-3">Identidad visual</h6>
      <div class="row g-3 mb-4">
        <div class="col-md-6">
          <label class="form-label">Emblema (JPG, máx. 1 MB)</label>
          <input class="form-control" type="file" name="emblema" accept="image/jpeg">
          $emblema_actual
        </div>
      </div>

      <div class="mt-4 d-flex gap-2">
        <button type="submit" class="btn btn-primary"><i class="bi bi-check-lg me-1"></i>Guardar</button>
        <a href="asociaciones.pl" class="btn btn-outline-secondary">Cancelar</a>
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
