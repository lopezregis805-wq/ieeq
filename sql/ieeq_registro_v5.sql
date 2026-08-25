-- ============================================================
-- BASE DE DATOS: ieeq_registro  (v5)
--
-- Cambios respecto a v4 (ver notas "-- [v5]" a lo largo del
-- archivo):
--
--   1. afiliaciones.domicilio_numero_interior -> columna nueva.
--      El domicilio de la credencial para votar distingue ahora
--      número exterior (columna domicilio_numero, ya existía) de
--      número interior (opcional, para departamentos/interiores).
--
--   2. Ciclo de vida de afiliaciones.estatus (ver notas "-- [v6]"):
--      REVISION_APE (recién capturada o corregida, pendiente de
--      validación) -> COMPULSA_IEEQ (el Admin de Asociación la
--      validó) o RECHAZADA (el Admin de Asociación encontró errores;
--      el Auxiliar corrige y vuelve a REVISION_APE) -> COMPULSA_INE
--      (el Funcionariado IEEQ ya la incluyó en un archivo de
--      compulsa al INE, sp_marcar_compulsa_ine). REVISION_APE y
--      RECHAZADA se comportan igual para efectos de edición y
--      eliminación (trg_validar_edicion_afiliacion,
--      sp_eliminar_afiliacion). sp_regresar_a_revision permite al
--      Admin de Asociación regresar un registro de COMPULSA_IEEQ a
--      REVISION_APE (subsanar antes de que IEEQ genere el archivo).
--
--   3. Permisos por rol sobre el proceso de afiliación -> se acotan
--      por responsabilidad, no por jerarquía:
--      - SUPERADMIN: control absoluto del sistema (usuarios,
--        permisos, asociaciones, padrón, bitácora), pero solo
--        consulta (LECTURA) en Verificación, Listado, Cédulas y
--        Compulsa — nunca ESCRITURA en el proceso operativo.
--      - ADMIN_ASOCIACION: valida/rechaza las afiliaciones de su
--        propia asociación (VERIFICACION_AFILIACIONES = ESCRITURA;
--        antes era exclusivo del Funcionariado IEEQ).
--      - FUNCIONARIO_IEEQ: ya no verifica afiliaciones contra el
--        padrón (VERIFICACION_AFILIACIONES = NINGUNO); su rol pasa a
--        ser generar el archivo de compulsa al INE
--        (COMPULSA_AFILIACIONES = ESCRITURA) sobre lo que la
--        asociación ya validó.
--      La regla se refuerza también del lado del código (los scripts
--      no dan bypass de rol para gestionar registros ajenos).
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

-- Municipios de Querétaro (18 municipios): dominio cerrado de
-- valores, modelado como catálogo en vez de texto libre.
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
('COMPULSA_AFILIACIONES',     'Afiliaciones para Compulsa',          9),
('BITACORA_AUDITORIA',        'Bitácora y Auditoría',                10),
('INICIO_SESION',             'Inicio de Sesión',                    11);

-- ============================================================
-- TABLA: asociaciones_politicas
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
    sitio_web              VARCHAR(255), -- [v6] para el aviso de privacidad de la cédula
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
-- TABLA: padron_electoral
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
-- TABLA: afiliaciones
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
    -- [v6] Flujo: REVISION_APE (recién capturada/corregida, pendiente de que
    -- el Admin de Asociación la valide) -> COMPULSA_IEEQ (validada por el
    -- Admin de Asociación) o RECHAZADA (el Admin de Asociación encontró
    -- errores, el Auxiliar corrige y vuelve a REVISION_APE) -> COMPULSA_INE
    -- (el Funcionariado IEEQ ya la incluyó en un archivo de compulsa al INE).
    estatus                   ENUM('REVISION_APE','RECHAZADA','COMPULSA_IEEQ','COMPULSA_INE') NOT NULL DEFAULT 'REVISION_APE',
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
-- TABLA: verificaciones_afiliaciones
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
-- TABLA: bitacora
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
                            'GENERACION_CEDULA',
                            'COMPULSA_GENERADA','REGRESO_REVISION'
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
    SUM(a.estatus = 'REVISION_APE')  AS revision_ape,
    SUM(a.estatus = 'RECHAZADA')     AS rechazadas,
    SUM(a.estatus = 'COMPULSA_IEEQ') AS compulsa_ieeq,
    SUM(a.estatus = 'COMPULSA_INE')  AS compulsa_ine
