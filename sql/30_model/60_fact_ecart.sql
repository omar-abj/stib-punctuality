-- =============================================================
-- 30_model/60_fact_ecart.sql
--
-- LA TABLE DE FAITS CENTRALE DU MODÈLE EN ÉTOILE
--
-- Grain : 1 ligne = 1 ÉVÉNEMENT DE PASSAGE à un arrêt, un jour donné.
--         Un événement est soit un passage attendu, soit un passage
--         observé, soit les deux réunis.
--
-- ⚠️ POURQUOI CE GRAIN ET PAS « arrêt × course × date » :
--    un passage réel non apparié n'a AUCUNE course théorique. Le grain
--    initialement prévu ne pouvait pas l'accueillir. Or le TAUX DE
--    NON-APPARIEMENT est le KPI PRINCIPAL du mémoire (§14bis) — il ne
--    peut pas vivre hors de la table de faits.
--
-- ⚠️ POURQUOI UNE SEULE TABLE ET PAS DEUX :
--    scinder appariés / non appariés obligerait à additionner des
--    dénominateurs venus de deux tables pour calculer le KPI principal.
--    Rendre difficile à calculer la mesure centrale serait un mauvais
--    arbitrage.
--
-- ⚠️ retard_sec EST CENSURÉ À ±tolerance_sec, VARIABLE SELON LA LIGNE
--    (de 205 à 300 s, voir ref_tolerance_ligne). Tout écart supérieur
--    devient un NON-APPARIÉ, pas un grand retard.
--    CONSÉQUENCE : les médianes et taux d'appariement BRUTS ne sont PAS
--    comparables entre lignes. Utiliser nb_conforme / nb_theorique.
--
-- Source      : int_appariement (§14bis, tolérance T = 240 s)
-- Dimensions  : dim_date, dim_heure, dim_ligne, dim_arret,
--               dim_desserte, dim_course, dim_meteo
-- Paramétré   : @ligne = '25', NULL = tout le réseau
-- Idempotent
-- =============================================================

DECLARE @ligne VARCHAR(10) = NULL;

DROP TABLE IF EXISTS #sens_reel;
DROP TABLE IF EXISTS fact_ecart;

-- =============================================================
-- 1. RÉSOUDRE LE SENS DES PASSAGES RÉELS NON APPARIÉS
--
--    Un réel non apparié n'a ni trip_id, ni stop_id, ni horaire
--    théorique — seulement point_id, line_id et destination_rt.
--    Or dim_desserte a pour clé (line_id, direction_id, racine) :
--    il faut donc reconstituer le sens.
--
--    Trois niveaux, du plus fiable au plus incertain :
--      1. La racine n'appartient qu'à un seul sens  -> ce sens
--      2. Racine ambiguë (terminus) + destination   -> sens déduit
--      3. Sinon                                     -> desserte_sk = -1
--
--    Mesuré sur la ligne 25 : le niveau 1 résout 49 points sur 51 ;
--    le niveau 2 résout les 19 lignes restantes (toutes sur 0539) ;
--    le niveau 3 ne sert jamais. Il est conservé pour la
--    retranscription, où d'autres lignes auront des cas que la 25 n'a pas.
-- =============================================================
;WITH racine_sens AS (
    -- Combien de sens par racine ? (0539 et 2351 = 2 sur la ligne 25)
    SELECT  line_id, stop_id_racine,
            COUNT(DISTINCT direction_id) AS n_sens,
            MIN(direction_id)            AS sens_unique
    FROM    dim_desserte
    WHERE   desserte_sk <> -1
    GROUP BY line_id, stop_id_racine
),
sens_par_destination AS (
    -- Sur un terminus, la destination annoncée désigne le sens.
    -- On s'appuie sur le trip_headsign majoritaire de chaque sens
    -- plutôt que sur une table de correspondance écrite à la main.
    SELECT  r.route_short_name AS line_id,
            t.trip_headsign,
            t.direction_id,
            ROW_NUMBER() OVER (PARTITION BY r.route_short_name, t.trip_headsign
                               ORDER BY COUNT(*) DESC, t.direction_id ASC) AS rang
    FROM        stg_trips  AS t
    INNER JOIN  stg_routes AS r ON  r.route_id     = t.route_id
                                AND r.feed_version = t.feed_version
    WHERE      (@ligne IS NULL OR r.route_short_name = @ligne)
    GROUP BY    r.route_short_name, t.trip_headsign, t.direction_id
)
SELECT      i.appariement_id,
            COALESCE(rs.sens_unique, sd.direction_id) AS direction_id_resolu,
            CASE WHEN rs.n_sens = 1        THEN 'racine'
                 WHEN sd.direction_id IS NOT NULL THEN 'destination'
                 ELSE                           'non_resolu'
            END AS methode_resolution
