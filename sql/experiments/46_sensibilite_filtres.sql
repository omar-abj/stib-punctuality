/*=============================================================================
  TFE STIB - 20_transform/46_sensibilite_filtres.sql
  ----------------------------------------------------------------------------
  OBJET : mesurer le COUT des filtres de qualite appliques au vivier reel
          (nb_obs >= 2 ET fraicheur_sec BETWEEN -120 AND 180) sur le taux
          d'appariement, sur la ponctualite et sur la STABILITE des couples.

  POURQUOI CE SCRIPT EXISTE
  ----------------------------------------------------------------------------
  Le diagnostic du 27/08 a montre que sur 3 238 theoriques non apparies :
      -   496 avaient a proximite un reel ecarte par nb_obs >= 2
      -   349 avaient a proximite un reel ecarte par la fraicheur
  Soit 845 appariements potentiellement perdus par les filtres, c'est-a-dire
  1,40 point du KPI principal. Les filtres sont donc un ARBITRAGE dont le prix
  n'avait jamais ete mesure. Ce script le mesure.

  ENTREES  : int_passage_theorique, wrk_passages, ref_feed_periode,
             map_destination  (identiques a Ligne_25.sql)
  SORTIE   : dbo.int_appariement_sensib   (une colonne 'variante' en plus)

  NON DESTRUCTIF : dbo.int_appariement N'EST PAS TOUCHEE. fact_ecart et
                   93_checks_fact_ecart.sql restent rejouables a tout moment.

  IDEMPOTENT : la table de sortie est reconstruite integralement a chaque
               execution complete.

  Auteur : Omar
  Base   : TFE_STIB
=============================================================================*/

USE TFE_STIB;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

/*=============================================================================
  0. PARAMETRES INVARIANTS
  ----------------------------------------------------------------------------
  Tout ce qui n'est pas le filtre teste doit rester STRICTEMENT identique a
  Ligne_25.sql, sinon la comparaison ne mesure plus rien.

  ATTENTION : 33300 s = 09:15:00  et  49500 s = 13:45:00.
  (Les commentaires de Ligne_25.sql annoncaient 09:00 / 14:00 : ils datent
   d'avant le resserrement de la fenetre analytique, cf. §14bis.)
=============================================================================*/

DECLARE @ligne         VARCHAR(50) = '25';
DECLARE @sec_debut     INT         = 33300;   -- 09:15:00 inclus
DECLARE @sec_fin       INT         = 49500;   -- 13:45:00 exclu
DECLARE @tolerance_sec INT         = 240;     -- 4 minutes, seuil valide


/*=============================================================================
  1. LE PLAN D'EXPERIENCE
  ----------------------------------------------------------------------------
  Plan factoriel 2x2 : deux facteurs (nb_obs, fraicheur), deux niveaux
  chacun (strict, relache). V1 et V2 isolent chaque facteur ; V3 mesure
  l'interaction eventuelle.

  Les quatre variantes tournent dans UNE SEULE execution, sur le MEME
  #theorique construit une seule fois. C'est ce qui garantit qu'aucun autre
  parametre n'a bouge entre deux mesures.
=============================================================================*/

DROP TABLE IF EXISTS #variantes;

CREATE TABLE #variantes (
    variante      VARCHAR(20) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY,
    libelle       VARCHAR(80) COLLATE DATABASE_DEFAULT NOT NULL,
    nb_obs_min    INT NOT NULL,
    fraicheur_min INT NOT NULL,
    fraicheur_max INT NOT NULL
);

INSERT INTO #variantes (variante, libelle, nb_obs_min, fraicheur_min, fraicheur_max)
VALUES
    ('V0', 'reference : filtres actuels',      2, -120, 180),
    ('V1', 'nb_obs relache (>= 1)',            1, -120, 180),
    ('V2', 'fraicheur relachee (-300..600)',   2, -300, 600),
    ('V3', 'les deux relaches',                1, -300, 600);


/*=============================================================================
  2. LE VIVIER THEORIQUE - construit UNE SEULE FOIS
  ----------------------------------------------------------------------------
  Invariant par construction : aucun des filtres testes ne porte sur le
  theorique. Le sortir de la boucle garantit que theo_id designe le meme
  passage dans les quatre variantes.

  L'exclusion 0539/ROGIER est reprise a l'identique de Ligne_25.sql.
  ATTENTION : elle utilise est_dernier_arret, dont le §3quater dit qu'il ne
  doit pas etre utilise. Conserve TEL QUEL ici pour la comparabilite. A
  traiter dans un chantier separe.
=============================================================================*/

