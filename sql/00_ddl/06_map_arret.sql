/*=============================================================================
  TFE STIB - 00_ddl/06_map_arret.sql
  ----------------------------------------------------------------------------
  OBJET : relier chaque point d'arret du flux temps reel (point_id) a un
          arret du GTFS statique (stop_id).
  Grain : 1 ligne = 1 point_id observe dans l'API.

  POURQUOI CETTE TABLE EXISTE
  ----------------------------------------------------------------------------
  L'API temps reel et le GTFS n'utilisent pas le meme identifiant d'arret.
  Le GTFS suffixe certains stop_id par une lettre (5102 / 5102F, 1258B /
  1258G) ; l'API publie un point_id sans suffixe. Sans table de
  correspondance, aucun passage reel ne peut etre compare a un horaire.

  CE QUE LE SUFFIXE N'EST PAS
  ----------------------------------------------------------------------------
  Hypothese testee et refutee (19/08) : le suffixe n'encode PAS le sens de
  circulation. Les paires de meme nom sont a quelques metres l'une de
  l'autre (AZUR 5102 / 5174 : 14 m) : ce sont les deux trottoirs d'un meme
  arret. Rattacher un point_id a l'un ou l'autre ne change donc pas le lieu.

  REGLE DE CORRESPONDANCE
  ----------------------------------------------------------------------------
  1. On calcule la RACINE de chaque stop_id GTFS : le stop_id sans sa
     derniere lettre s'il en porte une (1258B -> 1258).
  2. Un point_id est candidat pour tout stop_id dont la racine lui est egale.
  3. Priorite a la correspondance EXACTE (point_id = stop_id), sinon le plus
     petit stop_id. Le tri complet rend le choix deterministe.
  nb_candidats garde la trace des choix arbitraires (les 11 paires du type
  1258B | 1258G) ; nb_feeds, le nombre de feeds ou l'arret existe.

  NB : cette racine (derniere lettre retiree) differe de celle de
  04_stop_id_racine.sql (tout ce qui suit le premier caractere non
  numerique). Elles donnent le meme resultat tant que le stop_id ne porte
  qu'une lettre finale, ce qui est le cas des suffixes observes (F, B, G,
  C, H). Conservee telle quelle : c'est la regle qui a produit la table de
  reference.

  RESULTAT MESURE (19/08/2026) : 2 292 correspondances, taux 97,70 %,
  54 point_id orphelins representant 0,574 % du volume.

  /!\ DEPEND DU CONTENU DE staging_waiting_times
  ----------------------------------------------------------------------------
  La liste des point_id vient des donnees collectees. Rejouer ce script
  apres avoir collecte davantage de jours peut AJOUTER des point_id, donc
  changer dim_arret et toute la chaine en aval. Comparer le resultat a la
  version precedente (sauvegarde de la table + EXCEPT dans les deux sens)
  avant de rejouer 51 et la suite.

  DEPENDANCES : stg_stops, staging_waiting_times
  IDEMPOTENT  : DROP puis CREATE.
  ORIGINE     : session du 19/08/2026, extrait en fichier le 25/09/2026.
=============================================================================*/

USE TFE_STIB;
GO

/*--- 1. Referentiel GTFS unifie sur les 3 feeds ---------------------------*/
DROP TABLE IF EXISTS #gtfs_stops;

SELECT
    stop_id,
    MAX(stop_name) AS stop_name,
    CASE WHEN stop_id LIKE '%[^0-9]%'
         THEN LEFT(stop_id, LEN(stop_id) - 1)
         ELSE stop_id END           AS racine,
    COUNT(DISTINCT feed_version)    AS nb_feeds
INTO #gtfs_stops
FROM dbo.stg_stops
GROUP BY stop_id,
         CASE WHEN stop_id LIKE '%[^0-9]%'
              THEN LEFT(stop_id, LEN(stop_id) - 1)
              ELSE stop_id END;

CREATE UNIQUE CLUSTERED INDEX ix_g ON #gtfs_stops (stop_id);


