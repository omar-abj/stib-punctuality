/*=============================================================================
  TFE STIB - 00_ddl/04_stop_id_racine.sql
  ----------------------------------------------------------------------------
  OBJET : ajouter a stg_stop_times la RACINE NUMERIQUE du stop_id, calculee
          et persistee, avec son index.

  POURQUOI UNE RACINE
  ----------------------------------------------------------------------------
  Le GTFS distingue les quais d'un meme arret par un suffixe alphabetique
  (2351 et 2351F, 0470 et 0470F). Le flux temps reel, lui, publie un
  point_id sans suffixe. Joindre sur le stop_id complet ferait perdre les
  quais suffixes ; joindre sur la racine numerique les rattache tous a
  leur arret.
  Exemple mesure le 24/08 : 2351F BUYL est un doublon GTFS de 2351 (0,3 m
  d'ecart), absent de map_arret. La racine le resout mecaniquement.

  POURQUOI PERSISTED + INDEX
  ----------------------------------------------------------------------------
  stg_stop_times compte environ 5,7 M de lignes. Une racine recalculee a
  chaque jointure rendrait 40_int_passage_theorique et 52_dim_desserte
  tres lents. Persistee, elle est calculee une fois et indexable.

  POURQUOI LE CASE TRAITE D'ABORD "AUCUN CARACTERE NON NUMERIQUE"
  ----------------------------------------------------------------------------
  PATINDEX renvoie 0 quand le stop_id est purement numerique. Sans ce cas
  traite en premier, on calculerait LEFT(stop_id, -1), qui plante sur la
  majorite des identifiants.

  UTILISE PAR : 40_int_passage_theorique.sql, 52_dim_desserte.sql,
                60_fact_ecart.sql (via dim_desserte)
  IDEMPOTENT  : index et colonne supprimes puis recrees.
  ORIGINE     : session du 24/08/2026, extrait en fichier le 25/09/2026.
=============================================================================*/

USE TFE_STIB;
GO

-- L'index doit disparaitre AVANT la colonne : SQL Server refuse de
-- supprimer une colonne sur laquelle un index est construit.
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'ix_sst_racine'
             AND object_id = OBJECT_ID('dbo.stg_stop_times'))
    DROP INDEX ix_sst_racine ON dbo.stg_stop_times;
GO

IF COL_LENGTH('dbo.stg_stop_times', 'stop_id_racine') IS NOT NULL
    ALTER TABLE dbo.stg_stop_times DROP COLUMN stop_id_racine;
GO

ALTER TABLE dbo.stg_stop_times
ADD stop_id_racine AS
    LEFT(stop_id,
         CASE WHEN PATINDEX('%[^0-9]%', stop_id) = 0
              THEN LEN(stop_id)
              ELSE PATINDEX('%[^0-9]%', stop_id) - 1
         END)
    PERSISTED;
GO

CREATE INDEX ix_sst_racine
    ON dbo.stg_stop_times (feed_version, stop_id_racine)
    INCLUDE (trip_id, stop_id, stop_sequence, arrivee_sec);
GO


/*=============================================================================
  CONTROLES
=============================================================================*/

PRINT '=== R1 - La racine est-elle unique dans map_arret ? ===';
-- Attendu : 0 ligne.
-- Une racine partagee par deux point_id ferait DUPLIQUER les passages
-- dans toute jointure par racine (40_int_passage_theorique).
SELECT  racine,
        COUNT(*)                   AS nb_point_id,
        STRING_AGG(point_id, ', ') AS points
FROM (
    SELECT  point_id,
            LEFT(stop_id,
                 CASE WHEN PATINDEX('%[^0-9]%', stop_id) = 0
                      THEN LEN(stop_id)
                      ELSE PATINDEX('%[^0-9]%', stop_id) - 1 END) AS racine
    FROM    dbo.map_arret
) AS t
GROUP BY racine
HAVING   COUNT(*) > 1;
GO

PRINT '=== R2 - Aucune racine vide ===';
-- Attendu : 0. Un stop_id commencant par une lettre donnerait une racine
-- vide, qui ne se rattacherait a rien sans erreur.
SELECT  COUNT(*) AS nb_racines_vides
FROM    dbo.stg_stop_times
WHERE   stop_id_racine = '' OR stop_id_racine IS NULL;
GO
