-- =============================================================
-- 30_model/57_dim_course.sql
--
-- Grain : 1 ligne = 1 course TELLE QUE PUBLIÉE = (feed_version, trip_id)
--
-- ⚠️ Pourquoi feed_version dans la clé : un trip_id appartient à un
--    feed. La même course métier a trois trip_id différents dans les
--    trois publications, sans lien entre eux. Reconstituer une identité
--    inter-feeds demanderait un SECOND appariement (sur l'heure de
--    départ, avec tolérance) — chantier volontairement non ouvert.
--    Ce qui traverse les feeds, c'est la VARIANTE, pas la course.
--
-- ⚠️ La troncature a DEUX dimensions indépendantes, pas une :
--    une course peut démarrer en cours de ligne, s'arrêter avant le
--    terminus, ou les deux. D'où deux booléens plutôt qu'une classe :
--    exhaustif par construction, contrairement à une liste de cas.
--
-- Dépendances : stg_trips, stg_routes, stg_stop_times, dim_desserte
-- Paramétré  : @ligne = '25', NULL = tout le réseau
-- Idempotent
-- =============================================================

DECLARE @ligne VARCHAR(10) = NULL;

DROP TABLE IF EXISTS dim_course;

;WITH bornes AS (
    -- Premier et dernier rang géographique de chaque (ligne, sens).
    -- Comparaison sur ordre_geo et non sur stop_id_racine : les deux
    -- quais d'un terminus (0539 / 0529) partagent le même rang et
    -- doivent compter identiquement.
    SELECT  line_id, direction_id,
            MIN(ordre_geo) AS ordre_premier,
            MAX(ordre_geo) AS ordre_dernier
    FROM    dim_desserte
    GROUP BY line_id, direction_id
),
courses AS (
    SELECT  r.route_short_name AS line_id,
            t.feed_version,
            t.trip_id,
            t.direction_id,
            t.trip_headsign,
            COUNT(*)            AS nb_arrets,
            MIN(st.arrivee_sec) AS depart_sec,
            MAX(st.arrivee_sec) AS arrivee_sec,
            STRING_AGG(st.stop_id_racine, '>')
                WITHIN GROUP (ORDER BY st.stop_sequence) AS signature
    FROM        stg_trips      AS t
    INNER JOIN  stg_routes     AS r  ON  r.route_id      = t.route_id
                                     AND r.feed_version  = t.feed_version
    INNER JOIN  stg_stop_times AS st ON  st.trip_id      = t.trip_id
                                     AND st.feed_version = t.feed_version
    WHERE      (@ligne IS NULL OR r.route_short_name = @ligne)
      AND       EXISTS (SELECT 1 FROM dbo.ref_tolerance_ligne AS tol
      WHERE tol.line_id = r.route_short_name COLLATE DATABASE_DEFAULT
                          AND tol.est_dans_perimetre = 1)
    GROUP BY    r.route_short_name, t.feed_version, t.trip_id,
                t.direction_id, t.trip_headsign
),
extremites AS (
    -- Rang géographique du premier et du dernier arrêt de la course.
    -- Passe par dim_desserte : c'est elle qui porte l'ordre.
    SELECT  c.*,
            dd.ordre_geo AS ordre_debut,
            df.ordre_geo AS ordre_fin
    FROM        courses AS c
    CROSS APPLY (
        SELECT TOP 1 st.stop_id_racine
        FROM   stg_stop_times AS st
        WHERE  st.trip_id = c.trip_id AND st.feed_version = c.feed_version
        ORDER BY st.stop_sequence ASC
    ) AS prem
    CROSS APPLY (
        SELECT TOP 1 st.stop_id_racine
        FROM   stg_stop_times AS st
        WHERE  st.trip_id = c.trip_id AND st.feed_version = c.feed_version
        ORDER BY st.stop_sequence DESC
    ) AS dern
    LEFT  JOIN  dim_desserte AS dd ON  dd.line_id        = c.line_id
                                   AND dd.direction_id   = c.direction_id
                                   AND dd.stop_id_racine = prem.stop_id_racine
    LEFT  JOIN  dim_desserte AS df ON  df.line_id        = c.line_id
                                   AND df.direction_id   = c.direction_id
                                   AND df.stop_id_racine = dern.stop_id_racine
),
variantes AS (
    -- Numérotation des variantes par fréquence : la plus courante
    -- porte le n°1. Stable tant que la composition ne change pas.
    SELECT  line_id, direction_id, signature,
            COUNT(*) AS nb_courses_variante,
            ROW_NUMBER() OVER (PARTITION BY line_id, direction_id
                               ORDER BY COUNT(*) DESC, MIN(signature) ASC) AS num_variante
    FROM    extremites
    GROUP BY line_id, direction_id, signature
)
SELECT
    ROW_NUMBER() OVER (ORDER BY e.line_id, e.feed_version, e.trip_id) AS course_sk,
    e.feed_version,
    e.trip_id,
    e.line_id,
    e.direction_id,
    e.trip_headsign,
    e.nb_arrets,
    e.depart_sec,
    e.arrivee_sec,
    -- Durée théorique du parcours publié, en minutes
    (e.arrivee_sec - e.depart_sec) / 60             AS duree_min,
    e.ordre_debut,
    e.ordre_fin,
    CAST(CASE WHEN e.ordre_debut = b.ordre_premier THEN 1 ELSE 0 END AS BIT)
        AS demarre_au_terminus,
    CAST(CASE WHEN e.ordre_fin   = b.ordre_dernier THEN 1 ELSE 0 END AS BIT)
        AS finit_au_terminus,
    CAST(CASE WHEN e.ordre_debut = b.ordre_premier
               AND e.ordre_fin   = b.ordre_dernier THEN 1 ELSE 0 END AS BIT)
        AS est_parcours_complet,
    v.num_variante,
    v.nb_courses_variante,
    e.signature
