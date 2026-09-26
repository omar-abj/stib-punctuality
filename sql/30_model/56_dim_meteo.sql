-- =============================================================
-- 30_model/56_dim_meteo.sql
--
-- Grain : 1 ligne = 1 HEURE (grain de la source Open-Meteo)
-- Clé   : meteo_sk = AAAAMMJJHH  (+ ligne -1 = non renseigné)
-- Source: staging_meteo (ERA5 via Open-Meteo, heure locale
--         Europe/Brussels — VÉRIFIÉ : minimum thermique à 6h)
--
-- ⚠️ ÉTAT DES DONNÉES au 25/08/2026 : JUILLET SEULEMENT.
--    Les 13 jours d'août pointeront sur meteo_sk = -1.
--    Rechargement prévu début septembre (consolidation ERA5) :
--    relancer python/import_meteo.ipynb puis ce script. Rien d'autre à toucher.
--
-- ⚠️ La variance mesurée sur juillet est FAIBLE :
--    - pluie : 0 heure > 1 mm sur 155 heures de fenêtre
--    - chaleur : 5 jours >= 28 °C, dont 2 NON COLLECTÉS (11-12/07)
--    La dimension existe ; la décision d'en faire un axe d'analyse
--    reste ouverte jusqu'à la mesure sur 44 jours.
--
-- ⚠️ Piège n°15 — colinéarité : ne JAMAIS utiliser ensemble
--    temperature_2m + apparent_temp, ni vent_kmh + rafales_kmh,
--    dans un même modèle. La dimension porte les quatre ; c'est
--    à l'analyse d'en choisir une par famille.
-- Idempotent
-- =============================================================

DROP TABLE IF EXISTS dim_meteo;

;WITH source AS (
    SELECT  TRY_CAST(date_locale AS DATE)                        AS date_locale,
            TRY_CAST(LEFT(heure_locale, 2) AS INT)               AS heure,
            TRY_CAST(NULLIF(LTRIM(RTRIM(temperature_2m)),  '') AS DECIMAL(6,2)) AS temperature,
            TRY_CAST(NULLIF(LTRIM(RTRIM(apparent_temp)),   '') AS DECIMAL(6,2)) AS temp_ressentie,
            TRY_CAST(NULLIF(LTRIM(RTRIM(humidite_rel)),    '') AS DECIMAL(6,2)) AS humidite,
            TRY_CAST(NULLIF(LTRIM(RTRIM(precipitation_mm)),'') AS DECIMAL(6,2)) AS precipitation,
            TRY_CAST(NULLIF(LTRIM(RTRIM(pluie_mm)),        '') AS DECIMAL(6,2)) AS pluie,
            TRY_CAST(NULLIF(LTRIM(RTRIM(neige_cm)),        '') AS DECIMAL(6,2)) AS neige,
            TRY_CAST(NULLIF(LTRIM(RTRIM(code_meteo)),      '') AS INT)          AS code_wmo,
            TRY_CAST(NULLIF(LTRIM(RTRIM(vent_kmh)),        '') AS DECIMAL(6,2)) AS vent,
            TRY_CAST(NULLIF(LTRIM(RTRIM(rafales_kmh)),     '') AS DECIMAL(6,2)) AS rafales,
            TRY_CAST(NULLIF(LTRIM(RTRIM(couverture_nuage)),'') AS DECIMAL(6,2)) AS nuages
    FROM    staging_meteo
)
SELECT
    CAST(CONVERT(CHAR(8), s.date_locale, 112) AS BIGINT) * 100 + s.heure AS meteo_sk,
    s.date_locale,
    s.heure,
    s.temperature,
    s.temp_ressentie,
    s.humidite,
    s.precipitation,
    s.pluie,
    -- Écart mesuré nul sur juillet (piège n°14 non manifesté) :
    -- `rain` exclut les averses convectives, mais il n'y en a pas eu.
    CAST(CASE WHEN s.precipitation > s.pluie THEN 1 ELSE 0 END AS BIT) AS a_averse_convective,
    s.neige,
    s.code_wmo,
    s.vent,
    s.rafales,
    s.nuages,
    -- Classifications : NULL traité en PREMIER (piège n°8)
    CASE WHEN s.precipitation IS NULL THEN '0_inconnu'
         WHEN s.precipitation <  0.1  THEN '1_sec'
         WHEN s.precipitation <= 1.0  THEN '2_faible'
         WHEN s.precipitation <= 4.0  THEN '3_moderee'
         ELSE                              '4_forte'
    END AS classe_pluie,
    CASE WHEN s.temperature IS NULL THEN '0_inconnu'
         WHEN s.temperature <  10    THEN '1_froid'
         WHEN s.temperature <  20    THEN '2_doux'
         WHEN s.temperature <  28    THEN '3_chaud'
         WHEN s.temperature <  32    THEN '4_tres_chaud'
         ELSE                             '5_canicule'
    END AS classe_temp,
    CAST(0 AS BIT) AS est_inconnu
INTO    dim_meteo
FROM    source AS s
WHERE   s.date_locale IS NOT NULL AND s.heure IS NOT NULL;

-- ---------- La ligne « non renseigné » ----------
-- Indispensable : toute heure sans météo pointe ici plutôt que
-- de produire une FK nulle dans fact_ecart (anti-pattern).
-- Concerne actuellement les 13 jours d'août.
INSERT INTO dim_meteo (meteo_sk, date_locale, heure, classe_pluie, classe_temp, est_inconnu)
VALUES (-1, NULL, NULL, '0_inconnu', '0_inconnu', 1);

ALTER TABLE dim_meteo ALTER COLUMN meteo_sk BIGINT NOT NULL;
GO

ALTER TABLE dim_meteo ADD CONSTRAINT pk_dim_meteo PRIMARY KEY (meteo_sk);
CREATE INDEX ix_dim_meteo_date ON dim_meteo (date_locale, heure);
GO
