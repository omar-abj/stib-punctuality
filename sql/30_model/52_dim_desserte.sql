/*=============================================================================
  TFE STIB - 30_model/52_dim_desserte.sql
  ----------------------------------------------------------------------------
  Grain : 1 ligne = line_id x direction_id x stop_id_racine
  Parametre : @ligne = NULL -> tout le reseau

  REECRITURE DU 27/08 - quatre changements
  ----------------------------------------------------------------------------
  1. RATTACHEMENT HORS EPINE : le CROSS APPLY geographique est SUPPRIME.
     Mesure du 27/08 : sur 361 arrets hors epine du reseau, 144 (39,9 %)
     etaient a plus de 300 m de l'arret d'epine auquel la proximite les
     rattachait, dont 61 a plus de 1 km (jusqu'a 3 334 m, ligne 4).
     Lignes a branches : 87, 4, 1, 51, 93.
     La distance a vol d'oiseau n'a AUCUN rapport avec l'ordre de desserte.
     -> Un arret hors epine herite du rang de son PREDECESSEUR DANS SA
        PROPRE COURSE. Exact par construction, aucun seuil a justifier.

  2. ORDRE_GEO = ROW_NUMBER() x 10, et non stop_sequence.
     Le GTFS autorise une numerotation a trous (10, 20, 30). Verifie
     consecutif sur la ligne 25 seulement. Le x10 laisse la place aux
     arrets intercales sans renumeroter l'epine.

  3. est_quai_terminus SCINDE EN DEUX.
     Sur la 25, hors epine = quai de retournement, donc le nom etait juste.
     Au reseau, 61 arrets hors epine sont a plus de 1 km : ce sont des
     branches, pas des quais. Le drapeau serait devenu FAUX silencieusement.
       est_hors_epine     : fait structurel
       est_quai_terminus  : jumeau d'epine a moins de 50 m

  4. ORDRE_CORRIDOR : rang unique par LIEU, independant du sens.
     Remplace le contournement DAX UNICHAR(8203) (trap #56 d'Omar).

  ----------------------------------------------------------------------------
  POURQUOI LE CORRIDOR SE CONSTRUIT SUR stop_name ET PAS SUR stop_id_racine
  ----------------------------------------------------------------------------
  Mesure du 27/08 : 96,64 % des arrets ne sont desservis que dans UN sens.
  Les deux trottoirs d'un meme lieu portent des racines SANS RAPPORT
  (ROGIER = 0539 / 0529 ; WITLOOF ligne 65 = 2991 / 2899). Les racines ne
  se rencontrent jamais d'un sens a l'autre : il n'y a rien a rapprocher.

  Le nom, lui, est partage. Qualite du rapprochement par nom (27/08) :
      82,86 %  un seul candidat a moins de 300 m  -> direct
       9,15 %  homonymes                          -> departages par distance
       7,79 %  aucun homologue                    -> interpoles
       0,20 %  nom unique mais eloigne (4 arrets) -> interpoles

  ⚠️ LIMITE ASSUMEE. Sur une ligne en Y, un rang lineaire ne peut pas
     representer un arbre : les deux branches se superposeront sur un axe.
     est_hors_epine permet de les ecarter d'un visuel spatial.
     NE PAS presenter d'analyse spatiale par arret sur 87, 4, 1, 51, 93.

  Entrees : stg_trips, stg_routes, stg_stop_times, stg_stops
  Sortie  : dbo.dim_desserte
  Idempotent.
=============================================================================*/

USE TFE_STIB;
GO

SET NOCOUNT ON;

DECLARE @ligne VARCHAR(10) = NULL;   -- NULL = tout le reseau

DROP TABLE IF EXISTS #epine;
DROP TABLE IF EXISTS #seq;
DROP TABLE IF EXISTS #hors_epine;
DROP TABLE IF EXISTS #desserte;
DROP TABLE IF EXISTS #corridor;


