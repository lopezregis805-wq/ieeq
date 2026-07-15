#!/usr/bin/perl
use strict;
use warnings;
use utf8;                            # el codigo fuente de este archivo esta en UTF-8
use CGI;
use lib './lib';
use DB qw(conectar);
use Auth qw(iniciar_sesion cerrar_sesion);
use Bitacora qw(registrar);

my $cgi = CGI->new;
binmode(STDOUT, ":encoding(UTF-8)");   # lo que imprimimos tambien debe salir en UTF-8
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
