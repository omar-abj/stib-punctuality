/*=============================================================================
  TFE STIB - 20_transform/21_wrk_prochain.sql
  ----------------------------------------------------------------------------
  OBJET : ne retenir, par cycle de collecte, que la prediction du
          PROCHAIN vehicule.

  Grain : 1 ligne = 1 arret x 1 ligne x 1 destination x 1 cycle.

  POURQUOI CETTE COUCHE - LA PLUS IMPORTANTE DE LA CHAINE
  ----------------------------------------------------------------------------
  A chaque cycle, l'API publie plusieurs predictions pour un meme
  triplet : le prochain vehicule, puis le suivant, parfois un
  troisieme. 22_wrk_passages.sql reconstitue les passages en suivant
  l'evolution d'une prediction d'un cycle a l'autre : tant que
  l'horaire annonce reste proche, c'est le meme vehicule.

  Si on lui donnait TOUTES les predictions, ce suivi serait faux :
  le LAG comparerait l'horaire du 2e vehicule d'un cycle a celui du
  1er vehicule du cycle suivant, et decouperait des passages la ou il
  n'y en a pas.

  ⚠️ C'est ici que se trouve le piege du fichier tfe_stib_min_delta.sql :
     il construisait wrk_passages DEUX fois, la premiere directement
     depuis wrk_observations (donc FAUX), la seconde depuis
     wrk_prochain (correcte). Seule la seconde est reprise ici.

  La prediction retenue est celle dont expected_at est le PLUS TOT :
  le prochain vehicule est, par definition, celui qui arrive en
  premier.

  ENTREE : dbo.wrk_observations
  SORTIE : dbo.wrk_prochain
  IDEMPOTENT : table reconstruite integralement.

  VOLUME ATTENDU : ~16 M de lignes sur 52 jours
                   (14 409 232 mesures sur 44 jours).
=============================================================================*/

USE TFE_STIB;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DROP TABLE IF EXISTS dbo.wrk_prochain;

SELECT  point_id, line_id, destination, collected_at, expected_at
INTO    dbo.wrk_prochain
FROM   (SELECT  o.*,
                rn = ROW_NUMBER() OVER (
                         PARTITION BY o.point_id, o.line_id,
                                      o.destination, o.collected_at
                         ORDER BY o.expected_at)
        FROM    dbo.wrk_observations AS o) AS t
WHERE   rn = 1
OPTION (RECOMPILE);

CREATE CLUSTERED INDEX ix_wrk_prochain
    ON dbo.wrk_prochain (point_id, line_id, destination, collected_at);
GO


/*=============================================================================
  CONTROLES
=============================================================================*/

PRINT '=== C1 - Volumetrie ===';
-- Attendu : ~16 M de lignes, 52 jours.
SELECT  prochains = COUNT(*),
        jours     = COUNT(DISTINCT CAST(collected_at AS DATE)),
        du        = MIN(CAST(collected_at AS DATE)),
        au        = MAX(CAST(collected_at AS DATE))
FROM    dbo.wrk_prochain;
GO


PRINT '=== C2 - Unicite du grain declare ===';
-- DOIT renvoyer 0 ligne. Un doublon signifierait que le ROW_NUMBER
-- n'a pas fait son travail, donc que le decoupage en passages sera
-- fausse en aval.
SELECT TOP 20 point_id, line_id, destination, collected_at, nb = COUNT(*)
FROM    dbo.wrk_prochain
GROUP BY point_id, line_id, destination, collected_at
HAVING  COUNT(*) > 1
ORDER BY nb DESC;
GO


PRINT '=== C3 - Taux de reduction ===';
-- Ordre de grandeur mesure au 27/08 : 14,4 M retenus sur 28,2 M,
-- soit ~51 %. Un taux tres different signale un changement du
-- nombre de predictions publiees par l'API.
SELECT  observations = (SELECT COUNT(*) FROM dbo.wrk_observations),
        prochains    = (SELECT COUNT(*) FROM dbo.wrk_prochain),
        pct_retenu   = CAST(100.0 * (SELECT COUNT(*) FROM dbo.wrk_prochain)
                            / NULLIF((SELECT COUNT(*) FROM dbo.wrk_observations), 0)
                            AS DECIMAL(5,2));
GO
