/*=============================================================================
  TFE STIB - 20_transform/24_wrk_service_date.sql
  ----------------------------------------------------------------------------
  OBJET : dire, pour chaque jour du perimetre, QUELS SERVICES GTFS
          circulent.

  Grain : 1 ligne = feed_version x service_id x date_service.

  POURQUOI CETTE TABLE EXISTE
  ----------------------------------------------------------------------------
  Le GTFS ne liste pas les jours de circulation : il les DECRIT.
  calendar.txt donne une plage de validite et sept drapeaux de jour
  de semaine ; calendar_dates.txt applique ensuite des exceptions
  (exception_type = 1 ajoute une date, 2 la supprime).

  Pour comparer un horaire a une observation, il faut passer de cette
  description a une liste explicite de dates. C'est cette explosion.

  ⚠️ C'est ici que le perimetre temporel entre du cote THEORIQUE :
     la table part de wrk_jours, pas du calendrier GTFS. Un service
     valide un 30 aout n'apparait pas si le 30 aout n'est pas dans
     wrk_jours. C'est voulu : le theorique ne doit exister que les
     jours ou du reel a ete collecte, sinon chaque jour non collecte
     ajouterait des milliers de passages theoriques sans partenaire
     possible, comptes comme des suppressions.

  LE JOUR DE SEMAINE SANS SET DATEFIRST
  ----------------------------------------------------------------------------
  DATEDIFF(DAY, '19000101', date) % 7 renvoie 0 pour un lundi, le
  1er janvier 1900 en etant un. Cette formule ne depend d'aucun
  reglage de session, contrairement a DATEPART(WEEKDAY, ...) qui
  varie avec SET DATEFIRST et la langue du login.

  UNION et non UNION ALL : un service peut etre a la fois regulier et
  ajoute par exception le meme jour. UNION dedoublonne, ce que la
  cle primaire exige.

  ENTREES : dbo.wrk_jours, dbo.stg_calendar, dbo.stg_calendar_dates
  SORTIE  : dbo.wrk_service_date
  IDEMPOTENT : table reconstruite integralement.

  VOLUME ATTENDU : 3 349 lignes en passe A (44 jours).
=============================================================================*/

USE TFE_STIB;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DROP TABLE IF EXISTS dbo.wrk_service_date;

CREATE TABLE dbo.wrk_service_date (
    feed_version VARCHAR(50) NOT NULL,
    service_id   VARCHAR(50) NOT NULL,
    date_service DATE        NOT NULL,
    CONSTRAINT pk_wrk_service_date PRIMARY KEY (feed_version, service_id, date_service)
);

INSERT INTO dbo.wrk_service_date (feed_version, service_id, date_service)

-- 1. Services reguliers : dans la plage de validite, bon jour de
--    semaine, et non supprimes ce jour-la par une exception.
SELECT      c.feed_version, c.service_id, j.date_service
FROM        dbo.wrk_jours   AS j
INNER JOIN  dbo.stg_calendar AS c
        ON  c.feed_version = j.feed_version
       AND  j.date_service BETWEEN TRY_CONVERT(DATE, c.start_date, 112)
                               AND TRY_CONVERT(DATE, c.end_date,   112)
WHERE       '1' = CASE DATEDIFF(DAY, '19000101', j.date_service) % 7
                       WHEN 0 THEN c.monday
                       WHEN 1 THEN c.tuesday
                       WHEN 2 THEN c.wednesday
                       WHEN 3 THEN c.thursday
                       WHEN 4 THEN c.friday
                       WHEN 5 THEN c.saturday
                       ELSE        c.sunday
                  END
  AND       NOT EXISTS (
                SELECT 1
                FROM   dbo.stg_calendar_dates AS cd
                WHERE  cd.feed_version   = c.feed_version
                  AND  cd.service_id     = c.service_id
                  AND  cd.exception_type = '2'
                  AND  TRY_CONVERT(DATE, cd.date, 112) = j.date_service)

UNION

-- 2. Services ajoutes par exception (exception_type = 1).
--    Un jour ferie fait typiquement circuler un service "dimanche"
--    un mardi : il n'apparait que par cette branche.
SELECT      cd.feed_version, cd.service_id, j.date_service
FROM        dbo.wrk_jours          AS j
INNER JOIN  dbo.stg_calendar_dates AS cd
        ON  cd.feed_version   = j.feed_version
       AND  cd.exception_type = '1'
       AND  TRY_CONVERT(DATE, cd.date, 112) = j.date_service;
GO


/*=============================================================================
  CONTROLES
=============================================================================*/

PRINT '=== F1 - Volumetrie ===';
-- Attendu PASSE A : 3 349 lignes, 44 jours.
-- C'est un controle de NON-REGRESSION : ce chiffre vient de la
-- construction du 21/08 et doit reapparaitre a l'identique.
SELECT  lignes   = COUNT(*),
        jours    = COUNT(DISTINCT date_service),
        services = COUNT(DISTINCT service_id),
        du       = MIN(date_service),
        au       = MAX(date_service)
FROM    dbo.wrk_service_date;
GO


PRINT '=== F2 - Chaque jour du perimetre a-t-il au moins un service ? ===';
-- DOIT renvoyer 0 ligne. Un jour du perimetre sans aucun service
-- theorique produirait un jour de reel pur : tous ses passages
-- deviendraient des reel_non_apparie.
SELECT  j.date_service, j.feed_version
FROM    dbo.wrk_jours AS j
WHERE   NOT EXISTS (SELECT 1 FROM dbo.wrk_service_date AS s
                    WHERE s.date_service = j.date_service);
GO


PRINT '=== F3 - Services par jour de semaine ===';
-- Controle de vraisemblance. Les dimanches et les feries doivent
-- afficher nettement MOINS de services que les jours ouvrables.
-- Reference : 21 juillet et 15 aout se lisent au niveau dimanche.
SELECT  jour_semaine = CASE DATEDIFF(DAY, '19000101', date_service) % 7
                            WHEN 0 THEN '1-lundi'    WHEN 1 THEN '2-mardi'
                            WHEN 2 THEN '3-mercredi' WHEN 3 THEN '4-jeudi'
                            WHEN 4 THEN '5-vendredi' WHEN 5 THEN '6-samedi'
                            ELSE        '7-dimanche' END,
        jours          = COUNT(DISTINCT date_service),
        services_moyen = CAST(1.0 * COUNT(*) / COUNT(DISTINCT date_service) AS DECIMAL(8,1))
FROM    dbo.wrk_service_date
GROUP BY CASE DATEDIFF(DAY, '19000101', date_service) % 7
              WHEN 0 THEN '1-lundi'    WHEN 1 THEN '2-mardi'
              WHEN 2 THEN '3-mercredi' WHEN 3 THEN '4-jeudi'
              WHEN 4 THEN '5-vendredi' WHEN 5 THEN '6-samedi'
              ELSE        '7-dimanche' END
ORDER BY jour_semaine;
GO
