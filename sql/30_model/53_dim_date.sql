-- =============================================================
-- 30_model/53_dim_date.sql
--
-- Grain      : 1 ligne = 1 DATE DE SERVICE
--              ⚠️ date de service, pas date civile (piège n°4)
-- Couverture : plage CONTINUE 2026-07-01 → 2026-08-31
--              Les jours non collectés sont présents avec
--              est_collecte = 0 : un trou de collecte doit être
--              VISIBLE dans Power BI, pas absent des axes.
-- Clé        : date_sk = AAAAMMJJ (exception assumée à la règle
--              des clés opaques — voir en-tête de session)
-- Idempotent
-- =============================================================

DECLARE @debut DATE = '2026-07-01';
DECLARE @fin   DATE = '2026-08-31';

DROP TABLE IF EXISTS dim_date;

;WITH calendrier AS (
    SELECT @debut AS d
    UNION ALL
    SELECT DATEADD(DAY, 1, d) FROM calendrier WHERE d < @fin
),
feries AS (
    -- Jours fériés belges tombant dans la période.
    -- Liste explicite et non déduite du GTFS : une exception
    -- calendar_dates peut aussi bien signaler un chantier.
    SELECT CAST('2026-07-21' AS DATE) AS d, 'Fête nationale' AS libelle
    UNION ALL
    SELECT CAST('2026-08-15' AS DATE),      'Assomption'
),
base AS (
    SELECT  c.d AS date_service,
            -- 1900-01-01 était un LUNDI -> 0 = lundi, 6 = dimanche.
            -- Indépendant de SET DATEFIRST (piège n°30).
            DATEDIFF(DAY, '19000101', c.d) % 7 AS jour_semaine_num,
            f.libelle AS ferie_libelle
    FROM        calendrier AS c
    LEFT  JOIN  feries     AS f ON f.d = c.d
)
SELECT
    CAST(CONVERT(CHAR(8), b.date_service, 112) AS INT) AS date_sk,
    b.date_service,
    YEAR(b.date_service)                    AS annee,
    MONTH(b.date_service)                   AS mois,
    CHOOSE(MONTH(b.date_service),
           'January','February','March','April','May','June','July',
           'August','September','October','November','December') AS mois_nom,
    DAY(b.date_service)                     AS jour,
    b.jour_semaine_num,
    CHOOSE(b.jour_semaine_num + 1,
           'Monday','Tuesday','Wednesday','Thursday',
           'Friday','Saturday','Sunday')    AS jour_nom,
    -- Libelles en anglais depuis le 25/09/2026 : ils sont affiches tels
    -- quels dans le rapport Power BI, redige en anglais. regime_service
    -- reste en francais : valeur technique, jamais affichee.
    DATEPART(ISO_WEEK, b.date_service)      AS semaine_iso,
    CAST(CASE WHEN b.jour_semaine_num >= 5 THEN 1 ELSE 0 END AS BIT) AS est_weekend,
    CAST(CASE WHEN b.ferie_libelle IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS est_ferie,
    b.ferie_libelle,
    -- Régime d'exploitation attendu : un férié roule au niveau
    -- dimanche (mesuré : 21/07 = 63 643 passages, 15/08 = 64 128).
    CASE WHEN b.ferie_libelle IS NOT NULL THEN 'dimanche'
         WHEN b.jour_semaine_num = 6      THEN 'dimanche'
         WHEN b.jour_semaine_num = 5      THEN 'samedi'
         ELSE                                  'semaine'
    END AS regime_service,
    fp.feed_version,                       -- NULL au 31/08 : voulu
    CAST(CASE WHEN j.date_service IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS est_collecte
INTO        dim_date
FROM        base            AS b
LEFT  JOIN  ref_feed_periode AS fp
         ON b.date_service BETWEEN fp.date_debut AND fp.date_fin
LEFT  JOIN  wrk_jours        AS j
         ON j.date_service = b.date_service
OPTION (MAXRECURSION 0);

ALTER TABLE dim_date ALTER COLUMN date_sk      INT  NOT NULL;
ALTER TABLE dim_date ALTER COLUMN date_service DATE NOT NULL;
GO

ALTER TABLE dim_date ADD CONSTRAINT pk_dim_date PRIMARY KEY (date_sk);
CREATE UNIQUE INDEX ux_dim_date ON dim_date (date_service);
GO



-- C6 : effectifs
-- Attendu : 62 lignes (31 juillet + 31 août), 44 collectées
SELECT  COUNT(*)                              AS n_jours,
        SUM(CAST(est_collecte AS INT))        AS n_collectes,
        SUM(CAST(est_ferie    AS INT))        AS n_feries,
        SUM(CASE WHEN feed_version IS NULL THEN 1 ELSE 0 END) AS sans_feed
FROM    dim_date;

-- C7 : quels jours sans feed ?  Attendu : le 31/08 seul
SELECT date_service, jour_nom FROM dim_date WHERE feed_version IS NULL;

-- C8 : les jours non collectés
-- Attendu : 4, 5, 6, 11, 12 juillet + tout ce qui suit le 18 août
SELECT date_service, jour_nom, regime_service
FROM   dim_date WHERE est_collecte = 0 ORDER BY date_service;

-- C9 : contrôle du calcul du jour de semaine (piège n°30)
-- Le 21/07/2026 est un MARDI. Si jour_nom dit autre chose,
-- le calcul est faux — et il le serait silencieusement.
SELECT date_service, jour_semaine_num, jour_nom, est_ferie, ferie_libelle
FROM   dim_date WHERE date_service IN ('2026-07-21','2026-08-15','2026-07-19');

SELECT * FROM dim_date
