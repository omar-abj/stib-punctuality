/*================================================================
   20_transform/40_int_passage_theorique.sql
   Explosion de l'horaire GTFS sur les jours reellement collectes.
   Grain : 1 ligne = date_service x trip_id x stop_id
   Idempotent. Parametre : @ligne = NULL -> toutes les lignes.

   FENETRE : 09:15 -> 13:45 (resserree le 24/08 apres mesure de
      l'effet de bord).
      Valeurs precedentes : 31500 / 51300 (08:45-14:15)
                            32400 / 50400 (09:00-14:00)

   ATTENTION - ce script est lance ici avec @ligne = NULL, donc sur
   les 88 lignes. Volume attendu : ~3 M de lignes contre 61 802 pour
   la seule ligne 25 (facteur d'echelle mesure : 48).
   ================================================================ */

USE TFE_STIB;
GO

DECLARE @ligne     VARCHAR(5) = NULL;    -- 
DECLARE @sec_debut INT        = 33300;   -- 09:15 inclus
DECLARE @sec_fin   INT        = 49500;   -- 13:45 exclu

DROP TABLE IF EXISTS int_passage_theorique;

WITH ma AS (
    SELECT point_id,
           stop_id AS stop_id_map,
           LEFT(stop_id,
                CASE WHEN PATINDEX('%[^0-9]%', stop_id) = 0
                     THEN LEN(stop_id)
                     ELSE PATINDEX('%[^0-9]%', stop_id) - 1 END) AS racine
    FROM   map_arret
)
SELECT
        sd.date_service,
        sd.feed_version,
        t.trip_id,
        t.service_id,
        t.route_id,
        r.route_short_name                          AS line_id,
        r.route_type,
        t.trip_headsign,
        t.direction_id,
        st.stop_id,
        st.stop_id_racine,
        ma.point_id,
        st.stop_sequence,
        st.arrivee_sec,
        DATEADD(SECOND, st.arrivee_sec,
                CAST(sd.date_service AS DATETIME2)) AS arrivee_theorique,
        CASE WHEN st.stop_sequence = MIN(st.stop_sequence)
                    OVER (PARTITION BY st.feed_version, st.trip_id)
             THEN 1 ELSE 0 END                      AS est_premier_arret,
        CASE WHEN st.stop_sequence = MAX(st.stop_sequence)
                    OVER (PARTITION BY st.feed_version, st.trip_id)
             THEN 1 ELSE 0 END                      AS est_dernier_arret
INTO    int_passage_theorique
FROM    wrk_service_date  sd
JOIN    stg_trips         t  ON t.feed_version  = sd.feed_version
                            AND t.service_id    = sd.service_id
JOIN    stg_routes        r  ON r.feed_version  = t.feed_version
                            AND r.route_id      = t.route_id
JOIN    stg_stop_times    st ON st.feed_version = t.feed_version
                            AND st.trip_id      = t.trip_id
LEFT JOIN ma                 ON ma.racine       = st.stop_id_racine
WHERE   st.arrivee_sec >= @sec_debut
  AND   st.arrivee_sec <  @sec_fin
  AND   r.route_short_name NOT LIKE 'N%'
  AND   (@ligne IS NULL OR r.route_short_name = @ligne)
OPTION (RECOMPILE);
GO

CREATE CLUSTERED INDEX ix_ipt_appariement
    ON int_passage_theorique (line_id, date_service, point_id, arrivee_theorique);
GO

/* est_premier_arret / est_dernier_arret marquent le premier/dernier
   arret VISIBLE DANS LA FENETRE, pas de la course (la fonction fenetre
   s'applique apres le WHERE). Decision : conserves, NON UTILISES.
   Piege n°32. */


/*================================================================
  CONTROLES
  ================================================================*/

PRINT '=== C1 - Volumetrie globale ===';
-- Ligne 25 seule donnait : 61 802 lignes, 44 jours, 483 courses, 53 points.
-- Attendu ici : ~3 M de lignes, 44 jours, 88 lignes.
SELECT
    lignes        = COUNT(*),
    jours         = COUNT(DISTINCT date_service),
    lignes_stib   = COUNT(DISTINCT line_id),
    courses       = COUNT(DISTINCT trip_id),
    points        = COUNT(DISTINCT point_id)
FROM int_passage_theorique;
GO


