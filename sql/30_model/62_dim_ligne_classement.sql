/* ============================================================================
   62_dim_ligne_classement.sql        -- VERSION 2, remplace la V1
   ----------------------------------------------------------------------------
   OBJET   Materialise dans dim_ligne la regle d'exclusion des CLASSEMENTS
           PUBLIES (visuel Q2-2), sous forme d'un drapeau + son motif.

   /!\ CE DRAPEAU NE RETIRE RIEN DES DONNEES. Les lignes exclues restent dans
       fact_ecart, dans le KPI reseau, dans l'histogramme Q1-2 et dans
       l'analyse spatiale. Il ne filtre QUE les comparaisons entre lignes.

   ----------------------------------------------------------------------------
   POURQUOI PAS UN SEUIL DE VOLUME (V1, abandonnee)
           Le volume total confond DUREE et INTENSITE. Mesure :
             - ligne 72 : 4 900 passages sur 44 jours =  111 / jour
             - ligne T7 : 4 834 passages sur 11 jours =  440 / jour
           Meme total, deux objets sans rapport. La 72 est une ligne reguliere
           a basse frequence : elle est parfaitement comparable aux autres.
           T7 est un service de densite normale sur une fraction de la periode.

   POURQUOI PAS "MOINS DE 44 JOURS"
           Mesure : les lignes 78 (33 j), 76 (37 j) et 17 (39 j) couvrent une
           ETENDUE de 49 jours, du premier au dernier jour de la periode. Elles
           ne circulent simplement pas le dimanche. C'est un REGIME DE SERVICE,
           pas une interruption. Un critere en nombre de jours les excluait
           a tort.

   CRITERE RETENU  Presence dans les 7 PREMIERS jours ET dans les 7 DERNIERS
           jours du perimetre. Tolerant a tout regime hebdomadaire, il
           n'attrape que les apparitions et disparitions reelles.

   ----------------------------------------------------------------------------
   VALIDATION EXTERNE (sources STIB / presse, consultees le 04/09/2026)
     - Tram 7 remplace par T-bus entre Docks Bruxsel et Heysel,
       du 08/08 au 30/08/2026 (travaux Croix du Feu / pont Van Praet).
       -> base : T7 present du 08/08 au 18/08 (borne haute = fin du perimetre).
     - Tram 35 supprime du 08/08 au 30/08/2026.
       -> base : dernier jour 07/08. Concordance exacte.
     - Metro 1 limite a Merode les dimanches 05 et 19/07 jusqu'a 12h30 (M-bus).
     - Metro 5 limite a Gare de l'Ouest les dimanches 02 et 30/08, idem.
       -> base : M1 le 19/07 seulement, M5 le 02/08 seulement.
          Le 30/08 est hors perimetre. LE 05/07 EST MANQUANT -> voir controle J5.
     /!\ Les M-bus s'arretent a 12h30, alors que la fenetre analytique va
         jusqu'a 13h45 : leur taux porte sur un melange horaire different.
         Second motif d'incomparabilite, independant de la duree.

   NON COUVERT PAR LA REGLE (limite a enoncer, pas a corriger)
     Les lignes 7, 10, 47 et 56 sont en regime modifie en aout (limitation a
     Docks Bruxsel, prolongements, renforts) tout en conservant une couverture
     temporelle complete. Elles restent classees. Retirer les perturbations
     d'un indicateur de qualite de service le viderait de son sens.

   PREREQUIS   61_fact_ecart_postes.sql
   IDEMPOTENCE ALTER conditionnel + remise a zero puis reapplication. Aucun DROP.
   DATE        04/09/2026 -- perimetre 44 jours (01/07 -> 18/08), 75 lignes.
   ========================================================================== */

SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------------
   0. PARAMETRES  (piege n°61 : #param traverse les GO, pas DECLARE)
      Les bornes sont LUES dans les faits, jamais saisies a la main
      (piege n°66 : une constante en dur survit a un changement de perimetre).
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS #param;

SELECT
    MIN(f.date_sk) AS date_min,
    MAX(f.date_sk) AS date_max,
    CAST(7 AS INT) AS marge_jours
INTO #param
FROM dbo.fact_ecart AS f
WHERE f.nb_theorique = 1;
GO

/* ---------------------------------------------------------------------------
   1. COLONNES
   ------------------------------------------------------------------------ */
IF COL_LENGTH('dbo.dim_ligne', 'dans_classement') IS NULL
    ALTER TABLE dbo.dim_ligne ADD dans_classement BIT NOT NULL DEFAULT 1;
GO

IF COL_LENGTH('dbo.dim_ligne', 'motif_exclusion') IS NULL
    ALTER TABLE dbo.dim_ligne ADD motif_exclusion VARCHAR(80) NULL;
GO

/* ---------------------------------------------------------------------------
   2. APPLICATION DE LA REGLE
      Remise a l'etat neutre d'abord : sans cela, un rejeu apres modification
      du critere laisserait des exclusions perimees en place.
      Les motifs sont poses du plus GENERIQUE au plus SPECIFIQUE, chacun
      ecrasant le precedent.
   ------------------------------------------------------------------------ */
UPDATE dbo.dim_ligne
SET dans_classement = 1,
    motif_exclusion = NULL;
GO

/* 2a. Couverture temporelle partielle -----------------------------------------
   Une ligne est comparable si elle a servi au moins un jour dans la premiere
   semaine ET au moins un jour dans la derniere semaine du perimetre.        */
WITH bornes AS (
    SELECT
        p.date_min,
        p.date_max,
        CONVERT(INT, CONVERT(CHAR(8),
            DATEADD(DAY,  p.marge_jours - 1,
                    CONVERT(DATE, CAST(p.date_min AS CHAR(8)), 112)), 112)) AS fin_debut,
        CONVERT(INT, CONVERT(CHAR(8),
            DATEADD(DAY, -(p.marge_jours - 1),
                    CONVERT(DATE, CAST(p.date_max AS CHAR(8)), 112)), 112)) AS debut_fin
    FROM #param AS p
),
couverture AS (
    SELECT
        f.ligne_sk,
        MAX(CASE WHEN f.date_sk <= b.fin_debut THEN 1 ELSE 0 END) AS vu_au_debut,
        MAX(CASE WHEN f.date_sk >= b.debut_fin THEN 1 ELSE 0 END) AS vu_a_la_fin
    FROM dbo.fact_ecart AS f
    CROSS JOIN bornes   AS b
    WHERE f.nb_theorique = 1
    GROUP BY f.ligne_sk
)
UPDATE l
SET dans_classement = 0,
    motif_exclusion = 'Couverture temporelle partielle (service non permanent)'
FROM dbo.dim_ligne AS l
JOIN couverture    AS c ON c.ligne_sk = l.ligne_sk
WHERE c.vu_au_debut = 0 OR c.vu_a_la_fin = 0;
GO

/* 2b. Aucun passage dans la fenetre analytique --------------------------------
   Le JOIN de 2a ne peut pas atteindre une ligne absente de fact_ecart :
   il faut un NOT EXISTS. (Defaut de la V1, revele par le controle J1.)      */
UPDATE l
SET dans_classement = 0,
    motif_exclusion = 'Hors perimetre analytique (aucun passage en fenetre)'
FROM dbo.dim_ligne AS l
WHERE l.ligne_sk <> -1
  AND NOT EXISTS (SELECT 1 FROM dbo.fact_ecart AS f
                  WHERE f.ligne_sk = l.ligne_sk AND f.nb_theorique = 1);
GO

/* 2c. Exclusion documentee au §0 ---------------------------------------------- */
UPDATE dbo.dim_ligne
SET dans_classement = 0,
    motif_exclusion = 'Hors perimetre analytique (service residuel, §0)'
WHERE line_id = '69';
GO

/* 2d. Membre inconnu ---------------------------------------------------------- */
UPDATE dbo.dim_ligne
SET dans_classement = 0,
    motif_exclusion = 'Membre inconnu'
WHERE ligne_sk = -1;
GO

/* ===========================================================================
   3. CONTROLES
   ======================================================================== */

PRINT '--- J0 : bornes du perimetre lues dans les faits -----------------------';
SELECT * FROM #param;

PRINT '--- J1 : decompte ------------------------------------------------------';
SELECT
    COUNT(*)                                             AS lignes_dim,
    SUM(CASE WHEN dans_classement = 1 THEN 1 ELSE 0 END) AS classees,
    SUM(CASE WHEN dans_classement = 0 THEN 1 ELSE 0 END) AS exclues
FROM dbo.dim_ligne;

PRINT '--- J2 : exclues, avec motif, volume et etendue ------------------------';
SELECT
    l.line_id,
    l.motif_exclusion,
    COUNT(DISTINCT f.date_sk)           AS nb_jours,
    MIN(f.date_sk)                      AS premier,
    MAX(f.date_sk)                      AS dernier,
    SUM(CAST(f.nb_theorique AS BIGINT)) AS nb_theorique
FROM dbo.dim_ligne AS l
LEFT JOIN dbo.fact_ecart AS f
       ON f.ligne_sk = l.ligne_sk AND f.nb_theorique = 1
WHERE l.dans_classement = 0
GROUP BY l.line_id, l.motif_exclusion
ORDER BY l.motif_exclusion, nb_theorique;

PRINT '--- J3 : les 8 plus petits volumes CLASSES -----------------------------';
PRINT '        la 72 doit y figurer : basse frequence, mais service permanent.';
SELECT TOP 8
    l.line_id,
    COUNT(DISTINCT f.date_sk)                                 AS nb_jours,
    SUM(CAST(f.nb_theorique AS BIGINT))                       AS nb_theorique,
    CAST(1.0 * SUM(CAST(f.nb_theorique AS BIGINT))
             / COUNT(DISTINCT f.date_sk) AS DECIMAL(10,1))    AS theorique_par_jour
FROM dbo.dim_ligne AS l
JOIN dbo.fact_ecart AS f ON f.ligne_sk = l.ligne_sk AND f.nb_theorique = 1
WHERE l.dans_classement = 1
GROUP BY l.line_id
ORDER BY nb_theorique ASC;

PRINT '--- J4 : impact du filtre sur le KPI (attendu : ecart tres faible) -----';
SELECT
    CAST(100.0 * SUM(CAST(f.nb_conforme AS BIGINT))
              /  SUM(CAST(f.nb_theorique AS BIGINT)) AS DECIMAL(5,2)) AS conformite_classees,
    SUM(CAST(f.nb_theorique AS BIGINT))                               AS theorique_classees
FROM dbo.fact_ecart AS f
JOIN dbo.dim_ligne  AS l ON l.ligne_sk = f.ligne_sk
WHERE l.dans_classement = 1
  AND f.nb_theorique = 1;

PRINT '--- J5 : ANOMALIE -- le M-bus du dimanche 05/07 est-il dans la base ? --';
PRINT '        Source STIB : M1 limite a Merode les dimanches 05 ET 19/07.';
PRINT '        Attendu si tout va bien : deux lignes M1. Observe jusqu ici : une.';
SELECT
    d.date_sk,
    d.jour_nom,
    l.line_id,
    SUM(CAST(f.nb_theorique AS BIGINT)) AS nb_theorique,
    SUM(CAST(f.nb_reel      AS BIGINT)) AS nb_reel
FROM dbo.fact_ecart AS f
JOIN dbo.dim_ligne  AS l ON l.ligne_sk = f.ligne_sk
JOIN dbo.dim_date   AS d ON d.date_sk  = f.date_sk
WHERE l.line_id IN ('M1', 'M5')
GROUP BY d.date_sk, d.jour_nom, l.line_id
ORDER BY d.date_sk;

PRINT '--- J6 : le 05/07 a-t-il ete collecte tout court ? ---------------------';
SELECT
    d.date_sk,
    d.jour_nom,
    d.est_collecte,
    SUM(CAST(f.nb_theorique AS BIGINT)) AS theorique_reseau,
    SUM(CAST(f.nb_reel      AS BIGINT)) AS reel_reseau
FROM dbo.dim_date AS d
LEFT JOIN dbo.fact_ecart AS f ON f.date_sk = d.date_sk
WHERE d.date_sk BETWEEN 20260703 AND 20260707
GROUP BY d.date_sk, d.jour_nom, d.est_collecte
ORDER BY d.date_sk;

DROP TABLE IF EXISTS #param;
GO