/*=============================================================================
  1. L'EPINE - la course de reference de chaque sens
  ----------------------------------------------------------------------------
  Logique inchangee : la plus longue, puis la plus frequente, puis trip_id
  pour le determinisme. Seul ordre_geo change de mode de calcul.

  ⚠️ ORDRE DES CTE : un CTE ne voit que ceux declares AVANT lui.
=============================================================================*/

;WITH courses AS (
    SELECT  r.route_short_name AS line_id,
            t.feed_version,
            t.trip_id,
            t.direction_id,
            COUNT(*) AS nb_arrets,
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
    GROUP BY    r.route_short_name, t.feed_version, t.trip_id, t.direction_id
),
freq_signature AS (
    SELECT  line_id, direction_id, feed_version, signature,
            MAX(nb_arrets) AS nb_arrets,
            MIN(trip_id)   AS trip_id,
            COUNT(*)       AS nb_courses
    FROM    courses
    GROUP BY line_id, direction_id, feed_version, signature
),
feed_recent AS (
    SELECT  line_id, direction_id, MAX(feed_version) AS feed_version
    FROM    courses
    GROUP BY line_id, direction_id
),
reference AS (
    SELECT  f.line_id, f.direction_id, f.feed_version, f.trip_id, f.nb_arrets,
            ROW_NUMBER() OVER (PARTITION BY f.line_id, f.direction_id
                               ORDER BY     f.nb_arrets  DESC,
                                            f.nb_courses DESC,
                                            f.trip_id    ASC) AS rang
    FROM        freq_signature AS f
    INNER JOIN  feed_recent    AS fr ON  fr.line_id      = f.line_id
                                     AND fr.direction_id = f.direction_id
                                     AND fr.feed_version = f.feed_version
)
SELECT      ref.line_id,
            ref.direction_id,
            ref.feed_version,
            ref.trip_id,
            st.stop_id_racine,
            -- ORDRE_GEO x 10 : laisse 9 positions libres entre deux arrets
            -- d'epine pour les arrets intercales, sans renumeroter.
            ordre_geo = CAST(ROW_NUMBER() OVER (
                             PARTITION BY ref.line_id, ref.direction_id
                             ORDER BY     st.stop_sequence) * 10 AS INT),
            s.stop_name,
            lat = TRY_CAST(NULLIF(LTRIM(RTRIM(s.stop_lat)), '') AS FLOAT),
            lon = TRY_CAST(NULLIF(LTRIM(RTRIM(s.stop_lon)), '') AS FLOAT)
INTO        #epine
FROM        reference      AS ref
INNER JOIN  stg_stop_times AS st ON  st.trip_id      = ref.trip_id
                                 AND st.feed_version = ref.feed_version
LEFT  JOIN  stg_stops      AS s  ON  s.stop_id       = st.stop_id
                                 AND s.feed_version  = st.feed_version
WHERE       ref.rang = 1;

CREATE CLUSTERED INDEX ix_ep ON #epine (line_id, direction_id, stop_id_racine);


/*=============================================================================
  2. LA SEQUENCE COMPLETE - toutes les courses, arret par arret
  ----------------------------------------------------------------------------
  C'est le support du nouveau rattachement. Chaque arret de chaque course
  porte le rang d'epine s'il en a un, NULL sinon.
=============================================================================*/

SELECT      line_id = r.route_short_name COLLATE DATABASE_DEFAULT,
            t.direction_id,
            st.feed_version,
            st.trip_id,
            st.stop_sequence,
            racine    = st.stop_id_racine COLLATE DATABASE_DEFAULT,
            e.ordre_geo
INTO        #seq
FROM        stg_trips      AS t
INNER JOIN  stg_routes     AS r  ON  r.route_id      = t.route_id
                                 AND r.feed_version  = t.feed_version
INNER JOIN  stg_stop_times AS st ON  st.trip_id      = t.trip_id
                                 AND st.feed_version = t.feed_version
