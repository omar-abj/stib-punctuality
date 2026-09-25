/* ============================================================================
   63_diag_non_apparies.sql  (V2)
   ----------------------------------------------------------------------------
   OBJET   Materialise en table les quatre causes de non-appariement.
           Alimente le visuel Q1-3, qui explique le poste gris de Q1-1.

   V2 - 19/09/2026 : LA DETTE EST SOLDEE
           La V1 (04/09) contenait quatre valeurs FIGEES, recopiees de
           l'execution du 03/09 sur 44 jours, faute d'avoir retrouve les
           regles de classement. Ces regles sont celles de
           94_decomposition_kpi.sql, partie B. Elles sont reprises ici a
           l'identique : la table se RECALCULE a chaque execution et reste
           juste quel que soit le perimetre (44 jours, 52 jours, ...).
           Le controle L2 n'est donc plus un detecteur de peremption :
           c'est un controle structurel, dont l'ecart doit TOUJOURS valoir 0.

   V3 - 21/09/2026 : libelles accentues (affiches tels quels dans le
           dashboard). Colonnes en NVARCHAR et chaines prefixees par N :
           sans le N, SQL Server interprete la chaine dans la page de codes
           de la base, et les accents peuvent etre alteres.

   V4 - 25/09/2026 : libelles en anglais (le rapport Power BI est redige en
           anglais). cause_nature : 'Service' ou 'Method'.

   /!\ REGLES DUPLIQUEES
           Les filtres de qualite de la cause 2 (nb_obs >= 2, fraicheur
           entre -120 et +180 s) et les types de mapping retenus
           ('exact', 'devie', 'abrege') DOIVENT etre identiques a ceux de
           45_int_appariement.sql et de 94 partie B. Toute modification
           de l'un se reporte dans les trois scripts.

   /!\ TABLE DE FAITS AGREGEE, PAS UNE DIMENSION.
           Grain = une cause, pas un passage. Dans Power BI, la charger SANS
           relation. Toute relation vers fact_ecart produirait des doubles
           comptages.

   PREREQUIS   45_int_appariement.sql, 61_fact_ecart_postes.sql
   IDEMPOTENCE DROP + CREATE. Aucune FK ne pointe vers cette table.
   COUT        quelques minutes (~416 000 theoriques croises a wrk_passages)
   ========================================================================== */

USE TFE_STIB;
GO

SET NOCOUNT ON;
GO

DROP TABLE IF EXISTS dbo.diag_non_apparies;
GO

CREATE TABLE dbo.diag_non_apparies (
    cause_id        TINYINT       NOT NULL PRIMARY KEY,
    cause_libelle   NVARCHAR(60)  NOT NULL,
    cause_nature    NVARCHAR(20)  NOT NULL,   -- N'Service' ou N'Method'
    nb_passages     INT           NOT NULL,
    ordre_affichage TINYINT       NOT NULL
);
GO

/* ---------------------------------------------------------------------------
   ETAPE 1 - Les theoriques non apparies (population a diagnostiquer)
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS #theo_orphelin;

SELECT      i.appariement_id,
            i.date_service,
            i.line_id,
            i.point_id,
            i.trip_headsign,
            i.passage_theorique,
            i.tolerance_sec
INTO        #theo_orphelin
FROM        dbo.int_appariement AS i
WHERE       i.statut_appariement = 'theorique_non_apparie';

CREATE CLUSTERED INDEX ix_orph
    ON #theo_orphelin (line_id, point_id, date_service, passage_theorique);
GO

/* ---------------------------------------------------------------------------
   ETAPE 2 - Classement de chaque orphelin (regles de 94 partie B)

   NATURE : la distinction qui porte le visuel.
     - Service : aucun vehicule n'est passe  -> l'indicateur mesure le reel
     - Methode : notre chaine n'a pas conclu -> l'indicateur mesure sa limite
   ------------------------------------------------------------------------ */