INTO        #sens_reel
FROM        int_appariement AS i
LEFT  JOIN  racine_sens     AS rs ON  rs.line_id        = i.line_id
                                  AND rs.stop_id_racine = i.point_id
                                  AND rs.n_sens         = 1
LEFT  JOIN  sens_par_destination AS sd ON  sd.line_id       = i.line_id
                                       AND sd.trip_headsign = i.destination_rt
                                       AND sd.rang          = 1
WHERE       i.statut_appariement = 'reel_non_apparie'
  AND      (@ligne IS NULL OR i.line_id = @ligne);

CREATE UNIQUE INDEX ix_sens_reel ON #sens_reel (appariement_id);

-- =============================================================
-- 2. LA TABLE DE FAITS
-- =============================================================
;WITH prepare AS (
    SELECT
        i.appariement_id,
        i.statut_appariement,
        i.date_service,
        i.feed_version,
        i.line_id,
        i.point_id,
        i.trip_id,
        i.destination_rt,
        i.trip_headsign,
        i.retard_sec,
        i.ecart_abs_sec,
        i.nb_obs,
        i.fraicheur_sec,
        i.tolerance_sec,

        -- Sens : celui de la course pour les appariés et les théoriques
        -- seuls (ils ont un trip_id) ; le sens résolu pour les réels seuls.
        COALESCE(t.direction_id, sr.direction_id_resolu) AS direction_id,
        sr.methode_resolution,

        -- Horaires en SECONDES DEPUIS MINUIT.
        -- Contrôlé (F3) : passage_theorique porte toujours la même date
        -- que date_service dans la fenêtre 09:15–13:45. En dehors, une
        -- course franchissant minuit dépasserait 86 400 (piège n°5).
        CASE WHEN i.passage_theorique IS NOT NULL
             THEN DATEDIFF(SECOND, CAST(i.date_service AS DATETIME2), i.passage_theorique)
        END AS theorique_sec,
        CASE WHEN i.passage_reel_estime IS NOT NULL
             THEN DATEDIFF(SECOND, CAST(i.date_service AS DATETIME2), i.passage_reel_estime)
        END AS reel_sec
    FROM        int_appariement AS i
    LEFT  JOIN  stg_trips       AS t  ON  t.trip_id       = i.trip_id
                                      AND t.feed_version  = i.feed_version
    LEFT  JOIN  #sens_reel      AS sr ON  sr.appariement_id = i.appariement_id
    WHERE      (@ligne IS NULL OR i.line_id = @ligne)
),
horodate AS (
    SELECT  p.*,
            -- ⚠️ La FK vers dim_heure porte sur l'heure THÉORIQUE.
            --    Rattacher au créneau réel rendrait l'analyse circulaire :
            --    le retard déplacerait la donnée dans la dimension qui
            --    sert à le mesurer (§16.C).
            --    Les réels seuls n'ont pas de théorique : ils prennent
            --    leur créneau réel, signalé par heure_est_reelle = 1.
            COALESCE(p.theorique_sec, p.reel_sec) AS sec_pour_creneau,
            CAST(CASE WHEN p.theorique_sec IS NULL THEN 1 ELSE 0 END AS BIT)
                AS heure_est_reelle
    FROM    prepare AS p
)
SELECT
    ROW_NUMBER() OVER (ORDER BY h.date_service, h.line_id,
                                h.sec_pour_creneau, h.appariement_id) AS ecart_sk,

    -- ---------- Clés étrangères (7) ----------
    CAST(CONVERT(CHAR(8), h.date_service, 112) AS INT)   AS date_sk,
    COALESCE(dh.heure_sk, -1)                            AS heure_sk,
    COALESCE(dl.ligne_sk, -1)                            AS ligne_sk,
    COALESCE(da.arret_sk, -1)                            AS arret_sk,
    COALESCE(dd.desserte_sk, -1)                         AS desserte_sk,
    COALESCE(dc.course_sk, -1)                           AS course_sk,
    COALESCE(dm.meteo_sk, -1)                            AS meteo_sk,

    -- ---------- Compteurs additifs ----------
    -- Le KPI principal se calcule ainsi :
    --   taux d'appariement   = SUM(nb_apparie)   / SUM(nb_theorique)
    -- Additifs, donc agrégeables à n'importe quel niveau sans piège
    -- de contexte de filtre en DAX.
    CAST(CASE WHEN h.statut_appariement IN ('apparie','theorique_non_apparie')
              THEN 1 ELSE 0 END AS TINYINT)              AS nb_theorique,
    CAST(CASE WHEN h.statut_appariement IN ('apparie','reel_non_apparie')
              THEN 1 ELSE 0 END AS TINYINT)              AS nb_reel,
    CAST(CASE WHEN h.statut_appariement = 'apparie'
              THEN 1 ELSE 0 END AS TINYINT)              AS nb_apparie,
    CAST(CASE WHEN h.statut_appariement = 'theorique_non_apparie'
              THEN 1 ELSE 0 END AS TINYINT)              AS nb_theo_seul,
    CAST(CASE WHEN h.statut_appariement = 'reel_non_apparie'
              THEN 1 ELSE 0 END AS TINYINT)              AS nb_reel_seul,
        -- ---------- Conformite (KPI principal, decision du 27/08) ----------
    -- Fenetre STIB : -60 / +180 s. Asymetrique parce que l'avance est un
    -- probleme d'exploitation reconnu (gradient mesure le 27/08, §19.F).
    --
    -- SE CALCULE SUR LE THEORIQUE : taux = SUM(nb_conforme)/SUM(nb_theorique)
    -- Un passage non apparie est donc NON CONFORME, au meme titre qu'un
    -- passage apparie hors fenetre. C'est ce qui rend les lignes
    -- COMPARABLES malgre une tolerance T variable (option C, §19.E) :
    -- toutes ont T >= 180 s, donc +180 s est mesurable partout.
    CAST(CASE WHEN h.statut_appariement = 'apparie'
                   AND h.retard_sec BETWEEN -60 AND 180
              THEN 1 ELSE 0 END AS TINYINT)              AS nb_conforme,
    -- ---------- Mesures ----------
    h.theorique_sec,
    h.reel_sec,
    h.retard_sec,          -- ⚠️ CENSURÉ à ±tolerance_sec — voir en-tête
    h.ecart_abs_sec,
    h.tolerance_sec,

    -- ---------- Attributs de qualité (audit de confusion, §14bis) ----------
    h.nb_obs,
    h.fraicheur_sec,

    -- ---------- Attributs dégénérés ----------
    h.statut_appariement,
    h.heure_est_reelle,
    h.methode_resolution,  -- NULL sauf pour les réels seuls
    h.feed_version,
    h.destination_rt