LEFT  JOIN  #epine         AS e  ON  e.line_id        = r.route_short_name COLLATE DATABASE_DEFAULT
                                 AND e.direction_id   = t.direction_id
                                 AND e.stop_id_racine = st.stop_id_racine COLLATE DATABASE_DEFAULT
WHERE      (@ligne IS NULL OR r.route_short_name = @ligne)
    AND       EXISTS (SELECT 1 FROM dbo.ref_tolerance_ligne AS tol
                    WHERE tol.line_id = r.route_short_name COLLATE DATABASE_DEFAULT
                      AND tol.est_dans_perimetre = 1)

CREATE CLUSTERED INDEX ix_sq ON #seq (feed_version, trip_id, stop_sequence);


/*=============================================================================
  3. LE RATTACHEMENT PAR LA SEQUENCE
  ----------------------------------------------------------------------------
  Pour un arret hors epine :
    - on remonte dans SA PROPRE COURSE jusqu'au dernier arret d'epine
      (fonction fenetre ROWS UNBOUNDED PRECEDING) ;
    - on lui donne ce rang + son numero d'ordre dans le trou.

  Un arret intercale apres le rang 120 recoit 121, puis 122, etc.

  CAS LIMITE : un arret hors epine AVANT tout arret d'epine. On prend
  alors le PROCHAIN rang d'epine moins 10, ce qui le place devant.

  AGREGATION : un meme arret peut apparaitre dans plusieurs courses a des
  positions differentes. On retient le MIN, deterministe et reproductible.
=============================================================================*/

;WITH borne AS (
    SELECT  s.*,
            rang_avant = MAX(s.ordre_geo) OVER (
                             PARTITION BY s.feed_version, s.trip_id
                             ORDER BY     s.stop_sequence
                             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),
            rang_apres = MIN(s.ordre_geo) OVER (
                             PARTITION BY s.feed_version, s.trip_id
                             ORDER BY     s.stop_sequence
                             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)
    FROM    #seq AS s
),
trous AS (
    SELECT  b.line_id, b.direction_id, b.racine,
            ancre = COALESCE(b.rang_avant, b.rang_apres - 10),
            rn    = ROW_NUMBER() OVER (
                        PARTITION BY b.feed_version, b.trip_id,
                                     COALESCE(b.rang_avant, b.rang_apres - 10)
                        ORDER BY     b.stop_sequence)
    FROM    borne AS b
    WHERE   b.ordre_geo IS NULL          -- hors epine uniquement
      AND   COALESCE(b.rang_avant, b.rang_apres - 10) IS NOT NULL
)
SELECT      line_id, direction_id, racine AS stop_id_racine,
            ordre_geo = MIN(ancre + rn)
INTO        #hors_epine
FROM        trous
GROUP BY    line_id, direction_id, racine;

CREATE CLUSTERED INDEX ix_he ON #hors_epine (line_id, direction_id, stop_id_racine);

/*----------------------------------------------------------------------------
  3bis. LES BRANCHES DISJOINTES
  ----------------------------------------------------------------------------
  Mesure du 27/08 : 12 424 courses des lignes 4, 51 et 87 ne touchent
  AUCUN arret de l'epine de leur sens (epine_moyenne = 0 sur 7 groupes).
  Leurs arrets n'avaient donc aucune ancre et etaient ecartes en silence
  par la section 3 — puis dim_course les classait "parcours incomplet"
  sans qu'aucune comparaison n'ait eu lieu.

  Traitement : on les range APRES le maximum de l'epine, dans l'ordre de
  leur propre sequence. Le rang est valide et stable ; est_hors_epine = 1
  permet de les ecarter d'un visuel spatial, ou l'axe n'a pas de sens.
----------------------------------------------------------------------------*/

