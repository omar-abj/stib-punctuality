/*=============================================================================
  TFE STIB - 20_transform/45_int_appariement.sql
  ----------------------------------------------------------------------------
  Objet : construire un appariement un-a-un conservateur.
          Parametre par @ligne : '25' pour la ligne de developpement,
          NULL pour l'ensemble du reseau.

  (Anciennement Ligne_25.sql. Renomme le 27/08 : un script porte le nom
   de l'OBJET qu'il produit, pas du perimetre sur lequel on le teste.)

  Entrees :
    dbo.int_passage_theorique   <- DOIT avoir ete marque par
                                   41_est_observable.sql
    dbo.wrk_passages
    dbo.wrk_jours               <- SOURCE UNIQUE DU PERIMETRE TEMPOREL.
                                   Borne les DEUX cotes de l'appariement.
    dbo.ref_feed_periode
    dbo.ref_tolerance_ligne     <- produite par 44_ref_tolerance_ligne.sql
    dbo.map_destination

  Sortie :
    dbo.int_appariement

  Grain de sortie : un resultat de comparaison a un arret et une date :
    - apparie
    - theorique_non_apparie
    - reel_non_apparie

  Important : passage_reel_estime provient de la derniere prediction API.
  Le script ne doit donc jamais presenter cette valeur comme une heure observee.
=============================================================================*/

USE TFE_STIB;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ligne         VARCHAR(50) = NULL;
DECLARE @sec_debut     INT         = 33300;   -- 09:15:00 inclus
DECLARE @sec_fin       INT         = 49500;   -- 13:45:00 exclu
-- ATTENTION : les commentaires precedents annonçaient 09:00 / 14:00.
-- Ils dataient d'avant le resserrement de la fenetre (§14bis). Les
-- VALEURS ont toujours ete bonnes ; seuls les commentaires etaient faux.

-- LA TOLERANCE N'EST PLUS UN SCALAIRE (27/08).
-- Elle vaut T = MIN(intervalle_P10 / 2, 300 s) et depend de la ligne :
-- une tolerance de 240 s sur une ligne a 6 min d'intervalle englobe le
-- passage suivant et produit des appariements FAUX, pas absents.
-- La valeur est figee dans dbo.ref_tolerance_ligne, calculee une fois
-- par 44_ref_tolerance_ligne.sql. Un calcul refait a chaque execution
-- changerait silencieusement si le GTFS evoluait.
--
-- CONSEQUENCE A CONNAITRE : retard_sec est censure a des bornes
-- DIFFERENTES selon la ligne. Les medianes et taux d'appariement BRUTS
-- ne sont donc PAS comparables entre lignes. Les comparaisons se font
-- sur le taux de service conforme (-60/+180 s) rapporte au theorique
-- observable : toutes les lignes ayant T >= 180 s, +180 s est
-- mesurable partout.

/*=============================================================================
  1. Passages theoriques dans la fenetre analytique
=============================================================================*/

DROP TABLE IF EXISTS #theorique;

SELECT
    ROW_NUMBER() OVER (
        ORDER BY th.feed_version,
                 th.date_service,
                 th.line_id,
                 th.point_id,
                 th.trip_headsign,
                 th.arrivee_theorique,
                 th.trip_id,
                 th.stop_id,
                 th.stop_sequence
    ) AS theo_id,
    th.date_service,
    th.feed_version,
    th.line_id,
    th.point_id,
    th.stop_id,
    th.trip_id,
    th.trip_headsign,
    th.stop_sequence,
    th.arrivee_theorique,
    tol.tolerance_sec
INTO #theorique
FROM dbo.int_passage_theorique th
JOIN dbo.ref_tolerance_ligne tol
  ON tol.line_id = th.line_id
  AND tol.est_dans_perimetre = 1
  -- JOIN et non LEFT JOIN : une ligne absente de la table de reference
  -- doit faire ECHOUER visiblement, pas disparaitre en silence.
  -- Le controle F1 de 44_ref_tolerance_ligne.sql garantit la couverture.
