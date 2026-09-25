/*=============================================================================
  TFE STIB - 20_transform/22_wrk_passages.sql
  ----------------------------------------------------------------------------
  OBJET : reconstituer les PASSAGES reels a partir de la suite des
          predictions. Table pivot de tout le cote reel du projet.

  Grain : 1 ligne = 1 passage de vehicule a un arret.

  ⚠️ CE QU'EST arrivee_estimee, ET CE QU'ELLE N'EST PAS
  ----------------------------------------------------------------------------
  C'est la DERNIERE PREDICTION publiee avant que le vehicule ne
  disparaisse du flux. Ce n'est PAS une heure d'arrivee observee.
  L'API ne publie aucune arrivee constatee. Ce point doit etre dit
  tel quel devant le jury : le "reel" du memoire est une prediction
  a tres court terme, pas une mesure.
  La colonne fraicheur_sec de 45_int_appariement.sql chiffre l'ecart
  entre la derniere observation et l'horaire annonce : c'est la
  mesure de confiance de cette approximation.

  COMMENT UN PASSAGE EST DECOUPE
  ----------------------------------------------------------------------------
  On suit un triplet (arret, ligne, destination) cycle apres cycle.
  Tant que l'horaire annonce reste proche de celui du cycle
  precedent, c'est le meme vehicule qui approche. Quand l'horaire
  annonce BONDIT en avant de plus de @seuil_rupture_sec, le vehicule
  precedent a disparu : l'API annonce desormais le suivant. Ce saut
  marque donc la fin d'un passage et le debut du suivant.

  @seuil_rupture_sec = 240 s. Ce seuil separe deux vehicules
  successifs ; il n'a AUCUN rapport avec la tolerance d'appariement T
  de ref_tolerance_ligne, qui porte sur l'ecart theorique/reel. Deux
  parametres homonymes, deux roles differents.

  ENTREE : dbo.wrk_prochain   (et NON wrk_observations - voir 21)
  SORTIE : dbo.wrk_passages
  IDEMPOTENT : table reconstruite integralement.

  VOLUME ATTENDU : ~3,66 M de lignes sur 52 jours
                   (3 312 727 mesures sur 44 jours).
=============================================================================*/

USE TFE_STIB;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @seuil_rupture_sec INT = 240;

DROP TABLE IF EXISTS dbo.wrk_passages;

WITH obs AS (
    SELECT  p.*,
            prec = LAG(p.expected_at) OVER (
                       PARTITION BY p.point_id, p.line_id, p.destination
                       ORDER BY p.collected_at)
    FROM    dbo.wrk_prochain AS p
),
flag AS (
    -- debut = 1 : premiere observation du triplet, ou saut en avant
    -- de l'horaire annonce -> nouveau vehicule.
    SELECT  o.*,
            debut = CASE WHEN o.prec IS NULL
                           OR DATEDIFF(SECOND, o.prec, o.expected_at) > @seuil_rupture_sec
                         THEN 1 ELSE 0 END
    FROM    obs AS o
),
grp AS (
    -- La somme cumulee des ruptures numerote les passages.
    SELECT  f.*,
            passage_num = SUM(f.debut) OVER (
                              PARTITION BY f.point_id, f.line_id, f.destination
                              ORDER BY f.collected_at
                              ROWS UNBOUNDED PRECEDING)
    FROM    flag AS f
),
final AS (
    SELECT  g.*,
            rn          = ROW_NUMBER() OVER (
                              PARTITION BY g.point_id, g.line_id,
                                           g.destination, g.passage_num
                              ORDER BY g.collected_at DESC),
            nb_obs      = COUNT(*) OVER (
                              PARTITION BY g.point_id, g.line_id,
                                           g.destination, g.passage_num),
            premiere_obs = MIN(g.collected_at) OVER (
                              PARTITION BY g.point_id, g.line_id,
                                           g.destination, g.passage_num)
    FROM    grp AS g
)
SELECT  point_id,
        line_id,
        destination,
        passage_num,
        premiere_obs,
        derniere_obs    = collected_at,
        arrivee_estimee = expected_at,
        nb_obs
INTO    dbo.wrk_passages
FROM    final
WHERE   rn = 1            -- rn = 1 : la DERNIERE observation du passage
OPTION (RECOMPILE);

CREATE CLUSTERED INDEX ix_wrk_passages
    ON dbo.wrk_passages (point_id, line_id, arrivee_estimee);
GO


/*=============================================================================
  CONTROLES
=============================================================================*/

PRINT '=== D1 - Volumetrie et couverture ===';
-- Attendu : ~3,66 M de passages, 52 jours.
-- Reference 44 jours : 3 312 727.
SELECT  passages = COUNT(*),
        jours    = COUNT(DISTINCT CAST(derniere_obs AS DATE)),
        du       = MIN(CAST(derniere_obs AS DATE)),
        au       = MAX(CAST(derniere_obs AS DATE))
FROM    dbo.wrk_passages;
GO


PRINT '=== D2 - Fiabilite : distribution de nb_obs ===';
-- Reference du 27/08 (44 jours) :
--   nb_obs = 1  ->  3,4 %   |  2-3  -> 32,2 %
--   4-10       -> 63,8 %    |  11+  ->  0,6 %
-- Un passage vu une seule fois est une prediction fugace : il est
-- ecarte par le filtre nb_obs >= 2 de 45_int_appariement.sql (V0).
-- Une part de nb_obs = 1 nettement superieure a 3,4 % signalerait
-- un probleme de collecte, pas de service.
SELECT  classe = CASE WHEN nb_obs = 1 THEN '1'
                      WHEN nb_obs BETWEEN 2 AND 3  THEN '2-3'
                      WHEN nb_obs BETWEEN 4 AND 10 THEN '4-10'
                      ELSE '11+' END,
        passages = COUNT(*),
        pct      = CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2)),
        fraicheur_moy_sec = AVG(CAST(DATEDIFF(SECOND, derniere_obs, arrivee_estimee) AS FLOAT))
FROM    dbo.wrk_passages
GROUP BY CASE WHEN nb_obs = 1 THEN '1'
              WHEN nb_obs BETWEEN 2 AND 3  THEN '2-3'
              WHEN nb_obs BETWEEN 4 AND 10 THEN '4-10'
              ELSE '11+' END
ORDER BY classe;
GO


PRINT '=== D3 - Chaque jour de passage a-t-il un feed GTFS ? ===';
-- DOIT renvoyer 0 ligne. Un jour sans feed rendrait ses passages
-- inappariables : la jointure de 45 les ferait disparaitre en silence.
SELECT  jour = CAST(p.derniere_obs AS DATE), passages = COUNT(*)
FROM    dbo.wrk_passages AS p
WHERE   NOT EXISTS (SELECT 1 FROM dbo.ref_feed_periode AS f
                    WHERE CAST(p.derniere_obs AS DATE)
                          BETWEEN f.date_debut AND f.date_fin)
GROUP BY CAST(p.derniere_obs AS DATE)
ORDER BY jour;
GO


PRINT '=== D4 - Non-regression sur le perimetre 44 jours ===';
-- DOIT valoir exactement 3 312 727. C'est le controle qui prouve que
-- la reconstruction sur cette machine reproduit celle du 19/08.
-- Un ecart ici invalide tout ce qui suit : ne pas poursuivre.
SELECT  passages_44_jours = COUNT(*)
FROM    dbo.wrk_passages
WHERE   CAST(derniere_obs AS DATE) <= '2026-08-18';
GO
