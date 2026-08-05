-- ============================================================
-- BASE DE DATOS: ieeq_registro  (v5 - Reglas de negocio de
-- Registro de Afiliaciones, sección 8 del manual)
--
-- Cambios respecto a v4 (ver notas "-- [v5]" a lo largo del
-- archivo):
--
--   1. afiliaciones.domicilio_numero_interior -> columna nueva.
--      El domicilio de la credencial para votar distingue ahora
--      número exterior (columna domicilio_numero, ya existía) de
--      número interior (opcional, para departamentos/interiores).
--
-- El resto del esquema es idéntico a v4. Los siguientes cambios
-- de negocio del formulario de Registro de Afiliaciones NO
-- requieren alterar el esquema porque ya se validan o se muestran
-- desde la aplicación (afiliaciones_nueva.pl y otros scripts):
--   - Clave de elector y OCR ahora son obligatorios al capturar; la
--     clave de elector además debe tener exactamente 18 caracteres
--     alfanuméricos. Los datos de domicilio (calle, número exterior,
--     colonia, municipio y código postal) también son obligatorios;
--     número interior y apellido materno se mantienen opcionales.
--     Los 3 registros de prueba de más abajo usan claves de elector
--     de 18 caracteres para poder editarse bajo esta nueva regla.
--   - El campo Código CIC ya no se captura (se deja de pedir en
--     el formulario) NI se muestra en las pantallas de solo
--     lectura (afiliaciones_detalle.pl, afiliaciones_verificar.pl,
--     cedulas.pl); la columna `cic` se conserva únicamente para no
--     perder el dato de capturas anteriores a esta versión.
--   - El campo Estado del domicilio queda fijo en "QUERÉTARO"
--     (mayúsculas, igual que el resto de los datos capturados) y
--     no es editable — todas las afiliaciones son en ese estado.
--   - Todos los datos capturados en el formulario se normalizan a
--     mayúsculas antes de guardarse (incluye acentos y "ñ").
--   - Un Admin de Asociación solo puede otorgarle a sus Auxiliares
--     Escritura/Lectura en Registro de Afiliaciones y Lectura en
--     Consulta y Gestión del Listado; el resto de los módulos
--     queda bloqueado (antes solo se bloqueaban Gestión de
--     Usuarios y Gestión de Permisos). Además, permisos.pl ahora
--     muestra retroalimentación (éxito/error) al guardar cambios,
--     en vez de fallar en silencio o tronar con un 500.
--   - Las rutas de archivos subidos (fotos, firmas, emblemas) no
--     dependen de en qué carpeta absoluta se despliegue el
--     proyecto: lib/Rutas.pm expone $RUTA_UPLOADS, que usa
--     FindBin por defecto pero se puede sobreescribir con la
--     variable de entorno IEEQ_RUTA_UPLOADS — necesario en
--     servidores donde el DocumentRoot es un symlink hacia otra
--     ruta real (FindBin resuelve symlinks y puede apuntar mal).
-- ============================================================

DROP DATABASE IF EXISTS ieeq_registro;
CREATE DATABASE ieeq_registro CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE ieeq_registro;

-- ============================================================
-- CATÁLOGOS BASE
-- ============================================================

-- Municipios de Querétaro (18 municipios, RF-03).
-- Este catálogo YA estaba bien normalizado en la v3: es la
-- forma correcta de modelar un dominio cerrado de valores.
CREATE TABLE municipios (
    id_municipio  INT AUTO_INCREMENT PRIMARY KEY,
    nombre        VARCHAR(100) NOT NULL UNIQUE
);

INSERT INTO municipios (nombre) VALUES
('Amealco de Bonfil'),('Arroyo Seco'),('Cadereyta de Montes'),('Colón'),
('Corregidora'),('El Marqués'),('Ezequiel Montes'),('Huimilpan'),
('Jalpan de Serra'),('Landa de Matamoros'),('Pedro Escobedo'),('Peñamiller'),
('Pinal de Amoles'),('Querétaro'),('San Joaquín'),('San Juan del Río'),
('Tequisquiapan'),('Tolimán');

-- Catálogo de módulos del sistema (para permisos y bitácora).
CREATE TABLE modulos_sistema (
    id_modulo    INT AUTO_INCREMENT PRIMARY KEY,
    clave        VARCHAR(60) UNIQUE NOT NULL,
    descripcion  VARCHAR(200) NOT NULL,
    orden        INT NOT NULL DEFAULT 0
);