FROM asociaciones_politicas ap
LEFT JOIN usuarios u   ON u.id_asociacion = ap.id_asociacion
LEFT JOIN afiliaciones a ON a.id_registrador = u.id_usuario AND a.fecha_eliminacion IS NULL
CROSS JOIN (SELECT * FROM padron_electoral WHERE activo = 1 LIMIT 1) pe
GROUP BY ap.id_asociacion, ap.nombre;

-- ============================================================
-- TRIGGERS
-- ============================================================
DELIMITER //

CREATE TRIGGER trg_proteger_afiliacion_compulsa
BEFORE DELETE ON afiliaciones
FOR EACH ROW
BEGIN
    IF OLD.estatus IN ('COMPULSA_IEEQ', 'COMPULSA_INE') THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'No se puede eliminar una afiliacion que ya esta en compulsa';
    END IF;
END //

CREATE TRIGGER trg_validar_edicion_afiliacion
BEFORE UPDATE ON afiliaciones
FOR EACH ROW
BEGIN
    -- Rechazada se edita igual que Revision APE: permite corregir y reenviar.
    IF OLD.estatus NOT IN ('REVISION_APE', 'RECHAZADA') AND (
        NEW.nombre != OLD.nombre OR NEW.apellido_paterno != OLD.apellido_paterno
    ) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Solo se pueden editar afiliaciones con estatus Revision APE o Rechazada';
    END IF;
END //

DELIMITER ;

-- ============================================================
-- PROCEDIMIENTOS ALMACENADOS
-- ============================================================
DELIMITER //

-- Admin de Asociación valida (o rechaza) una afiliación de su propia
-- asociación que esté en Revisión APE.
CREATE PROCEDURE sp_verificar_afiliacion(
    IN p_id_afiliacion  INT,
    IN p_id_verificador INT,
    IN p_decision       ENUM('APROBADO','RECHAZADO'),
    IN p_observaciones  TEXT
)
BEGIN
    DECLARE v_estatus ENUM('REVISION_APE','RECHAZADA','COMPULSA_IEEQ','COMPULSA_INE');
    DECLARE v_estatus_nuevo ENUM('REVISION_APE','RECHAZADA','COMPULSA_IEEQ','COMPULSA_INE');
    DECLARE v_asociacion_registro    INT;
    DECLARE v_asociacion_verificador INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SELECT a.estatus, u.id_asociacion INTO v_estatus, v_asociacion_registro
    FROM afiliaciones a JOIN usuarios u ON u.id_usuario = a.id_registrador
    WHERE a.id_afiliacion = p_id_afiliacion;

    SELECT id_asociacion INTO v_asociacion_verificador FROM usuarios WHERE id_usuario = p_id_verificador;

    IF v_estatus IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La afiliacion no existe';
    ELSEIF v_estatus != 'REVISION_APE' THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Solo se pueden validar afiliaciones que esten en Revision APE';
    ELSEIF v_asociacion_registro IS NULL OR v_asociacion_verificador IS NULL OR v_asociacion_registro != v_asociacion_verificador THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Solo puedes validar afiliaciones de tu propia asociacion';
    END IF;

    START TRANSACTION;

    SET v_estatus_nuevo = IF(p_decision = 'APROBADO', 'COMPULSA_IEEQ', 'RECHAZADA');

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

