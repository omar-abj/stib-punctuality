/* ============================================================================
   65_dim_direction.sql  (V2)
   ----------------------------------------------------------------------------
   OBJET   Dimension partagee de direction. Relie fact_ecart (depuis 66),
           int_profil_arret et int_segment : un seul segment "sens" filtre
           tout le rapport.

   V1 - 19/09/2026 : recreee a l'identique du modele Power BI (fichier
        d'origine introuvable). 2 lignes, TINYINT.
   V2 - 19/09/2026 : ajout du MEMBRE INCONNU (-1), comme toutes les autres
        dimensions. Il recoit les passages dont la desserte est inconnue
        (desserte_sk = -1). TINYINT (0 a 255) ne stocke pas -1 : passage
        en SMALLINT.

   IDEMPOTENCE
        DROP + CREATE. Depuis 66, fact_ecart porte une FK vers cette table :
        la FK est supprimee d'abord si elle existe. Relancer 66 ensuite
        pour la recreer (ordre de rejeu : 65 -> 66).
   ========================================================================== */

USE TFE_STIB;
GO

IF OBJECT_ID(N'dbo.FK_fact_ecart_dim_direction', N'F') IS NOT NULL
    ALTER TABLE dbo.fact_ecart DROP CONSTRAINT FK_fact_ecart_dim_direction;
GO

DROP TABLE IF EXISTS dbo.dim_direction;
GO

CREATE TABLE dbo.dim_direction (
    direction_id  SMALLINT      NOT NULL PRIMARY KEY,
    libelle       NVARCHAR(30)  NOT NULL
);

INSERT INTO dbo.dim_direction (direction_id, libelle)
VALUES (-1, N'Sens inconnu'),
       ( 0, N'Sens aller'),
       ( 1, N'Sens retour');
GO

SELECT * FROM dbo.dim_direction ORDER BY direction_id;
GO