INSERT INTO modulos_sistema (clave, descripcion, orden) VALUES
('GESTION_USUARIOS',          'Gestión de Usuarios',                 1),
('GESTION_PERMISOS',          'Gestión de Permisos',                 2),
('GESTION_ASOCIACIONES',      'Gestión de Asociaciones Políticas',   3),
('PADRON_ELECTORAL',          'Padrón Electoral de Referencia',      4),
('REGISTRO_AFILIACIONES',     'Registro de Afiliaciones',            5),
('CONSULTA_AFILIACIONES',     'Consulta y Gestión del Listado',      6),
('VERIFICACION_AFILIACIONES', 'Verificación de Afiliaciones',        7),
('CEDULAS_AFILIACION',        'Generación de Cédulas de Afiliación', 8),
('BITACORA_AUDITORIA',        'Bitácora y Auditoría',                9),
('INICIO_SESION',             'Inicio de Sesión',                    10);
-- Nota: son exactamente los 10 módulos del Diagrama 3 del manual.
-- Ya no incluyo "Registro de Auxiliares" / "Verificación de
-- Auxiliares" porque el manual no los define como módulos.

-- ============================================================
-- TABLA: asociaciones_politicas (RF-01)
-- ============================================================
CREATE TABLE asociaciones_politicas (
    id_asociacion          INT AUTO_INCREMENT PRIMARY KEY,
    nombre                 VARCHAR(200) NOT NULL,
    representante_legal    VARCHAR(200) NOT NULL,
    calle                  VARCHAR(200),
    numero                 VARCHAR(20),
    colonia                VARCHAR(150),
    municipio              VARCHAR(100),
    codigo_postal          VARCHAR(10),
    correo_electronico     VARCHAR(150),
    telefono               VARCHAR(15),
    emblema                VARCHAR(255),
    fecha_aprobacion       DATE,
    fecha_perdida_registro DATE,
    estatus                ENUM('VIGENTE','SIN_REGISTRO') NOT NULL DEFAULT 'VIGENTE',
    fecha_creacion         DATETIME NOT NULL DEFAULT NOW(),
    fecha_actualizacion    DATETIME NULL ON UPDATE NOW(),
    CONSTRAINT chk_fecha_perdida CHECK (
        estatus = 'VIGENTE' OR fecha_perdida_registro IS NOT NULL
    )
);

-- ============================================================
-- TABLA: padron_electoral (RF-02)
-- ============================================================
CREATE TABLE padron_electoral (
    id_padron         INT AUTO_INCREMENT PRIMARY KEY,
    total_padron      BIGINT NOT NULL,
    fecha_corte       DATE NOT NULL,
    porcentaje_minimo DECIMAL(6,4) NOT NULL DEFAULT 0.1300,
    activo            TINYINT(1) NOT NULL DEFAULT 1,
    fecha_registro    DATETIME NOT NULL DEFAULT NOW()
);

-- ============================================================
-- TABLA: usuarios
-- ============================================================
CREATE TABLE usuarios (
    id_usuario           INT AUTO_INCREMENT PRIMARY KEY,
    correo_electronico   VARCHAR(150) UNIQUE NOT NULL,
    contrasena           VARCHAR(255) NOT NULL,
    nombre               VARCHAR(100) NOT NULL,
    apellido_paterno     VARCHAR(100) NOT NULL,
    apellido_materno     VARCHAR(100),
    telefono_movil       VARCHAR(15),
    tipo_usuario         ENUM('SUPERADMIN','ADMIN_ASOCIACION','FUNCIONARIO_IEEQ','AUXILIAR') NOT NULL,
    id_asociacion        INT NULL,
    activo               TINYINT(1) NOT NULL DEFAULT 1,
    fecha_creacion       DATETIME NOT NULL DEFAULT NOW(),
    fecha_actualizacion  DATETIME NULL ON UPDATE NOW(),
    FOREIGN KEY (id_asociacion) REFERENCES asociaciones_politicas(id_asociacion),
    CONSTRAINT chk_usuario_asociacion CHECK (
        (tipo_usuario IN ('SUPERADMIN','FUNCIONARIO_IEEQ') AND id_asociacion IS NULL)
        OR
        (tipo_usuario IN ('ADMIN_ASOCIACION','AUXILIAR') AND id_asociacion IS NOT NULL)
    )
);

