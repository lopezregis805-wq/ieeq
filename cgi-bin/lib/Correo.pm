package Correo;
# ============================================================
# Correo.pm — envío de notificaciones por correo (alta de
# usuario, baja de cuenta) vía SMTP con autenticación y
# STARTTLS. Mismo patrón que DB.pm/Rutas.pm: configuración por
# variables de entorno, con valores por defecto razonables.
# ============================================================

use strict;
use warnings;
use utf8;
use Exporter 'import';

our @EXPORT_OK = qw(enviar_correo);

my $SMTP_HOST   = $ENV{IEEQ_SMTP_HOST}   || 'smtp.office365.com';
my $SMTP_PORT   = $ENV{IEEQ_SMTP_PORT}   || 587;
my $SMTP_USER   = $ENV{IEEQ_SMTP_USER}   || '';
my $SMTP_PASS   = $ENV{IEEQ_SMTP_PASS}   || '';
my $SMTP_NOMBRE = $ENV{IEEQ_SMTP_NOMBRE} || 'Sistema de Registro IEEQ';

# enviar_correo(destinatario => ..., asunto => ..., mensaje_html => ...,
#               copias => 'a@x.com;b@x.com' (opcional))
# Devuelve undef si se envió correctamente, o un mensaje de error (string)
# si no. Usa require (no use) para Net::SMTPS/MIME::Lite, igual que
# Exportar.pm con Excel::Writer::XLSX: si esos módulos todavía no están
# instalados, esta función falla con un mensaje claro en vez de tronar
# toda la aplicación. El envío NUNCA debe bloquear la operación que lo
# dispara (alta o baja de un usuario) — quien llama a esta función debe
# tratar el error como una advertencia, no como motivo para deshacer nada.
sub enviar_correo {
    my (%args) = @_;
    my $destinatario  = $args{destinatario} or return 'Falta el destinatario del correo.';
    my $asunto        = $args{asunto} // '';
    my $mensaje_html  = $args{mensaje_html} // '';
    my $copias        = $args{copias};

    unless (length $SMTP_USER && length $SMTP_PASS) {
        return 'El servidor de correo no está configurado (definir IEEQ_SMTP_USER e IEEQ_SMTP_PASS).';
    }

    my $error;
    my $ok = eval {
        require Net::SMTPS;
        require MIME::Lite;

        my $msg = MIME::Lite->new(
            From    => "$SMTP_NOMBRE <$SMTP_USER>",
            To      => $destinatario,
            Subject => $asunto,
            Data    => $mensaje_html,
            Type    => 'text/html;charset=UTF-8',
        );

        my $smtps = Net::SMTPS->new($SMTP_HOST, Port => $SMTP_PORT, doSSL => 'starttls')
            or die "No se pudo conectar al servidor de correo ($SMTP_HOST:$SMTP_PORT).\n";
        $smtps->auth($SMTP_USER, $SMTP_PASS)
            or die "No se pudo autenticar con el servidor de correo.\n";
        $smtps->mail($SMTP_USER);
        $smtps->to($destinatario);
        if ($copias) {
            $smtps->cc($_) for split /;/, $copias;
        }
        $smtps->data();
        $smtps->datasend($msg->as_string());
        $smtps->dataend();
        $smtps->quit();
        1;
    };
    if (!$ok) {
        $error = $@ || 'No se pudo enviar el correo.';
        chomp $error;
    }
    return $error;
}

1;
