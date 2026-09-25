/*=============================================================================
  TFE STIB - 20_transform/23_wrk_jours.sql
  ----------------------------------------------------------------------------
  OBJET : definir LE PERIMETRE TEMPOREL de l'analyse.

  Grain : 1 ligne = 1 jour de service analyse, avec son feed GTFS.

  ⚠️ SOURCE UNIQUE DU PERIMETRE (piege n°68, version temporelle)
  ----------------------------------------------------------------------------
  Cette table est la seule definition du "quels jours sont analyses".
  Tout ce qui lit wrk_passages doit la consulter :
    - 40_int_passage_theorique.sql, via wrk_service_date  (cote theorique)
    - 41_est_observable.sql,        JOIN direct           (cote reel)
    - 45_int_appariement.sql,       EXISTS                (cote reel)
  Si un seul de ces trois s'en affranchit, les deux cotes de
  l'appariement portent sur des periodes differentes et le taux de
  conformite est faux SANS aucune erreur SQL.

  PARAMETRE @date_fin - LE SEUL ENDROIT OU LE PERIMETRE SE DECIDE
  ----------------------------------------------------------------------------
  wrk_passages couvre 52 jours (1er juillet -> 26 aout 2026).

    '2026-08-18' -> PASSE A, non-regression. 44 jours, le perimetre
                    sur lequel tous les chiffres publies ont ete
                    calcules (fact_ecart = 3 077 266 ; reseau 88,70 % ;
                    ligne 25 95,86 %). Sert a prouver que la chaine
                    reproduit ses resultats sur cette machine.

    '2026-08-26' -> PASSE B, perimetre etendu. 52 jours.
                    A ne lancer qu'APRES la passe A validee : sinon
                    machine et periode changent en meme temps et un
                    ecart de KPI devient ininterpretable.

  ⚠️ Changer ce parametre peut deplacer T dans ref_tolerance_ligne
     (P10 des intervalles theoriques). Comparer le controle F4 de
     44_ref_tolerance_ligne.sql entre les deux passes.

  ENTREES : dbo.wrk_passages, dbo.ref_feed_periode
  SORTIE  : dbo.wrk_jours
  IDEMPOTENT : table reconstruite integralement.
=============================================================================*/

USE TFE_STIB;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @date_fin DATE = '2026-08-26';   -- <<< PASSE A. Mettre '2026-08-26' pour la passe B.

DROP TABLE IF EXISTS dbo.wrk_jours;

CREATE TABLE dbo.wrk_jours (
    date_service DATE        NOT NULL PRIMARY KEY,
    feed_version VARCHAR(50) NOT NULL
);

INSERT INTO dbo.wrk_jours (date_service, feed_version)
SELECT DISTINCT
        CAST(p.derniere_obs AS DATE),
        f.feed_version
FROM        dbo.wrk_passages     AS p
INNER JOIN  dbo.ref_feed_periode AS f
        ON  CAST(p.derniere_obs AS DATE) BETWEEN f.date_debut AND f.date_fin
WHERE       CAST(p.derniere_obs AS DATE) <= @date_fin;
-- INNER JOIN volontaire : un jour sans feed correspondant DOIT
-- disparaitre, et le controle E1 le rend visible immediatement.
-- Un LEFT JOIN produirait un feed_version NULL qui casserait la PK.
GO


/*=============================================================================
  CONTROLES
=============================================================================*/

PRINT '=== E1 - Perimetre retenu ===';
-- Attendu PASSE A : 44 jours, du 2026-07-01 au 2026-08-18.
-- Attendu PASSE B : 52 jours, du 2026-07-01 au 2026-08-26.
-- Un nombre inferieur signifie qu'un jour de collecte n'a trouve
-- aucun feed : l'instruire AVANT de poursuivre.
SELECT  jours = COUNT(*),
        du    = MIN(date_service),
        au    = MAX(date_service)
FROM    dbo.wrk_jours;
GO


PRINT '=== E2 - Repartition par feed ===';
-- Attendu PASSE A : 2_15 -> 3 j | 2_16 -> 25 j | 2_18 -> 16 j
-- Attendu PASSE B : 2_15 -> 3 j | 2_16 -> 25 j | 2_18 -> 24 j
SELECT  feed_version,
        jours = COUNT(*),
        du    = MIN(date_service),
        au    = MAX(date_service)
FROM    dbo.wrk_jours
GROUP BY feed_version
ORDER BY du;
GO


PRINT '=== E3 - Jours de collecte exclus du perimetre ===';
-- Liste explicite de ce que le parametre ecarte. Doit renvoyer 8
-- lignes en passe A (19 -> 26 aout), 0 en passe B.
-- Le perimetre devient une phrase chiffree au lieu d'un silence.
SELECT  jour     = CAST(p.derniere_obs AS DATE),
        passages = COUNT(*)
FROM    dbo.wrk_passages AS p
WHERE   NOT EXISTS (SELECT 1 FROM dbo.wrk_jours AS j
                    WHERE j.date_service = CAST(p.derniere_obs AS DATE))
GROUP BY CAST(p.derniere_obs AS DATE)
ORDER BY jour;
GO