PRINT '=== C2 - point_id manquants (echec de map_arret) ===';
-- Sur la ligne 25 : 0. Ici, un residu est ATTENDU (54 orphelins mesures
-- au niveau reseau, 0,574 % du volume). Le chiffre est a noter, pas a
-- corriger : c'est une mesure de couverture de la source.
SELECT
    total          = COUNT(*),
    sans_point_id  = SUM(CASE WHEN point_id IS NULL THEN 1 ELSE 0 END),
    pct_sans_point = CAST(100.0 * SUM(CASE WHEN point_id IS NULL THEN 1 ELSE 0 END)
                          / COUNT(*) AS DECIMAL(5,3))
FROM int_passage_theorique;
GO


PRINT '=== C3 - Doublons sur le grain declare ===';
-- Doit renvoyer 0 ligne. Un doublon signifierait que la jointure sur
-- racine duplique (une racine rattachee a deux point_id).
SELECT TOP 20 date_service, trip_id, stop_id, nb = COUNT(*)
FROM int_passage_theorique
GROUP BY date_service, trip_id, stop_id
HAVING COUNT(*) > 1
ORDER BY nb DESC;
GO


PRINT '=== C4 - Repartition par mode (prepare Q1) ===';
-- route_type GTFS : 0 = tram, 1 = metro, 3 = bus.
-- Premiere vue de l'equilibre des trois modes dans la fenetre.
SELECT
    route_type,
    lignes_stib = COUNT(DISTINCT line_id),
    passages    = COUNT(*),
    pct         = CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))
FROM int_passage_theorique
GROUP BY route_type
ORDER BY passages DESC;
GO


PRINT '=== C5 - Non-regression sur la ligne 25 ===';
-- DOIT valoir exactement 61 802. Si ce n'est pas le cas, le passage a
-- @ligne = NULL a change autre chose que le perimetre.
SELECT lignes_ligne_25 = COUNT(*)
FROM int_passage_theorique
WHERE line_id = '25';
GO




USE TFE_STIB;

PRINT '=== D1 - Lignes publiees absentes de la fenetre analytique ===';
SELECT
    l.line_id,
    l.route_type,
    l.est_noctis,
    presente_dans_ipt = CASE WHEN EXISTS (
        SELECT 1 FROM int_passage_theorique i WHERE i.line_id = l.line_id
    ) THEN 'oui' ELSE 'NON' END
FROM dim_ligne AS l
WHERE l.est_noctis = 0
  AND NOT EXISTS (SELECT 1 FROM int_passage_theorique i WHERE i.line_id = l.line_id)
ORDER BY l.route_type, l.line_id;


PRINT '=== D2 - Ces lignes ont-elles un horaire GTFS HORS fenetre ? ===';
-- Si oui : la ligne existe mais ne circule pas en journee creuse.
-- Si non : la ligne n'est dans aucun feed, autre probleme.
SELECT
    r.route_short_name,
    r.route_type,
    premier_passage = MIN(st.arrivee_sec),
    dernier_passage = MAX(st.arrivee_sec),
    nb_arrets       = COUNT(*)
FROM stg_routes  AS r
JOIN stg_trips   AS t  ON t.feed_version = r.feed_version AND t.route_id = r.route_id
JOIN stg_stop_times AS st ON st.feed_version = t.feed_version AND st.trip_id = t.trip_id
WHERE r.route_short_name NOT LIKE 'N%'
  AND NOT EXISTS (SELECT 1 FROM int_passage_theorique i
                  WHERE i.line_id = r.route_short_name)
GROUP BY r.route_short_name, r.route_type
ORDER BY r.route_type, r.route_short_name;


PRINT '=== D3 - Ou se concentrent les 34 883 sans point_id ? ===';
-- Un petit nombre d'arrets tres frequentes, ou une longue traine ?
-- La reponse decide s'il y a une correction possible ou seulement
-- une limite a documenter.
SELECT TOP 25
    i.stop_id_racine,
    lignes_concernees = COUNT(DISTINCT i.line_id),
    passages          = COUNT(*),
    pct_du_manquant   = CAST(100.0 * COUNT(*)
                             / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))
FROM int_passage_theorique AS i
WHERE i.point_id IS NULL
GROUP BY i.stop_id_racine
ORDER BY passages DESC;