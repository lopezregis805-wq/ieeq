package Plantilla;
# ============================================================
# Plantilla.pm — encabezado y pie de página comunes.
#
# El manual pide Bootstrap 5 en el frontend (sección 3). Como
# el proyecto NO usa un framework de plantillas (ni Perl ni PHP
# tienen aquí un motor tipo Blade/Twig), la forma más simple y
# mantenible es concentrar el HTML repetido (head, navbar, pie)
# en funciones que cada script llama al imprimir su página.
# ============================================================

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(encabezado pie_pagina);

sub encabezado {
    my (%args) = @_;
    my $titulo = $args{titulo} // 'Sistema de Registro IEEQ';
    my $usuario_nombre = $args{usuario_nombre} // '';
    my $rol = $args{rol} // '';

    return <<"HTML";
Content-type: text/html; charset=utf-8

<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$titulo · IEEQ</title>
  <link href="https://cdn.jsdelivr.net/npm/bootstrap\@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
</head>
<body class="bg-light">
<nav class="navbar navbar-expand-lg navbar-dark bg-primary mb-4">
  <div class="container">
    <a class="navbar-brand" href="dashboard.pl">IEEQ · Registro de Afiliaciones</a>
    <div class="d-flex text-white align-items-center">
      <span class="me-3">$usuario_nombre ($rol)</span>
      <a class="btn btn-outline-light btn-sm" href="logout.pl">Cerrar sesión</a>
    </div>
  </div>
</nav>
<div class="container">
HTML
}

sub pie_pagina {
    return <<'HTML';
</div>
<footer class="text-center text-muted py-4 mt-5">
  Instituto Electoral del Estado de Querétaro &mdash; Sistema de Registro de Afiliaciones
</footer>
<script src="https://cdn.jsdelivr.net/npm/bootstrap\@5.3.3/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
HTML
}

1;