;WITH candidats AS (
    -- Tous les passages REELS BRUTS du meme triplet, le meme jour,
    -- sans aucun filtre de qualite ni de fenetre.
    SELECT      o.appariement_id,
                p.nb_obs,
                fraicheur_sec = DATEDIFF(SECOND, p.derniere_obs, p.arrivee_estimee),
                ecart_sec     = ABS(DATEDIFF(SECOND, o.passage_theorique, p.arrivee_estimee)),
                o.tolerance_sec
    FROM        #theo_orphelin AS o
    INNER JOIN  dbo.ref_feed_periode AS f
            ON  o.date_service BETWEEN f.date_debut AND f.date_fin
    INNER JOIN  dbo.map_destination AS m
            ON  m.feed_version   = f.feed_version
           AND  m.line_id        = o.line_id       COLLATE DATABASE_DEFAULT
           AND  m.trip_headsign  = o.trip_headsign COLLATE DATABASE_DEFAULT
           AND  m.type_mapping IN ('exact', 'devie', 'abrege')
    INNER JOIN  dbo.wrk_passages AS p
            ON  p.line_id     = o.line_id  COLLATE DATABASE_DEFAULT
           AND  p.point_id    = o.point_id COLLATE DATABASE_DEFAULT
           AND  p.destination = m.destination_rt
           AND  CAST(p.derniere_obs AS DATE) = o.date_service
),
bilan AS (
    SELECT      o.appariement_id,
                n_du_jour    = COUNT(c.appariement_id),
                n_dans_tol   = SUM(CASE WHEN c.ecart_sec <= c.tolerance_sec
                                        THEN 1 ELSE 0 END),
                n_valide_tol = SUM(CASE WHEN c.ecart_sec <= c.tolerance_sec
                                         AND c.nb_obs >= 2
                                         AND c.fraicheur_sec BETWEEN -120 AND 180
                                        THEN 1 ELSE 0 END)
    FROM        #theo_orphelin AS o
    LEFT  JOIN  candidats      AS c ON c.appariement_id = o.appariement_id
    GROUP BY    o.appariement_id
),
classe AS (
    SELECT      cause_id = CASE
                    WHEN b.n_du_jour    = 0 THEN 1
                    WHEN b.n_dans_tol   = 0 THEN 4
                    WHEN b.n_valide_tol = 0 THEN 2
                    ELSE                         3
                END
    FROM        bilan AS b
)
INSERT INTO dbo.diag_non_apparies
    (cause_id, cause_libelle, cause_nature, nb_passages, ordre_affichage)
SELECT      r.cause_id,
            r.cause_libelle,
            r.cause_nature,
            nb_passages = COUNT(c.cause_id),
            r.ordre_affichage
FROM        (VALUES
                (4, N'No observed vehicle within range',  N'Service', 1),
                (2, N'Removed by quality filters',        N'Method',  2),
                (3, N'Lost to a competing match',         N'Method',  3),
                (1, N'No data collected that day',        N'Method',  4)
            ) AS r (cause_id, cause_libelle, cause_nature, ordre_affichage)
LEFT JOIN   classe AS c ON c.cause_id = r.cause_id
GROUP BY    r.cause_id, r.cause_libelle, r.cause_nature, r.ordre_affichage;
GO

DROP TABLE IF EXISTS #theo_orphelin;
GO

/* ===========================================================================
   CONTROLES
   ======================================================================== */

PRINT '--- L1 : les quatre causes ---------------------------------------------';
SELECT
    d.cause_id,
    d.cause_libelle,
    d.cause_nature,
    d.nb_passages,
    CAST(100.0 * d.nb_passages
              /  SUM(d.nb_passages) OVER () AS DECIMAL(5,2)) AS pct_des_non_apparies
FROM dbo.diag_non_apparies AS d
ORDER BY d.ordre_affichage;

PRINT '--- L2 : bouclage sur fact_ecart (ecart DOIT valoir 0) ----------------';
SELECT
    (SELECT SUM(nb_passages) FROM dbo.diag_non_apparies)                AS total_diagnostic,
    (SELECT SUM(CAST(nb_theo_seul AS BIGINT)) FROM dbo.fact_ecart)      AS total_fact_ecart,
    (SELECT SUM(nb_passages) FROM dbo.diag_non_apparies)
  - (SELECT SUM(CAST(nb_theo_seul AS BIGINT)) FROM dbo.fact_ecart)      AS ecart;

PRINT '--- L3 : points de theorique par nature ---------------------------------';
SELECT
    d.cause_nature,
    SUM(d.nb_passages)                                                  AS nb_passages,
    CAST(100.0 * SUM(d.nb_passages)
              /  (SELECT SUM(CAST(nb_theorique AS BIGINT)) FROM dbo.fact_ecart)
         AS DECIMAL(5,2))                                               AS points_du_theorique
FROM dbo.diag_non_apparies AS d
GROUP BY d.cause_nature;
GO
