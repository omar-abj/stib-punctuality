/* ============================================================================
   61_fact_ecart_postes.sql
   ----------------------------------------------------------------------------
   OBJET   Ajoute a fact_ecart les trois compteurs additifs manquants de la
           cascade de conformite, plus la colonne de binning servant a
           l'histogramme des ecarts (visuel Q1-2).

   POURQUOI EN SQL ET PAS EN DAX
           La fenetre de conformite (-60 / +180 s) est un CHOIX METHODOLOGIQUE
           au meme titre que la tolerance T. Elle doit vivre dans un script
           numerote et rejouable, pas dans une formule d'un .pbix non versionne.
           En outre, le §18 justifie les compteurs additifs par le fait qu'un
           ratio de deux SUM() est juste a tout niveau d'agregation, sans
           CALCULATE ni contexte de filtre. On prolonge ce motif.

   PREREQUIS
           60_fact_ecart.sql execute. La table doit exister et etre peuplee.

   IDEMPOTENCE
           ALTER ... ADD conditionnel, puis UPDATE inconditionnel. Le script se
           rejoue autant de fois que voulu. AUCUN DROP : reconstruire
           fact_ecart declencherait le piege n°62 (les 7 FK des dimensions
           empechent le DROP) sans aucun benefice.

   PIEGE N°61
           DECLARE ne survit pas a un GO. Le GO est obligatoire apres l'ALTER
           (une colonne ajoutee n'est pas referencable dans le meme batch), donc
           tout parametre passe par la table temporaire #param.

   DATE    03/09/2026 - perimetre 44 jours, 75 lignes, fenetre 09:15-13:45
   ========================================================================== */

SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------------
   0. PARAMETRES  (piege n°61 : #param traverse les GO, pas DECLARE)
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS #param;

CREATE TABLE #param (
    borne_avance_sec  INT,   -- seuil de conformite cote avance  (negatif)
    borne_retard_sec  INT,   -- seuil de conformite cote retard  (positif)
    borne_hist_sec    INT,   -- demi-etendue de l'histogramme
    largeur_bin_sec   INT    -- largeur d'une classe
);

INSERT INTO #param (borne_avance_sec, borne_retard_sec, borne_hist_sec, largeur_bin_sec)
VALUES (-60, 180, 190, 20);

/*  borne_hist_sec = 190 : c'est le T MINIMUM du reseau (ligne 71, 193 s
    arrondi a la baisse). En deca, AUCUNE ligne n'est amputee par la
    tolerance -- toutes contribuent egalement a l'histogramme. Au-dela, on
    superposerait des populations tronquees a des bornes differentes.        */
GO

/* ---------------------------------------------------------------------------
   1. AJOUT DES COLONNES  (conditionnel)
   ------------------------------------------------------------------------ */
IF COL_LENGTH('dbo.fact_ecart', 'nb_conforme') IS NULL
    ALTER TABLE dbo.fact_ecart ADD nb_conforme TINYINT NOT NULL DEFAULT 0;
GO

IF COL_LENGTH('dbo.fact_ecart', 'nb_avance') IS NULL
    ALTER TABLE dbo.fact_ecart ADD nb_avance TINYINT NOT NULL DEFAULT 0;
GO

IF COL_LENGTH('dbo.fact_ecart', 'nb_retard') IS NULL
    ALTER TABLE dbo.fact_ecart ADD nb_retard TINYINT NOT NULL DEFAULT 0;
GO

IF COL_LENGTH('dbo.fact_ecart', 'retard_bin') IS NULL
    ALTER TABLE dbo.fact_ecart ADD retard_bin SMALLINT NULL;
GO

/* ---------------------------------------------------------------------------
   2. ALIMENTATION DES TROIS POSTES
   ---------------------------------------------------------------------------
   Le 4e poste de la cascade n'est PAS cree : c'est nb_theo_seul, qui existe
   deja. Bouclage attendu :

       nb_conforme + nb_avance + nb_retard + nb_theo_seul = nb_theorique

   Les lignes 'reel_non_apparie' ont nb_theorique = 0 et restent a 0 partout :
   elles ne sont pas dans le denominateur du KPI.
   ------------------------------------------------------------------------ */
UPDATE f
SET nb_conforme = CASE WHEN f.nb_apparie = 1
                        AND f.retard_sec >= p.borne_avance_sec
                        AND f.retard_sec <= p.borne_retard_sec
                       THEN 1 ELSE 0 END,
    nb_avance   = CASE WHEN f.nb_apparie = 1
                        AND f.retard_sec <  p.borne_avance_sec
                       THEN 1 ELSE 0 END,
    nb_retard   = CASE WHEN f.nb_apparie = 1
                        AND f.retard_sec >  p.borne_retard_sec
                       THEN 1 ELSE 0 END
FROM dbo.fact_ecart AS f
CROSS JOIN #param AS p;
GO

