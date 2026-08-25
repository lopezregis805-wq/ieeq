package Exportar;
# ============================================================
# Exportar.pm — genera y entrega un archivo .xlsx descargable
# directamente a STDOUT, para los botones "Descargar Excel" de
# los listados de afiliaciones.
# ============================================================

use strict;
use warnings;
use utf8;
use Exporter 'import';

our @EXPORT_OK = qw(exportar_xlsx);

# exportar_xlsx($cgi, $nombre_archivo, \@encabezados, \@filas)
# \@filas es un arrayref de arrayrefs (una fila = un arrayref de valores,
# en el mismo orden que \@encabezados). Usa require (no use) para que el
# resto de la aplicación siga funcionando aunque Excel::Writer::XLSX
# todavía no esté instalado en el servidor — solo esta función falla
# hasta que se instale.
sub exportar_xlsx {
    my ($cgi, $nombre_archivo, $encabezados, $filas) = @_;

    my $modulo_disponible = eval { require Excel::Writer::XLSX; 1 };
    unless ($modulo_disponible) {
        print $cgi->header(-charset => 'utf-8', -status => '503 Service Unavailable');
        print qq(<!DOCTYPE html><html lang="es"><head><meta charset="utf-8">
        <title>Exportar a Excel no disponible</title>
        <link href="https://cdn.jsdelivr.net/npm/bootstrap\@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
        </head><body class="p-4">
        <div class="alert alert-danger mb-0">
          No se pudo generar el archivo de Excel: falta instalar un componente en el servidor
          (<code>Excel::Writer::XLSX</code>). Avisa al administrador del sistema para que lo instale
          (<code>sudo apt install libexcel-writer-xlsx-perl</code>).
        </div>
        </body></html>);
        return;
    }

    print $cgi->header(
        -type       => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        -attachment => $nombre_archivo,
        -charset    => 'utf-8',
    );

    my $workbook = Excel::Writer::XLSX->new('-');
    my $hoja = $workbook->add_worksheet();
    my $formato_encabezado = $workbook->add_format(bold => 1, bg_color => '#6B2D8B', color => 'white');

    $hoja->write_row(0, 0, $encabezados, $formato_encabezado);
    my $fila_num = 1;
    for my $fila (@$filas) {
        $hoja->write_row($fila_num, 0, $fila);
        $fila_num++;
    }
    $workbook->close();
}

1;