-- El Admin de Asociación regresa a Revisión APE una afiliación de SU
-- PROPIA asociación que ya estaba en Compulsa IEEQ, para subsanarla antes
-- de que el Funcionariado IEEQ la incluya en el archivo de compulsa.
-- Regresa una afiliación de Compulsa IEEQ a Revisión APE, para que la
-- asociación la subsane. La ejecuta el Admin de Asociación sobre SUS
-- PROPIOS registros (antes de que IEEQ genere la compulsa), o el
-- Funcionariado IEEQ sobre cualquier registro (mientras revisa el lote
-- en afiliaciones_compulsa.pl, en vez de incluir en la compulsa algo
-- que detectó incorrecto).
CREATE PROCEDURE sp_regresar_a_revision(
    IN p_id_afiliacion INT,
    IN p_id_usuario    INT
)
BEGIN
    DECLARE v_estatus ENUM('REVISION_APE','RECHAZADA','COMPULSA_IEEQ','COMPULSA_INE');
    DECLARE v_asociacion_registro INT;
    DECLARE v_tipo_usuario     ENUM('SUPERADMIN','ADMIN_ASOCIACION','FUNCIONARIO_IEEQ','AUXILIAR');
    DECLARE v_asociacion_usuario  INT;

    SELECT a.estatus, u.id_asociacion INTO v_estatus, v_asociacion_registro
    FROM afiliaciones a JOIN usuarios u ON u.id_usuario = a.id_registrador
    WHERE a.id_afiliacion = p_id_afiliacion;

    SELECT tipo_usuario, id_asociacion INTO v_tipo_usuario, v_asociacion_usuario
    FROM usuarios WHERE id_usuario = p_id_usuario;

    IF v_estatus IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La afiliacion no existe';
    ELSEIF v_estatus != 'COMPULSA_IEEQ' THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Solo se pueden regresar a revision afiliaciones en estatus Compulsa IEEQ';
    ELSEIF v_tipo_usuario = 'ADMIN_ASOCIACION' AND (v_asociacion_registro IS NULL OR v_asociacion_registro != v_asociacion_usuario) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Solo puedes regresar a revision afiliaciones de tu propia asociacion';
    ELSEIF v_tipo_usuario NOT IN ('ADMIN_ASOCIACION', 'FUNCIONARIO_IEEQ') THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'No tienes permiso para regresar afiliaciones a revision';
    END IF;

    UPDATE afiliaciones
    SET estatus = 'REVISION_APE', id_usuario_actualizacion = p_id_usuario
    WHERE id_afiliacion = p_id_afiliacion;

    INSERT INTO bitacora(id_usuario, accion, id_modulo, id_registro_afectado, detalles)
    VALUES(p_id_usuario, 'REGRESO_REVISION',
           (SELECT id_modulo FROM modulos_sistema WHERE clave = 'CONSULTA_AFILIACIONES'),
           p_id_afiliacion, 'Afiliacion regresada a revision (Compulsa IEEQ -> Revision APE)');
END //

-- El Funcionariado IEEQ marca UNA afiliación en Compulsa IEEQ como ya
-- incluida en un archivo de compulsa al INE. afiliaciones_compulsa.pl la
-- llama en un bucle, una vez por cada registro seleccionado, dentro de una
-- sola transacción Perl (begin_work/commit) para que la selección completa
-- se procese junto o no se procese nada.
CREATE PROCEDURE sp_marcar_compulsa_ine(
    IN p_id_afiliacion INT,
    IN p_id_usuario    INT
)
BEGIN
    DECLARE v_estatus ENUM('REVISION_APE','RECHAZADA','COMPULSA_IEEQ','COMPULSA_INE');

    SELECT estatus INTO v_estatus FROM afiliaciones WHERE id_afiliacion = p_id_afiliacion;

    IF v_estatus IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La afiliacion no existe';
    ELSEIF v_estatus != 'COMPULSA_IEEQ' THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Solo se pueden marcar como Compulsa INE afiliaciones en estatus Compulsa IEEQ';
    END IF;

    UPDATE afiliaciones
    SET estatus = 'COMPULSA_INE', id_usuario_actualizacion = p_id_usuario
    WHERE id_afiliacion = p_id_afiliacion;

    INSERT INTO bitacora(id_usuario, accion, id_modulo, id_registro_afectado, detalles)
    VALUES(p_id_usuario, 'COMPULSA_GENERADA',
           (SELECT id_modulo FROM modulos_sistema WHERE clave = 'COMPULSA_AFILIACIONES'),
           p_id_afiliacion, 'Afiliacion incluida en archivo de compulsa al INE');
END //

CREATE PROCEDURE sp_eliminar_afiliacion(
    IN p_id_afiliacion INT,
    IN p_id_usuario    INT
)
BEGIN
    DECLARE v_estatus ENUM('REVISION_APE','RECHAZADA','COMPULSA_IEEQ','COMPULSA_INE');

    SELECT estatus INTO v_estatus FROM afiliaciones WHERE id_afiliacion = p_id_afiliacion;

    IF v_estatus NOT IN ('REVISION_APE', 'RECHAZADA') THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Solo se pueden eliminar afiliaciones con estatus Revision APE o Rechazada';
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

