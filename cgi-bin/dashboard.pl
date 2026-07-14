#!/usr/bin/perl
# ============================================================
# dashboard.pl — panel principal, uno por rol (Diagrama 4: "
# redirección al panel según su rol"). En vez de tener un
# dashboard distinto por cada rol, aquí construimos el menú
# dinámicamente a partir de permisos_usuario: si el nivel es
# 'NINGUNO', el módulo "ni siquiera aparece en su menú" (regla
# del manual, sección 6).
# ============================================================
use strict;
use warnings;
use CGI;
use lib './lib';
use DB qw(conectar);
use Auth qw(iniciar_sesion requerir_sesion);
use Plantilla qw(encabezado pie_pagina);

my $cgi = CGI->new;
my $session = iniciar_sesion($cgi);
my $id_usuario = requerir_sesion($session, $cgi);

my $dbh = conectar();

# Mapa clave_modulo -> script .pl al que enlaza cada tarjeta del menú.
# Según se vayan construyendo los demás módulos, solo se agrega
# su entrada aquí.
my %enlace_por_modulo = (
    GESTION_USUARIOS          => 'usuarios.pl',
    GESTION_PERMISOS          => 'permisos.pl',
    GESTION_ASOCIACIONES      => 'asociaciones.pl',
    PADRON_ELECTORAL          => 'padron.pl',
    REGISTRO_AFILIACIONES     => 'afiliaciones_nueva.pl',
    CONSULTA_AFILIACIONES     => 'afiliaciones_listado.pl',
    VERIFICACION_AFILIACIONES => 'afiliaciones_verificar.pl',
    CEDULAS_AFILIACION        => 'cedulas.pl',
    BITACORA_AUDITORIA        => 'bitacora.pl',
);

my $sth = $dbh->prepare(
    'SELECT m.clave, m.descripcion, p.nivel
     FROM permisos_usuario p
     JOIN modulos_sistema m ON m.id_modulo = p.id_modulo
     WHERE p.id_usuario = ? AND p.nivel != "NINGUNO"
     ORDER BY m.orden'
);
$sth->execute($id_usuario);

print $cgi->header(-charset => 'utf-8') if 0; # el header ya lo manda encabezado()
print encabezado(
    titulo => 'Panel principal',
    usuario_nombre => $session->param('nombre'),
    rol => $session->param('rol'),
);

print '<h4 class="mb-4">Módulos disponibles</h4><div class="row g-3">';

while (my $mod = $sth->fetchrow_hashref) {
    my $enlace = $enlace_por_modulo{ $mod->{clave} } // '#';
    my $insignia = $mod->{nivel} eq 'ESCRITURA' ? 'success' : 'secondary';
    print qq(
      <div class="col-md-4">
        <a href="$enlace" class="text-decoration-none">
          <div class="card h-100 shadow-sm">
            <div class="card-body">
              <h6 class="card-title">$mod->{descripcion}</h6>
              <span class="badge bg-$insignia">$mod->{nivel}</span>
            </div>
          </div>
        </a>
      </div>
    );
}

print '</div>';
print pie_pagina();