;WITH restants AS (
    SELECT  s.line_id, s.direction_id, s.racine, s.trip_id, s.feed_version,
            s.stop_sequence
    FROM    #seq AS s
    LEFT JOIN #epine AS e
           ON e.line_id        = s.line_id
          AND e.direction_id   = s.direction_id
          AND e.stop_id_racine = s.racine
    LEFT JOIN #hors_epine AS h
           ON h.line_id        = s.line_id
          AND h.direction_id   = s.direction_id
          AND h.stop_id_racine = s.racine
    WHERE   e.stop_id_racine IS NULL
      AND   h.stop_id_racine IS NULL
),
course_ref AS (
    -- La course la plus longue parmi les restants : elle sert d'epine
    -- de branche. Meme logique que la section 1, a un niveau inferieur.
    SELECT  line_id, direction_id, feed_version, trip_id,
            rang = ROW_NUMBER() OVER (PARTITION BY line_id, direction_id
                                      ORDER BY COUNT(*) DESC,
                                               feed_version DESC, trip_id)
    FROM    restants
    GROUP BY line_id, direction_id, feed_version, trip_id
),
base AS (
    SELECT  r.line_id, r.direction_id, r.racine,
            ordre = ROW_NUMBER() OVER (PARTITION BY r.line_id, r.direction_id
                                       ORDER BY r.stop_sequence)
    FROM    restants  AS r
    JOIN    course_ref AS c ON  c.line_id      = r.line_id
                            AND c.direction_id = r.direction_id
                            AND c.trip_id      = r.trip_id
                            AND c.feed_version = r.feed_version
                            AND c.rang = 1
),
plafond AS (
    SELECT line_id, direction_id, ordre_max = MAX(ordre_geo)
    FROM   #epine GROUP BY line_id, direction_id
)
INSERT INTO #hors_epine (line_id, direction_id, stop_id_racine, ordre_geo)
SELECT  b.line_id, b.direction_id, b.racine,
        p.ordre_max + b.ordre * 10
FROM    base    AS b
JOIN    plafond AS p ON  p.line_id      = b.line_id
                     AND p.direction_id = b.direction_id;


/*=============================================================================
  4. ASSEMBLAGE + est_quai_terminus
  ----------------------------------------------------------------------------
  est_quai_terminus : un arret hors epine dont le plus proche arret
  d'epine du meme sens est a MOINS DE 50 M. C'est le meme lieu physique,
  autre trottoir. Au-dela, c'est une variante ou une branche.

  Le facteur 0,63 corrige l'anisotropie lat/lon a 50,85 deg de latitude.
  Il ne sert PLUS a rattacher (point 1), seulement a QUALIFIER.
=============================================================================*/

SELECT      d.line_id, d.direction_id, d.stop_id_racine, d.ordre_geo,
            d.est_hors_epine,
            s.stop_name,
            lat = TRY_CAST(NULLIF(LTRIM(RTRIM(s.stop_lat)), '') AS FLOAT),
            lon = TRY_CAST(NULLIF(LTRIM(RTRIM(s.stop_lon)), '') AS FLOAT)
INTO        #desserte
FROM (
    SELECT line_id, direction_id, stop_id_racine, ordre_geo,
           est_hors_epine = CAST(0 AS BIT)
    FROM   #epine
    UNION ALL
    SELECT line_id, direction_id, stop_id_racine, ordre_geo,
           CAST(1 AS BIT)
    FROM   #hors_epine
) AS d
OUTER APPLY (
    SELECT TOP 1 st.stop_id, st.feed_version
    FROM   stg_stop_times AS st
    WHERE  st.stop_id_racine COLLATE DATABASE_DEFAULT = d.stop_id_racine
    ORDER BY st.feed_version DESC, st.stop_id
) AS pick
LEFT JOIN   stg_stops AS s ON s.stop_id      = pick.stop_id
                          AND s.feed_version = pick.feed_version;

ALTER TABLE #desserte ADD est_quai_terminus BIT NULL;
ALTER TABLE #desserte ADD ordre_corridor    INT NULL;

