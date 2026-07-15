#!/usr/bin/perl
# ============================================================
# login.pl — puerta de entrada al sistema (manual, sección 5.1)
# Layout tomado del diseño de Figma: panel izquierdo con
# degradado morado institucional + panel derecho con el
# formulario y una caja de accesos de demostración.
# ============================================================
use strict;
use warnings;
use utf8;                            # el codigo fuente de este archivo esta en UTF-8
use CGI;
use lib './lib';
use DB qw(conectar);
use Auth qw(iniciar_sesion validar_credenciales);
use Bitacora qw(registrar);

my $cgi = CGI->new;
binmode(STDOUT, ":encoding(UTF-8)");   # lo que imprimimos tambien debe salir en UTF-8
my $session = iniciar_sesion($cgi);
my $error = '';

if ($cgi->request_method eq 'POST') {
    my $correo     = $cgi->param('correo')     // '';
    my $contrasena = $cgi->param('contrasena') // '';

    my $dbh = conectar();
    my $usuario = validar_credenciales($dbh, $correo, $contrasena);

    if ($usuario) {
        $session->param('id_usuario', $usuario->{id_usuario});
        $session->param('nombre', "$usuario->{nombre} $usuario->{apellido_paterno}");
        $session->param('rol',        $usuario->{tipo_usuario});
        $session->param('id_asociacion', $usuario->{id_asociacion});
        $session->flush();

        registrar(
            dbh => $dbh, id_usuario => $usuario->{id_usuario},
            accion => 'LOGIN', clave_modulo => 'INICIO_SESION',
            detalles => 'Inicio de sesión exitoso',
            ip => $cgi->remote_addr,
        );

        # La cookie de la sesión debe viajar en la redirección,
        # si no, el navegador nunca sabe que existe la sesión.
        print $cgi->redirect(-uri => 'dashboard.pl', -cookie => $session->cookie);
        exit;
    } else {
        $error = 'Correo o contraseña incorrectos, o la cuenta está inactiva.';
    }
}

print $cgi->header(-charset => 'utf-8');
print <<"HTML";
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Iniciar sesión · IEEQ</title>
  <link href="https://cdn.jsdelivr.net/npm/bootstrap\@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
  <link href="https://cdn.jsdelivr.net/npm/bootstrap-icons\@1.11.3/font/bootstrap-icons.css" rel="stylesheet">
  <link href="public/css/custom.css" rel="stylesheet">
</head>
<body>
<div class="row g-0" style="min-height:100vh;">

  <div class="col-lg-5 ieeq-login-panel d-flex flex-column align-items-center justify-content-center text-center p-5">
    
    <h1 class="display-4 fw-bold mb-3">IEEQ</h1>
    <p class="fs-5">Instituto Electoral del Estado de Querétaro</p>
    <hr Style="width:60px; border-top:3px solid #fff; margin:1rem auto 2rem auto;">
    <p class="opacity-75">Sistema de Registro de Afiliaciones</p>
  </div>

  <div class="col-lg-7 d-flex align-items-center justify-content-center bg-white p-5">
    <div style="max-width:420px; width:100%;">
      <h2 class="fw-bold text-ieeq-primary mb-1">Iniciar Sesión</h2>
      <p class="text-muted mb-4">Accede con tus credenciales institucionales</p>
HTML

print qq(<div class="alert alert-danger">$error</div>) if $error;

print <<"HTML";
      <form method="post" action="login.pl">
        <div class="mb-3">
          <label class="form-label">Correo electrónico</label>
          <input type="email" name="correo" class="form-control" placeholder="usuario\@dominio.mx" required autofocus>
        </div>
        <div class="mb-3">
          <label class="form-label">Contraseña</label>
          <input type="password" name="contrasena" class="form-control" placeholder="********" required>
        </div>
        <button type="submit" class="btn btn-primary w-100 py-2">Entrar al Sistema</button>
      </form>
    </div>
  </div>

</div>
</body>
</html>
HTML
