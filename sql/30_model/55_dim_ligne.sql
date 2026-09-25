-- =============================================================
-- 30_model/55_dim_ligne.sql
--
-- Grain : 1 ligne = 1 line_id (= route_short_name)
--
-- ⚠️ PAS de feed_version dans la clé. Vérifié : sur 88 lignes et
--    3 feeds, route_type ne varie JAMAIS. Seule la 96 a deux
--    route_long_name (LEGRAND / TRINITE, service partiel) —
--    variation cosmétique, résolue par le volume de courses.
--
-- ⚠️ Le préfixe T*/M* désigne le mode REMPLACÉ ; route_type
--    donne le mode RÉEL (piège n°29). Preuve : M1 a route_type = 3.
-- Idempotent
-- =============================================================

DROP TABLE IF EXISTS dim_ligne;

;WITH volume_route AS (
    -- Nombre de courses par route_id, pour départager les lignes
    -- ayant plusieurs route_long_name (cas de la 96).
    SELECT  r.route_short_name,
            r.feed_version,
            r.route_id,
            r.route_long_name,
            r.route_type,
            COUNT(t.trip_id) AS nb_courses
    FROM        stg_routes AS r
    LEFT  JOIN  stg_trips  AS t ON  t.route_id     = r.route_id
                                AND t.feed_version = r.feed_version
    GROUP BY    r.route_short_name, r.feed_version, r.route_id,
                r.route_long_name, r.route_type
),
choix AS (
    SELECT  route_short_name, route_long_name, route_type, nb_courses,
            ROW_NUMBER() OVER (PARTITION BY route_short_name
                               ORDER BY     nb_courses      DESC,
                                            feed_version    DESC,
                                            route_id        ASC) AS rang
    FROM    volume_route
),
presence AS (
    -- Dans combien de feeds la ligne existe-t-elle ?
    -- T7 = 1 seul feed, confirmation de la rupture du 8 août.
    SELECT  route_short_name,
            COUNT(DISTINCT feed_version)     AS nb_feeds,
            MIN(feed_version)                AS feed_premier,
            MAX(feed_version)                AS feed_dernier
    FROM    stg_routes
    GROUP BY route_short_name
)
SELECT
    ROW_NUMBER() OVER (ORDER BY c.route_short_name) AS ligne_sk,
    c.route_short_name                              AS line_id,
    c.route_long_name,
    TRY_CAST(c.route_type AS SMALLINT)              AS route_type,
    CASE TRY_CAST(c.route_type AS SMALLINT)
         WHEN 0 THEN 'tram'
         WHEN 1 THEN 'metro'
         WHEN 3 THEN 'bus'
         ELSE        'autre'
    END                                             AS mode_reel,
    -- Bus de remplacement : préfixe T* ou M* SUIVI D'UN CHIFFRE.
    -- La contrainte sur le chiffre évite d'attraper une ligne
    -- qui commencerait par T ou M sans être un remplacement.
    CAST(CASE WHEN c.route_short_name LIKE '[TM][0-9]%'
              THEN 1 ELSE 0 END AS BIT)             AS est_remplacement,
    CASE WHEN c.route_short_name LIKE 'M[0-9]%' THEN 'metro'
         WHEN c.route_short_name LIKE 'T[0-9]%' THEN 'tram'
         ELSE NULL
    END                                             AS mode_remplace,
    -- Noctis : hors fenêtre 09:15–13:45 par construction
    CAST(CASE WHEN c.route_short_name LIKE 'N[0-9]%'
              THEN 1 ELSE 0 END AS BIT)             AS est_noctis,
    p.nb_feeds,
    p.feed_premier,
    p.feed_dernier,
    est_dans_perimetre = CAST(CASE WHEN EXISTS (
        SELECT 1 FROM dbo.ref_tolerance_ligne AS tol
        WHERE tol.line_id = c.route_short_name COLLATE DATABASE_DEFAULT
        AND tol.est_dans_perimetre = 1)
            THEN 1 ELSE 0 END AS BIT)
INTO    dim_ligne
FROM        choix    AS c
INNER JOIN  presence AS p ON p.route_short_name = c.route_short_name
WHERE       c.rang = 1;

ALTER TABLE dim_ligne ALTER COLUMN ligne_sk BIGINT      NOT NULL;
ALTER TABLE dim_ligne ALTER COLUMN line_id  VARCHAR(50) NOT NULL;
GO

ALTER TABLE dim_ligne ADD CONSTRAINT pk_dim_ligne PRIMARY KEY (ligne_sk);
CREATE UNIQUE INDEX ux_dim_ligne ON dim_ligne (line_id);
GO


-- C14 : effectifs et répartition par mode
-- Attendu : 88 lignes (nombre de route_short_name distincts)
SELECT  COUNT(*) AS n_lignes,
        SUM(CAST(est_remplacement AS INT)) AS n_remplacement,
        SUM(CAST(est_noctis       AS INT)) AS n_noctis
FROM    dim_ligne;

SELECT mode_reel, COUNT(*) AS n FROM dim_ligne GROUP BY mode_reel;

-- C15 : les lignes de remplacement
-- Attendu : M1, M5, T7, T81, T92 — mode_reel = bus pour toutes,
-- mode_remplace = metro pour M*, tram pour T*
SELECT line_id, route_long_name, mode_reel, mode_remplace,
       nb_feeds, feed_premier, feed_dernier
FROM   dim_ligne WHERE est_remplacement = 1 ORDER BY line_id;

-- C16 : la ligne 96 — quel nom a été retenu ?
-- Attendu : GARE DU MIDI - LEGRAND (variante majoritaire)
SELECT line_id, route_long_name, mode_reel FROM dim_ligne WHERE line_id = '96';

-- C17 : cohérence — une ligne de remplacement doit être un bus
-- Attendu : 0 ligne. Si une sort, le piège n°29 est mal appliqué.
SELECT line_id, mode_reel, mode_remplace
FROM   dim_ligne WHERE est_remplacement = 1 AND mode_reel <> 'bus';

-- C18 : couverture — toute ligne observée est-elle dans la dimension ?
-- Attendu : 0
SELECT COUNT(DISTINCT p.line_id)
FROM        wrk_passages AS p
LEFT  JOIN  dim_ligne    AS d ON d.line_id = p.line_id
WHERE       d.ligne_sk IS NULL;


SELECT est_dans_perimetre, nb = COUNT(*)
FROM dim_ligne
GROUP BY est_dans_perimetre;