-- ============================================================
-- TABLA: permisos_usuario
-- ============================================================
CREATE TABLE permisos_usuario (
    id_permiso   INT AUTO_INCREMENT PRIMARY KEY,
    id_usuario   INT NOT NULL,
    id_modulo    INT NOT NULL,
    nivel        ENUM('ESCRITURA','LECTURA','NINGUNO') NOT NULL DEFAULT 'NINGUNO',
    UNIQUE KEY uq_usuario_modulo (id_usuario, id_modulo),
    FOREIGN KEY (id_usuario) REFERENCES usuarios(id_usuario) ON DELETE CASCADE,
    FOREIGN KEY (id_modulo)  REFERENCES modulos_sistema(id_modulo)
);

-- ============================================================
-- TABLA: afiliaciones (RF-03)
-- ============================================================
CREATE TABLE afiliaciones (
    id_afiliacion            INT AUTO_INCREMENT PRIMARY KEY,
    fecha_hora_afiliacion     DATETIME NOT NULL DEFAULT NOW(),
    id_municipio_afiliacion   INT NOT NULL,
    nombre                    VARCHAR(100) NOT NULL,
    apellido_paterno          VARCHAR(100) NOT NULL,
    apellido_materno          VARCHAR(100),
    domicilio_calle           VARCHAR(200),
    domicilio_numero          VARCHAR(20),  -- número exterior
    domicilio_numero_interior VARCHAR(20),  -- [v5] número interior, opcional
    domicilio_colonia         VARCHAR(150),
    domicilio_municipio       VARCHAR(100),
    domicilio_estado          VARCHAR(100),
    domicilio_cp              VARCHAR(10),
    clave_elector             VARCHAR(18),  -- obligatorio en la app desde v5
    ocr                       VARCHAR(18),  -- obligatorio en la app desde v5
    cic                       VARCHAR(18),  -- [v5] ya no se captura; se conserva por compatibilidad
    foto_anverso_ine          VARCHAR(255),
    foto_reverso_ine          VARCHAR(255),
    foto_persona              VARCHAR(255),
    firma                     VARCHAR(255),
    acepta_afiliacion_libre   TINYINT(1) NOT NULL DEFAULT 0,
    acepta_documentos         TINYINT(1) NOT NULL DEFAULT 0,
    acepta_no_otro_partido    TINYINT(1) NOT NULL DEFAULT 0,
    acepta_aviso_privacidad   TINYINT(1) NOT NULL DEFAULT 0,
    estatus                   ENUM('NUEVA','EN_REVISION','VERIFICADO') NOT NULL DEFAULT 'NUEVA',
    id_registrador            INT NOT NULL,
    fecha_creacion            DATETIME NOT NULL DEFAULT NOW(),
    fecha_actualizacion       DATETIME NULL ON UPDATE NOW(),
    fecha_eliminacion         DATETIME NULL,
    id_usuario_actualizacion  INT NULL,
    id_usuario_eliminacion    INT NULL,
    FOREIGN KEY (id_municipio_afiliacion) REFERENCES municipios(id_municipio),
    FOREIGN KEY (id_registrador)          REFERENCES usuarios(id_usuario),
    FOREIGN KEY (id_usuario_actualizacion) REFERENCES usuarios(id_usuario),
    FOREIGN KEY (id_usuario_eliminacion)   REFERENCES usuarios(id_usuario)
);

-- ============================================================
-- TABLA: verificaciones_afiliaciones (RF-04)
-- ============================================================
CREATE TABLE verificaciones_afiliaciones (
    id_verificacion    INT AUTO_INCREMENT PRIMARY KEY,
    id_afiliacion      INT NOT NULL,
    id_verificador     INT NOT NULL,
    decision           ENUM('APROBADO','RECHAZADO') NOT NULL,
    observaciones      TEXT,
    fecha_verificacion DATETIME NOT NULL DEFAULT NOW(),
    FOREIGN KEY (id_afiliacion)  REFERENCES afiliaciones(id_afiliacion),
    FOREIGN KEY (id_verificador) REFERENCES usuarios(id_usuario)
);