INTO    fact_ecart
FROM        horodate AS h
LEFT  JOIN  dim_heure    AS dh ON  h.sec_pour_creneau BETWEEN dh.sec_debut AND dh.sec_fin
LEFT  JOIN  dim_ligne    AS dl ON  dl.line_id  = h.line_id
LEFT  JOIN  dim_arret    AS da ON  da.point_id = h.point_id
LEFT  JOIN  dim_desserte AS dd ON  dd.line_id        = h.line_id
                               AND dd.direction_id   = h.direction_id
                               AND dd.stop_id_racine = h.point_id
LEFT  JOIN  dim_course   AS dc ON  dc.feed_version = h.feed_version
                               AND dc.trip_id      = h.trip_id
LEFT  JOIN  dim_meteo    AS dm ON  dm.date_locale = h.date_service
                               AND dm.heure       = h.sec_pour_creneau / 3600;

-- =============================================================
-- 3. CONTRAINTES
-- =============================================================
-- ⚠️ SELECT INTO crée les colonnes issues d'expressions en NULL
--    et ne transporte aucune contrainte (piège n°42).
ALTER TABLE fact_ecart ALTER COLUMN ecart_sk    BIGINT  NOT NULL;
ALTER TABLE fact_ecart ALTER COLUMN date_sk     INT     NOT NULL;
ALTER TABLE fact_ecart ALTER COLUMN heure_sk    INT     NOT NULL;
ALTER TABLE fact_ecart ALTER COLUMN ligne_sk    BIGINT  NOT NULL;
ALTER TABLE fact_ecart ALTER COLUMN arret_sk    BIGINT  NOT NULL;
ALTER TABLE fact_ecart ALTER COLUMN desserte_sk BIGINT  NOT NULL;
ALTER TABLE fact_ecart ALTER COLUMN course_sk   BIGINT  NOT NULL;
ALTER TABLE fact_ecart ALTER COLUMN meteo_sk    BIGINT  NOT NULL;
GO
-- ⚠️ GO obligatoire : le batch est compilé avant d'être exécuté,
--    la PRIMARY KEY serait validée contre les colonnes AVANT
--    modification (piège n°43).

