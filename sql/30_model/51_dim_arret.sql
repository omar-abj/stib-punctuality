/*=============================================================================
  TFE STIB - 30_model/51_dim_arret.sql
  ----------------------------------------------------------------------------
  OBJET : dimension des points d'arret.
  Grain : 1 ligne = 1 point_id (referentiel du flux temps reel).
  Role  : identite d'un point d'arret, INDEPENDANTE de toute ligne.
          L'ordre d'un arret le long d'une ligne n'est pas ici : il depend
          du triplet (ligne, sens, arret) et vit dans dim_desserte (52).

  POURQUOI UNE VUE PUIS UNE TABLE
  ----------------------------------------------------------------------------
  La vue v_dim_arret porte la LOGIQUE (lisible, versionnee). La table
  dim_arret porte la CLE DE SUBSTITUTION arret_sk. Une cle de substitution
  doit etre STABLE : dans une vue, ROW_NUMBER() est recalcule a chaque
  interrogation, arret_sk = 47 pourrait valoir 48 demain, et fact_ecart,
  materialisee, pointerait vers le mauvais arret SANS erreur SQL.

  CHOIX DU stop_id DE REFERENCE
  ----------------------------------------------------------------------------
  Un point_id peut correspondre a plusieurs stop_id (suffixes de quai) et
  a plusieurs feeds GTFS. On retient le feed le plus recent, puis le
  stop_id le plus petit. ORDER BY complet = determinisme (piege n°26 :
  TOP 1 ou ROW_NUMBER sans ORDER BY total).

  PAS DE MEMBRE INCONNU (-1)
  ----------------------------------------------------------------------------
  Contrairement a dim_desserte, dim_course et dim_meteo, dim_arret n'a
  pas de membre inconnu : elle compte exactement autant de lignes que
  map_arret (2 292). 60_fact_ecart.sql ecrit COALESCE(arret_sk, -1) et
  pose une cle etrangere vers dim_arret : si un point_id n'etait pas
  retrouve, le script 60 ECHOUERAIT sur la contrainte. C'est voulu : un
  arret inconnu doit arreter la chaine, pas passer inapercu.

  ORDRE DE REJEU
  ----------------------------------------------------------------------------
  fact_ecart porte une cle etrangere vers dim_arret : DROP TABLE dim_arret
  echoue tant que fact_ecart existe. Supprimer fact_ecart d'abord, puis
  rejouer 51 -> 60 -> 61... -> 67.
  67_dim_arret_correspondances.sql ajoute ensuite trois colonnes a
  dim_arret : il doit etre rejoue apres ce script.

  DEPENDANCES : map_arret, stg_stops
  IDEMPOTENT  : DROP ... IF EXISTS puis recreation.
  ORIGINE     : session de construction des dimensions (25/08/2026),
                extrait en fichier le 25/09/2026.
=============================================================================*/

USE TFE_STIB;
GO

DROP VIEW IF EXISTS dbo.v_dim_arret;
GO

CREATE VIEW dbo.v_dim_arret AS
WITH gtfs_par_point AS (
    SELECT  m.point_id,
            s.stop_id,
            s.stop_name,
            -- NULLIF(..., '') : CAST('' AS DECIMAL) renvoie 0, pas NULL
            -- (piege n°7). Un arret sans coordonnees se placerait sinon
            -- au large du golfe de Guinee sur la carte.
            TRY_CAST(NULLIF(LTRIM(RTRIM(s.stop_lat)), '') AS DECIMAL(9,6)) AS stop_lat,
            TRY_CAST(NULLIF(LTRIM(RTRIM(s.stop_lon)), '') AS DECIMAL(9,6)) AS stop_lon,
            s.feed_version,
            ROW_NUMBER() OVER (PARTITION BY m.point_id
                               ORDER BY     s.feed_version DESC,
                                            s.stop_id      ASC) AS rang
    FROM        dbo.map_arret AS m
    INNER JOIN  dbo.stg_stops AS s ON s.stop_id = m.stop_id
    WHERE       s.location_type = '0'      -- points d'embarquement uniquement
)
SELECT  point_id,
        stop_id      AS stop_id_ref,
        stop_name,
        stop_lat,
        stop_lon,
        feed_version AS feed_version_ref
FROM    gtfs_par_point
WHERE   rang = 1;
GO

-- ---------- Materialisation ----------
DROP TABLE IF EXISTS dbo.dim_arret;

SELECT  ROW_NUMBER() OVER (ORDER BY point_id) AS arret_sk,
        v.*
INTO    dbo.dim_arret
FROM    dbo.v_dim_arret AS v;

-- SELECT INTO cree les colonnes issues d'expressions en NULL : il faut les
-- forcer NOT NULL avant toute PRIMARY KEY (Msg 8111).
ALTER TABLE dbo.dim_arret ALTER COLUMN arret_sk BIGINT      NOT NULL;
ALTER TABLE dbo.dim_arret ALTER COLUMN point_id VARCHAR(50) NOT NULL;
GO
-- GO obligatoire : le batch est compile avant d'etre execute, la PRIMARY
-- KEY serait validee contre les colonnes AVANT modification (piege n°43).

ALTER TABLE dbo.dim_arret ADD CONSTRAINT pk_dim_arret PRIMARY KEY (arret_sk);
CREATE UNIQUE INDEX ux_dim_arret_point ON dbo.dim_arret (point_id);
GO


/*=============================================================================
  CONTROLES
=============================================================================*/

PRINT '=== A1 - Volume : autant de lignes que map_arret ===';
-- Attendu : n_dim_arret = n_map_arret = 2 292.
-- Un ecart signale un point_id dont le stop_id n'existe dans aucun feed,
-- ou n'est pas un point d'embarquement (location_type <> 0).
SELECT  (SELECT COUNT(*) FROM dbo.dim_arret) AS n_dim_arret,
        (SELECT COUNT(*) FROM dbo.map_arret) AS n_map_arret;

PRINT '=== A2 - Coordonnees ===';
-- Attendu : 0 coordonnee nulle, 0 coordonnee a 0,
-- latitudes et longitudes dans l'emprise de Bruxelles (~50,7-50,95 / 4,2-4,5).
SELECT  COUNT(*)                                                      AS n_lignes,
        SUM(CASE WHEN stop_lat IS NULL OR stop_lon IS NULL THEN 1 ELSE 0 END) AS coord_nulles,
        SUM(CASE WHEN stop_lat = 0 OR stop_lon = 0 THEN 1 ELSE 0 END)  AS coord_zero,
        MIN(stop_lat) AS lat_min, MAX(stop_lat) AS lat_max,
        MIN(stop_lon) AS lon_min, MAX(stop_lon) AS lon_max
FROM    dbo.dim_arret;
GO