DROP TABLE IF EXISTS #theorique;

SELECT
    ROW_NUMBER() OVER (
        ORDER BY th.feed_version, th.date_service, th.line_id, th.point_id,
                 th.trip_headsign, th.arrivee_theorique, th.trip_id,
                 th.stop_id, th.stop_sequence
    ) AS theo_id,
    th.date_service, th.feed_version, th.line_id, th.point_id,
    th.stop_id, th.trip_id, th.trip_headsign, th.stop_sequence,
    th.arrivee_theorique
INTO #theorique
FROM dbo.int_passage_theorique th
WHERE th.point_id IS NOT NULL
  AND NOT (
      th.est_dernier_arret = 1
      AND th.point_id      = '0539'
      AND th.trip_headsign = 'ROGIER'
  )
  AND th.arrivee_sec >= @sec_debut
  AND th.arrivee_sec <  @sec_fin
  AND (@ligne IS NULL OR th.line_id = @ligne)
OPTION (RECOMPILE);

CREATE UNIQUE CLUSTERED INDEX ix_theorique_id ON #theorique (theo_id);
CREATE INDEX ix_theorique_groupe ON #theorique
       (feed_version, date_service, line_id, point_id, trip_headsign,
        arrivee_theorique);


/*=============================================================================
  3. LA TABLE DE SORTIE
  ----------------------------------------------------------------------------
  Une seule table pour les quatre variantes, discriminees par la colonne
  'variante'. Un scenario = un sous-ensemble, pas un objet separe : cela
  rend la comparaison ecrivable en une seule requete.
=============================================================================*/

DROP TABLE IF EXISTS dbo.int_appariement_sensib;

CREATE TABLE dbo.int_appariement_sensib (
    sensib_id              BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    variante               VARCHAR(20)  NOT NULL,
    statut_appariement     VARCHAR(30)  NOT NULL,
    date_service           DATE         NOT NULL,
    feed_version           VARCHAR(50)  NOT NULL,
    line_id                VARCHAR(50)  NOT NULL,
    point_id               VARCHAR(50)  NOT NULL,
    stop_id                VARCHAR(50)  NULL,
    trip_id                VARCHAR(50)  NULL,
    trip_headsign          VARCHAR(255) NULL,
    destination_rt         VARCHAR(100) NULL,
    passage_num_reel       BIGINT       NULL,
    passage_theorique      DATETIME2    NULL,
    passage_reel_estime    DATETIME2    NULL,
    retard_sec             INT          NULL,
    ecart_abs_sec          INT          NULL,
    nb_obs                 INT          NULL,
    fraicheur_sec          INT          NULL,
    iteration_appariement  INT          NULL
);


/*=============================================================================
  4. LA BOUCLE SUR LES VARIANTES
=============================================================================*/

DECLARE @variante      VARCHAR(20);
DECLARE @nb_obs_min    INT;
DECLARE @fraicheur_min INT;
DECLARE @fraicheur_max INT;

DECLARE cur_var CURSOR LOCAL FAST_FORWARD FOR
    SELECT variante, nb_obs_min, fraicheur_min, fraicheur_max
    FROM #variantes ORDER BY variante;

OPEN cur_var;
FETCH NEXT FROM cur_var INTO @variante, @nb_obs_min, @fraicheur_min, @fraicheur_max;