WHERE th.point_id IS NOT NULL
  -- REGLE MESUREE, remplace l'exclusion nominative 0539 / ROGIER
  -- (voir 41_est_observable.sql). Un passage theorique dont le trio
  -- (ligne, arret, destination) n'a JAMAIS ete publie par le flux en
  -- 44 jours n'est pas un passage supprime : il est inobservable.
  -- Mesure du 27/08 : 1 261 passages sur la ligne 25 (Rogier ET Buyl),
  -- 4,82 % du theorique reseau. L'ancienne exclusion n'en voyait
  -- que 1 149 : les arrivees terminales a Buyl etaient comptees
  -- comme des suppressions.
  -- Ceci retire aussi le dernier usage de est_dernier_arret, dont la
  -- valeur est fausse dans la fenetre (piege n°32).
  AND th.est_observable = 1
  AND th.arrivee_sec >= @sec_debut
  AND th.arrivee_sec <  @sec_fin
  AND (@ligne IS NULL OR th.line_id = @ligne)
OPTION (RECOMPILE);

CREATE UNIQUE CLUSTERED INDEX ix_theorique_id
    ON #theorique (theo_id);

CREATE INDEX ix_theorique_groupe
    ON #theorique
       (feed_version, date_service, line_id, point_id, trip_headsign,
        arrivee_theorique);

/*=============================================================================
  2. Passages reels reconstruits, filtres et rattaches au headsign canonique
=============================================================================*/

DROP TABLE IF EXISTS #reel;

WITH reel_source AS (
    SELECT
        f.feed_version,
        CAST(p.derniere_obs AS DATE) AS date_service,
        p.line_id,
        p.point_id,
        p.destination               AS destination_rt,
        m.trip_headsign,
        p.passage_num,
        p.premiere_obs,
        p.derniere_obs,
        p.arrivee_estimee,
        p.nb_obs,
        DATEDIFF(SECOND, p.derniere_obs, p.arrivee_estimee) AS fraicheur_sec,
        tol.tolerance_sec
    FROM dbo.wrk_passages p
    JOIN dbo.ref_tolerance_ligne tol
      ON tol.line_id = p.line_id COLLATE DATABASE_DEFAULT
     AND tol.est_dans_perimetre = 1
      -- Le cote reel doit couvrir EXACTEMENT les memes lignes que le cote
      -- theorique. Sans cette jointure, #reel contient des passages de
      -- lignes hors perimetre : ils gonflent les reels non apparies avec
      -- des passages dont aucun theorique ne peut etre le partenaire.
    JOIN dbo.ref_feed_periode f
      ON CAST(p.derniere_obs AS DATE) BETWEEN f.date_debut AND f.date_fin
    JOIN dbo.map_destination m
      ON m.feed_version   = f.feed_version
     AND m.line_id        = p.line_id
     AND m.destination_rt = p.destination
     AND m.type_mapping IN ('exact', 'devie', 'abrege')
    WHERE p.nb_obs >= 2
      AND DATEDIFF(SECOND, p.derniere_obs, p.arrivee_estimee)
          BETWEEN -120 AND 180
      AND (@ligne IS NULL OR p.line_id = @ligne)
      -- PERIMETRE TEMPOREL - ajout du 03/09.
      -- Le cote theorique descend de wrk_service_date, donc de wrk_jours.
      -- Le cote reel partait directement de wrk_passages : les deux cotes
      -- n'etaient pas bornes par la meme source. Tant que wrk_passages et
      -- wrk_jours couvraient les memes jours, la coincidence masquait le
      -- defaut. Des qu'ils divergent, les passages reels des jours hors
      -- perimetre entrent SANS aucun theorique en face : ils deviennent
      -- autant de reel_non_apparie et le taux de conformite chute sans
      -- cause reelle, SANS erreur SQL.
      -- wrk_jours est la source unique du perimetre (piege n°68, version
      -- temporelle). EXISTS et non JOIN : aucun risque de duplication,
      -- et l'intention de filtrage reste lisible.
      AND EXISTS (SELECT 1 FROM dbo.wrk_jours AS j
                  WHERE j.date_service = CAST(p.derniere_obs AS DATE))
)
SELECT
    ROW_NUMBER() OVER (
        ORDER BY r.feed_version,
                 r.date_service,
                 r.line_id,
                 r.point_id,
                 r.trip_headsign,
                 r.arrivee_estimee,
                 r.derniere_obs,
                 r.destination_rt,
                 r.passage_num
    ) AS reel_id,
    r.feed_version,
    r.date_service,
    r.line_id,
    r.point_id,
    r.destination_rt,
    r.trip_headsign,
    r.passage_num,
    r.premiere_obs,
    r.derniere_obs,
    r.arrivee_estimee,
    r.nb_obs,
    r.fraicheur_sec,
    r.tolerance_sec
