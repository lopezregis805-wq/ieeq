#!/usr/bin/perl
# ============================================================
# dashboard.pl — panel principal, uno por rol (manual, Diagrama
# 4: "redirección al panel según su rol"). Cada rol ve tarjetas,
# accesos rápidos y una lista de "capacidades" distintas, según
# el diseño de Figma. El SUPERADMIN no aparecía en las capturas
# que compartió Regi, así que ese panel es una propuesta propia
# enfocada en administración del sistema.
#
# Diseño del código: en vez de escribir un bloque de HTML
# distinto por cada rol (copy-paste x4), armamos una struct de
# configuración por rol (@STATS, @ACCIONES, @CAPACIDADES...) y
# UNA sola función que la dibuja. Si mañana se agrega un rol
# nuevo, solo se agrega su entrada al hash de configuración.
# ============================================================
use strict;
use warnings;
use utf8;                            # el codigo fuente de este archivo esta en UTF-8
use CGI;
use lib './lib';
use DB qw(conectar);
use Auth qw(iniciar_sesion requerir_sesion obtener_texto_sesion);
use Plantilla qw(encabezado pie_pagina);

my $cgi = CGI->new;
binmode(STDOUT, ":encoding(UTF-8)");
my $session = iniciar_sesion($cgi);
my $id_usuario = requerir_sesion($session, $cgi);
my $dbh = conectar();

my $nombre         = obtener_texto_sesion($session, 'nombre');
my $rol            = $session->param('rol');
my $id_asociacion  = $session->param('id_asociacion');

my %etiquetas_rol = (
    SUPERADMIN       => 'Administrador del Sistema',
    ADMIN_ASOCIACION => 'Administrador de Asociación',
    FUNCIONARIO_IEEQ => 'Funcionariado IEEQ',
    AUXILIAR         => 'Persona Auxiliar',
);
my $rol_legible = $etiquetas_rol{$rol} // $rol;

# ============================================================
# 1. Estadísticas de afiliaciones: propias (según alcance del
#    rol) y globales (todo el sistema, sin filtrar).
# ============================================================
my ($filtro_sql, @filtro_params) = ('1=1', ());
if ($rol eq 'AUXILIAR') {
    $filtro_sql = 'a.id_registrador = ?';
    @filtro_params = ($id_usuario);
} elsif ($rol eq 'ADMIN_ASOCIACION') {
    $filtro_sql = 'u2.id_asociacion = ?';
    @filtro_params = ($id_asociacion);
}

