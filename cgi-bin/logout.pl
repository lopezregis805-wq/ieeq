#!/usr/bin/perl
use strict;
use warnings;
use CGI;
use lib './lib';
use DB qw(conectar);
use Auth qw(iniciar_sesion cerrar_sesion);
use Bitacora qw(registrar);

my $cgi = CGI->new;
my $session = iniciar_sesion($cgi);
my $id_usuario = $session->param('id_usuario');

if ($id_usuario) {
    my $dbh = conectar();
    registrar(
        dbh => $dbh, id_usuario => $id_usuario,
        accion => 'LOGOUT', clave_modulo => 'INICIO_SESION',
        detalles => 'Cierre de sesión', ip => $cgi->remote_addr,
    );
}

cerrar_sesion($session);
print $cgi->redirect('login.pl');