-- Padrón Electoral: elimina el registro activo y promueve el más reciente
-- que quede a activo, para que siempre exista exactamente un "Activo".
CREATE PROCEDURE sp_eliminar_padron(
    IN p_id_padron  INT,
    IN p_id_usuario INT
)
BEGIN
    DECLARE v_activo TINYINT;
    DECLARE v_siguiente INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SELECT activo INTO v_activo FROM padron_electoral WHERE id_padron = p_id_padron;

    IF v_activo IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El registro no existe';
    ELSEIF v_activo != 1 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Solo se puede eliminar el registro activo del padron';
    END IF;

    START TRANSACTION;

    DELETE FROM padron_electoral WHERE id_padron = p_id_padron;

    SELECT id_padron INTO v_siguiente FROM padron_electoral
    ORDER BY fecha_registro DESC LIMIT 1;

    IF v_siguiente IS NOT NULL THEN
        UPDATE padron_electoral SET activo = 1 WHERE id_padron = v_siguiente;
    END IF;

    INSERT INTO bitacora(id_usuario, accion, id_modulo, id_registro_afectado, detalles)
    VALUES(p_id_usuario, 'ELIMINACION',
           (SELECT id_modulo FROM modulos_sistema WHERE clave = 'PADRON_ELECTORAL'),
           p_id_padron, 'Registro de padron electoral eliminado');

    COMMIT;
END //

DELIMITER ;

-- ============================================================
-- DATOS DE PRUEBA
-- ============================================================

INSERT INTO asociaciones_politicas (
    nombre, representante_legal, calle, numero, colonia, municipio, codigo_postal,
    correo_electronico, telefono, sitio_web, fecha_aprobacion, estatus
) VALUES (
    'Nuevo Rumbo', 'García Mendoza Luis Alberto',
    'Av. Constitución', '100', 'Centro', 'Querétaro', '76000',
    'contacto@nuevorumbo.mx', '4421000000', 'https://www.nuevorumbo.mx', '2024-01-15', 'VIGENTE'
);

INSERT INTO padron_electoral (total_padron, fecha_corte, porcentaje_minimo)
VALUES (1500000, '2024-12-31', 0.1300);

INSERT INTO usuarios (correo_electronico, contrasena, nombre, apellido_paterno, apellido_materno, tipo_usuario, id_asociacion, activo) VALUES
('admin@ieeq.mx',           SHA2('12345678',256), 'Juan',      'Administrador','García',  'SUPERADMIN',       NULL, 1),
('maria.func@ieeq.mx',      SHA2('12345678',256), 'María Elena','Funcionaria', 'López',   'FUNCIONARIO_IEEQ', NULL, 1),
('admin.rumbo@nuevorumbo.mx',SHA2('12345678',256),'Sofía',     'Ramírez',      'Castillo','ADMIN_ASOCIACION', 1,    1),
('pedro.aux@nuevorumbo.mx', SHA2('12345678',256), 'Pedro',     'Auxiliar',     'Vargas',  'AUXILIAR',         1,    1),
('laura.aux@nuevorumbo.mx', SHA2('12345678',256), 'Laura',     'Auxiliar',     'Cruz',    'AUXILIAR',         1,    1);

-- [v6] SUPERADMIN tiene control absoluto del SISTEMA (usuarios, permisos,
-- asociaciones, padrón, cédulas, bitácora, compulsa) pero no de los
-- PROCESOS operativos de afiliación: no registra ni verifica afiliaciones.
INSERT INTO permisos_usuario (id_usuario, id_modulo, nivel)
SELECT 1, id_modulo,
       CASE clave
           WHEN 'REGISTRO_AFILIACIONES'      THEN 'NINGUNO'
           WHEN 'VERIFICACION_AFILIACIONES'  THEN 'LECTURA'
           WHEN 'CONSULTA_AFILIACIONES'      THEN 'LECTURA'
           WHEN 'CEDULAS_AFILIACION'         THEN 'LECTURA'
           WHEN 'COMPULSA_AFILIACIONES'      THEN 'LECTURA'
           ELSE 'ESCRITURA'
       END
FROM modulos_sistema;

-- [v6] Funcionariado IEEQ ya no verifica afiliaciones (eso lo hace el Admin
-- de Asociación) — su rol en el flujo es generar el archivo de compulsa al
-- INE una vez que la asociación ya validó internamente.
INSERT INTO permisos_usuario (id_usuario, id_modulo, nivel)
SELECT 2, id_modulo,
       CASE clave
           WHEN 'COMPULSA_AFILIACIONES'     THEN 'ESCRITURA'
           WHEN 'CEDULAS_AFILIACION'        THEN 'LECTURA'
           WHEN 'VERIFICACION_AFILIACIONES' THEN 'NINGUNO'
           WHEN 'GESTION_USUARIOS'          THEN 'NINGUNO'
           WHEN 'GESTION_PERMISOS'          THEN 'NINGUNO'
           WHEN 'REGISTRO_AFILIACIONES'     THEN 'NINGUNO'
           ELSE 'LECTURA'
       END
