/* ============================================================================
   67_dim_arret_correspondances.sql
   ----------------------------------------------------------------------------
   OBJET   Ajoute a dim_arret le nombre de lignes desservant l'ARRET PHYSIQUE,
           et sa classe de correspondance. Alimente la page "Arrets" :
           les poles d'echange sont-ils moins ponctuels que les autres arrets ?

   DEFINITION DE L'ARRET PHYSIQUE : le NOM (stop_name).
        stop_id_racine ne convient pas : GARE DU MIDI en compte 10, ce sont
        des quais ou des groupes de quais, pas le pole. Le nom regroupe le
        pole tel que le voyageur le percoit.
        Controle du 23/09 : parmi les arrets a 5 lignes ou plus, l'etendue
        geographique maximale d'un meme nom est de 464 m (mediane ~170 m).
        Aucun cas d'homonymes eloignes : le regroupement par nom est sur.

   PERIMETRE   Les 71 lignes du classement (dim_ligne.dans_classement = 1),
        ET qui ont au moins 50 passages theoriques a l'arret sur la periode.
        Une ligne hors classement (M1, M5, T7, 35) ou de nuit n'est pas une
        correspondance utile dans le creneau analyse (09:15-13:45).

   V2 - 23/09/2026 : COMPTAGE SUR LES PASSAGES, PLUS SUR LE REFERENTIEL.
        La V1 comptait les lignes presentes dans dim_desserte. Or une
        desserte peut exister dans le GTFS sans qu'aucune course n'y passe :
        a ERASME, la ligne 1 (variante basculant sur le parcours du 5)
        totalisait 0 passage theorique et etait pourtant comptee, d'ou
        3 lignes au lieu de 2.
        La V2 joint dim_desserte a fact_ecart : une ligne ne compte que si
        elle a effectivement des passages annonces a cet arret.
        Seuil de 50 passages (~1 par jour) : ecarte les courses
        exceptionnelles sans exclure une ligne peu frequente.

   /!\ DEPENDANCE A LA PERIODE
        Le comptage decrit la periode collectee (01/07 - 26/08/2026).
        Une ligne suspendue pendant l'ete n'apparait pas comme
        correspondance, meme si elle dessert l'arret le reste de l'annee.

   /!\ CE QUE LA COLONNE NE DIT PAS
        nb_lignes_arret compte les lignes qui PASSENT, pas les correspondances
        effectivement pratiquees par les voyageurs, ni la frequence de
        l'arret. Deux arrets a 5 lignes n'ont pas le meme trafic.

   PREREQUIS   52-57 (dimensions), 62 (dans_classement)
   IDEMPOTENCE ADD conditionnel, UPDATE rejouable.
   DATE        23/09/2026
   ========================================================================== */

USE TFE_STIB;
GO

SET NOCOUNT ON;
GO

/* 1. Les colonnes ---------------------------------------------------------- */
IF COL_LENGTH('dbo.dim_arret', 'nb_lignes_arret') IS NULL
    ALTER TABLE dbo.dim_arret ADD nb_lignes_arret SMALLINT NULL;
GO

IF COL_LENGTH('dbo.dim_arret', 'classe_correspondance') IS NULL
    ALTER TABLE dbo.dim_arret ADD classe_correspondance NVARCHAR(20) NULL;
GO

IF COL_LENGTH('dbo.dim_arret', 'ordre_classe_correspondance') IS NULL
    ALTER TABLE dbo.dim_arret ADD ordre_classe_correspondance TINYINT NULL;
GO

/* 2. Le comptage ----------------------------------------------------------
   Une desserte = (ligne, sens, arret). On compte les LIGNES distinctes,
   pas les dessertes : une ligne qui passe dans les deux sens compte 1.
------------------------------------------------------------------------- */
WITH passages_ligne_arret AS (
    -- Une ligne "dessert" un arret si elle y a des passages ANNONCES.
    SELECT      d.stop_name,
                d.line_id,
                passages = SUM(CAST(f.nb_theorique AS BIGINT))
    FROM        dbo.dim_desserte AS d
    INNER JOIN  dbo.fact_ecart   AS f ON f.desserte_sk = d.desserte_sk
    INNER JOIN  dbo.dim_ligne    AS l
            ON  l.line_id = d.line_id COLLATE DATABASE_DEFAULT
    WHERE       l.dans_classement = 1
      AND       d.stop_name <> '?'
    GROUP BY    d.stop_name, d.line_id
),
lignes_par_nom AS (
    SELECT      stop_name,
                nb_lignes = COUNT(DISTINCT line_id)
    FROM        passages_ligne_arret
    WHERE       passages >= 50
    GROUP BY    stop_name
)
UPDATE      a
SET         a.nb_lignes_arret = ISNULL(n.nb_lignes, 0)
FROM        dbo.dim_arret     AS a
LEFT JOIN   lignes_par_nom    AS n
        ON  n.stop_name = a.stop_name COLLATE DATABASE_DEFAULT;
GO

/* 3. La classe ------------------------------------------------------------ */
UPDATE  dbo.dim_arret
SET     classe_correspondance =
            CASE
                WHEN nb_lignes_arret = 0      THEN N'Hors classement'
                WHEN nb_lignes_arret = 1      THEN N'1 ligne'
                WHEN nb_lignes_arret <= 3     THEN N'2 à 3 lignes'
                WHEN nb_lignes_arret <= 6     THEN N'4 à 6 lignes'
                ELSE                               N'7 lignes et plus'
            END,
        ordre_classe_correspondance =
            CASE
                WHEN nb_lignes_arret = 0      THEN 0
                WHEN nb_lignes_arret = 1      THEN 1
                WHEN nb_lignes_arret <= 3     THEN 2
                WHEN nb_lignes_arret <= 6     THEN 3
                ELSE                               4
            END;
GO

/* ===========================================================================
   CONTROLES
   ======================================================================== */

PRINT '--- C1 : aucun arret sans valeur (attendu : 0) -------------------------';
SELECT  sans_valeur = SUM(CASE WHEN nb_lignes_arret IS NULL THEN 1 ELSE 0 END),
        total_arrets = COUNT(*)
FROM    dbo.dim_arret;

PRINT '--- C2 : repartition des arrets par classe -----------------------------';
SELECT      a.classe_correspondance,
            a.ordre_classe_correspondance,
            nb_arrets = COUNT(*),
            pct = CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))
FROM        dbo.dim_arret AS a
GROUP BY    a.classe_correspondance, a.ordre_classe_correspondance
ORDER BY    a.ordre_classe_correspondance;

PRINT '--- C3 : les 15 plus gros poles (GARE DU MIDI en tete, ERASME a 2) -----';
SELECT TOP 15
            a.stop_name,
            a.nb_lignes_arret,
            nb_points = COUNT(*)
FROM        dbo.dim_arret AS a
WHERE       a.point_id <> '?'
GROUP BY    a.stop_name, a.nb_lignes_arret
ORDER BY    a.nb_lignes_arret DESC, a.stop_name;

PRINT '--- C4 : arrets sans aucune ligne classee (doit rester marginal) -------';
SELECT      nb_arrets = COUNT(*)
FROM        dbo.dim_arret
WHERE       nb_lignes_arret = 0
  AND       point_id <> '?';
GO

PRINT '--- C5 : controle cible, ERASME doit valoir 2 --------------------------';
SELECT DISTINCT stop_name, nb_lignes_arret, classe_correspondance
FROM   dbo.dim_arret
WHERE  stop_name IN ('ERASME', 'GARE DU MIDI', 'SIMONIS');
GO