UPDATE  d
SET     est_quai_terminus =
            CASE WHEN d.est_hors_epine = 1 AND v.dist_m < 50 THEN 1 ELSE 0 END
FROM    #desserte AS d
OUTER APPLY (
    SELECT TOP 1
        dist_m = SQRT(POWER(e.lat - d.lat, 2)
                    + POWER((e.lon - d.lon) * 0.63, 2)) * 111320
    FROM   #epine AS e
    WHERE  e.line_id      = d.line_id
      AND  e.direction_id = d.direction_id
      AND  e.lat IS NOT NULL
    ORDER BY SQRT(POWER(e.lat - d.lat, 2) + POWER((e.lon - d.lon) * 0.63, 2))
) AS v;


/*=============================================================================
  5. ORDRE_CORRIDOR
  ----------------------------------------------------------------------------
  Etape 1 : le sens 0 donne les positions de reference.
  Etape 2 : chaque arret du sens 1 est rapproche par NOM, departage par
            DISTANCE (les 9,15 % d'homonymes), et herite de la position.
  Etape 3 : les arrets sans homologue (7,79 %) sont intercales entre leurs
            voisins DANS LEUR PROPRE SENS.
  Etape 4 : DENSE_RANK sur la position -> deux racines au meme lieu
            recoivent le MEME rang. C'est ce qui retablit la dependance
            fonctionnelle exigee par Power BI.
=============================================================================*/

;/*=============================================================================
  5. ORDRE_CORRIDOR
=============================================================================*/

;WITH ref0 AS (
    SELECT line_id, stop_name, lat, lon, position = ordre_geo
    FROM   #desserte
    WHERE  direction_id = '0'
),
apparie AS (
    SELECT  d.line_id, d.direction_id, d.stop_id_racine, d.ordre_geo,
            position = CASE WHEN d.direction_id = '0' THEN d.ordre_geo
                            ELSE m.position END
    FROM    #desserte AS d
    OUTER APPLY (
        SELECT TOP 1 r.position
        FROM   ref0 AS r
        WHERE  d.direction_id = '1'
          AND  r.line_id   = d.line_id
          AND  r.stop_name = d.stop_name
          AND  SQRT(POWER(r.lat - d.lat, 2)
                  + POWER((r.lon - d.lon) * 0.63, 2)) * 111320 < 300
        ORDER BY SQRT(POWER(r.lat - d.lat, 2) + POWER((r.lon - d.lon) * 0.63, 2))
    ) AS m
),
bornes AS (
    -- Les positions connues de part et d'autre, dans la sequence du sens.
    SELECT  a.*,
            avant = MAX(a.position) OVER (PARTITION BY a.line_id, a.direction_id
                                          ORDER BY a.ordre_geo
                                          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),
            apres = MIN(a.position) OVER (PARTITION BY a.line_id, a.direction_id
                                          ORDER BY a.ordre_geo
                                          ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)
    FROM    apparie AS a
),
comble AS (
    -- ⚠️ Le decalage 0,001 ne s'applique QU'AUX arrets interpoles.
    --    L'appliquer aussi aux apparies donnerait deux positions
    --    differentes au meme lieu, et le DENSE_RANK les separerait.
    SELECT  b.line_id, b.direction_id, b.stop_id_racine,
            position_finale = CASE
                WHEN b.position IS NOT NULL THEN CAST(b.position AS DECIMAL(12,4))
                ELSE CAST(
                       (COALESCE(b.avant, b.apres - 10)
                      + COALESCE(b.apres, b.avant + 10)) / 2.0
                     + 0.001 * ROW_NUMBER() OVER (
                           PARTITION BY b.line_id, b.direction_id,
                                        COALESCE(b.avant, -1)
                           ORDER BY b.ordre_geo)
                     AS DECIMAL(12,4))
            END
    FROM    bornes AS b
)
UPDATE  d
SET     ordre_corridor = c.rang
FROM    #desserte AS d
JOIN (
    SELECT  line_id, direction_id, stop_id_racine,
            rang = DENSE_RANK() OVER (PARTITION BY line_id
                                      ORDER BY position_finale)
    FROM    comble
) AS c ON  c.line_id        = d.line_id
       AND c.direction_id   = d.direction_id
       AND c.stop_id_racine = d.stop_id_racine;