-- ============================================================
-- TABLA: bitacora (RF-06)
-- ============================================================
CREATE TABLE bitacora (
    id_log               INT AUTO_INCREMENT PRIMARY KEY,
    id_usuario           INT NULL,
    accion               ENUM(
                            'LOGIN','LOGOUT',
                            'REGISTRO','EDICION','ELIMINACION',
                            'APROBACION','RECHAZO',
                            'CONSULTA',
                            'PERMISO_ASIGNADO',
                            'CREACION_USUARIO',
                            'GENERACION_CEDULA'
                         ) NOT NULL,
    id_modulo             INT NULL,
    id_registro_afectado  INT NULL,
    detalles              TEXT,
    ip_origen             VARCHAR(45),
    fecha                 DATETIME NOT NULL DEFAULT NOW(),
    FOREIGN KEY (id_usuario) REFERENCES usuarios(id_usuario) ON DELETE SET NULL,
    FOREIGN KEY (id_modulo)  REFERENCES modulos_sistema(id_modulo)
);

-- ============================================================
-- ÍNDICES
-- ============================================================
CREATE INDEX idx_afiliaciones_estatus     ON afiliaciones(estatus);
CREATE INDEX idx_afiliaciones_registrador ON afiliaciones(id_registrador);
CREATE INDEX idx_afiliaciones_municipio   ON afiliaciones(id_municipio_afiliacion);
CREATE INDEX idx_bitacora_usuario         ON bitacora(id_usuario);
CREATE INDEX idx_bitacora_fecha           ON bitacora(fecha);
CREATE INDEX idx_bitacora_modulo          ON bitacora(id_modulo);
CREATE INDEX idx_usuarios_tipo            ON usuarios(tipo_usuario);
CREATE INDEX idx_usuarios_asociacion      ON usuarios(id_asociacion);

-- ============================================================
-- VISTAS
-- ============================================================
CREATE OR REPLACE VIEW vw_afiliaciones_reporte AS
SELECT
    a.id_afiliacion,
    CONCAT(a.nombre, ' ', a.apellido_paterno,
           IFNULL(CONCAT(' ', a.apellido_materno), '')) AS nombre_completo,
    a.clave_elector,
    a.ocr,
    a.cic,
    m.nombre AS municipio_afiliacion,
    a.estatus,
    a.fecha_hora_afiliacion AS fecha_registro,
    u.id_asociacion,
    ap.nombre AS asociacion,
    CONCAT(u.nombre, ' ', u.apellido_paterno) AS registrador,
    v.decision       AS ultima_decision,
    v.observaciones  AS ultima_observacion,
    v.fecha_verificacion
FROM afiliaciones a
JOIN municipios m               ON m.id_municipio   = a.id_municipio_afiliacion
JOIN usuarios u                  ON u.id_usuario      = a.id_registrador
JOIN asociaciones_politicas ap   ON ap.id_asociacion  = u.id_asociacion
LEFT JOIN verificaciones_afiliaciones v
       ON v.id_afiliacion = a.id_afiliacion
      AND v.id_verificacion = (
          SELECT MAX(id_verificacion) FROM verificaciones_afiliaciones
          WHERE id_afiliacion = a.id_afiliacion
      )
WHERE a.fecha_eliminacion IS NULL;

CREATE OR REPLACE VIEW vw_bitacora_detalle AS
SELECT
    b.id_log,
    b.fecha,
    CONCAT(u.nombre, ' ', u.apellido_paterno) AS usuario,
    u.tipo_usuario,
    b.accion,
    ms.descripcion AS modulo,
    b.id_registro_afectado,
    b.detalles,
    b.ip_origen
FROM bitacora b
LEFT JOIN usuarios u        ON u.id_usuario = b.id_usuario
LEFT JOIN modulos_sistema ms ON ms.id_modulo = b.id_modulo
ORDER BY b.fecha DESC;

CREATE OR REPLACE VIEW vw_estadisticas_afiliaciones AS
SELECT
    ap.id_asociacion,
    ap.nombre AS asociacion,
    MAX(pe.total_padron) AS total_padron,
    MAX(pe.porcentaje_minimo) AS porcentaje_minimo,
    ROUND(MAX(pe.total_padron) * (MAX(pe.porcentaje_minimo) / 100)) AS minimo_requerido,
    COUNT(a.id_afiliacion) AS total_afiliaciones,
    SUM(a.estatus = 'VERIFICADO')  AS verificadas,
    SUM(a.estatus = 'EN_REVISION') AS en_revision,
    SUM(a.estatus = 'NUEVA')       AS nuevas