INTO    dim_course
FROM        extremites AS e
INNER JOIN  bornes     AS b ON  b.line_id      = e.line_id
                            AND b.direction_id = e.direction_id
INNER JOIN  variantes  AS v ON  v.line_id      = e.line_id
                            AND v.direction_id = e.direction_id
                            AND v.signature    = e.signature;

ALTER TABLE dim_course ALTER COLUMN course_sk    BIGINT      NOT NULL;
ALTER TABLE dim_course ALTER COLUMN feed_version VARCHAR(50) NOT NULL;
ALTER TABLE dim_course ALTER COLUMN trip_id      VARCHAR(50) NOT NULL;
GO

ALTER TABLE dim_course ADD CONSTRAINT pk_dim_course PRIMARY KEY (course_sk);
CREATE UNIQUE INDEX ux_dim_course ON dim_course (feed_version, trip_id);
CREATE INDEX ix_dim_course_ligne ON dim_course (line_id, direction_id, num_variante);
GO
-- ---------- Membre inconnu ----------
-- Pour les 1 216 passages réels sans course théorique.
INSERT INTO dim_course
    (course_sk, feed_version, trip_id, line_id, direction_id, trip_headsign,
     nb_arrets, depart_sec, arrivee_sec, duree_min, ordre_debut, ordre_fin,
     demarre_au_terminus, finit_au_terminus, est_parcours_complet,
     num_variante, nb_courses_variante, signature)
VALUES
    (-1, '?', '?', NULL, NULL, NULL,
     NULL, NULL, NULL, NULL, NULL, NULL,
     NULL, NULL, NULL, NULL, NULL, 'Aucune course théorique');
GO


USE TFE_STIB;
SET NOCOUNT ON;

PRINT '=== H1 - Volumetrie par mode ===';
SELECT  l.mode_reel,
        lignes  = COUNT(DISTINCT c.line_id),
        courses = COUNT(*),
        arrets_moyens = AVG(c.nb_arrets * 1.0),
        duree_moyenne_min = AVG(c.duree_min * 1.0)
FROM    dim_course AS c
JOIN    dim_ligne  AS l ON l.line_id = c.line_id
WHERE   c.course_sk > 0
GROUP BY l.mode_reel
ORDER BY courses DESC;