INTO #reel
FROM reel_source r
WHERE r.arrivee_estimee >= DATEADD(SECOND, @sec_debut,
                                   CAST(r.date_service AS DATETIME2))
  AND r.arrivee_estimee <  DATEADD(SECOND, @sec_fin,
                                   CAST(r.date_service AS DATETIME2))
OPTION (RECOMPILE);

CREATE UNIQUE CLUSTERED INDEX ix_reel_id
    ON #reel (reel_id);

CREATE INDEX ix_reel_groupe
    ON #reel
       (feed_version, date_service, line_id, point_id, trip_headsign,
        arrivee_estimee);

/*=============================================================================
  3. Couples candidats situes dans la tolerance
=============================================================================*/

DROP TABLE IF EXISTS #candidats;

SELECT
    t.theo_id,
    r.reel_id,
    DATEDIFF(SECOND, t.arrivee_theorique, r.arrivee_estimee) AS retard_sec,
    ABS(DATEDIFF(SECOND, t.arrivee_theorique, r.arrivee_estimee))
        AS ecart_abs_sec
INTO #candidats
FROM #theorique t
JOIN #reel r
  ON r.feed_version  = t.feed_version
 AND r.date_service  = t.date_service
 AND r.line_id       = t.line_id
 AND r.point_id      = t.point_id
 AND r.trip_headsign = t.trip_headsign
WHERE ABS(DATEDIFF(SECOND, t.arrivee_theorique, r.arrivee_estimee))
      <= t.tolerance_sec;
-- La tolerance vient desormais du theorique, ligne par ligne.

CREATE INDEX ix_candidats_theo
    ON #candidats (theo_id, ecart_abs_sec, reel_id);

CREATE INDEX ix_candidats_reel
    ON #candidats (reel_id, ecart_abs_sec, theo_id);

/*=============================================================================
  4. Appariement un-a-un par meilleurs candidats reciproques, par iterations

  A chaque tour :
    - chaque theorique choisit son reel restant le plus proche ;
    - chaque reel choisit son theorique restant le plus proche ;
    - seuls les choix reciproques sont retenus ;
    - les deux passages sont retires des tours suivants.

  Les identifiants servent de departage deterministe en cas d'egalite.
=============================================================================*/

DROP TABLE IF EXISTS #apparies;

CREATE TABLE #apparies (
    theo_id              BIGINT NOT NULL PRIMARY KEY,
    reel_id              BIGINT NOT NULL UNIQUE,
    retard_sec           INT    NOT NULL,
    ecart_abs_sec        INT    NOT NULL,
    iteration_appariement INT   NOT NULL
);

DECLARE @iteration INT = 0;
DECLARE @nb_ajoutes INT = 1;

