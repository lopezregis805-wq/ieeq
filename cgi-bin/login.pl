#!/usr/bin/perl
# ============================================================
# login.pl — puerta de entrada al sistema (manual, sección 5.1)
#
# Flujo (Diagrama 4):
#   usuario ingresa correo y contraseña
#     -> se valida el hash SHA-256 contra la BD
#     -> si es válido: se crea sesión con id, nombre y rol
#     -> se redirige a dashboard.pl
# ============================================================
use strict;
use warnings;
use CGI;
use lib './lib';
use DB qw(conectar);
use Auth qw(iniciar_sesion validar_credenciales);
use Bitacora qw(registrar);

my $cgi = CGI->new;
my $session = iniciar_sesion($cgi);
my $error = '';

if ($cgi->request_method eq 'POST') {
    my $correo     = $cgi->param('correo')     // '';
    my $contrasena = $cgi->param('contrasena') // '';

    my $dbh = conectar();
    my $usuario = validar_credenciales($dbh, $correo, $contrasena);

    if ($usuario) {
        # Se crea la sesión: guardamos solo lo necesario, nunca la contraseña.
        $session->param('id_usuario', $usuario->{id_usuario});
        $session->param('nombre',     "$usuario->{nombre} $usuario->{apellido_paterno}");
        $session->param('rol',        $usuario->{tipo_usuario});
        $session->param('id_asociacion', $usuario->{id_asociacion});
        $session->flush();

        registrar(
            dbh => $dbh, id_usuario => $usuario->{id_usuario},
            accion => 'LOGIN', clave_modulo => 'INICIO_SESION',
            detalles => 'Inicio de sesión exitoso',
            ip => $cgi->remote_addr,
        );

        print $cgi->redirect('dashboard.pl');
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
</head>
<body class="bg-primary bg-gradient d-flex align-items-center" style="min-height:100vh;">
<div class="container">
  <div class="row justify-content-center">
    <div class="col-md-4">
      <div class="card shadow">
        <div class="card-body p-4">
          <h4 class="card-title mb-3 text-center">Sistema de Registro IEEQ</h4>
HTML

print qq(<div class="alert alert-danger">$error</div>) if $error;

print <<"HTML";
          <form method="post" action="login.pl">
            <div class="mb-3">
              <label class="form-label">Correo electrónico</label>
              <input type="email" name="correo" class="form-control" required autofocus>
            </div>
            <div class="mb-3">
              <label class="form-label">Contraseña</label>
              <input type="password" name="contrasena" class="form-control" required>
            </div>
            <button type="submit" class="btn btn-primary w-100">Entrar</button>
          </form>
        </div>
      </div>
    </div>
  </div>
</div>
</body>
</html>
HTML
