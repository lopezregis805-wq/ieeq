package Bitacora;
# ============================================================
# Bitacora.pm — un solo lugar para escribir en la tabla bitacora.
#
# Toda alta, edición o eliminación queda
# registrada en bitácora de forma automática e inalterable.

# ============================================================

use strict;
use warnings;
use utf8;                            
use Exporter 'import';

our @EXPORT_OK = qw(registrar);

sub registrar {
    my (%args) = @_;
    # args esperados: dbh, id_usuario, accion, clave_modulo,
    #                 id_registro_afectado (opcional), detalles (opcional), ip (opcional)

    my $dbh = $args{dbh} or die 'Bitacora::registrar requiere dbh';

    my $sth = $dbh->prepare(
        'INSERT INTO bitacora (id_usuario, accion, id_modulo, id_registro_afectado, detalles, ip_origen)
         VALUES (?, ?, (SELECT id_modulo FROM modulos_sistema WHERE clave = ?), ?, ?, ?)'
    );
    $sth->execute(
        $args{id_usuario},
        $args{accion},
        $args{clave_modulo},
        $args{id_registro_afectado},
        $args{detalles},
        $args{ip} || '',
    );
    return 1;
}

1;