/*=============================================================================
  6. LIBELLE D'AFFICHAGE
  ----------------------------------------------------------------------------
  Numerote par ORDRE_CORRIDOR et non par sens : deux racines au meme lieu
  doivent porter le MEME libelle, sinon la dependance fonctionnelle
  libelle_affichage -> ordre_corridor est violee et le tri Power BI casse.

  Les quais de terminus reprennent le nom nu de leur jumeau : c'est le
  meme lieu physique, pas un homonyme.
=============================================================================*/

DROP TABLE IF EXISTS dim_desserte;

;WITH lieux AS (
    -- Un lieu = un couple (ligne, ordre_corridor). Le GROUP BY garantit
    -- deja l'unicite : COUNT(*) compte donc bien des positions
    -- DISTINCTES, sans avoir besoin du mot-cle (interdit avec OVER).
    SELECT  line_id, stop_name, ordre_corridor,
            occurrence   = ROW_NUMBER() OVER (PARTITION BY line_id, stop_name
                                              ORDER BY ordre_corridor),
            nb_homonymes = COUNT(*) OVER (PARTITION BY line_id, stop_name)
    FROM    #desserte
    GROUP BY line_id, stop_name, ordre_corridor
)
SELECT  desserte_sk = ROW_NUMBER() OVER (
                          ORDER BY d.line_id, d.direction_id,
                                   d.ordre_geo, d.stop_id_racine),
        d.line_id,
        d.direction_id,
        d.stop_id_racine,
        d.ordre_geo,
        d.ordre_corridor,
        d.stop_name,
        libelle_affichage = CASE
            WHEN l.nb_homonymes > 1
            THEN d.stop_name + ' (' + CAST(l.occurrence AS VARCHAR(2)) + ')'
            ELSE d.stop_name END,
        d.est_hors_epine,
        d.est_quai_terminus
INTO    dim_desserte
FROM    #desserte AS d
LEFT JOIN lieux AS l ON  l.line_id        = d.line_id
                     AND l.stop_name      = d.stop_name
                     AND l.ordre_corridor = d.ordre_corridor;