/* ---------------------------------------------------------------------------
   3. BINNING DE retard_sec  (visuel Q1-2)
   ---------------------------------------------------------------------------
   Renseigne UNIQUEMENT pour les appariés dans la plage non censuree.
   NULL partout ailleurs : un NULL est ignore par Power BI, ce qui evite
   qu'une barre parasite apparaisse a une extremite de l'axe.

   Formule : indice = (retard_sec + 190) / 20   -> division entiere = FLOOR,
                                                   sure car l'operande est >= 0
             centre  = -180 + 20 * indice

   19 classes, centres de -180 a +180 par pas de 20. L'indice 19 (atteint par
   le seul retard_sec = +190) est ramene a 18 : sans ce plafonnement, la
   derniere valeur creerait une 20e classe a 200, hors bornes.
   ------------------------------------------------------------------------ */
UPDATE f
SET retard_bin = CASE
        WHEN f.nb_apparie = 1
         AND ABS(f.retard_sec) <= p.borne_hist_sec
        THEN -180 + p.largeur_bin_sec
                  * CASE WHEN (f.retard_sec + p.borne_hist_sec) / p.largeur_bin_sec > 18
                         THEN 18
                         ELSE (f.retard_sec + p.borne_hist_sec) / p.largeur_bin_sec
                    END
        ELSE NULL
    END
FROM dbo.fact_ecart AS f
CROSS JOIN #param AS p;
GO

/* ===========================================================================
   4. CONTROLES  -- criteres de reussite explicites
   ---------------------------------------------------------------------------
   Toutes les valeurs de reference portent leur DATE et leur PERIMETRE
   (piege n°66 : une constante en dur sans contexte fausse un controle en
   silence quand le perimetre change).
   ======================================================================== */

PRINT '--- H1 : bouclage de la cascade (attendu 0) ---------------------------';
SELECT COUNT(*) AS lignes_en_defaut
FROM dbo.fact_ecart
WHERE nb_theorique = 1
  AND (nb_conforme + nb_avance + nb_retard + nb_theo_seul) <> 1;

PRINT '--- H2 : aucun poste pose hors du theorique (attendu 0) ----------------';
SELECT COUNT(*) AS lignes_en_defaut
FROM dbo.fact_ecart
WHERE nb_theorique = 0
  AND (nb_conforme + nb_avance + nb_retard) > 0;

PRINT '--- H3 : KPI reseau (ref. 03/09/2026, 44 j, 75 lignes) -----------------';
PRINT '        attendu conformite 65,06 % / appariement 88,69 %';
SELECT
    SUM(CAST(nb_theorique AS BIGINT))                                 AS theorique,
    CAST(100.0 * SUM(CAST(nb_conforme AS BIGINT))
              /  SUM(CAST(nb_theorique AS BIGINT)) AS DECIMAL(5,2))   AS pct_conformite,
    CAST(100.0 * SUM(CAST(nb_apparie  AS BIGINT))
              /  SUM(CAST(nb_theorique AS BIGINT)) AS DECIMAL(5,2))   AS pct_appariement,
    CAST(100.0 * SUM(CAST(nb_avance   AS BIGINT))
              /  SUM(CAST(nb_theorique AS BIGINT)) AS DECIMAL(5,2))   AS pct_avance,
    CAST(100.0 * SUM(CAST(nb_retard   AS BIGINT))
              /  SUM(CAST(nb_theorique AS BIGINT)) AS DECIMAL(5,2))   AS pct_retard,
    CAST(100.0 * SUM(CAST(nb_theo_seul AS BIGINT))
              /  SUM(CAST(nb_theorique AS BIGINT)) AS DECIMAL(5,2))   AS pct_non_apparie
FROM dbo.fact_ecart;

PRINT '--- H4 : structure du binning (attendu 19 / -180 / +180) ---------------';
SELECT
    COUNT(DISTINCT retard_bin) AS nb_classes,
    MIN(retard_bin)            AS bin_min,
    MAX(retard_bin)            AS bin_max,
    COUNT(retard_bin)          AS lignes_binnees
FROM dbo.fact_ecart;

PRINT '--- H5 : coherence bin / apparie (attendu 0 dans les deux colonnes) ----';
SELECT
    SUM(CASE WHEN retard_bin IS NOT NULL AND nb_apparie = 0 THEN 1 ELSE 0 END)  AS bin_sans_appariement,
    SUM(CASE WHEN retard_bin IS NULL AND nb_apparie = 1
              AND ABS(retard_sec) <= 190 THEN 1 ELSE 0 END)                     AS appariement_sans_bin
FROM dbo.fact_ecart;

PRINT '--- H6 : non-regression ligne 25 (ref. 03/09/2026) ---------------------';
PRINT '        attendu conformite 64,40 % / appariement 95,86 %';
SELECT
    CAST(100.0 * SUM(CAST(f.nb_conforme AS BIGINT))
              /  SUM(CAST(f.nb_theorique AS BIGINT)) AS DECIMAL(5,2)) AS pct_conformite_25,
    CAST(100.0 * SUM(CAST(f.nb_apparie  AS BIGINT))
              /  SUM(CAST(f.nb_theorique AS BIGINT)) AS DECIMAL(5,2)) AS pct_appariement_25
FROM dbo.fact_ecart AS f
JOIN dbo.dim_ligne  AS l ON l.ligne_sk = f.ligne_sk
WHERE l.line_id = '25';

DROP TABLE IF EXISTS #param;
GO
