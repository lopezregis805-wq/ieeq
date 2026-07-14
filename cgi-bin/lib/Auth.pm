package Auth;
# ============================================================
# Auth.pm — sesiones, login y verificación de permisos.
#
# Perl CGI no trae sesiones "de fábrica" como otros lenguajes.
# Aquí usamos CGI::Session, que guarda cada sesión como un
# archivo en el servidor y le entrega al navegador solo un ID
# (cookie). Así replicamos el Diagrama 4 del manual:
#   1. valida correo + contraseña (hash SHA-256)
#   2. si son válidas, crea una sesión con id, nombre y rol
#   3. si no, regresa error
# ============================================================

use strict;
use warnings;
use CGI::Session;
use Digest::SHA qw(sha256_hex);
use Exporter 'import';

our @EXPORT_OK = qw(iniciar_sesion validar_credenciales requerir_sesion tiene_permiso cerrar_sesion);

my $SESSION_DIR = '/tmp/ieeq_sesiones';
mkdir $SESSION_DIR unless -d $SESSION_DIR;

# Crea (o recupera) la sesión ligada a la cookie del navegador.
sub iniciar_sesion {
    my ($cgi) = @_;
    my $session = CGI::Session->new(
        "driver:File", $cgi,
        { Directory => $SESSION_DIR }
    ) or die CGI::Session->errstr;
    return $session;
}

# Compara el hash de la contraseña capturada contra la BD.
# Devuelve el registro del usuario (hashref) si es válido, o undef.
sub validar_credenciales {
    my ($dbh, $correo, $contrasena_plana) = @_;

    my $sth = $dbh->prepare(
        'SELECT id_usuario, correo_electronico, contrasena, nombre,
                apellido_paterno, tipo_usuario, id_asociacion, activo
         FROM usuarios WHERE correo_electronico = ?'
    );
    $sth->execute($correo);
    my $usuario = $sth->fetchrow_hashref;

    return undef unless $usuario;                 # no existe ese correo
    return undef unless $usuario->{activo};        # cuenta desactivada

    my $hash_capturado = sha256_hex($contrasena_plana);
    return undef unless $hash_capturado eq $usuario->{contrasena};

    return $usuario;                               # credenciales válidas
}

# Corta la ejecución con un 302 hacia login.pl si no hay sesión activa.
# Se debe llamar al principio de CADA script protegido.
sub requerir_sesion {
    my ($session, $cgi) = @_;
    my $id_usuario = $session->param('id_usuario');
    unless ($id_usuario) {
        print $cgi->redirect('login.pl');
        exit;
    }
    return $id_usuario;
}

# Revisa en permisos_usuario si el usuario tiene al menos $nivel_minimo
# en el módulo indicado por su clave (ej. 'GESTION_ASOCIACIONES').
# $nivel_minimo: 'LECTURA' o 'ESCRITURA'.
sub tiene_permiso {
    my ($dbh, $id_usuario, $clave_modulo, $nivel_minimo) = @_;

    my $sth = $dbh->prepare(
        'SELECT p.nivel
         FROM permisos_usuario p
         JOIN modulos_sistema m ON m.id_modulo = p.id_modulo
         WHERE p.id_usuario = ? AND m.clave = ?'
    );
    $sth->execute($id_usuario, $clave_modulo);
    my ($nivel) = $sth->fetchrow_array;
    $nivel ||= 'NINGUNO';

    return 1 if $nivel eq 'ESCRITURA';                      # escritura cubre lectura también
    return 1 if $nivel eq 'LECTURA' && $nivel_minimo eq 'LECTURA';
    return 0;
}

sub cerrar_sesion {
    my ($session) = @_;
    $session->delete();
    $session->flush();
}

1;