FROM asociaciones_politicas ap
LEFT JOIN usuarios u   ON u.id_asociacion = ap.id_asociacion
LEFT JOIN afiliaciones a ON a.id_registrador = u.id_usuario AND a.fecha_eliminacion IS NULL
CROSS JOIN (SELECT * FROM padron_electoral WHERE activo = 1 LIMIT 1) pe
GROUP BY ap.id_asociacion, ap.nombre;

-- ============================================================
-- TRIGGERS
-- ============================================================
DELIMITER //

CREATE TRIGGER trg_proteger_afiliacion_verificada
BEFORE DELETE ON afiliaciones
FOR EACH ROW
BEGIN
    IF OLD.estatus = 'VERIFICADO' THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'No se puede eliminar una afiliacion ya verificada';
    END IF;
END //

CREATE TRIGGER trg_validar_edicion_afiliacion
BEFORE UPDATE ON afiliaciones
FOR EACH ROW
BEGIN
    IF OLD.estatus != 'NUEVA' AND (
        NEW.nombre != OLD.nombre OR NEW.apellido_paterno != OLD.apellido_paterno
    ) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Solo se pueden editar afiliaciones con estatus Nueva afiliacion';
    END IF;
END //

DELIMITER ;

-- ============================================================
-- PROCEDIMIENTOS ALMACENADOS
-- ============================================================
DELIMITER //

CREATE PROCEDURE sp_enviar_a_revision(
    IN p_id_afiliacion INT,
    IN p_id_usuario    INT
)
BEGIN
    DECLARE v_estatus ENUM('NUEVA','EN_REVISION','VERIFICADO');

    SELECT estatus INTO v_estatus FROM afiliaciones WHERE id_afiliacion = p_id_afiliacion;

    IF v_estatus IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La afiliacion no existe';
    ELSEIF v_estatus != 'NUEVA' THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Solo se puede enviar a revision una afiliacion en estatus Nueva afiliacion';
    END IF;

    UPDATE afiliaciones
    SET estatus = 'EN_REVISION', id_usuario_actualizacion = p_id_usuario
    WHERE id_afiliacion = p_id_afiliacion;

    INSERT INTO bitacora(id_usuario, accion, id_modulo, id_registro_afectado, detalles)
    VALUES(p_id_usuario, 'EDICION',
           (SELECT id_modulo FROM modulos_sistema WHERE clave = 'CONSULTA_AFILIACIONES'),
           p_id_afiliacion, 'Afiliacion enviada a revision (Nueva -> En revision)');
END //

CREATE PROCEDURE sp_verificar_afiliacion(
    IN p_id_afiliacion  INT,
    IN p_id_verificador INT,
    IN p_decision       ENUM('APROBADO','RECHAZADO'),
    IN p_observaciones  TEXT
)
BEGIN
    DECLARE v_estatus ENUM('NUEVA','EN_REVISION','VERIFICADO');
    DECLARE v_estatus_nuevo ENUM('NUEVA','EN_REVISION','VERIFICADO');

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SELECT estatus INTO v_estatus FROM afiliaciones WHERE id_afiliacion = p_id_afiliacion;

    IF v_estatus IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La afiliacion no existe';
    ELSEIF v_estatus != 'EN_REVISION' THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Solo se pueden verificar afiliaciones que esten En revision';
    END IF;

    START TRANSACTION;

    SET v_estatus_nuevo = IF(p_decision = 'APROBADO', 'VERIFICADO', 'NUEVA');

    UPDATE afiliaciones
    SET estatus = v_estatus_nuevo,
        id_usuario_actualizacion = p_id_verificador
    WHERE id_afiliacion = p_id_afiliacion;

    INSERT INTO verificaciones_afiliaciones (id_afiliacion, id_verificador, decision, observaciones)
    VALUES (p_id_afiliacion, p_id_verificador, p_decision, p_observaciones);

    INSERT INTO bitacora(id_usuario, accion, id_modulo, id_registro_afectado, detalles)
    VALUES(p_id_verificador, IF(p_decision = 'APROBADO', 'APROBACION', 'RECHAZO'),
           (SELECT id_modulo FROM modulos_sistema WHERE clave = 'VERIFICACION_AFILIACIONES'),
           p_id_afiliacion, CONCAT('Decision: ', p_decision, IFNULL(CONCAT(' - ', p_observaciones), '')));

    COMMIT;
