#!/usr/bin/perl
# ============================================================
# padron.pl — Padrón Electoral de Referencia: mantiene el dato
# oficial del padrón, su fecha de corte y el % mínimo de
# afiliados requerido. Solo debe existir UN registro "activo"
# a la vez — al capturar uno nuevo, los anteriores se desactivan
# (se guarda su historial, no se borran).
#
# Acceso: SUPERADMIN y, cuando se le asigne el permiso desde
# permisos.pl, también FUNCIONARIO_IEEQ.
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

unless (tiene_permiso($dbh, $id_usuario, 'PADRON_ELECTORAL', 'LECTURA')) {
    denegar_acceso(titulo => 'Padrón Electoral', usuario_nombre => obtener_texto_sesion($session, 'nombre'),
                    rol => $rol, dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'PADRON_ELECTORAL',
                    mensaje => 'Acceso no autorizado a este módulo.');
    exit;
}
my $puede_escribir = tiene_permiso($dbh, $id_usuario, 'PADRON_ELECTORAL', 'ESCRITURA');

my @errores;
my $guardado_ok = 0;

if ($cgi->request_method eq 'POST' && ($cgi->param('accion') // '') eq 'guardar') {
    unless ($puede_escribir) {
        denegar_acceso(titulo => 'Padrón Electoral', usuario_nombre => obtener_texto_sesion($session, 'nombre'),
                        rol => $rol, dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'PADRON_ELECTORAL',
                        mensaje => 'No tienes permiso de escritura en este módulo.');
        exit;
    }

    my $total_padron = $cgi->param('total_padron') // '';
    my $fecha_corte   = $cgi->param('fecha_corte') // '';
    my $porcentaje    = $cgi->param('porcentaje_minimo') // '0.13';

    $total_padron =~ s/[^\d]//g; # quita comas/espacios que a veces se pegan al copiar

    push @errores, 'El total del padrón es obligatorio y debe ser mayor a cero.' unless $total_padron && $total_padron > 0;
    push @errores, 'La fecha de corte es obligatoria.' unless length $fecha_corte;
    push @errores, 'El porcentaje mínimo debe ser mayor a cero.' unless $porcentaje && $porcentaje > 0;

    if (!@errores) {
        # Transacción: desactivar el/los anterior(es) e insertar el
        # nuevo como único activo, todo o nada.
        eval {
            $dbh->begin_work;
            $dbh->do('UPDATE padron_electoral SET activo = 0 WHERE activo = 1');
            $dbh->do(
                'INSERT INTO padron_electoral (total_padron, fecha_corte, porcentaje_minimo, activo)
                 VALUES (?,?,?,1)',
                undef, $total_padron, $fecha_corte, $porcentaje,
            );
            $dbh->commit;
        };
        if ($@) {
            $dbh->rollback;
            push @errores, "No se pudo guardar: $@";
        } else {
            my $nuevo_id = $dbh->last_insert_id(undef, undef, 'padron_electoral', undef);
            registrar(dbh => $dbh, id_usuario => $id_usuario, accion => 'REGISTRO',
                      clave_modulo => 'PADRON_ELECTORAL', id_registro_afectado => $nuevo_id,
                      detalles => "Actualización del padrón: $total_padron electores, corte $fecha_corte",
                      ip => $cgi->remote_addr);
            $guardado_ok = 1;
        }
    }
}

# --- editar el registro activo EN SITIO (no crea una versión nueva) ---
if ($cgi->request_method eq 'POST' && ($cgi->param('accion') // '') eq 'editar_guardar') {
    unless ($puede_escribir) {
        denegar_acceso(titulo => 'Padrón Electoral', usuario_nombre => obtener_texto_sesion($session, 'nombre'),
                        rol => $rol, dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'PADRON_ELECTORAL',
                        mensaje => 'No tienes permiso de escritura en este módulo.');
        exit;
    }
    my $id_padron    = $cgi->param('id_padron');
    my $total_padron = $cgi->param('total_padron') // '';
    my $fecha_corte  = $cgi->param('fecha_corte') // '';
    my $porcentaje   = $cgi->param('porcentaje_minimo') // '0.13';
    $total_padron =~ s/[^\d]//g;

    push @errores, 'El total del padrón es obligatorio y debe ser mayor a cero.' unless $total_padron && $total_padron > 0;
    push @errores, 'La fecha de corte es obligatoria.' unless length $fecha_corte;
    push @errores, 'El porcentaje mínimo debe ser mayor a cero.' unless $porcentaje && $porcentaje > 0;

    if (!@errores) {
        my $filas = $dbh->do(
            'UPDATE padron_electoral SET total_padron=?, fecha_corte=?, porcentaje_minimo=?
             WHERE id_padron=? AND activo=1',
            undef, $total_padron, $fecha_corte, $porcentaje, $id_padron,
        );
        if ($filas < 1) {
            push @errores, 'No se pudo editar: ese registro ya no es el activo.';
        } else {
            registrar(dbh => $dbh, id_usuario => $id_usuario, accion => 'EDICION',
                      clave_modulo => 'PADRON_ELECTORAL', id_registro_afectado => $id_padron,
                      detalles => "Edición del padrón activo: $total_padron electores, corte $fecha_corte",
                      ip => $cgi->remote_addr);
            $guardado_ok = 1;
        }
    }
}

# --- eliminar el registro activo; sp_eliminar_padron promueve el más
#     reciente que quede a activo, para que siempre haya exactamente uno ---
if ($cgi->request_method eq 'POST' && ($cgi->param('accion') // '') eq 'eliminar') {
    unless ($puede_escribir) {
        denegar_acceso(titulo => 'Padrón Electoral', usuario_nombre => obtener_texto_sesion($session, 'nombre'),
                        rol => $rol, dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'PADRON_ELECTORAL',
                        mensaje => 'No tienes permiso de escritura en este módulo.');
        exit;
    }
    eval {
        $dbh->do('CALL sp_eliminar_padron(?, ?)', undef, $cgi->param('id_padron'), $id_usuario);
    };
    if ($@) {
        push @errores, 'No se pudo eliminar: ese registro ya no es el activo.';
    } else {
        $guardado_ok = 1;
    }
}

print encabezado(titulo => 'Padrón Electoral de Referencia',
                  usuario_nombre => obtener_texto_sesion($session, 'nombre'), rol => $rol,
                  dbh => $dbh, id_usuario => $id_usuario, pagina_actual => 'PADRON_ELECTORAL');

if ($guardado_ok) {
    print '<div class="alert alert-success">Padrón actualizado correctamente.</div>';
}
if (@errores) {
    print '<div class="alert alert-danger"><ul class="mb-0">';
    print "<li>$_</li>" for @errores;
    print '</ul></div>';
}

mostrar_actual($dbh);

# El Admin de Asociación solo consulta las 3 tarjetas y la fecha de corte
# de arriba: ni el formulario de captura ni el historial le corresponden.
if ($rol ne 'ADMIN_ASOCIACION') {
    # el formulario de editar vive en un modal de Bootstrap: no ocupa
    # espacio en la página ni se mezcla con el historial, solo aparece
    # cuando se presiona "Editar" (o de una vez abierto si el intento
    # anterior de guardar falló, para que el error se vea en contexto).
    my $accion_actual = $cgi->param('accion') // '';
    my $reabrir_modal = $puede_escribir && $accion_actual eq 'editar_guardar' && @errores;
    my $pagina = int($cgi->param('pagina') // 1);
    $pagina = 1 if $pagina < 1;

    mostrar_formulario() if $puede_escribir;
    mostrar_historial($dbh, $puede_escribir, $pagina);
    mostrar_modal_editar($dbh, $reabrir_modal) if $puede_escribir;
}

print pie_pagina();

# ============================================================
sub mostrar_actual {
    my ($dbh) = @_;
    my $sth = $dbh->prepare('SELECT * FROM padron_electoral WHERE activo = 1 ORDER BY id_padron DESC LIMIT 1');
    $sth->execute;
    my $p = $sth->fetchrow_hashref;

    unless ($p) {
        print '<div class="alert alert-warning">Aún no se ha capturado ningún padrón electoral.</div>';
        return;
    }

    my $total_formateado = comma($p->{total_padron});
    my $minimo = int($p->{total_padron} * ($p->{porcentaje_minimo} / 100));

    print qq(
    <div class="row g-3 mb-4">
      <div class="col-md-4">
        <div class="ieeq-stat-card morado">
          <i class="bi bi-people fs-3"></i>
          <div class="fs-3 fw-bold mt-2">$total_formateado</div>
          <div class="small opacity-75">Total del padrón electoral</div>
        </div>
      </div>
      <div class="col-md-4">
        <div class="ieeq-stat-card azul">
          <i class="bi bi-percent fs-3"></i>
          <div class="fs-3 fw-bold mt-2">$p->{porcentaje_minimo}%</div>
          <div class="small opacity-75">Porcentaje mínimo requerido</div>
        </div>
      </div>
      <div class="col-md-4">
        <div class="ieeq-stat-card verde">
          <i class="bi bi-check2-square fs-3"></i>
          <div class="fs-3 fw-bold mt-2">@{[ comma($minimo) ]}</div>
          <div class="small opacity-75">Mínimo de afiliados requerido</div>
        </div>
      </div>
    </div>
    <p class="text-muted">Fecha de corte del padrón vigente: <strong>$p->{fecha_corte}</strong></p>
    );
}

sub mostrar_formulario {
    print qq(
    <div class="card border-0 shadow-sm mb-4"><div class="card-body">
      <h6 class="text-ieeq-primary mb-3">Capturar nueva actualización del padrón</h6>
      <form method="post" action="padron.pl">
        <input type="hidden" name="accion" value="guardar">
        <div class="row g-3">
          <div class="col-md-4">
            <label class="form-label">Total del padrón</label>
            <input class="form-control" name="total_padron" placeholder="Ej. 1500000" required>
          </div>
          <div class="col-md-4">
            <label class="form-label">Fecha de corte</label>
            <input class="form-control" type="date" name="fecha_corte" required>
          </div>
          <div class="col-md-4">
            <label class="form-label">Porcentaje mínimo (%)</label>
            <input class="form-control" type="number" step="0.01" name="porcentaje_minimo" value="0.13" required>
          </div>
        </div>
        <div class="mt-3">
          <button type="submit" class="btn btn-primary"><i class="bi bi-check-lg me-1"></i>Guardar actualización</button>
        </div>
        <small class="text-muted d-block mt-2">Al guardar, la actualización anterior queda registrada en el historial de abajo, no se pierde.</small>
      </form>
    </div></div>
    );
}

sub mostrar_historial {
    my ($dbh, $puede_escribir, $pagina) = @_;
    $pagina //= 1;

    my ($total_filas) = $dbh->selectrow_array('SELECT COUNT(*) FROM padron_electoral');
    my $total_paginas = $total_filas ? int(($total_filas + $POR_PAGINA - 1) / $POR_PAGINA) : 1;
    $pagina = $total_paginas if $pagina > $total_paginas;
    my $offset = ($pagina - 1) * $POR_PAGINA;

    my $sth = $dbh->prepare("SELECT * FROM padron_electoral ORDER BY fecha_registro DESC LIMIT $POR_PAGINA OFFSET $offset");
    $sth->execute;

    print '<h6 class="mb-3">Historial de actualizaciones</h6>';
    print '<div class="card border-0 shadow-sm"><div class="card-body p-0">';
    print '<table class="table table-sm mb-0"><thead><tr><th class="ps-3">Total</th><th>Fecha de corte</th><th>% mínimo</th><th>Capturado el</th><th>Estatus</th>';
    print '<th class="pe-3 text-end">Acciones</th>' if $puede_escribir;
    print '</tr></thead><tbody>';
    while (my $p = $sth->fetchrow_hashref) {
        my $badge = $p->{activo} ? '<span class="badge bg-success-subtle text-success">Activo</span>' : '<span class="badge bg-secondary-subtle text-secondary">Histórico</span>';
        print qq(<tr><td class="ps-3">@{[ comma($p->{total_padron}) ]}</td><td>$p->{fecha_corte}</td><td>$p->{porcentaje_minimo}%</td><td>$p->{fecha_registro}</td><td>$badge</td>);
        if ($puede_escribir) {
            print '<td class="pe-3 text-end text-nowrap">';
            if ($p->{activo}) {
                print qq(
                <button type="button" class="btn btn-sm btn-outline-secondary" title="Editar" data-bs-toggle="modal" data-bs-target="#modalEditarPadron"><i class="bi bi-pencil"></i></button>
                <form method="post" action="padron.pl" class="d-inline" onsubmit="return confirm('¿Eliminar este registro? El más reciente que quede pasará a Activo.');">
                  <input type="hidden" name="accion" value="eliminar">
                  <input type="hidden" name="id_padron" value="$p->{id_padron}">
                  <button type="submit" class="btn btn-sm btn-outline-danger" title="Eliminar"><i class="bi bi-trash"></i></button>
                </form>
                );
            }
            print '</td>';
        }
        print '</tr>';
    }
    print '</tbody></table></div></div>';
    print paginacion(pagina_actual => $pagina, total_paginas => $total_paginas, total_filas => $total_filas, por_pagina => $POR_PAGINA, base_url => 'padron.pl');
}

sub mostrar_modal_editar {
    my ($dbh, $reabrir) = @_;
    my $sth = $dbh->prepare('SELECT * FROM padron_electoral WHERE activo = 1 ORDER BY id_padron DESC LIMIT 1');
    $sth->execute;
    my $p = $sth->fetchrow_hashref;
    return unless $p; # nada que editar todavía

    # si se reabre por un error de validación, se conserva lo que la
    # persona ya había escrito en vez de mostrarle otra vez el valor
    # guardado (que es el que falló al intentar cambiar).
    if ($reabrir) {
        $p = {
            id_padron         => $cgi->param('id_padron') // $p->{id_padron},
            total_padron      => $cgi->param('total_padron') // $p->{total_padron},
            fecha_corte       => $cgi->param('fecha_corte') // $p->{fecha_corte},
            porcentaje_minimo => $cgi->param('porcentaje_minimo') // $p->{porcentaje_minimo},
        };
    }

    print qq(
    <div class="modal fade" id="modalEditarPadron" tabindex="-1" aria-labelledby="modalEditarPadronLabel" aria-hidden="true">
      <div class="modal-dialog">
        <div class="modal-content">
          <form method="post" action="padron.pl">
            <div class="modal-header">
              <h6 class="modal-title text-ieeq-primary" id="modalEditarPadronLabel">Editar registro activo del padrón</h6>
              <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Cerrar"></button>
            </div>
            <div class="modal-body">
              <input type="hidden" name="accion" value="editar_guardar">
              <input type="hidden" name="id_padron" value="$p->{id_padron}">
              <div class="mb-3">
                <label class="form-label">Total del padrón</label>
                <input class="form-control" name="total_padron" value="$p->{total_padron}" required>
              </div>
              <div class="mb-3">
                <label class="form-label">Fecha de corte</label>
                <input class="form-control" type="date" name="fecha_corte" value="$p->{fecha_corte}" required>
              </div>
              <div class="mb-3">
                <label class="form-label">Porcentaje mínimo (%)</label>
                <input class="form-control" type="number" step="0.01" name="porcentaje_minimo" value="$p->{porcentaje_minimo}" required>
              </div>
            </div>
            <div class="modal-footer">
              <button type="button" class="btn btn-outline-secondary" data-bs-dismiss="modal">Cancelar</button>
              <button type="submit" class="btn btn-primary"><i class="bi bi-check-lg me-1"></i>Guardar cambios</button>
            </div>
          </form>
        </div>
      </div>
    </div>
    );

    if ($reabrir) {
        print qq(
        <script>
          (function() {
            var modal = new bootstrap.Modal(document.getElementById('modalEditarPadron'));
            modal.show();
          })();
        </script>
        );
    }
}

sub comma {
    my ($n) = @_;
    return $n unless defined $n;
    1 while $n =~ s/(\d)(\d{3})(?!\d)/$1,$2/;
    return $n;
}