ALTER TABLE fact_ecart ADD CONSTRAINT pk_fact_ecart PRIMARY KEY (ecart_sk);

-- Intégrité référentielle : aucune FK ne peut être orpheline.
-- Les membres inconnus (-1) rendent ces contraintes tenables.
ALTER TABLE fact_ecart ADD CONSTRAINT fk_fact_date
    FOREIGN KEY (date_sk)     REFERENCES dim_date     (date_sk);
ALTER TABLE fact_ecart ADD CONSTRAINT fk_fact_heure
    FOREIGN KEY (heure_sk)    REFERENCES dim_heure    (heure_sk);
ALTER TABLE fact_ecart ADD CONSTRAINT fk_fact_ligne
    FOREIGN KEY (ligne_sk)    REFERENCES dim_ligne    (ligne_sk);
ALTER TABLE fact_ecart ADD CONSTRAINT fk_fact_arret
    FOREIGN KEY (arret_sk)    REFERENCES dim_arret    (arret_sk);
ALTER TABLE fact_ecart ADD CONSTRAINT fk_fact_desserte
    FOREIGN KEY (desserte_sk) REFERENCES dim_desserte (desserte_sk);
ALTER TABLE fact_ecart ADD CONSTRAINT fk_fact_course
    FOREIGN KEY (course_sk)   REFERENCES dim_course   (course_sk);
ALTER TABLE fact_ecart ADD CONSTRAINT fk_fact_meteo
    FOREIGN KEY (meteo_sk)    REFERENCES dim_meteo    (meteo_sk);

-- Index de parcours pour Power BI
CREATE INDEX ix_fact_date     ON fact_ecart (date_sk)     INCLUDE (nb_theorique, nb_apparie, retard_sec);
CREATE INDEX ix_fact_desserte ON fact_ecart (desserte_sk) INCLUDE (nb_theorique, nb_apparie, retard_sec);
CREATE INDEX ix_fact_heure    ON fact_ecart (heure_sk)    INCLUDE (nb_theorique, nb_apparie);
GO
