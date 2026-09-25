/*=============================================================================
  TFE STIB - 20_transform/20_wrk_observations.sql
  ----------------------------------------------------------------------------
  OBJET : nettoyer et typer le flux temps reel brut.

  Grain : 1 ligne = 1 prediction publiee par l'API
          (1 arret x 1 ligne x 1 destination x 1 cycle de collecte).
          Un meme cycle publie plusieurs predictions pour un meme
          triplet : le prochain vehicule, celui d'apres, etc.
          Le tri de ce lot est fait par 21_wrk_prochain.sql.

  POURQUOI CETTE COUCHE
  ----------------------------------------------------------------------------
  staging_waiting_times est charge en VARCHAR integral : aucune ligne
  n'est rejetee a l'import, la conversion est reportee ici. Deux filtres
  seulement, tous deux justifies :

  1. TRY_CONVERT sur expected_arrival. Une prediction non convertible
     n'est pas une observation : elle ne peut pas etre comparee a un
     horaire. Le controle B2 chiffre la perte.
  2. JOIN sur map_arret. Un point_id sans equivalent GTFS ne pourra
     jamais s'apparier, faute d'identifiant commun. Perte mesuree au
     27/08 : 0,574 % du volume.

  ATTENTION - LES TYPES SONT CEUX D'ORIGINE, VOLONTAIREMENT.
  point_id VARCHAR(10), line_id VARCHAR(5), destination VARCHAR(100).
  Ils ne suivent pas la convention VARCHAR(50) du staging GTFS. Les
  changer maintenant deplacerait les comparaisons de chaines en aval
  et invaliderait le test de non-regression. A harmoniser plus tard,
  si besoin, comme un changement a part entiere.

  ENTREES : dbo.staging_waiting_times, dbo.map_arret
  SORTIE  : dbo.wrk_observations
  IDEMPOTENT : table reconstruite integralement.

  VOLUME ATTENDU : ~31 M de lignes sur 52 jours de collecte
                   (28 175 316 mesures sur 44 jours).
  DUREE ATTENDUE : quelques minutes. C'est l'etape la plus lourde
                   de toute la chaine.
=============================================================================*/

USE TFE_STIB;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DROP TABLE IF EXISTS dbo.wrk_observations;

CREATE TABLE dbo.wrk_observations (
    point_id      VARCHAR(10)  NOT NULL,
    line_id       VARCHAR(5)   NOT NULL,
    destination   VARCHAR(100) NULL,
    collected_at  DATETIME2    NOT NULL,
    expected_at   DATETIME2    NOT NULL
);
-- CREATE explicite et non SELECT INTO : SELECT INTO herite de la
-- nullabilite de la source, or tout le staging est nullable.

INSERT INTO dbo.wrk_observations
       (point_id, line_id, destination, collected_at, expected_at)
SELECT  LTRIM(RTRIM(w.point_id)),
        w.line_id,
        w.destination,
        w.collected_at,
        TRY_CONVERT(DATETIME2, w.expected_arrival)
FROM        dbo.staging_waiting_times AS w
INNER JOIN  dbo.map_arret             AS m
        ON  m.point_id = LTRIM(RTRIM(w.point_id))
WHERE   TRY_CONVERT(DATETIME2, w.expected_arrival) IS NOT NULL;

CREATE CLUSTERED INDEX ix_wrk_obs
    ON dbo.wrk_observations (point_id, line_id, destination, collected_at);
GO


/*=============================================================================
  CONTROLES
=============================================================================*/

PRINT '=== B1 - Volumetrie et couverture temporelle ===';
-- Attendu : ~31 M de lignes, 52 jours, du 2026-07-01 au 2026-08-26.
SELECT  observations = COUNT(*),
        jours        = COUNT(DISTINCT CAST(collected_at AS DATE)),
        du           = MIN(CAST(collected_at AS DATE)),
        au           = MAX(CAST(collected_at AS DATE))
FROM    dbo.wrk_observations;
GO


PRINT '=== B2 - Ce que les deux filtres ont ecarte ===';
-- Un taux de perte qui s'ecarte nettement de la mesure du 27/08
-- (~7 % au total, dont 0,574 % faute de point_id) signale un
-- changement de format de l'API ou une map_arret devenue obsolete.
SELECT  brut               = (SELECT COUNT(*) FROM dbo.staging_waiting_times),
        retenu             = (SELECT COUNT(*) FROM dbo.wrk_observations),
        non_convertibles   = (SELECT COUNT(*) FROM dbo.staging_waiting_times
                              WHERE expected_arrival IS NOT NULL
                                AND TRY_CONVERT(DATETIME2, expected_arrival) IS NULL),
        sans_point_id      = (SELECT COUNT(*) FROM dbo.staging_waiting_times AS w
                              WHERE NOT EXISTS (SELECT 1 FROM dbo.map_arret AS m
                                                WHERE m.point_id = LTRIM(RTRIM(w.point_id))));
GO


PRINT '=== B3 - Predictions par cycle : le lot a trier ===';
-- Un cycle publie plusieurs predictions par triplet. Cette
-- distribution justifie l'existence de 21_wrk_prochain.sql.
SELECT  predictions_par_cycle = nb,
        cas                   = COUNT(*)
FROM   (SELECT point_id, line_id, destination, collected_at, nb = COUNT(*)
        FROM   dbo.wrk_observations
        GROUP BY point_id, line_id, destination, collected_at) AS t
GROUP BY nb
ORDER BY nb;
GO