-- SELECT INTO cree les colonnes d'expression en NULL et ne transporte ni
-- contrainte ni index (piege n°57 : la nullabilite se propage aussi).
ALTER TABLE dim_desserte ALTER COLUMN desserte_sk     BIGINT      NOT NULL;
ALTER TABLE dim_desserte ALTER COLUMN line_id         VARCHAR(50) NOT NULL;
ALTER TABLE dim_desserte ALTER COLUMN direction_id    VARCHAR(50) NOT NULL;
ALTER TABLE dim_desserte ALTER COLUMN stop_id_racine  VARCHAR(50) NOT NULL;
GO
-- ⚠️ GO obligatoire : SQL Server compile le batch entier avant execution.
--    Sans coupure, la PRIMARY KEY est validee contre la colonne AVANT
--    modification. (@ligne meurt ici ; les #temp survivent a la session.)

ALTER TABLE dim_desserte ADD CONSTRAINT pk_dim_desserte PRIMARY KEY (desserte_sk);
CREATE UNIQUE INDEX ux_dim_desserte
    ON dim_desserte (line_id, direction_id, stop_id_racine);
GO

-- ---------- Membre inconnu ----------
INSERT INTO dim_desserte
    (desserte_sk, line_id, direction_id, stop_id_racine, ordre_geo,
     ordre_corridor, stop_name, libelle_affichage, est_hors_epine,
     est_quai_terminus)
VALUES
    (-1, '?', '?', '?', 0, 0, 'Non résolu', 'Non résolu', 0, 0);
GO

-- ---------- Surcharges manuelles ----------
-- Figees ici, JAMAIS tapees a la main dans SSMS (incident du 24/08).
-- ⚠️ A REVERIFIER : la numerotation des homonymes porte desormais sur
--    ordre_corridor et non sur le sens. MEISER peut deja etre correct.
UPDATE  dim_desserte
SET     libelle_affichage = 'MEISER REYERS'
WHERE   line_id = '25' AND direction_id = '1' AND stop_id_racine = '2246';
GO


/*=============================================================================
  CONTROLES
=============================================================================*/

PRINT '=== G1 - Volumetrie ===';
SELECT  lignes = COUNT(DISTINCT line_id),
        dessertes = COUNT(*),
        hors_epine = SUM(CAST(est_hors_epine AS INT)),
        quais_terminus = SUM(CAST(est_quai_terminus AS INT))
FROM    dim_desserte WHERE desserte_sk > 0;
GO


PRINT '=== G2 - DEPENDANCE FONCTIONNELLE (le controle decisif) ===';
-- Doit renvoyer 0 ligne. Un libelle qui porterait deux ordre_corridor
-- casserait le tri Power BI - c'est le probleme que ce script resout.
SELECT  line_id, libelle_affichage,
        nb_rangs = COUNT(DISTINCT ordre_corridor)
FROM    dim_desserte WHERE desserte_sk > 0
GROUP BY line_id, libelle_affichage
HAVING  COUNT(DISTINCT ordre_corridor) > 1
ORDER BY nb_rangs DESC;
GO


PRINT '=== G3 - Aucun ordre_corridor manquant ===';
SELECT  line_id, direction_id, stop_id_racine, stop_name, ordre_geo
FROM    dim_desserte
WHERE   desserte_sk > 0 AND ordre_corridor IS NULL;
GO


PRINT '=== G4 - Non-regression ligne 25 ===';
-- Attendu : 28 dessertes sens 0, 27 sens 1, 3 hors epine tous a moins
-- de 50 m donc est_quai_terminus = 1.
SELECT  direction_id, dessertes = COUNT(*),
        hors_epine = SUM(CAST(est_hors_epine AS INT)),
        quais = SUM(CAST(est_quai_terminus AS INT)),
        ordre_geo_min = MIN(ordre_geo), ordre_geo_max = MAX(ordre_geo),
        corridor_max = MAX(ordre_corridor)
FROM    dim_desserte WHERE line_id = '25'
GROUP BY direction_id;
GO


PRINT '=== G5 - Le corridor de la ligne 25, les deux sens cote a cote ===';
-- Lecture visuelle : les deux racines d un meme lieu doivent porter le
-- MEME ordre_corridor et le MEME libelle.
SELECT  ordre_corridor, libelle_affichage,
        sens_0 = MAX(CASE WHEN direction_id = '0' THEN stop_id_racine END),
        sens_1 = MAX(CASE WHEN direction_id = '1' THEN stop_id_racine END)
FROM    dim_desserte WHERE line_id = '25'
GROUP BY ordre_corridor, libelle_affichage
ORDER BY ordre_corridor;
GO


PRINT '=== G6 - Lignes a branches : ampleur du hors-epine ===';
-- 87, 4, 1, 51, 93 doivent ressortir. Ces lignes sont a EXCLURE de
-- toute analyse spatiale par arret.
SELECT  line_id,
        dessertes = COUNT(*),
        hors_epine = SUM(CAST(est_hors_epine AS INT)),
        pct = CAST(100.0 * SUM(CAST(est_hors_epine AS INT))
                   / COUNT(*) AS DECIMAL(5,2))
FROM    dim_desserte WHERE desserte_sk > 0
GROUP BY line_id
HAVING  SUM(CAST(est_hors_epine AS INT)) >= 5
ORDER BY hors_epine DESC;
GO
