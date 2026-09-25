/* ============================================================================
   66_fact_ecart_direction.sql
   ----------------------------------------------------------------------------
   OBJET   Ajoute direction_id a fact_ecart et le relie a dim_direction.

   POURQUOI
        fact_ecart n'avait pas de sens de circulation : pour filtrer le fait
        par sens, il fallait passer par dim_desserte[direction_id], alors que
        les tables d'analyse spatiale utilisent dim_direction. Deux champs
        "sens" dans le rapport, et un segment qui ne filtrait qu'une partie
        des visuels.
        Meme denormalisation assumee que ligne_sk et arret_sk a cote de
        desserte_sk : dans un modele en etoile, on aplatit plutot que de
        faire du flocon.

   SOURCE DU SENS
        dim_desserte, via desserte_sk (et non dim_course : les reels non
        apparies n'ont pas de course, mais la plupart ont une desserte).
        Desserte inconnue (-1) ou sens hors {0,1}  ->  -1 (Sens inconnu).

   /!\ TYPE DE LA SOURCE (corrige le 19/09, 2e execution)
        dim_desserte.direction_id est un VARCHAR, et son membre inconnu
        porte '?'. Comparer ce VARCHAR a des entiers (IN (0, 1)) force
        SQL Server a convertir TOUTE la colonne en INT (l'entier a la
        priorite de type) : echec sur '?' (Msg 245), UPDATE annule,
        colonne restee NULL, puis echec du NOT NULL (Msg 515).
        TRY_CAST renvoie NULL au lieu d'echouer : '?' tombe dans le -1.

   METHODE
        ALTER TABLE ADD + UPDATE, comme 61 : reconstruire fact_ecart via 60
        declencherait le piege n°62 sans aucun benefice.
        /!\ L'ADD et l'UPDATE sont dans deux lots separes (GO) : SQL Server
        compile un lot entier avant de l'executer ; dans le meme lot,
        l'UPDATE ne "verrait" pas encore la nouvelle colonne.

   PREREQUIS   61_fact_ecart_postes.sql, 65_dim_direction.sql (V2)
   IDEMPOTENCE ADD conditionnel, UPDATE rejouable, FK conditionnelle.
   DATE        19/09/2026 (V2 le meme jour : TRY_CAST)
   ========================================================================== */

USE TFE_STIB;
GO

SET NOCOUNT ON;
GO

/* 1. La colonne ---------------------------------------------------------- */
IF COL_LENGTH('dbo.fact_ecart', 'direction_id') IS NULL
    ALTER TABLE dbo.fact_ecart ADD direction_id SMALLINT NULL;
GO

/* 2. Le remplissage ------------------------------------------------------ */
UPDATE      f
SET         f.direction_id = CASE WHEN TRY_CAST(d.direction_id AS SMALLINT) IN (0, 1)
                                  THEN TRY_CAST(d.direction_id AS SMALLINT)
                                  ELSE -1
                             END
FROM        dbo.fact_ecart   AS f
LEFT JOIN   dbo.dim_desserte AS d ON d.desserte_sk = f.desserte_sk;
GO

/* 3. Contraintes : jamais NULL, toujours une valeur connue de la dimension */
ALTER TABLE dbo.fact_ecart ALTER COLUMN direction_id SMALLINT NOT NULL;
GO

IF OBJECT_ID(N'dbo.FK_fact_ecart_dim_direction', N'F') IS NULL
    ALTER TABLE dbo.fact_ecart
        ADD CONSTRAINT FK_fact_ecart_dim_direction
        FOREIGN KEY (direction_id) REFERENCES dbo.dim_direction (direction_id);
GO

/* ===========================================================================
   CONTROLES
   ======================================================================== */

PRINT '--- D1 : repartition par sens ---------------------------------------';
SELECT      f.direction_id,
            dd.libelle,
            n   = COUNT(*),
            pct = CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))
FROM        dbo.fact_ecart    AS f
JOIN        dbo.dim_direction AS dd ON dd.direction_id = f.direction_id
GROUP BY    f.direction_id, dd.libelle
ORDER BY    f.direction_id;

PRINT '--- D2 : sens inconnu = desserte inconnue (ecart attendu : 0) -------';
SELECT      sens_inconnu      = SUM(CASE WHEN direction_id = -1 THEN 1 ELSE 0 END),
            desserte_inconnue = SUM(CASE WHEN desserte_sk  = -1 THEN 1 ELSE 0 END),
            ecart             = SUM(CASE WHEN direction_id = -1 THEN 1 ELSE 0 END)
                              - SUM(CASE WHEN desserte_sk  = -1 THEN 1 ELSE 0 END)
FROM        dbo.fact_ecart;

PRINT '--- D3 : coherence avec le sens de la course (attendu : 0) ----------';
-- Deux sources independantes du sens doivent s'accorder pour tout passage
-- qui a une course connue.
SELECT      desaccords = COUNT(*)
FROM        dbo.fact_ecart AS f
JOIN        dbo.dim_course AS c ON c.course_sk = f.course_sk
WHERE       f.course_sk <> -1
  AND       f.direction_id <> -1
  AND       TRY_CAST(c.direction_id AS SMALLINT) <> f.direction_id;
GO
