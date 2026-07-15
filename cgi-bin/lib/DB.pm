package DB;
# ============================================================
# DB.pm — capa de acceso a datos que arma y ejecuta las
# consultas SQL. La ponemos en un módulo (paquete) para que
# TODOS los scripts .pl la reutilicen en vez de copiar/pegar
# la conexión en cada archivo.
# ============================================================

use strict;
use warnings;
use utf8;                           
use DBI;
use Exporter 'import';

our @EXPORT_OK = qw(conectar);

# Datos de conexión.
my $DB_HOST = $ENV{IEEQ_DB_HOST} || 'localhost';
my $DB_NAME = $ENV{IEEQ_DB_NAME} || 'ieeq_registro';
my $DB_USER = $ENV{IEEQ_DB_USER} || 'ieeq_app';
my $DB_PASS = $ENV{IEEQ_DB_PASS} || '';

# conectar() devuelve un handle DBI listo para usarse.
# Muere con un mensaje claro si no logra conectar.
sub conectar {
    my $dsn = "DBI:mysql:database=$DB_NAME;host=$DB_HOST";
    my $dbh = DBI->connect(
        $dsn, $DB_USER, $DB_PASS,
        {
            RaiseError => 1,   # cualquier error de SQL lanza una excepción (die)
            PrintError => 0,   # no lo imprime dos veces
            AutoCommit => 1,   # cada sentencia se confirma sola, salvo que hagamos begin_work
            mysql_enable_utf8mb4 => 1,
        }
    ) or die "No se pudo conectar a la base de datos: $DBI::errstr";
    return $dbh;
}

1; 