FROM modulos_sistema;

-- [v6] El Admin de Asociación ahora valida las afiliaciones de su propia
-- asociación (antes era exclusivo del Funcionariado IEEQ); no ve el listado
-- de compulsa, eso es exclusivo de SUPERADMIN/Funcionariado IEEQ.
INSERT INTO permisos_usuario (id_usuario, id_modulo, nivel)
SELECT 3, id_modulo,
       CASE clave
           WHEN 'PADRON_ELECTORAL'          THEN 'LECTURA'
           WHEN 'VERIFICACION_AFILIACIONES' THEN 'ESCRITURA'
           WHEN 'COMPULSA_AFILIACIONES'     THEN 'NINGUNO'
           ELSE 'ESCRITURA'
       END
FROM modulos_sistema;

-- [v6] Un Auxiliar solo puede tener Escritura en Registro de
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

-- [v6] nombre, apellidos y domicilio en mayúsculas: refleja lo que
-- guarda hoy afiliaciones_nueva.pl (normaliza todo a mayúsculas
-- antes de insertar). El código CIC ya no se captura (columna NULL
-- en capturas nuevas); domicilio_numero_interior es opcional. Las
-- claves de elector y OCR de muestra ya cumplen el formato estructurado
-- validado por la aplicación (18 y 13 caracteres respectivamente), para
-- que estos registros sigan siendo editables desde la interfaz.
-- foto_anverso_ine/foto_reverso_ine/foto_persona/firma van en NULL: son
-- registros de muestra, no capturas reales, y no existe ningún archivo
-- físico detrás de un nombre inventado — la pantalla ya maneja el caso
-- NULL mostrando "(sin archivo)".
INSERT INTO afiliaciones (
    id_municipio_afiliacion, nombre, apellido_paterno, apellido_materno,
    domicilio_calle, domicilio_numero, domicilio_numero_interior, domicilio_colonia,
    domicilio_municipio, domicilio_estado, domicilio_cp,
    clave_elector, ocr, cic, foto_anverso_ine, foto_reverso_ine, foto_persona, firma,
    acepta_afiliacion_libre, acepta_documentos, acepta_no_otro_partido, acepta_aviso_privacidad,
    estatus, id_registrador
) VALUES
(14,'JUAN','PÉREZ','GARCÍA','AV. CONSTITUCIÓN','123',NULL,'CENTRO','QUERÉTARO','QUERÉTARO','76000',
 'PRGJHR85031500H100','1234567890123','987654321098',
 NULL,NULL,NULL,NULL,
 1,1,1,1,'COMPULSA_IEEQ',4),
(14,'MARÍA','LÓPEZ','HERNÁNDEZ','CALLE HIDALGO','45','A','JARDINES','QUERÉTARO','QUERÉTARO','76100',
 'LOHMXX90072200M600','2345678901234',NULL,
 NULL,NULL,NULL,NULL,
 1,1,1,1,'REVISION_APE',4),
(16,'CARLOS','RODRÍGUEZ','SILVA','BLVD. BERNARDO QUINTANA','789',NULL,'PRADOS','SAN JUAN DEL RÍO','QUERÉTARO','76800',
 'ROSCXX78110800H900','3456789012345',NULL,
 NULL,NULL,NULL,NULL,
 1,1,1,1,'REVISION_APE',5);

INSERT INTO verificaciones_afiliaciones (id_afiliacion, id_verificador, decision, observaciones) VALUES
(1, 2, 'APROBADO', 'Documentación completa y verificada.');

INSERT INTO bitacora (id_usuario, accion, id_modulo, id_registro_afectado, detalles, ip_origen) VALUES
(1, 'CREACION_USUARIO', (SELECT id_modulo FROM modulos_sistema WHERE clave='GESTION_USUARIOS'), 3, 'Usuario admin.rumbo@nuevorumbo.mx creado', '192.168.1.1'),
(4, 'REGISTRO', (SELECT id_modulo FROM modulos_sistema WHERE clave='REGISTRO_AFILIACIONES'), 1, 'Nueva afiliación: Juan Pérez García', '192.168.1.20'),
(2, 'APROBACION', (SELECT id_modulo FROM modulos_sistema WHERE clave='VERIFICACION_AFILIACIONES'), 1, 'Afiliación aprobada', '192.168.1.10');
