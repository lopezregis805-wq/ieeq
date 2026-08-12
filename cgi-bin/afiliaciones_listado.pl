#!/usr/bin/perl
# ============================================================
# afiliaciones_listado.pl — Consulta y Gestión del Listado.
# Pastillas de filtro por estatus, buscador, avatar con
# iniciales, columna de "Flujo" (ciclo de vida) y acciones como
# íconos.
#
# Regla de negocio central: solo quien capturó o corrige un
# registro puede editarlo/eliminarlo/reenviarlo a revisión
# (puede_gestionar_afiliacion, abajo):
#   - un Auxiliar solo gestiona las afiliaciones que ÉL MISMO
#     capturó
#   - un Admin de Asociación gestiona cualquiera de su propia
#     asociación, mientras esté en estatus Nueva o Rechazada
#   - Funcionariado IEEQ y SUPERADMIN ven el listado completo
#     (control del sistema) pero NUNCA gestionan estos registros
#     — no son quienes capturan ni corrigen afiliaciones, ese es
#     el proceso operativo de la asociación
# ============================================================
use strict;
use warnings;
use utf8;                            # el codigo fuente de este archivo esta en UTF-8
use CGI;
use lib './lib';
use DB qw(conectar);
use Auth qw(iniciar_sesion requerir_sesion tiene_permiso obtener_texto_sesion);
use Bitacora qw(registrar);
use Plantilla qw(encabezado pie_pagina denegar_acceso);

my $cgi = CGI->new;
binmode(STDOUT, ":encoding(UTF-8)");
my $session = iniciar_sesion($cgi);
my $id_usuario = requerir_sesion($session, $cgi);
my $dbh = conectar();
my $rol = $session->param('rol');
my $id_asociacion = $session->param('id_asociacion');

unless (tiene_permiso($dbh, $id_usuario, 'CONSULTA_AFILIACIONES', 'LECTURA')) {
    denegar_acceso(titulo => ($rol eq 'AUXILIAR' ? 'Mis Registros' : 'Listado de Afiliados'),
                    usuario_nombre => obtener_texto_sesion($session, 'nombre'),
                    rol => $rol, dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'CONSULTA_AFILIACIONES',
                    mensaje => 'Acceso no autorizado a este módulo.');
    exit;
}

