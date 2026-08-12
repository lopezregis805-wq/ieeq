package Rutas;
# ============================================================
# Rutas.pm — ruta base absoluta usada por los scripts que
# guardan archivos subidos (fotos, firmas, emblemas) en disco.
#
# Por defecto usa $Bin (carpeta del script en ejecución), pero
# permite sobreescribirla con la variable de entorno
# IEEQ_RUTA_UPLOADS.
# ============================================================

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use Exporter 'import';

our @EXPORT_OK = qw($RUTA_UPLOADS);

our $RUTA_UPLOADS = $ENV{IEEQ_RUTA_UPLOADS} || $Bin;

1;
