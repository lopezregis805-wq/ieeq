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
use CGI;
use lib './lib';
use DB qw(conectar);
use Auth qw(iniciar_sesion requerir_sesion tiene_permiso);
use Bitacora qw(registrar);
use Plantilla qw(encabezado pie_pagina);

my $cgi = CGI->new;
my $session = iniciar_sesion($cgi);
my $id_usuario = requerir_sesion($session, $cgi);
my $dbh = conectar();

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
my $puede_escribir = tiene_permiso($dbh, $id_usuario, 'GESTION_ASOCIACIONES', 'ESCRITURA');

my $accion = $cgi->param('accion') // 'listar';
my @errores;

# --- Paso 2 y 3: procesar el guardado (solo si tiene ESCRITURA) ---
if ($accion eq 'guardar' && $cgi->request_method eq 'POST') {
    unless ($puede_escribir) {
        print $cgi->header(-charset => 'utf-8', -status => '403 Forbidden');
        print "No tienes permiso de escritura en este módulo.";
        exit;
    }

    my $id           = $cgi->param('id_asociacion') || undef;
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
            open(my $fh, '>', "/var/www/html/IEEQ/$ruta_emblema")
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
print encabezado(titulo => 'Gestión de Asociaciones',
                 usuario_nombre => $session->param('nombre'), rol => $session->param('rol'));

if (@errores) {
    print '<div class="alert alert-danger"><ul class="mb-0">';
    print "<li>$_</li>" for @errores;
    print '</ul></div>';
}

if ($accion eq 'nuevo' || $accion eq 'editar') {
    mostrar_formulario($dbh, $cgi);
} else {
    mostrar_listado($dbh, $puede_escribir);
}

print pie_pagina();

# ============================================================
# Funciones de vista
# ============================================================

sub mostrar_listado {
    my ($dbh, $puede_escribir) = @_;
    my $sth = $dbh->prepare('SELECT * FROM asociaciones_politicas ORDER BY nombre');
    $sth->execute;

    print '<div class="d-flex justify-content-between align-items-center mb-3">';
    print '<h4>Asociaciones políticas registradas</h4>';
    print '<a href="asociaciones.pl?accion=nuevo" class="btn btn-primary">+ Nueva asociación</a>' if $puede_escribir;
    print '</div>';

    print '<table class="table table-striped bg-white shadow-sm">';
    print '<thead><tr><th>Nombre</th><th>Representante</th><th>Municipio</th><th>Estatus</th><th></th></tr></thead><tbody>';
    while (my $a = $sth->fetchrow_hashref) {
        my $color = $a->{estatus} eq 'VIGENTE' ? 'success' : 'danger';
        print "<tr><td>$a->{nombre}</td><td>$a->{representante_legal}</td>";
        print "<td>$a->{municipio}</td><td><span class=\"badge bg-$color\">$a->{estatus}</span></td>";
        print qq(<td><a href="asociaciones.pl?accion=editar&id=$a->{id_asociacion}" class="btn btn-sm btn-outline-secondary">Editar</a></td>) if $puede_escribir;
        print '</tr>';
    }
    print '</tbody></table>';
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

    print qq(
    <h4>@{[ $id ? 'Editar' : 'Nueva' ]} asociación política</h4>
    <form method="post" action="asociaciones.pl" enctype="multipart/form-data" class="bg-white p-4 rounded shadow-sm">
      <input type="hidden" name="accion" value="guardar">
      <input type="hidden" name="id_asociacion" value="@{[ $id // '' ]}">
      <div class="row g-3">
        <div class="col-md-6">
          <label class="form-label">Nombre de la asociación</label>
          <input class="form-control" name="nombre" value="@{[ $a->{nombre} // '' ]}" required>
        </div>
        <div class="col-md-6">
          <label class="form-label">Representante legal</label>
          <input class="form-control" name="representante_legal" value="@{[ $a->{representante_legal} // '' ]}" required>
        </div>
        <div class="col-md-4">
          <label class="form-label">Calle</label>
          <input class="form-control" name="calle" value="@{[ $a->{calle} // '' ]}">
        </div>
        <div class="col-md-2">
          <label class="form-label">Número</label>
          <input class="form-control" name="numero" value="@{[ $a->{numero} // '' ]}">
        </div>
        <div class="col-md-3">
          <label class="form-label">Colonia</label>
          <input class="form-control" name="colonia" value="@{[ $a->{colonia} // '' ]}">
        </div>
        <div class="col-md-3">
          <label class="form-label">Municipio</label>
          <input class="form-control" name="municipio" value="@{[ $a->{municipio} // '' ]}">
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
        <div class="col-md-3" id="grupo_fecha_perdida" style="display:@{[ $sinreg_sel ? 'block' : 'none' ]};">
          <label class="form-label">Fecha de pérdida de registro</label>
          <input class="form-control" type="date" name="fecha_perdida_registro" value="@{[ $a->{fecha_perdida_registro} // '' ]}">
        </div>
        <div class="col-md-6">
          <label class="form-label">Emblema (JPG, máx. 1 MB)</label>
          <input class="form-control" type="file" name="emblema" accept="image/jpeg">
        </div>
      </div>
      <div class="mt-4">
        <button type="submit" class="btn btn-primary">Guardar</button>
        <a href="asociaciones.pl" class="btn btn-secondary">Cancelar</a>
      </div>
    </form>
    );
}

sub trim {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}