sub contar_afiliaciones {
    my ($dbh, $filtro_sql, @filtro_params) = @_;
    my $sth = $dbh->prepare(
        "SELECT
            COUNT(*) AS total,
            SUM(a.estatus = 'NUEVA')       AS nuevas,
            SUM(a.estatus = 'EN_REVISION')  AS en_revision,
            SUM(a.estatus = 'VERIFICADO')  AS verificadas,
            SUM(EXISTS (
                SELECT 1 FROM verificaciones_afiliaciones v
                WHERE v.id_afiliacion = a.id_afiliacion AND v.decision = 'RECHAZADO'
                AND v.id_verificacion = (SELECT MAX(id_verificacion) FROM verificaciones_afiliaciones WHERE id_afiliacion = a.id_afiliacion)
            )) AS rechazadas
         FROM afiliaciones a
         JOIN usuarios u2 ON u2.id_usuario = a.id_registrador
         WHERE a.fecha_eliminacion IS NULL AND $filtro_sql"
    );
    $sth->execute(@filtro_params);
    my $stats = $sth->fetchrow_hashref;
    for (qw(total nuevas en_revision verificadas rechazadas)) { $stats->{$_} //= 0; }
    return $stats;
}

my $propio  = contar_afiliaciones($dbh, $filtro_sql, @filtro_params);
my $global  = contar_afiliaciones($dbh, '1=1');

# ============================================================
# 2. Avance hacia el mínimo requerido (solo tiene sentido por
#    asociación: Auxiliar y Admin de Asociación).
# ============================================================
my $avance;
if (($rol eq 'AUXILIAR' || $rol eq 'ADMIN_ASOCIACION') && $id_asociacion) {
    my $sth = $dbh->prepare('SELECT * FROM vw_estadisticas_afiliaciones WHERE id_asociacion = ?');
    $sth->execute($id_asociacion);
    $avance = $sth->fetchrow_hashref;
    if ($avance && $avance->{minimo_requerido} > 0) {
        $avance->{porcentaje} = sprintf('%.1f', ($avance->{total_afiliaciones} / $avance->{minimo_requerido}) * 100);
        $avance->{porcentaje} = 100 if $avance->{porcentaje} > 100;
        $avance->{restantes}  = $avance->{minimo_requerido} - $avance->{total_afiliaciones};
        $avance->{restantes}  = 0 if $avance->{restantes} < 0;
    }
}

# ============================================================
# 3. Configuración por rol: tarjetas, accesos rápidos, capacidades y alerta.
# ============================================================
my %config = (
    FUNCIONARIO_IEEQ => {
        tarjetas => [
            ['morado',  'people',        $global->{total},       'Total Afiliaciones',    'en el sistema'],
            ['azul',    'clock-history', $global->{en_revision}, 'Pendientes de verificar','esperan tu revisión'],
            ['verde',   'check-circle',  $global->{verificadas}, 'Verificados por IEEQ',  'localizados en padrón'],
            ['rojo',    'x-circle',      $global->{rechazadas},  'Rechazadas',            'no localizadas'],
        ],
        acciones => [
            ['check2-circle', 'afiliaciones_verificar.pl', 'Verificar Registros', 'Verificar en el padrón electoral'],
            ['people',        'afiliaciones_listado.pl',   'Consultar Registros', 'Vista completa de afiliaciones'],
            ['award',         'cedulas.pl',                'Generar Cédulas',     'Emitir cédulas de afiliados verificados'],
            ['journal-text',  'bitacora.pl',                'Bitácora',           'Revisión de operaciones'],
        ],
        capacidades => [
            [1, 'Consultar todos los registros', 'Vista completa del sistema en modo lectura'],
            [1, 'Verificar afiliaciones',         'Localizar en el padrón electoral del estado'],
            [1, 'Rechazar afiliaciones',          'Marcar como no localizadas en el padrón'],
            [1, 'Generar cédulas',                'Emitir cédulas de afiliados verificados'],
            [0, 'Capturar afiliaciones',          'Solo disponible para la Asociación'],
            [0, 'Gestionar usuarios',             'Solo disponible para el Administrador'],
        ],
        alerta => ($global->{en_revision} > 0)
            ? ['info', "Tienes $global->{en_revision} afiliaciones pendientes de verificación",
               'Estas afiliaciones están en "En revisión" y esperan tu validación contra el padrón electoral.']
            : undef,
        mostrar_avance => 0,
    },
    AUXILIAR => {
        tarjetas => [
            ['morado',  'people',        $propio->{total},       'Mis Afiliaciones',       'capturas realizadas'],
            ['naranja', 'clock-history', $propio->{nuevas},      'En edición (nuevas)',    'puedes editarlas todavía'],
            ['verde',   'check-circle',  $propio->{verificadas}, 'Total verificadas',      'de tus capturas'],
            ['azul',    'graph-up',      $global->{total},       'Total afiliaciones',     'en el sistema'],
        ],
        acciones => [
            ['person-plus', 'afiliaciones_nueva.pl',   'Nueva Afiliación', 'Capturar un nuevo ciudadano'],
            ['list-ul',      'afiliaciones_listado.pl', 'Mis Registros',    'Ver y editar mis capturas'],
        ],
        capacidades => [
            [1, 'Capturar afiliaciones',  'Registrar nuevos afiliados'],
            [1, 'Editar mis capturas',    'Solo registros propios con estatus "Nueva"'],
            [1, 'Eliminar mis capturas',  'Solo registros propios con estatus "Nueva"'],
            [0, 'Enviar a revisión',      'Solo disponible para el Administrador'],
            [0, 'Gestionar usuarios',     'Solo disponible para el Administrador'],
            [0, 'Generar cédulas',        'Solo disponible para Administrador e IEEQ'],
        ],
        alerta => ($propio->{nuevas} > 0)
            ? ['warning', "$propio->{nuevas} de tus registros pueden ser editados",
               'Tienes capturas con estatus "Nueva afiliación" que aún puedes modificar antes de que el Administrador las envíe a revisión.']
            : undef,
        mostrar_avance => 1,
    },
    ADMIN_ASOCIACION => {
        tarjetas => [
            ['morado',  'people',        $propio->{total},       'Total Afiliaciones', 'en el sistema'],
            ['naranja', 'clock-history', $propio->{nuevas},      'Pendientes de enviar','requieren tu acción'],
            ['verde',   'check-circle',  $propio->{verificadas}, 'Verificadas',         sprintf('%.1f%% del total', $propio->{total} ? $propio->{verificadas}/$propio->{total}*100 : 0)],
            ['rojo',    'x-circle',      $propio->{rechazadas},  'Rechazadas',          'no aptas para registro'],
        ],
        acciones => [
            ['person-plus', 'afiliaciones_nueva.pl',   'Nueva Afiliación',    'Capturar nuevo registro'],
            ['list-ul',      'afiliaciones_listado.pl', 'Listado de Afiliados','Ver y gestionar registros'],
            ['award',        'cedulas.pl',              'Generar Cédulas',     'Cédulas de afiliados verificados'],
            ['people',       'usuarios.pl',             'Gestión de Usuarios', 'Administrar accesos al sistema'],
        ],
        capacidades => [
            [1, 'Capturar afiliaciones',  'Registrar nuevos afiliados'],
            [1, 'Gestionar usuarios',     'Crear, editar y desactivar auxiliares'],
            [1, 'Enviar a revisión IEEQ', 'Afiliaciones capturadas al Instituto'],
            [1, 'Generar cédulas',        'Emitir cédulas de afiliados verificados'],
            [1, 'Ver bitácora completa',  'Historial de operaciones del sistema'],
            [0, 'Verificar en padrón',    'Solo disponible para Funcionariado IEEQ'],
        ],
        alerta => undef,
        mostrar_avance => 1,
    },
    SUPERADMIN => {
        tarjetas => [], # se dibujan aparte, ver mostrar_panel_superadmin()
        acciones => [
            ['people',        'usuarios.pl',      'Gestión de Usuarios',      'Crear administradores y funcionariado'],
            ['shield-check',  'permisos.pl',       'Gestión de Permisos',      'Ajustar accesos por módulo'],
            ['bank',          'asociaciones.pl',   'Asociaciones Políticas',   'Alta y estatus de asociaciones'],
            ['journal-text',  'bitacora.pl',        'Bitácora',                'Auditoría de todo el sistema'],
        ],
        capacidades => [
            [1, 'Gestionar todos los usuarios',  'Crear Administradores de Asociación y Funcionariado IEEQ'],
            [1, 'Gestionar permisos',            'Ajustar el nivel de acceso de cualquier usuario'],
            [1, 'Administrar asociaciones',      'Alta, edición y estatus de asociaciones políticas'],
            [1, 'Auditar el sistema completo',   'Ver la bitácora de todas las operaciones'],
        ],
        alerta => undef,
        mostrar_avance => 0,
    },
);
my $cfg = $config{$rol} // $config{FUNCIONARIO_IEEQ};

# ============================================================
# 4. Render
# ============================================================
print encabezado(
    titulo => 'Dashboard Principal',
    usuario_nombre => $nombre, rol => $rol_legible,
    dbh => $dbh, id_usuario => $id_usuario, pagina_actual => '__INICIO__',
);

my $accion_principal = $cfg->{acciones}[0];
my $accion_secundaria = $cfg->{acciones}[1];

print qq(
<div class="card border-0 shadow-sm mb-4">
  <div class="card-body d-flex flex-wrap justify-content-between align-items-center gap-3">
    <div>
      <div class="d-flex align-items-center gap-2 mb-1">
        <h5 class="mb-0">¡Hola, $nombre!</h5>
        <span class="badge bg-success-subtle text-success">Sesión Activa</span>
      </div>
      <div class="text-muted">
        Bienvenido/a al Sistema de Registro de Afiliaciones del IEEQ.
        Tu rol es <strong class="text-ieeq-primary">$rol_legible</strong>.
      </div>
      <span class="badge bg-secondary-subtle text-secondary-emphasis mt-2">$rol</span>
    </div>
);

if ($accion_principal || $accion_secundaria) {
    print '<div class="d-flex gap-2">';
    if ($accion_principal) {
        my ($icono, $enlace, $etiqueta) = @$accion_principal;
        print qq(<a href="$enlace" class="btn btn-primary"><i class="bi bi-$icono me-1"></i>$etiqueta</a>);
    }
    if ($accion_secundaria) {
        my ($icono, $enlace, $etiqueta) = @$accion_secundaria;
        print qq(<a href="$enlace" class="btn btn-outline-secondary"><i class="bi bi-$icono me-1"></i>$etiqueta</a>);
    }
    print '</div>';
}
print '</div></div>';

# --- Alerta contextual ---
if (my $alerta = $cfg->{alerta}) {
    my ($tipo, $titulo_alerta, $texto_alerta) = @$alerta;
    print qq(
    <div class="alert alert-$tipo d-flex justify-content-between align-items-center mb-4">
      <div><strong>$titulo_alerta</strong><div class="small">$texto_alerta</div></div>
      <i class="bi bi-arrow-right fs-5"></i>
    </div>
    );
}

# --- Tarjetas de estadísticas ---
if (@{ $cfg->{tarjetas} }) {
    print '<div class="row g-3 mb-4">';
    for my $t (@{ $cfg->{tarjetas} }) {
        my ($color, $icono, $valor, $etiqueta, $sub) = @$t;
        print qq(
        <div class="col-md-3">
          <div class="ieeq-stat-card $color">
            <i class="bi bi-$icono fs-3"></i>
            <div class="fs-2 fw-bold mt-2">$valor</div>
            <div class="small opacity-75">$etiqueta</div>
            <div class="small opacity-50">$sub</div>
          </div>
        </div>
        );
    }
    print '</div>';
} else {
    mostrar_panel_superadmin($dbh);
}

# --- Acciones rápidas + Capacidades de tu rol ---
print '<div class="row g-3">';
print '<div class="col-md-5"><div class="card border-0 shadow-sm h-100"><div class="card-body">';
print '<h6 class="mb-3">Acciones rápidas</h6>';
for my $a (@{ $cfg->{acciones} }) {
    my ($icono, $enlace, $etiqueta, $sub) = @$a;
    print qq(
    <a href="$enlace" class="d-flex align-items-center text-decoration-none text-dark p-2 mb-1 rounded-3" style="background-color:var(--ieeq-primary-light);">
      <i class="bi bi-$icono fs-5 text-ieeq-primary me-3"></i>
      <div class="flex-fill"><div class="fw-semibold small">$etiqueta</div><div class="text-muted" style="font-size:0.8rem;">$sub</div></div>
      <i class="bi bi-chevron-right text-muted"></i>
    </a>
    );
}
print '</div></div></div>';

print '<div class="col-md-7"><div class="card border-0 shadow-sm h-100"><div class="card-body">';
print '<h6 class="mb-3">Capacidades de tu rol</h6><div class="row">';
for my $c (@{ $cfg->{capacidades} }) {
    my ($activo, $etiqueta, $sub) = @$c;
    my $color_icono = $activo ? 'text-ieeq-primary' : 'text-muted';
    my $color_texto = $activo ? '' : 'text-muted';
    my $icono = $activo ? 'check-circle-fill' : 'dash-circle';
    print qq(
    <div class="col-md-6 d-flex align-items-start gap-2 mb-3">
      <i class="bi bi-$icono $color_icono mt-1"></i>
      <div class="$color_texto"><div class="small fw-semibold">$etiqueta</div><div class="text-muted" style="font-size:0.78rem;">$sub</div></div>
    </div>
    );
}
print '</div></div></div></div>';
print '</div>'; # cierra row

# --- Barra de avance hacia el mínimo requerido ---
if ($cfg->{mostrar_avance} && $avance && $avance->{minimo_requerido}) {
    print qq(
    <div class="card border-0 shadow-sm mt-4"><div class="card-body">
      <div class="d-flex justify-content-between mb-1">
        <h6 class="mb-0">Avance hacia el mínimo requerido</h6>
        <strong class="text-ieeq-primary">$avance->{porcentaje}%</strong>
      </div>
      <div class="small text-muted mb-2">
        Padrón de referencia: $avance->{total_padron} electores · Mínimo reglamentario: $avance->{minimo_requerido} ($avance->{porcentaje_minimo}%)
      </div>
      <div class="progress" style="height:10px;">
        <div class="progress-bar bg-ieeq-primary" style="width:$avance->{porcentaje}%;"></div>
      </div>
      <div class="d-flex justify-content-between mt-1">
        <small class="text-muted">$avance->{total_afiliaciones} afiliaciones registradas</small>
        <small class="text-muted">$avance->{restantes} restantes para el mínimo</small>
      </div>
    </div></div>
    );
}

print pie_pagina();

# ============================================================
sub mostrar_panel_superadmin {
    my ($dbh) = @_;
    my ($total_usuarios) = $dbh->selectrow_array('SELECT COUNT(*) FROM usuarios');
    my ($total_asociaciones) = $dbh->selectrow_array('SELECT COUNT(*) FROM asociaciones_politicas');
    my ($total_afiliaciones) = $dbh->selectrow_array('SELECT COUNT(*) FROM afiliaciones WHERE fecha_eliminacion IS NULL');
    my ($usuarios_inactivos) = $dbh->selectrow_array('SELECT COUNT(*) FROM usuarios WHERE activo = 0');

    print qq(
    <div class="row g-3 mb-4">
      <div class="col-md-3"><div class="ieeq-stat-card morado"><i class="bi bi-people fs-3"></i>
        <div class="fs-2 fw-bold mt-2">$total_usuarios</div><div class="small opacity-75">Usuarios registrados</div></div></div>
      <div class="col-md-3"><div class="ieeq-stat-card azul"><i class="bi bi-bank fs-3"></i>
        <div class="fs-2 fw-bold mt-2">$total_asociaciones</div><div class="small opacity-75">Asociaciones políticas</div></div></div>
      <div class="col-md-3"><div class="ieeq-stat-card verde"><i class="bi bi-people-fill fs-3"></i>
        <div class="fs-2 fw-bold mt-2">$total_afiliaciones</div><div class="small opacity-75">Afiliaciones en el sistema</div></div></div>
      <div class="col-md-3"><div class="ieeq-stat-card rojo"><i class="bi bi-person-x fs-3"></i>
        <div class="fs-2 fw-bold mt-2">$usuarios_inactivos</div><div class="small opacity-75">Usuarios inactivos</div></div></div>
    </div>
    );
}
