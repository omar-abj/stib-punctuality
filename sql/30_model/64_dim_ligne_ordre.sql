/* 64_dim_ligne_ordre.sql
   Ordre d'affichage des lignes : le tri alphabetique d'un varchar place
   "10" avant "2". On materialise un rang numerique. Les identifiants
   alphanumeriques (T81, M1, N04) n'etant pas convertibles, ils passent
   apres les lignes purement numeriques, tries alphabetiquement.        */

IF COL_LENGTH('dbo.dim_ligne', 'ordre_ligne') IS NULL
    ALTER TABLE dbo.dim_ligne ADD ordre_ligne INT NULL;
GO

WITH calc AS (
    SELECT
        l.ligne_sk,
        ROW_NUMBER() OVER (
            ORDER BY
                CASE WHEN TRY_CAST(l.line_id AS INT) IS NULL THEN 1 ELSE 0 END,
                TRY_CAST(l.line_id AS INT),
                l.line_id
        ) AS rang
    FROM dbo.dim_ligne AS l
)
UPDATE l
SET ordre_ligne = c.rang
FROM dbo.dim_ligne AS l
JOIN calc          AS c ON c.ligne_sk = l.ligne_sk;
GO

SELECT line_id, ordre_ligne
FROM dbo.dim_ligne
ORDER BY ordre_ligne;