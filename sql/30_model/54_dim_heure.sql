-- =============================================================
-- 30_model/54_dim_heure.sql
--
-- Grain      : 1 ligne = 1 créneau de 15 minutes
-- Couverture : les 96 créneaux de la journée, avec deux drapeaux
--              distinguant la fenêtre de COLLECTE (09:00–14:00)
--              et la fenêtre ANALYTIQUE (09:15–13:45, §14bis)
-- Clé        : heure_sk = HHMM (915, 1345…) — lisible, triable
--
-- ⚠️ La FK depuis fact_ecart porte sur l'heure THÉORIQUE.
--    Rattacher au créneau réel rendrait l'analyse circulaire :
--    le retard déplacerait la donnée dans la dimension qui
--    sert à le mesurer.
-- Idempotent
-- =============================================================

DROP TABLE IF EXISTS dim_heure;

;WITH creneaux AS (
    SELECT 0 AS n
    UNION ALL
    SELECT n + 1 FROM creneaux WHERE n < 95      -- 96 créneaux de 15 min
),
base AS (
    SELECT  n,
            n * 900          AS sec_debut,       -- 900 s = 15 min
            n * 900 + 899    AS sec_fin,         -- borne INCLUSE
            n / 4            AS heure,
            (n % 4) * 15     AS minute
    FROM    creneaux
)
SELECT
    heure * 100 + minute                          AS heure_sk,
    RIGHT('0' + CAST(heure  AS VARCHAR(2)), 2) + ':' +
    RIGHT('0' + CAST(minute AS VARCHAR(2)), 2)    AS libelle_creneau,
    -- Libellé d'intervalle, plus lisible sur un axe :
    RIGHT('0' + CAST(heure  AS VARCHAR(2)), 2) + ':' +
    RIGHT('0' + CAST(minute AS VARCHAR(2)), 2) + '–' +
    RIGHT('0' + CAST((sec_fin + 1) / 3600 % 24 AS VARCHAR(2)), 2) + ':' +
    RIGHT('0' + CAST((sec_fin + 1) / 60 % 60   AS VARCHAR(2)), 2) AS libelle_intervalle,
    heure                                         AS heure_pleine,
    minute                                        AS minute_debut,
    sec_debut,
    sec_fin,
    CAST(CASE WHEN sec_debut >= 32400 AND sec_fin < 50400
              THEN 1 ELSE 0 END AS BIT)           AS est_fenetre_collecte,
    -- 32400 = 09:00:00   50400 = 14:00:00
    CAST(CASE WHEN sec_debut >= 33300 AND sec_fin < 49500
              THEN 1 ELSE 0 END AS BIT)           AS est_fenetre_analytique
    -- 33300 = 09:15:00   49500 = 13:45:00  (§14bis)
INTO    dim_heure
FROM    base
OPTION (MAXRECURSION 0);

ALTER TABLE dim_heure ALTER COLUMN heure_sk  INT NOT NULL;
ALTER TABLE dim_heure ALTER COLUMN sec_debut INT NOT NULL;
ALTER TABLE dim_heure ALTER COLUMN sec_fin   INT NOT NULL;
GO

ALTER TABLE dim_heure ADD CONSTRAINT pk_dim_heure PRIMARY KEY (heure_sk);
CREATE UNIQUE INDEX ux_dim_heure_sec ON dim_heure (sec_debut);
GO


-- C10 : effectifs
-- Attendu : 96 créneaux, 20 en fenêtre de collecte, 18 en analytique
SELECT  COUNT(*)                                    AS n_creneaux,
        SUM(CAST(est_fenetre_collecte   AS INT))    AS n_collecte,
        SUM(CAST(est_fenetre_analytique AS INT))    AS n_analytique
FROM    dim_heure;

-- C11 : les bornes de la fenêtre analytique
-- Attendu : premier = 09:15, dernier = 13:30 (créneau 13:30–13:45)
SELECT  MIN(libelle_creneau) AS premier, MAX(libelle_creneau) AS dernier
FROM    dim_heure WHERE est_fenetre_analytique = 1;

-- C12 : continuité — aucun trou, aucun recouvrement
-- Attendu : 0 ligne
SELECT  h.heure_sk, h.sec_fin, s.sec_debut
FROM        dim_heure AS h
INNER JOIN  dim_heure AS s ON s.heure_sk = (
                SELECT MIN(heure_sk) FROM dim_heure WHERE heure_sk > h.heure_sk)
WHERE       s.sec_debut <> h.sec_fin + 1;

-- C13 : contrôle sur un cas connu
-- 09:15 -> sec_debut 33300 ; 13:30 -> sec_debut 48600
SELECT heure_sk, libelle_intervalle, sec_debut, sec_fin,
       est_fenetre_collecte, est_fenetre_analytique
FROM   dim_heure
WHERE  heure_sk IN (900, 915, 1330, 1345, 1400);