END //

CREATE PROCEDURE sp_eliminar_afiliacion(
    IN p_id_afiliacion INT,
    IN p_id_usuario    INT
)
BEGIN
    DECLARE v_estatus ENUM('NUEVA','EN_REVISION','VERIFICADO');

    SELECT estatus INTO v_estatus FROM afiliaciones WHERE id_afiliacion = p_id_afiliacion;

    IF v_estatus != 'NUEVA' THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Solo se pueden eliminar afiliaciones con estatus Nueva afiliacion';
    END IF;

    UPDATE afiliaciones
    SET fecha_eliminacion = NOW(),
        id_usuario_eliminacion = p_id_usuario
    WHERE id_afiliacion = p_id_afiliacion;

    INSERT INTO bitacora(id_usuario, accion, id_modulo, id_registro_afectado, detalles)
    VALUES(p_id_usuario, 'ELIMINACION',
           (SELECT id_modulo FROM modulos_sistema WHERE clave = 'CONSULTA_AFILIACIONES'),
           p_id_afiliacion, 'Registro eliminado (soft delete)');
END //

DELIMITER ;

-- ============================================================
-- DATOS DE PRUEBA
-- ============================================================

INSERT INTO asociaciones_politicas (
    nombre, representante_legal, calle, numero, colonia, municipio, codigo_postal,
    correo_electronico, telefono, fecha_aprobacion, estatus
) VALUES (
    'Nuevo Rumbo', 'García Mendoza Luis Alberto',
    'Av. Constitución', '100', 'Centro', 'Querétaro', '76000',
    'contacto@nuevorumbo.mx', '4421000000', '2024-01-15', 'VIGENTE'
);

INSERT INTO padron_electoral (total_padron, fecha_corte, porcentaje_minimo)
VALUES (1500000, '2024-12-31', 0.1300);

INSERT INTO usuarios (correo_electronico, contrasena, nombre, apellido_paterno, apellido_materno, tipo_usuario, id_asociacion, activo) VALUES
('admin@ieeq.mx',           SHA2('12345678',256), 'Juan',      'Administrador','García',  'SUPERADMIN',       NULL, 1),
('maria.func@ieeq.mx',      SHA2('12345678',256), 'María Elena','Funcionaria', 'López',   'FUNCIONARIO_IEEQ', NULL, 1),
('admin.rumbo@nuevorumbo.mx',SHA2('12345678',256),'Sofía',     'Ramírez',      'Castillo','ADMIN_ASOCIACION', 1,    1),
('pedro.aux@nuevorumbo.mx', SHA2('12345678',256), 'Pedro',     'Auxiliar',     'Vargas',  'AUXILIAR',         1,    1),
('laura.aux@nuevorumbo.mx', SHA2('12345678',256), 'Laura',     'Auxiliar',     'Cruz',    'AUXILIAR',         1,    1);

INSERT INTO permisos_usuario (id_usuario, id_modulo, nivel)
SELECT 1, id_modulo, 'ESCRITURA' FROM modulos_sistema;

INSERT INTO permisos_usuario (id_usuario, id_modulo, nivel)
SELECT 2, id_modulo,
       CASE clave
           WHEN 'VERIFICACION_AFILIACIONES' THEN 'ESCRITURA'
           WHEN 'CEDULAS_AFILIACION'        THEN 'ESCRITURA'
           WHEN 'GESTION_USUARIOS'          THEN 'NINGUNO'
           WHEN 'GESTION_PERMISOS'          THEN 'NINGUNO'
           WHEN 'REGISTRO_AFILIACIONES'     THEN 'NINGUNO'
           ELSE 'LECTURA'
       END
FROM modulos_sistema;

INSERT INTO permisos_usuario (id_usuario, id_modulo, nivel)
SELECT 3, id_modulo,
       CASE clave
           WHEN 'PADRON_ELECTORAL' THEN 'LECTURA'
           WHEN 'VERIFICACION_AFILIACIONES' THEN 'NINGUNO'
           ELSE 'ESCRITURA'
       END