/*--- 2. Points d'arret observes cote API ----------------------------------*/
DROP TABLE IF EXISTS #api_stops;

SELECT DISTINCT LTRIM(RTRIM(point_id)) AS point_id
INTO #api_stops
FROM dbo.staging_waiting_times;

CREATE UNIQUE CLUSTERED INDEX ix_a ON #api_stops (point_id);


/*--- 3. Mapping prioritaire : exact d'abord, racine ensuite ---------------
  CREATE TABLE explicite et non SELECT INTO : SELECT INTO herite la
  nullabilite des expressions, et la PRIMARY KEY echouerait (Msg 8111).   */
DROP TABLE IF EXISTS dbo.map_arret;

CREATE TABLE dbo.map_arret (
    point_id      VARCHAR(50)  NOT NULL PRIMARY KEY,
    stop_id       VARCHAR(50)  NOT NULL,
    stop_name     VARCHAR(255) NULL,
    nb_feeds      INT          NULL,
    nb_candidats  INT          NULL
);

WITH candidats AS (
    SELECT
        a.point_id,
        g.stop_id,
        g.stop_name,
        g.nb_feeds,
        CASE WHEN a.point_id = g.stop_id THEN 1 ELSE 2 END AS priorite,
        COUNT(*) OVER (PARTITION BY a.point_id)             AS nb_candidats
    FROM #api_stops  AS a
    JOIN #gtfs_stops AS g ON a.point_id = g.racine
)
INSERT INTO dbo.map_arret (point_id, stop_id, stop_name, nb_feeds, nb_candidats)
SELECT point_id, stop_id, stop_name, nb_feeds, nb_candidats
FROM (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY point_id
                              ORDER BY priorite, stop_id) AS rn
    FROM candidats
) AS t
WHERE rn = 1;
GO


/*=============================================================================
  CONTROLES
=============================================================================*/

PRINT '=== M1 - Bilan ===';
-- Attendu au 19/08 : 2 292 mappes, taux 97,70 %.
SELECT
    (SELECT COUNT(*) FROM #api_stops)                           AS points_api,
    (SELECT COUNT(*) FROM dbo.map_arret)                        AS mappes,
    (SELECT COUNT(*) FROM dbo.map_arret WHERE nb_candidats > 1) AS ambigus,
    (SELECT COUNT(*) FROM #api_stops)
      - (SELECT COUNT(*) FROM dbo.map_arret)                    AS orphelins,
    CAST(100.0 * (SELECT COUNT(*) FROM dbo.map_arret)
         / NULLIF((SELECT COUNT(*) FROM #api_stops), 0)
         AS DECIMAL(5,2))                                       AS taux_pct;

PRINT '=== M2 - Orphelins : point_id sans correspondance GTFS ===';
SELECT a.point_id
FROM        #api_stops    AS a
LEFT JOIN   dbo.map_arret AS m ON m.point_id = a.point_id
WHERE       m.point_id IS NULL
ORDER BY    a.point_id;

PRINT '=== M3 - Cas ambigus : plusieurs candidats, choix par la regle ===';
SELECT point_id, stop_id, stop_name, nb_candidats
FROM   dbo.map_arret
WHERE  nb_candidats > 1
ORDER BY point_id;

PRINT '=== M4 - Unicite de la racine (prerequis de 40 et 04) ===';
-- Attendu : 0 ligne. Voir 04_stop_id_racine.sql, controle R1.
SELECT  LEFT(stop_id, CASE WHEN PATINDEX('%[^0-9]%', stop_id) = 0
                           THEN LEN(stop_id)
                           ELSE PATINDEX('%[^0-9]%', stop_id) - 1 END) AS racine,
        COUNT(*) AS nb_point_id
FROM    dbo.map_arret
GROUP BY LEFT(stop_id, CASE WHEN PATINDEX('%[^0-9]%', stop_id) = 0
                            THEN LEN(stop_id)
                            ELSE PATINDEX('%[^0-9]%', stop_id) - 1 END)
HAVING  COUNT(*) > 1;
GO