PRINT '=== H2 - LE CONTROLE DECISIF : extremites non resolues ===';
-- ordre_debut et ordre_fin viennent de deux LEFT JOIN sur dim_desserte.
-- Un LEFT JOIN qui echoue produit NULL, et NULL = b.ordre_premier est
-- toujours FAUX : la course serait classee "partielle" sans qu'aucune
-- erreur ne se produise. C'est le mode de defaillance silencieux du
-- script (piege n°23). Attendu : 0.
SELECT  courses_total       = COUNT(*),
        sans_ordre_debut    = SUM(CASE WHEN ordre_debut IS NULL THEN 1 ELSE 0 END),
        sans_ordre_fin      = SUM(CASE WHEN ordre_fin   IS NULL THEN 1 ELSE 0 END),
        pct_non_resolu      = CAST(100.0 * SUM(CASE WHEN ordre_debut IS NULL
                                                     OR ordre_fin   IS NULL
                                                    THEN 1 ELSE 0 END)
                                   / COUNT(*) AS DECIMAL(5,2))
FROM    dim_course WHERE course_sk > 0;

PRINT '=== H3 - Ou se concentrent les extremites non resolues ? ===';
-- Ne renvoie des lignes que si H2 n'est pas a zero.
SELECT TOP 20
        line_id, direction_id,
        courses = COUNT(*),
        exemple_headsign = MIN(trip_headsign)
FROM    dim_course
WHERE   course_sk > 0 AND (ordre_debut IS NULL OR ordre_fin IS NULL)
GROUP BY line_id, direction_id
ORDER BY courses DESC;


PRINT '=== H4 - Repartition des parcours complets ===';
-- Si le taux de parcours complets s'effondre par rapport a la ligne 25,
-- c'est le signe que le passage de ordre_geo a des multiples de 10 a
-- casse la comparaison aux bornes.
SELECT  est_parcours_complet,
        demarre_au_terminus,
        finit_au_terminus,
        courses = COUNT(*),
        pct = CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))
FROM    dim_course WHERE course_sk > 0
GROUP BY est_parcours_complet, demarre_au_terminus, finit_au_terminus
ORDER BY courses DESC;


PRINT '=== H5 - Non-regression ligne 25 ===';
-- Attendu : 483 courses (valeur validee le 24/08).
SELECT  courses = COUNT(*),
        variantes = COUNT(DISTINCT signature),
        completes = SUM(CAST(est_parcours_complet AS INT))
FROM    dim_course WHERE line_id = '25';


PRINT '=== H6 - Couverture : toute course theorique a-t-elle sa dimension ? ===';
-- Attendu : 0. Une course de int_passage_theorique absente de dim_course
-- ferait echouer la cle etrangere de fact_ecart.
SELECT  courses_orphelines = COUNT(DISTINCT i.trip_id)
FROM    int_passage_theorique AS i
LEFT JOIN dim_course AS c ON  c.feed_version = i.feed_version
                          AND c.trip_id      = i.trip_id
WHERE   i.est_observable = 1 AND c.course_sk IS NULL;




SELECT TOP 20
    c.line_id, c.direction_id, c.trip_headsign,
    racine_premier = prem.stop_id_racine,
    dans_dim_desserte = CASE WHEN d.stop_id_racine IS NULL THEN 'NON' ELSE 'oui' END,
    courses = COUNT(*)
FROM dim_course AS c
CROSS APPLY (
    SELECT TOP 1 st.stop_id_racine
    FROM stg_stop_times AS st
    WHERE st.trip_id = c.trip_id AND st.feed_version = c.feed_version
    ORDER BY st.stop_sequence ASC
) AS prem
LEFT JOIN dim_desserte AS d
       ON d.line_id        = c.line_id
      AND d.direction_id   = c.direction_id
      AND d.stop_id_racine = prem.stop_id_racine COLLATE DATABASE_DEFAULT
WHERE c.course_sk > 0 AND c.ordre_debut IS NULL
GROUP BY c.line_id, c.direction_id, c.trip_headsign,
         prem.stop_id_racine,
         CASE WHEN d.stop_id_racine IS NULL THEN 'NON' ELSE 'oui' END
ORDER BY courses DESC;