WHILE @nb_ajoutes > 0
BEGIN
    SET @iteration += 1;

    ;WITH actifs AS (
        SELECT c.theo_id,
               c.reel_id,
               c.retard_sec,
               c.ecart_abs_sec
        FROM #candidats c
        WHERE NOT EXISTS (
                  SELECT 1 FROM #apparies a WHERE a.theo_id = c.theo_id
              )
          AND NOT EXISTS (
                  SELECT 1 FROM #apparies a WHERE a.reel_id = c.reel_id
              )
    ),
    classes AS (
        SELECT a.*,
               ROW_NUMBER() OVER (
                   PARTITION BY a.theo_id
                   ORDER BY a.ecart_abs_sec, a.reel_id
               ) AS rang_cote_theorique,
               ROW_NUMBER() OVER (
                   PARTITION BY a.reel_id
                   ORDER BY a.ecart_abs_sec, a.theo_id
               ) AS rang_cote_reel
        FROM actifs a
    )
    INSERT INTO #apparies
        (theo_id, reel_id, retard_sec, ecart_abs_sec,
         iteration_appariement)
    SELECT theo_id,
           reel_id,
           retard_sec,
           ecart_abs_sec,
           @iteration
    FROM classes
    WHERE rang_cote_theorique = 1
      AND rang_cote_reel      = 1;

    SET @nb_ajoutes = @@ROWCOUNT;
END;

/*=============================================================================
  5. Table de comparaison exhaustive
=============================================================================*/

BEGIN TRY
    BEGIN TRANSACTION;

    DROP TABLE IF EXISTS dbo.int_appariement;

    CREATE TABLE dbo.int_appariement (
        appariement_id         BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        statut_appariement     VARCHAR(30)  NOT NULL,
        date_service           DATE         NOT NULL,
        feed_version           VARCHAR(50)  NOT NULL,
        line_id                VARCHAR(50)  NOT NULL,
        point_id               VARCHAR(50)  NOT NULL,
        stop_id                VARCHAR(50)  NULL,
        trip_id                VARCHAR(50)  NULL,
        trip_headsign          VARCHAR(255) NULL,
        destination_rt         VARCHAR(100) NULL,
        stop_sequence          INT          NULL,
        passage_num_reel       BIGINT       NULL,
        passage_theorique      DATETIME2    NULL,
        passage_reel_estime    DATETIME2    NULL,
        premiere_obs           DATETIME2    NULL,
        derniere_obs           DATETIME2    NULL,
        retard_sec             INT          NULL,
        ecart_abs_sec          INT          NULL,
        nb_obs                 INT          NULL,
        fraicheur_sec          INT          NULL,
        tolerance_sec          INT          NOT NULL,
        iteration_appariement  INT          NULL
    );

    /* 5a. Couples apparies */
    INSERT INTO dbo.int_appariement (
        statut_appariement, date_service, feed_version, line_id, point_id,
        stop_id, trip_id, trip_headsign, destination_rt, stop_sequence,
        passage_num_reel, passage_theorique, passage_reel_estime,
        premiere_obs, derniere_obs, retard_sec, ecart_abs_sec,
        nb_obs, fraicheur_sec, tolerance_sec, iteration_appariement
    )
    SELECT
        'apparie',
        t.date_service,
        t.feed_version,
        t.line_id,
        t.point_id,
        t.stop_id,
        t.trip_id,
        t.trip_headsign,
        r.destination_rt,
        t.stop_sequence,
        r.passage_num,
        t.arrivee_theorique,
        r.arrivee_estimee,
        r.premiere_obs,
        r.derniere_obs,
        a.retard_sec,
        a.ecart_abs_sec,
        r.nb_obs,
        r.fraicheur_sec,
        t.tolerance_sec,
        a.iteration_appariement
    FROM #apparies a
    JOIN #theorique t ON t.theo_id = a.theo_id
    JOIN #reel      r ON r.reel_id = a.reel_id;

    /* 5b. Passages theoriques sans reel retenu */
    INSERT INTO dbo.int_appariement (
        statut_appariement, date_service, feed_version, line_id, point_id,
        stop_id, trip_id, trip_headsign, destination_rt, stop_sequence,
        passage_num_reel, passage_theorique, passage_reel_estime,
        premiere_obs, derniere_obs, retard_sec, ecart_abs_sec,
        nb_obs, fraicheur_sec, tolerance_sec, iteration_appariement
    )
    SELECT
        'theorique_non_apparie',
        t.date_service,
        t.feed_version,
        t.line_id,
        t.point_id,
        t.stop_id,
        t.trip_id,
        t.trip_headsign,
        NULL,
        t.stop_sequence,
        NULL,
        t.arrivee_theorique,
        NULL,
        NULL,
        NULL,
        NULL,
        NULL,
        NULL,
        NULL,
        t.tolerance_sec,
        NULL
    FROM #theorique t
    WHERE NOT EXISTS (
        SELECT 1 FROM #apparies a WHERE a.theo_id = t.theo_id
    );

    /* 5c. Passages reels sans theorique retenu */
    INSERT INTO dbo.int_appariement (
        statut_appariement, date_service, feed_version, line_id, point_id,
        stop_id, trip_id, trip_headsign, destination_rt, stop_sequence,
        passage_num_reel, passage_theorique, passage_reel_estime,
        premiere_obs, derniere_obs, retard_sec, ecart_abs_sec,
        nb_obs, fraicheur_sec, tolerance_sec, iteration_appariement
    )
    SELECT
        'reel_non_apparie',
        r.date_service,
        r.feed_version,
        r.line_id,
        r.point_id,
        NULL,
        NULL,
        r.trip_headsign,
        r.destination_rt,
        NULL,
        r.passage_num,
        NULL,
        r.arrivee_estimee,
        r.premiere_obs,
        r.derniere_obs,
        NULL,
        NULL,
        r.nb_obs,
        r.fraicheur_sec,
        r.tolerance_sec,
        NULL
    FROM #reel r
    WHERE NOT EXISTS (
        SELECT 1 FROM #apparies a WHERE a.reel_id = r.reel_id
    );

    CREATE INDEX ix_int_appariement_analyse
        ON dbo.int_appariement
           (line_id, date_service, point_id, statut_appariement)
        INCLUDE (trip_id, trip_headsign, passage_theorique,
                 passage_reel_estime, retard_sec, ecart_abs_sec);

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;
    THROW;
