package Plantilla;
# ============================================================
# Plantilla.pm — funciones para imprimir encabezado y pie de página.
# ============================================================

use strict;
use warnings;
use utf8;                           
use Exporter 'import';

our @EXPORT_OK = qw(encabezado pie_pagina);

# Mapa clave_modulo -> {enlace, icono, etiqueta}. Un solo lugar
# para mantener el orden y los textos del menú.
my @MENU = (
    { clave => '__INICIO__',              enlace => 'dashboard.pl',           etiqueta => 'Inicio',                  icono => 'house' },
    { clave => 'GESTION_USUARIOS',         enlace => 'usuarios.pl',            etiqueta => 'Gestión de Usuarios',     icono => 'people' },
    { clave => 'GESTION_PERMISOS',         enlace => 'permisos.pl',            etiqueta => 'Gestión de Permisos',     icono => 'shield-check' },
    { clave => 'GESTION_ASOCIACIONES',     enlace => 'asociaciones.pl',        etiqueta => 'Asociación',              icono => 'bank' },
    { clave => 'PADRON_ELECTORAL',         enlace => 'padron.pl',              etiqueta => 'Padrón Electoral',        icono => 'clipboard-data' },
    { clave => 'REGISTRO_AFILIACIONES',    enlace => 'afiliaciones_nueva.pl',  etiqueta => 'Registro de Afiliaciones',icono => 'person-plus' },
    { clave => 'CONSULTA_AFILIACIONES',    enlace => 'afiliaciones_listado.pl',etiqueta => 'Listado de Afiliados',    icono => 'list-ul' },
    { clave => 'VERIFICACION_AFILIACIONES',enlace => 'afiliaciones_verificar.pl',etiqueta => 'Verificación',          icono => 'check-circle' },
    { clave => 'CEDULAS_AFILIACION',       enlace => 'cedulas.pl',             etiqueta => 'Cédulas',                 icono => 'award' },
    { clave => 'BITACORA_AUDITORIA',       enlace => 'bitacora.pl',            etiqueta => 'Bitácora',                icono => 'journal-text' },
);

# encabezado(): imprime <head> + sidebar + abre el <main> de contenido.

sub encabezado {
    my (%args) = @_;
    my $titulo         = $args{titulo} // 'Sistema de Registro IEEQ';
    my $usuario_nombre = $args{usuario_nombre} // '';
    my $rol            = $args{rol} // '';
    my $dbh            = $args{dbh};
    my $id_usuario     = $args{id_usuario};
    my $pagina_actual  = $args{pagina_actual} // '';

    my %permisos_usuario;
    if ($dbh && $id_usuario) {
        my $sth = $dbh->prepare(
            'SELECT m.clave FROM permisos_usuario p
             JOIN modulos_sistema m ON m.id_modulo = p.id_modulo
             WHERE p.id_usuario = ? AND p.nivel != "NINGUNO"'
        );
        $sth->execute($id_usuario);
        while (my ($clave) = $sth->fetchrow_array) { $permisos_usuario{$clave} = 1; }
    }

    my $html = <<"HTML";
Content-type: text/html; charset=utf-8

<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$titulo · IEEQ</title>
  <link href="https://cdn.jsdelivr.net/npm/bootstrap\@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
  <link href="https://cdn.jsdelivr.net/npm/bootstrap-icons\@1.11.3/font/bootstrap-icons.css" rel="stylesheet">
  <link href="public/css/custom.css" rel="stylesheet">
</head>
<body>
<div class="ieeq-sidebar-backdrop" id="ieeqSidebarBackdrop"></div>
<div class="d-flex">
  <aside class="ieeq-sidebar d-flex flex-column p-3" id="ieeqSidebar">
    <div class="d-flex align-items-center justify-content-center gap-2 mb-4 px-1">

      <div class="text-center">
        <div class="fw-bold f-1" style="font-size: 2em;">IEEQ</div>
        <small class="opacity-75">Sistema de Registro</small>
        <hr class="my-2">
      </div>
    </div>
    <div class="menu-titulo mb-2">Menú Principal</div>
    <nav class="nav flex-column mb-auto">
HTML

    for my $item (@MENU) {
        next unless $item->{clave} eq '__INICIO__' || $permisos_usuario{ $item->{clave} };
        my $activo = ($pagina_actual eq $item->{clave}) ? 'active' : '';
        $html .= qq(      <a class="nav-link $activo" href="$item->{enlace}"><i class="bi bi-$item->{icono} me-2"></i>$item->{etiqueta}</a>\n);
    }

    $html .= <<"HTML";
    </nav>
    <div class="ieeq-usuario-card mt-3">
      <div class="fw-semibold small">$usuario_nombre</div>
      <div class="opacity-75" style="font-size:0.8rem;">$rol</div>
      <a href="logout.pl" class="d-block mt-2 small text-white-50"><i class="bi bi-box-arrow-right me-1"></i>Cerrar Sesión</a>
    </div>
  </aside>
  <main class="flex-fill">
    <div class="bg-white border-bottom px-4 py-3 mb-4 d-flex align-items-center gap-2">
      <button type="button" class="ieeq-sidebar-toggle" id="ieeqSidebarToggle" aria-label="Abrir menú" aria-controls="ieeqSidebar">
        <i class="bi bi-list"></i>
      </button>
      <div>
        <h4 class="mb-0 fs-3">$titulo</h4>
        <small class="text-muted">Instituto Electoral del Estado de Querétaro</small>
      </div>
    </div>
    <div class="px-4 pb-4">
HTML

    return $html;
}

sub pie_pagina {
    return <<'HTML';
    </div>
  </main>
</div>
<script src="https://cdn.jsdelivr.net/npm/bootstrap\@5.3.3/dist/js/bootstrap.bundle.min.js"></script>
<script src="public/js/sidebar.js"></script>
</body>
</html>
HTML
}

1;