WHILE @@FETCH_STATUS = 0
BEGIN

    PRINT '=== Variante ' + @variante
        + ' : nb_obs >= ' + CAST(@nb_obs_min AS VARCHAR(10))
        + ', fraicheur ' + CAST(@fraicheur_min AS VARCHAR(10))
        + ' .. ' + CAST(@fraicheur_max AS VARCHAR(10)) + ' ===';

    /*---------------------------------------------------------------------
      4a. Vivier reel - SEUL ENDROIT OU LES PARAMETRES INTERVIENNENT
    ---------------------------------------------------------------------*/
    DROP TABLE IF EXISTS #reel;

    ;WITH reel_source AS (
        SELECT
            f.feed_version,
            CAST(p.derniere_obs AS DATE) AS date_service,
            p.line_id, p.point_id,
            p.destination AS destination_rt,
            m.trip_headsign,
            p.passage_num, p.premiere_obs, p.derniere_obs, p.arrivee_estimee,
            p.nb_obs,
            DATEDIFF(SECOND, p.derniere_obs, p.arrivee_estimee) AS fraicheur_sec
        FROM dbo.wrk_passages p
        JOIN dbo.ref_feed_periode f
          ON CAST(p.derniere_obs AS DATE) BETWEEN f.date_debut AND f.date_fin
        JOIN dbo.map_destination m
          ON m.feed_version   = f.feed_version
         AND m.line_id        = p.line_id
         AND m.destination_rt = p.destination
         AND m.type_mapping IN ('exact', 'devie', 'abrege')
        WHERE p.nb_obs >= @nb_obs_min
          AND DATEDIFF(SECOND, p.derniere_obs, p.arrivee_estimee)
              BETWEEN @fraicheur_min AND @fraicheur_max
          AND (@ligne IS NULL OR p.line_id = @ligne)
    )
    SELECT
        ROW_NUMBER() OVER (
            ORDER BY r.feed_version, r.date_service, r.line_id, r.point_id,
                     r.trip_headsign, r.arrivee_estimee, r.derniere_obs,
                     r.destination_rt, r.passage_num
        ) AS reel_id,
        r.feed_version, r.date_service, r.line_id, r.point_id,
        r.destination_rt, r.trip_headsign, r.passage_num,
        r.premiere_obs, r.derniere_obs, r.arrivee_estimee,
        r.nb_obs, r.fraicheur_sec
    INTO #reel
    FROM reel_source r
    WHERE r.arrivee_estimee >= DATEADD(SECOND, @sec_debut, CAST(r.date_service AS DATETIME2))
      AND r.arrivee_estimee <  DATEADD(SECOND, @sec_fin,   CAST(r.date_service AS DATETIME2))
    OPTION (RECOMPILE);

    CREATE UNIQUE CLUSTERED INDEX ix_reel_id ON #reel (reel_id);
    CREATE INDEX ix_reel_groupe ON #reel
           (feed_version, date_service, line_id, point_id, trip_headsign,
            arrivee_estimee);

    /*---------------------------------------------------------------------
      4b. Couples candidats - identique a Ligne_25.sql
    ---------------------------------------------------------------------*/
    DROP TABLE IF EXISTS #candidats;

    SELECT
        t.theo_id, r.reel_id,
        DATEDIFF(SECOND, t.arrivee_theorique, r.arrivee_estimee) AS retard_sec,
        ABS(DATEDIFF(SECOND, t.arrivee_theorique, r.arrivee_estimee)) AS ecart_abs_sec
    INTO #candidats
    FROM #theorique t
    JOIN #reel r
      ON r.feed_version  = t.feed_version
     AND r.date_service  = t.date_service
     AND r.line_id       = t.line_id
     AND r.point_id      = t.point_id
     AND r.trip_headsign = t.trip_headsign
    WHERE ABS(DATEDIFF(SECOND, t.arrivee_theorique, r.arrivee_estimee)) <= @tolerance_sec;

    CREATE INDEX ix_candidats_theo ON #candidats (theo_id, ecart_abs_sec, reel_id);
    CREATE INDEX ix_candidats_reel ON #candidats (reel_id, ecart_abs_sec, theo_id);

    /*---------------------------------------------------------------------
      4c. Glouton reciproque iteratif - identique a Ligne_25.sql
    ---------------------------------------------------------------------*/
    DROP TABLE IF EXISTS #apparies;

    CREATE TABLE #apparies (
        theo_id               BIGINT NOT NULL PRIMARY KEY,
        reel_id               BIGINT NOT NULL UNIQUE,
        retard_sec            INT    NOT NULL,
        ecart_abs_sec         INT    NOT NULL,
        iteration_appariement INT    NOT NULL
    );

    DECLARE @iteration  INT = 0;
    DECLARE @nb_ajoutes INT = 1;

    WHILE @nb_ajoutes > 0
    BEGIN
        SET @iteration += 1;

        ;WITH actifs AS (
            SELECT c.theo_id, c.reel_id, c.retard_sec, c.ecart_abs_sec
            FROM #candidats c
            WHERE NOT EXISTS (SELECT 1 FROM #apparies a WHERE a.theo_id = c.theo_id)
              AND NOT EXISTS (SELECT 1 FROM #apparies a WHERE a.reel_id = c.reel_id)
        ),
        classes AS (
            SELECT a.*,
                   ROW_NUMBER() OVER (PARTITION BY a.theo_id
                                      ORDER BY a.ecart_abs_sec, a.reel_id) AS rang_cote_theorique,
                   ROW_NUMBER() OVER (PARTITION BY a.reel_id
                                      ORDER BY a.ecart_abs_sec, a.theo_id) AS rang_cote_reel
            FROM actifs a
        )
        INSERT INTO #apparies (theo_id, reel_id, retard_sec, ecart_abs_sec, iteration_appariement)
        SELECT theo_id, reel_id, retard_sec, ecart_abs_sec, @iteration
        FROM classes
        WHERE rang_cote_theorique = 1 AND rang_cote_reel = 1;

        SET @nb_ajoutes = @@ROWCOUNT;
    END;

    SET @iteration = 0;
    SET @nb_ajoutes = 1;

    /*---------------------------------------------------------------------
      4d. Ecriture des trois populations
    ---------------------------------------------------------------------*/
    INSERT INTO dbo.int_appariement_sensib (
        variante, statut_appariement, date_service, feed_version, line_id,
        point_id, stop_id, trip_id, trip_headsign, destination_rt,
        passage_num_reel, passage_theorique, passage_reel_estime,
        retard_sec, ecart_abs_sec, nb_obs, fraicheur_sec, iteration_appariement)
    SELECT @variante, 'apparie', t.date_service, t.feed_version, t.line_id,
           t.point_id, t.stop_id, t.trip_id, t.trip_headsign, r.destination_rt,
           r.passage_num, t.arrivee_theorique, r.arrivee_estimee,
           a.retard_sec, a.ecart_abs_sec, r.nb_obs, r.fraicheur_sec,
           a.iteration_appariement
    FROM #apparies a
    JOIN #theorique t ON t.theo_id = a.theo_id
    JOIN #reel      r ON r.reel_id = a.reel_id;

    INSERT INTO dbo.int_appariement_sensib (
        variante, statut_appariement, date_service, feed_version, line_id,
        point_id, stop_id, trip_id, trip_headsign, destination_rt,
        passage_num_reel, passage_theorique, passage_reel_estime,
        retard_sec, ecart_abs_sec, nb_obs, fraicheur_sec, iteration_appariement)
    SELECT @variante, 'theorique_non_apparie', t.date_service, t.feed_version,
           t.line_id, t.point_id, t.stop_id, t.trip_id, t.trip_headsign,
           NULL, NULL, t.arrivee_theorique, NULL, NULL, NULL, NULL, NULL, NULL
    FROM #theorique t
    WHERE NOT EXISTS (SELECT 1 FROM #apparies a WHERE a.theo_id = t.theo_id);

    INSERT INTO dbo.int_appariement_sensib (
        variante, statut_appariement, date_service, feed_version, line_id,
        point_id, stop_id, trip_id, trip_headsign, destination_rt,
        passage_num_reel, passage_theorique, passage_reel_estime,
        retard_sec, ecart_abs_sec, nb_obs, fraicheur_sec, iteration_appariement)
    SELECT @variante, 'reel_non_apparie', r.date_service, r.feed_version,
           r.line_id, r.point_id, NULL, NULL, r.trip_headsign, r.destination_rt,
           r.passage_num, NULL, r.arrivee_estimee, NULL, NULL,
           r.nb_obs, r.fraicheur_sec, NULL
    FROM #reel r
    WHERE NOT EXISTS (SELECT 1 FROM #apparies a WHERE a.reel_id = r.reel_id);

    FETCH NEXT FROM cur_var INTO @variante, @nb_obs_min, @fraicheur_min, @fraicheur_max;
END;

CLOSE cur_var;
DEALLOCATE cur_var;

CREATE INDEX ix_sensib_analyse
    ON dbo.int_appariement_sensib (variante, statut_appariement)
    INCLUDE (date_service, trip_id, stop_id, passage_reel_estime, retard_sec, ecart_abs_sec);
GO


/*=============================================================================
  5. CONTROLES
=============================================================================*/

PRINT '=== 5.1 - Conservation du volume theorique ===';
-- Le nombre de theoriques doit etre IDENTIQUE dans les 4 variantes (60 653).
-- S'il varie, un parametre autre que les filtres a bouge : tout est a jeter.
SELECT variante,
       theoriques = SUM(CASE WHEN statut_appariement <> 'reel_non_apparie' THEN 1 ELSE 0 END),
       reels      = SUM(CASE WHEN statut_appariement <> 'theorique_non_apparie' THEN 1 ELSE 0 END)
FROM dbo.int_appariement_sensib
GROUP BY variante
ORDER BY variante;
GO


PRINT '=== 5.2 - Le tableau de comparaison ===';
-- Plafonds predits avant mesure (diagnostic du 27/08) :
--   V1 <= 95,48 %   V2 <= 95,24 %   V3 <= 96,05 %
-- Un depassement signifie que le TEST est faux, pas que le filtre etait mauvais.
WITH base AS (
    SELECT variante,
           theoriques = SUM(CASE WHEN statut_appariement <> 'reel_non_apparie' THEN 1 ELSE 0 END),
           reels      = SUM(CASE WHEN statut_appariement <> 'theorique_non_apparie' THEN 1 ELSE 0 END),
           apparies   = SUM(CASE WHEN statut_appariement = 'apparie' THEN 1 ELSE 0 END),
           reels_seuls= SUM(CASE WHEN statut_appariement = 'reel_non_apparie' THEN 1 ELSE 0 END)
    FROM dbo.int_appariement_sensib
    GROUP BY variante
),
stats AS (
    SELECT DISTINCT
           variante,
           mediane_retard = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY CAST(retard_sec AS FLOAT))
                            OVER (PARTITION BY variante),
           p90_ecart_abs  = PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY CAST(ecart_abs_sec AS FLOAT))
                            OVER (PARTITION BY variante)
    FROM dbo.int_appariement_sensib
    WHERE statut_appariement = 'apparie'
)
SELECT
    v.variante, v.libelle,
    b.reels                AS vivier_reel,
    b.apparies,
    taux_appariement = CAST(100.0 * b.apparies / b.theoriques AS DECIMAL(5,2)),
    taux_ajout       = CAST(100.0 * b.reels_seuls / b.reels   AS DECIMAL(5,2)),
    s.mediane_retard,
    s.p90_ecart_abs
FROM #variantes v
JOIN base  b ON b.variante = v.variante
JOIN stats s ON s.variante = v.variante
ORDER BY v.variante;
GO


PRINT '=== 5.3 - LA STABILITE : combien de couples changent de partenaire ? ===';
-- LE controle decisif. Un taux qui monte pendant que les couples se
-- reorganisent n'est pas une amelioration, c'est un autre appariement.
--
-- Jointure sur la cle NATURELLE du theorique (date_service, trip_id, stop_id),
-- grain de int_passage_theorique. JAMAIS sur reel_id : ROW_NUMBER renumerote
-- tout le vivier des qu'une ligne est ajoutee, donc reel_id ne designe pas le
-- meme passage d'une variante a l'autre.
SELECT
    v.variante,
    couples_v0_conserves = SUM(CASE WHEN v.passage_reel_estime = r.passage_reel_estime THEN 1 ELSE 0 END),
    couples_v0_modifies  = SUM(CASE WHEN v.passage_reel_estime <> r.passage_reel_estime THEN 1 ELSE 0 END),
    couples_v0_perdus    = SUM(CASE WHEN v.passage_reel_estime IS NULL THEN 1 ELSE 0 END),
    pct_modifies = CAST(100.0 * SUM(CASE WHEN v.passage_reel_estime <> r.passage_reel_estime
                                         THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2))
FROM dbo.int_appariement_sensib r
LEFT JOIN dbo.int_appariement_sensib v
       ON v.date_service = r.date_service
      AND v.trip_id      = r.trip_id
      AND v.stop_id      = r.stop_id
      AND v.variante     <> 'V0'
      AND v.statut_appariement = 'apparie'
WHERE r.variante = 'V0'
  AND r.statut_appariement = 'apparie'
  AND v.variante IS NOT NULL
GROUP BY v.variante
ORDER BY v.variante;
GO


PRINT '=== 5.4 - Non-regression : V0 doit reproduire int_appariement ===';
-- Si V0 ne redonne pas 57 415 / 3 238 / 1 216, le script de test differe du
-- script de reference et AUCUNE des trois autres variantes n'est lisible.
SELECT source = 'int_appariement (reference)', statut_appariement, nb = COUNT(*)
FROM dbo.int_appariement WHERE line_id = '25'
GROUP BY statut_appariement
UNION ALL
SELECT 'int_appariement_sensib V0', statut_appariement, COUNT(*)
FROM dbo.int_appariement_sensib WHERE variante = 'V0'
GROUP BY statut_appariement
ORDER BY statut_appariement, source;
GO