# --- eliminar (soft delete vía procedimiento almacenado) ---
# Los procedimientos sp_eliminar_afiliacion / sp_enviar_a_revision solo
# validan el estatus, no de quién es el registro ni su asociación — por
# eso esa autorización se verifica aquí ANTES de llamarlos, con la misma
# regla que decide qué botones se muestran en el listado
# (puede_gestionar_afiliacion, más abajo). Nunca hay que confiar en que
# el botón simplemente no se haya mostrado.
my @errores;
if (($cgi->param('accion') // '') eq 'eliminar' && $cgi->request_method eq 'POST') {
    my $id = $cgi->param('id');
    my $registro_objetivo = obtener_registro_para_gestion($dbh, $id);
    if ($registro_objetivo && puede_gestionar_afiliacion($rol, $id_usuario, $id_asociacion, $registro_objetivo)) {
        eval {
            $dbh->do('CALL sp_eliminar_afiliacion(?, ?)', undef, $id, $id_usuario);
            registrar(dbh => $dbh, id_usuario => $id_usuario, accion => 'ELIMINACION',
                      clave_modulo => 'CONSULTA_AFILIACIONES', id_registro_afectado => $id,
                      detalles => 'Afiliación eliminada (soft delete)', ip => $cgi->remote_addr);
        };
        push @errores, 'No se pudo eliminar: el registro ya no está en estatus "Nueva afiliación" o "Rechazada".' if $@;
    } else {
        push @errores, 'No tienes permiso para eliminar este registro.';
    }
}

# --- enviar a revisión (Nueva o Rechazada -> En revisión), para que
#     aparezca en la cola del Funcionariado IEEQ ---
if (($cgi->param('accion') // '') eq 'enviar_revision' && $cgi->request_method eq 'POST') {
    my $id = $cgi->param('id');
    my $registro_objetivo = obtener_registro_para_gestion($dbh, $id);
    if ($registro_objetivo && puede_gestionar_afiliacion($rol, $id_usuario, $id_asociacion, $registro_objetivo)) {
        eval {
            $dbh->do('CALL sp_enviar_a_revision(?, ?)', undef, $id, $id_usuario);
        };
        push @errores, 'No se pudo enviar a revisión: el registro ya no está en estatus "Nueva afiliación" o "Rechazada".' if $@;
    } else {
        push @errores, 'No tienes permiso para enviar este registro a revisión.';
    }
}

my $filtro_estatus = $cgi->param('filtro') // 'TODOS';
my $buscar = trim($cgi->param('buscar') // '');

print encabezado(titulo => ($rol eq 'AUXILIAR' ? 'Mis Registros' : 'Listado de Afiliados'),
                  usuario_nombre => obtener_texto_sesion($session, 'nombre'), rol => $rol,
                  dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'CONSULTA_AFILIACIONES');

if (@errores) {
    print '<div class="alert alert-danger"><ul class="mb-0">';
    print "<li>$_</li>" for @errores;
    print '</ul></div>';
}

mostrar_listado($dbh, $rol, $id_usuario, $id_asociacion, $filtro_estatus, $buscar);
print pie_pagina();

# ============================================================
# Alcance por rol: condición SQL + parámetros, reutilizada tanto
# para los conteos de las pastillas como para la tabla.
# ============================================================
sub alcance_por_rol {
    my ($rol, $id_usuario, $id_asociacion) = @_;
    return ('a.id_registrador = ?', [$id_usuario])       if $rol eq 'AUXILIAR';
    return ('u.id_asociacion = ?', [$id_asociacion])      if $rol eq 'ADMIN_ASOCIACION';
    return ('1=1', []); # FUNCIONARIO_IEEQ / SUPERADMIN: todo el sistema (solo consulta)
}

# ¿este rol puede editar/eliminar/reenviar ESTE registro? El Auxiliar
# solo gestiona lo que él mismo capturó; el Admin de Asociación gestiona
# lo de su propia asociación. SUPERADMIN y Funcionariado IEEQ tienen
# control absoluto del sistema (usuarios, permisos, asociaciones) pero
# no de este proceso operativo, así que aquí nunca regresan verdadero
# — para eso está Verificación, que es su propio proceso con su propia
# regla de autorización.
sub puede_gestionar_afiliacion {
    my ($rol, $id_usuario, $id_asociacion, $r) = @_;
    return 0 unless $r->{estatus} eq 'NUEVA' || $r->{estatus} eq 'RECHAZADA';
    return 1 if $rol eq 'ADMIN_ASOCIACION' && $r->{id_asociacion_registrador} == $id_asociacion;
    return 1 if $rol eq 'AUXILIAR' && $r->{id_registrador} == $id_usuario;
    return 0;
}

# Datos mínimos de un registro para decidir si puede gestionarse
# (usado tanto por eliminar como por enviar_revision antes de llamar al
# procedimiento correspondiente).
sub obtener_registro_para_gestion {
    my ($dbh, $id) = @_;
    return undef unless $id;
    my $sth = $dbh->prepare(
        'SELECT a.estatus, a.id_registrador, u.id_asociacion AS id_asociacion_registrador
         FROM afiliaciones a JOIN usuarios u ON u.id_usuario = a.id_registrador
         WHERE a.id_afiliacion = ? AND a.fecha_eliminacion IS NULL'
    );
    $sth->execute($id);
    return $sth->fetchrow_hashref;
}

sub mostrar_listado {
    my ($dbh, $rol, $id_usuario, $id_asociacion, $filtro_estatus, $buscar) = @_;
    my ($condicion_alcance, $params_alcance) = alcance_por_rol($rol, $id_usuario, $id_asociacion);

    # --- conteos para las pastillas de filtro ---
    my $sth_conteos = $dbh->prepare(
        "SELECT
            COUNT(*) AS todos,
            SUM(a.estatus = 'NUEVA')       AS nueva,
            SUM(a.estatus = 'EN_REVISION') AS en_revision,
            SUM(a.estatus = 'VERIFICADO')  AS verificada,
            SUM(a.estatus = 'RECHAZADA')   AS rechazada
         FROM afiliaciones a JOIN usuarios u ON u.id_usuario = a.id_registrador
         WHERE a.fecha_eliminacion IS NULL AND $condicion_alcance"
    );
    $sth_conteos->execute(@$params_alcance);
    my $c = $sth_conteos->fetchrow_hashref;
    for (qw(todos nueva en_revision verificada rechazada)) { $c->{$_} //= 0; }

    print '<div class="d-flex flex-wrap gap-2 mb-3">';
    my @pastillas = (
        ['TODOS', 'Todos', $c->{todos}],
        ['NUEVA', 'Nueva afiliación', $c->{nueva}],
        ['EN_REVISION', 'En revisión', $c->{en_revision}],
        ['VERIFICADO', 'Verificada', $c->{verificada}],
        ['RECHAZADA', 'Rechazada', $c->{rechazada}],
    );
    for my $p (@pastillas) {
        my ($valor, $etiqueta, $conteo) = @$p;
        my $activa = ($filtro_estatus eq $valor) ? 'btn-primary' : 'btn-outline-secondary';
        print qq(<a href="afiliaciones_listado.pl?filtro=$valor" class="btn btn-sm $activa rounded-pill">$etiqueta <span class="badge bg-light text-dark ms-1">$conteo</span></a>);
    }
    print '</div>';

    print qq(
    <form method="get" action="afiliaciones_listado.pl" class="mb-3">
      <input type="hidden" name="filtro" value="$filtro_estatus">
      <input type="text" name="buscar" class="form-control" style="max-width:320px;"
             placeholder="Nombre o clave de elector..." value="@{[ $buscar // '' ]}">
    </form>
    );

    # --- consulta principal ---
    my $sql = 'SELECT a.id_afiliacion,
                 CONCAT(a.nombre, " ", a.apellido_paterno, IFNULL(CONCAT(" ", a.apellido_materno), "")) AS nombre_completo,
                 a.clave_elector, a.estatus, a.fecha_hora_afiliacion, a.id_registrador,
                 m.nombre AS municipio, u.id_asociacion AS id_asociacion_registrador,
                 CONCAT(u.nombre, " ", u.apellido_paterno) AS registrador
               FROM afiliaciones a
               JOIN municipios m ON m.id_municipio = a.id_municipio_afiliacion
               JOIN usuarios u ON u.id_usuario = a.id_registrador
               WHERE a.fecha_eliminacion IS NULL AND ' . $condicion_alcance;
    my @params = @$params_alcance;

    if ($filtro_estatus ne 'TODOS') {
        $sql .= ' AND a.estatus = ?';
        push @params, $filtro_estatus;
    }
    if (length $buscar) {
        $sql .= ' AND (a.nombre LIKE ? OR a.apellido_paterno LIKE ? OR a.clave_elector LIKE ?)';
        push @params, ("%$buscar%") x 3;
    }
    $sql .= ' ORDER BY a.fecha_hora_afiliacion DESC';

    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);

    my $mostrar_columna_registrador = ($rol ne 'AUXILIAR');
    my %color_estatus = (NUEVA => 'secondary', EN_REVISION => 'warning', VERIFICADO => 'success', RECHAZADA => 'danger');
    my @colores_avatar = qw(morado azul verde naranja rojo);

    print '<div class="card border-0 shadow-sm"><div class="card-body p-0">';
    print '<table class="table table-hover align-middle mb-0"><thead><tr><th class="ps-3">#</th><th>Nombre completo</th><th>Clave de elector</th><th>Municipio</th>';
    print '<th>Registrador</th>' if $mostrar_columna_registrador;
    print '<th>Fecha</th><th>Estatus</th><th>Flujo</th><th class="text-end pe-3">Acciones</th></tr></thead><tbody>';

    my $fila = 0;
    while (my $r = $sth->fetchrow_hashref) {
        $fila++;
        my $color = $color_estatus{ $r->{estatus} } // 'secondary';
        my $iniciales = uc(substr($r->{nombre_completo}, 0, 1) . substr((split / /, $r->{nombre_completo})[1] // '', 0, 1));
        my $color_avatar = $colores_avatar[$fila % scalar @colores_avatar];

        # ¿este usuario puede editar/eliminar ESTE registro? Rechazada se
        # gestiona igual que Nueva: se puede corregir y reenviar a revisión.
        my $puede_gestionar = puede_gestionar_afiliacion($rol, $id_usuario, $id_asociacion, $r);

        # --- Flujo: 3 puntos según el ciclo de vida del registro ---
        my ($p1, $p2, $p3) = ('bg-secondary', 'bg-light', 'bg-light');
        if ($r->{estatus} eq 'EN_REVISION') { ($p1, $p2, $p3) = ('bg-ieeq-primary', 'bg-ieeq-primary', 'bg-light'); }
        if ($r->{estatus} eq 'VERIFICADO')  { ($p1, $p2, $p3) = ('bg-success', 'bg-success', 'bg-success'); }
        if ($r->{estatus} eq 'RECHAZADA')   { ($p1, $p2, $p3) = ('bg-danger', 'bg-light', 'bg-light'); }

        print qq(
        <tr>
          <td class="ps-3 text-muted">$fila</td>
          <td>
            <div class="d-flex align-items-center gap-2">
              <span class="ieeq-avatar $color_avatar">$iniciales</span>
              $r->{nombre_completo}
            </div>
          </td>
          <td class="font-monospace small">@{[ $r->{clave_elector} // '—' ]}</td>
          <td>$r->{municipio}</td>
        );
        print qq(<td>$r->{registrador}</td>) if $mostrar_columna_registrador;
        print qq(
          <td>$r->{fecha_hora_afiliacion}</td>
          <td><span class="badge bg-$color-subtle text-$color-emphasis">$r->{estatus}</span></td>
          <td><span class="ieeq-dot $p1"></span><span class="ieeq-dot $p2"></span><span class="ieeq-dot $p3"></span></td>
          <td class="text-end pe-3 text-nowrap">
            <a href="afiliaciones_detalle.pl?id=$r->{id_afiliacion}" class="btn btn-sm btn-outline-secondary" title="Ver"><i class="bi bi-eye"></i></a>
        );
        if ($puede_gestionar) {
            print qq(
            <a href="afiliaciones_nueva.pl?accion=editar&id=$r->{id_afiliacion}" class="btn btn-sm btn-outline-secondary" title="Editar"><i class="bi bi-pencil"></i></a>
            <form method="post" action="afiliaciones_listado.pl" class="d-inline" onsubmit="return confirm('¿Enviar este registro a revisión? Ya no podrás editarlo hasta que el IEEQ lo evalúe.');">
              <input type="hidden" name="accion" value="enviar_revision">
              <input type="hidden" name="id" value="$r->{id_afiliacion}">
              <button type="submit" class="btn btn-sm btn-outline-primary" title="Enviar a revisión"><i class="bi bi-send"></i></button>
            </form>
            <form method="post" action="afiliaciones_listado.pl" class="d-inline" onsubmit="return confirm('¿Eliminar este registro?');">
              <input type="hidden" name="accion" value="eliminar">
              <input type="hidden" name="id" value="$r->{id_afiliacion}">
              <button type="submit" class="btn btn-sm btn-outline-danger" title="Eliminar"><i class="bi bi-trash"></i></button>
            </form>
            );
        }
        print '</td></tr>';
    }
    if ($fila == 0) {
        my $colspan = $mostrar_columna_registrador ? 8 : 7;
        print qq(<tr><td colspan="$colspan" class="text-center text-muted py-4">No hay registros con este filtro.</td></tr>);
    }
    print '</tbody></table></div></div>';
}

sub trim {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}