END CATCH;

/*=============================================================================
  6. Controles a lire apres l'execution
=============================================================================*/

-- 6.1 Cohérence des volumes
SELECT
    (SELECT COUNT(*) FROM #theorique) AS passages_theoriques,
    (SELECT COUNT(*) FROM #reel)      AS passages_reels_filtres,
    (SELECT COUNT(*) FROM #apparies)  AS passages_apparies,
    (SELECT COUNT(*) FROM #theorique)
        - (SELECT COUNT(*) FROM #apparies) AS theoriques_non_apparies,
    (SELECT COUNT(*) FROM #reel)
        - (SELECT COUNT(*) FROM #apparies) AS reels_non_apparies;

-- 6.2 Répartition des statuts
SELECT statut_appariement,
       COUNT(*) AS nb_passages,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))
           AS pct_des_lignes_de_sortie
FROM dbo.int_appariement
GROUP BY statut_appariement
ORDER BY nb_passages DESC;

-- 6.2b Taux de couverture avec les bons dénominateurs
SELECT
    CAST(100.0 * (SELECT COUNT(*) FROM #apparies)
         / NULLIF((SELECT COUNT(*) FROM #theorique), 0)
         AS DECIMAL(5,2)) AS pct_theoriques_apparies,
    CAST(100.0 * ((SELECT COUNT(*) FROM #theorique)
                  - (SELECT COUNT(*) FROM #apparies))
         / NULLIF((SELECT COUNT(*) FROM #theorique), 0)
         AS DECIMAL(5,2)) AS pct_theoriques_non_apparies,
    CAST(100.0 * (SELECT COUNT(*) FROM #apparies)
         / NULLIF((SELECT COUNT(*) FROM #reel), 0)
         AS DECIMAL(5,2)) AS pct_reels_apparies,
    CAST(100.0 * ((SELECT COUNT(*) FROM #reel)
                  - (SELECT COUNT(*) FROM #apparies))
         / NULLIF((SELECT COUNT(*) FROM #reel), 0)
         AS DECIMAL(5,2)) AS pct_reels_non_apparies;

-- 6.3 Résumé du retard : négatif = avance ; positif = retard
SELECT COUNT(*) AS nb_apparies,
       CAST(AVG(CAST(retard_sec AS DECIMAL(12,2))) AS DECIMAL(12,2))
           AS retard_moyen_sec,
       MIN(retard_sec) AS avance_max_sec,
       MAX(retard_sec) AS retard_max_sec,
       CAST(AVG(CAST(ecart_abs_sec AS DECIMAL(12,2))) AS DECIMAL(12,2))
           AS ecart_absolu_moyen_sec
FROM dbo.int_appariement
WHERE statut_appariement = 'apparie';

-- 6.4 Médiane du retard et 90e percentile de l'écart absolu
SELECT TOP (1)
       CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY retard_sec)
            OVER () AS DECIMAL(12,2)) AS retard_median_sec,
       CAST(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY ecart_abs_sec)
            OVER () AS DECIMAL(12,2)) AS p90_ecart_absolu_sec
FROM dbo.int_appariement
WHERE statut_appariement = 'apparie';

-- 6.5 Comparatif lisible, ligne par ligne
SELECT date_service,
       line_id,
       point_id,
       stop_id,
       trip_id,
       trip_headsign,
       passage_theorique,
       passage_reel_estime,
       retard_sec,
       ecart_abs_sec,
       nb_obs,
       fraicheur_sec
FROM dbo.int_appariement
WHERE statut_appariement = 'apparie'
ORDER BY date_service, point_id, passage_theorique;

-- 6.6 Le nombre d'observations est-il lié au retard mesuré ?
SELECT
    CASE WHEN nb_obs = 2 THEN '2'
         WHEN nb_obs = 3 THEN '3'
         WHEN nb_obs BETWEEN 4 AND 5 THEN '4-5'
         ELSE '6+' END AS classe_nb_obs,
    COUNT(*) AS nb_apparies,
    CAST(AVG(CAST(retard_sec AS DECIMAL(12,2))) AS DECIMAL(12,2))
        AS retard_moyen_sec,
    CAST(AVG(CAST(ecart_abs_sec AS DECIMAL(12,2))) AS DECIMAL(12,2))
        AS ecart_absolu_moyen_sec,
    CAST(100.0 * SUM(CASE WHEN retard_sec < 0 THEN 1 ELSE 0 END)
         / COUNT(*) AS DECIMAL(5,2)) AS pct_en_avance
FROM dbo.int_appariement
WHERE statut_appariement = 'apparie'
GROUP BY CASE WHEN nb_obs = 2 THEN '2'
              WHEN nb_obs = 3 THEN '3'
              WHEN nb_obs BETWEEN 4 AND 5 THEN '4-5'
              ELSE '6+' END
ORDER BY classe_nb_obs;

-- 6.7 Les appariements des tours tardifs sont-ils plus éloignés ?
SELECT iteration_appariement,
       COUNT(*) AS nb_apparies,
       CAST(AVG(CAST(ecart_abs_sec AS DECIMAL(12,2))) AS DECIMAL(12,2))
           AS ecart_absolu_moyen_sec,
       MAX(ecart_abs_sec) AS ecart_absolu_max_sec
FROM dbo.int_appariement
WHERE statut_appariement = 'apparie'
GROUP BY iteration_appariement
ORDER BY iteration_appariement;

-- 6.8 Concentration des non-appariés par arrêt et destination canonique
SELECT TOP (30)
       statut_appariement,
       point_id,
       stop_id,
       trip_headsign,
       COUNT(*) AS nb_passages
FROM dbo.int_appariement
WHERE statut_appariement <> 'apparie'
GROUP BY statut_appariement, point_id, stop_id, trip_headsign
ORDER BY nb_passages DESC;

/* ANALYSE DE SENSIBILITE
   La tolerance n'est plus un scalaire de ce script : elle est figee
   dans dbo.ref_tolerance_ligne. Pour tester un autre calibrage, modifier
   @plafond_sec / @plancher_sec dans 44_ref_tolerance_ligne.sql, relancer
   ce script-ci, et comparer. Ne JAMAIS editer ref_tolerance_ligne a la
   main : la valeur doit rester reproductible depuis un script numerote.

   Sensibilite mesuree le 24/08 sur la ligne 25 (T scalaire) :
     T=120 -> 55 331   T=240 -> 63 568   T=300 -> 64 263   T=600 -> 64 520
   Le rendement s'effondre apres 240 s : +695 puis +257 couples.
*/


/*=============================================================================
  7. Controle de non-regression du 27/08 - passage a est_observable
  ----------------------------------------------------------------------------
  Attendu SUR LA LIGNE 25 :

    passages theoriques      60 541   (etait 60 653 : -112, les arrivees
                                       terminales a Buyl que l'ancienne
                                       exclusion nominative ne voyait pas)
    passages reels filtres   58 631   (inchange : rien n'a bouge cote reel)
    apparies                 57 415   (inchange, ou tres proche)
    taux d'appariement       94,84 %  (etait 94,66 %)

  ⚠️ Si "apparies" bouge de plus de quelques unites, ce n'est PAS le
  marquage : cela signifierait que des passages retires servaient de
  partenaires a d'autres theoriques.

  ⚠️ Si "passages reels filtres" bouge, quelque chose d'autre a change.
=============================================================================*/

SELECT
    passages_theoriques    = (SELECT COUNT(*) FROM #theorique),
    passages_reels_filtres = (SELECT COUNT(*) FROM #reel),
    apparies               = (SELECT COUNT(*) FROM #apparies),
    taux_appariement       = CAST(100.0 * (SELECT COUNT(*) FROM #apparies)
                                  / NULLIF((SELECT COUNT(*) FROM #theorique), 0)
                                  AS DECIMAL(5,2)),
    ecart_vs_ancien        = 60653 - (SELECT COUNT(*) FROM #theorique);


-- 7.2 La tolerance appliquee est-elle bien celle attendue ?
-- Sur la ligne 25 : 300 s (etait 240 s). Le taux d'appariement MONTE.
SELECT DISTINCT line_id, tolerance_sec
FROM dbo.int_appariement
ORDER BY line_id;


-- 7.3 Combien de couples doivent leur existence a l'elargissement ?
-- Ce sont ceux dont l'ecart absolu depasse l'ancienne tolerance de 240 s.
-- Ils sont, par construction, les moins surs de tous : a surveiller si
-- leur poids devient important.
SELECT
    classe = CASE WHEN ecart_abs_sec <= 240 THEN '1_sous_ancien_seuil'
                  ELSE '2_gagnes_par_elargissement' END,
    nb  = COUNT(*),
    pct = CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))
FROM dbo.int_appariement
WHERE statut_appariement = 'apparie'
GROUP BY CASE WHEN ecart_abs_sec <= 240 THEN '1_sous_ancien_seuil'
              ELSE '2_gagnes_par_elargissement' END
ORDER BY classe;


-- 7.1 Plus aucun theorique non apparie ne doit etre un terminus muet.
-- Les 30 premieres concentrations : Rogier et Buyl doivent avoir DISPARU
-- de cette liste. Ce qui reste est du non-appariement a instruire.
SELECT TOP (30)
       point_id,
       trip_headsign,
       nb_passages = COUNT(*)
FROM dbo.int_appariement
WHERE statut_appariement = 'theorique_non_apparie'
GROUP BY point_id, trip_headsign
ORDER BY nb_passages DESC;