FROM modulos_sistema;

-- [v5] Un Auxiliar solo puede tener Escritura en Registro de
-- Afiliaciones y Lectura en Consulta y Gestión del Listado; el
-- resto queda en NINGUNO (permisos.pl vuelve a forzar esta misma
-- regla del lado del servidor, no depende solo de estos datos).
INSERT INTO permisos_usuario (id_usuario, id_modulo, nivel)
SELECT id_usuario, id_modulo,
       CASE clave
           WHEN 'REGISTRO_AFILIACIONES'  THEN 'ESCRITURA'
           WHEN 'CONSULTA_AFILIACIONES'  THEN 'LECTURA'
           ELSE 'NINGUNO'
       END
FROM modulos_sistema
CROSS JOIN (SELECT id_usuario FROM usuarios WHERE tipo_usuario='AUXILIAR') aux;

-- [v5] nombre, apellidos y domicilio en mayúsculas: refleja lo que
-- guarda hoy afiliaciones_nueva.pl (normaliza todo a mayúsculas
-- antes de insertar). El código CIC ya no se captura (columna NULL
-- en capturas nuevas); domicilio_numero_interior es opcional.
INSERT INTO afiliaciones (
    id_municipio_afiliacion, nombre, apellido_paterno, apellido_materno,
    domicilio_calle, domicilio_numero, domicilio_numero_interior, domicilio_colonia,
    domicilio_municipio, domicilio_estado, domicilio_cp,
    clave_elector, ocr, cic, foto_anverso_ine, foto_reverso_ine, foto_persona, firma,
    acepta_afiliacion_libre, acepta_documentos, acepta_no_otro_partido, acepta_aviso_privacidad,
    estatus, id_registrador
) VALUES
(14,'JUAN','PÉREZ','GARCÍA','AV. CONSTITUCIÓN','123',NULL,'CENTRO','QUERÉTARO','QUERÉTARO','76000',
 'PRGJ850315HQRR0100','123456789012','987654321098',
 'uploads/ine/anverso/ine_001.jpg','uploads/ine/reverso/ine_001.jpg','uploads/fotos/foto_001.jpg','uploads/firmas/firma_001.png',
 1,1,1,1,'VERIFICADO',4),
(14,'MARÍA','LÓPEZ','HERNÁNDEZ','CALLE HIDALGO','45','A','JARDINES','QUERÉTARO','QUERÉTARO','76100',
 'LOHM900722MQTR0600','234567890123',NULL,
 'uploads/ine/anverso/ine_002.jpg','uploads/ine/reverso/ine_002.jpg','uploads/fotos/foto_002.jpg','uploads/firmas/firma_002.png',
 1,1,1,1,'EN_REVISION',4),
(16,'CARLOS','RODRÍGUEZ','SILVA','BLVD. BERNARDO QUINTANA','789',NULL,'PRADOS','SAN JUAN DEL RÍO','QUERÉTARO','76800',
 'ROSC781108HQTD0900','345678901234',NULL,
 'uploads/ine/anverso/ine_003.jpg','uploads/ine/reverso/ine_003.jpg','uploads/fotos/foto_003.jpg','uploads/firmas/firma_003.png',
 1,1,1,1,'NUEVA',5);

INSERT INTO verificaciones_afiliaciones (id_afiliacion, id_verificador, decision, observaciones) VALUES
(1, 2, 'APROBADO', 'Documentación completa y verificada.');

INSERT INTO bitacora (id_usuario, accion, id_modulo, id_registro_afectado, detalles, ip_origen) VALUES
(1, 'CREACION_USUARIO', (SELECT id_modulo FROM modulos_sistema WHERE clave='GESTION_USUARIOS'), 3, 'Usuario admin.rumbo@nuevorumbo.mx creado', '192.168.1.1'),
(4, 'REGISTRO', (SELECT id_modulo FROM modulos_sistema WHERE clave='REGISTRO_AFILIACIONES'), 1, 'Nueva afiliación: Juan Pérez García', '192.168.1.20'),
(2, 'APROBACION', (SELECT id_modulo FROM modulos_sistema WHERE clave='VERIFICACION_AFILIACIONES'), 1, 'Afiliación aprobada', '192.168.1.10');
