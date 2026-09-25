/*================================================================
   20_transform/41_est_observable.sql
   ----------------------------------------------------------------
   OBJET : marquer les passages theoriques pour lesquels le flux
           temps reel ne publie JAMAIS rien, sur les jours du
           perimetre d'analyse (dbo.wrk_jours).

   ORDRE D'EXECUTION - AMORCAGE EN DEUX TEMPS (note du 03/09)
   ----------------------------------------------------------------
   Ce script et 44_ref_tolerance_ligne.sql se lisent mutuellement :
     - la passe 3d ci-dessous lit dbo.ref_tolerance_ligne ;
     - 44 lit int_passage_theorique WHERE est_observable = 1,
       colonne creee ici.
   Sur une base ou ref_tolerance_ligne n'existe pas encore, la passe
   3d ECHOUE : c'est attendu. La sequence est donc :

       40  ->  41 (echoue en 3d)  ->  44  ->  41 (complet)  ->  45

   Le script etant idempotent, la seconde execution est sans risque.

   POURQUOI
   ----------------------------------------------------------------
   L'endpoint WaitingTimes est un service VOYAGEUR : il annonce dans
   combien de temps arrive le prochain vehicule pour ceux qui vont
   MONTER. A un terminus, personne ne monte : rien n'est publie.
   Ces passages theoriques n'ont donc aucun reel en face, quel que
   soit le jour, et quelle que soit la qualite du service.

   Sans ce marquage, ils seraient comptes comme des suppressions.
   Mesure du 27/08 : ~35 000 passages, 1,15 % du theorique reseau.

   REMPLACE l'exclusion codee en dur "0539 / ROGIER" de
   45_int_appariement.sql, qui traitait UN cas parmi des dizaines.

   ENTREES : int_passage_theorique, wrk_passages, wrk_jours,
             map_destination, ref_feed_periode, ref_tolerance_ligne
   SORTIE  : deux colonnes ajoutees a int_passage_theorique
             est_observable (0/1) et motif_inobservable

   ON MARQUE, ON NE SUPPRIME PAS : le chiffre doit rester
   presentable et la decision reversible.

   IDEMPOTENT : les colonnes sont supprimees puis recreees.
   ================================================================ */

USE TFE_STIB;
GO

SET NOCOUNT ON;

/*----------------------------------------------------------------
  1. Ce que le flux temps reel a REELLEMENT publie, tous jours
     confondus. Aucune restriction de fenetre horaire : on veut
     savoir si le couple existe, pas quand.
----------------------------------------------------------------*/

DROP TABLE IF EXISTS #desserte_observee;

SELECT DISTINCT
    p.line_id       COLLATE DATABASE_DEFAULT AS line_id,
    p.point_id      COLLATE DATABASE_DEFAULT AS point_id,
    m.trip_headsign COLLATE DATABASE_DEFAULT AS trip_headsign
INTO #desserte_observee
FROM dbo.wrk_passages AS p
JOIN dbo.wrk_jours AS j
  ON j.date_service = CAST(p.derniere_obs AS DATE)
  -- PERIMETRE TEMPOREL - ajout du 03/09.
  -- Sans cette jointure, #desserte_observee balaie TOUT wrk_passages,
  -- y compris les jours hors perimetre d'analyse. Un couple
  -- (ligne, arret, destination) publie une seule fois en dehors de la
  -- periode etudiee suffirait alors a declarer la desserte "observee",
  -- donc a NE PAS marquer inobservables des milliers de passages
  -- theoriques qui n'ont aucun reel en face dans la periode.
  -- Effet : est_observable devient plus permissif, le denominateur
  -- gonfle, le taux de conformite baisse. Silencieusement.
  -- wrk_jours est la source unique du perimetre (piege n°68).
JOIN dbo.ref_feed_periode AS f
  ON CAST(p.derniere_obs AS DATE) BETWEEN f.date_debut AND f.date_fin
JOIN dbo.map_destination AS m
  ON m.feed_version   = f.feed_version
 AND m.line_id        = p.line_id
 AND m.destination_rt = p.destination
 AND m.type_mapping IN ('exact', 'devie', 'abrege')
WHERE m.trip_headsign IS NOT NULL;

CREATE CLUSTERED INDEX ix_obs ON #desserte_observee (line_id, point_id, trip_headsign);

-- Controle d'amorcage : le nombre de jours balayes doit egaler
-- COUNT(*) FROM dbo.wrk_jours. Sinon le perimetre a diverge.
SELECT dessertes_observees = COUNT(*) FROM #desserte_observee;
SELECT jours_du_perimetre = COUNT(*) FROM dbo.wrk_jours;
GO


/*----------------------------------------------------------------
  2. Les deux colonnes
----------------------------------------------------------------*/
DROP INDEX IF EXISTS ix_ipt_observable ON dbo.int_passage_theorique;
GO

IF COL_LENGTH('dbo.int_passage_theorique', 'est_observable') IS NOT NULL
    ALTER TABLE dbo.int_passage_theorique DROP COLUMN est_observable;
IF COL_LENGTH('dbo.int_passage_theorique', 'motif_inobservable') IS NOT NULL
    ALTER TABLE dbo.int_passage_theorique DROP COLUMN motif_inobservable;
GO

ALTER TABLE dbo.int_passage_theorique ADD est_observable BIT NULL;
GO
ALTER TABLE dbo.int_passage_theorique ADD motif_inobservable VARCHAR(30) NULL;
GO
-- Un ALTER et l'objet qui en depend ne cohabitent pas dans un meme
-- batch : SQL Server compile tout avant d'executer. D'ou les GO.
-- (Piege n°43.)


/*----------------------------------------------------------------
  3. Le marquage, en trois passes ordonnees
----------------------------------------------------------------*/

/* 3a. Par defaut : observable. */
UPDATE dbo.int_passage_theorique
SET est_observable = 1, motif_inobservable = NULL;
GO

/* 3b. Aucun point_id : l'arret GTFS n'a pas d'equivalent temps reel.
       Ces passages ne peuvent pas s'apparier, faute d'identifiant. */
UPDATE dbo.int_passage_theorique
SET est_observable = 0, motif_inobservable = '1_arret_absent_du_flux'
WHERE point_id IS NULL;
GO

/* 3c. Le point_id existe, mais ce couple (ligne, arret, destination)
       n'a JAMAIS ete publie sur les jours du perimetre. C'est le cas
       des terminus :
       l'arret est bien annonce pour les departs, jamais pour les
       arrivees terminales. */
UPDATE i
SET est_observable = 0, motif_inobservable = '2_desserte_jamais_publiee'
FROM dbo.int_passage_theorique AS i
WHERE i.point_id IS NOT NULL
  AND NOT EXISTS (
        SELECT 1 FROM #desserte_observee AS o
        WHERE o.line_id       = i.line_id
          AND o.point_id      = i.point_id
          AND o.trip_headsign = i.trip_headsign
  );
GO

CREATE INDEX ix_ipt_observable
    ON dbo.int_passage_theorique (est_observable, line_id)
    INCLUDE (point_id, trip_headsign, arrivee_theorique);
GO
/* 3d. Lignes hors perimetre d'analyse.
       Mesure du 27/08 : la ligne 69 (3 courses, service residuel de
       09:16, aucun intervalle mesurable — cf. ref_tolerance_ligne).
       Ses passages theoriques existent mais ne sont pas analysables :
       ils n'ont ni tolerance, ni desserte, ni course en dimension.

       REGLE MESUREE, pas un numero de ligne en dur : le critere est
       l'absence dans le perimetre de ref_tolerance_ligne. */

UPDATE i
SET est_observable = 0, motif_inobservable = '3_ligne_hors_perimetre'
FROM dbo.int_passage_theorique AS i
WHERE NOT EXISTS (
        SELECT 1 FROM dbo.ref_tolerance_ligne AS tol
        WHERE tol.line_id = i.line_id COLLATE DATABASE_DEFAULT
          AND tol.est_dans_perimetre = 1);
GO

/*================================================================
  CONTROLES
================================================================*/

PRINT '=== E1 - Volume marque ===';
-- Attendu, ordre de grandeur : ~35 000 en motif 1, un volume
-- comparable ou superieur en motif 2 (les terminus de 76 lignes).
SELECT
    motif = ISNULL(motif_inobservable, '0_observable'),
    passages = COUNT(*),
    pct = CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))
FROM dbo.int_passage_theorique
GROUP BY ISNULL(motif_inobservable, '0_observable')
ORDER BY motif;
GO


PRINT '=== E2 - Le cas ROGIER doit etre capture ===';
-- Remplace l'exclusion codee en dur. Les arrivees terminales de la
-- 25 a Rogier (point 0539, headsign ROGIER) doivent ressortir
-- inobservables, SANS qu'aucun arret ne soit nomme dans le script.
SELECT
    point_id, trip_headsign,
    est_observable,
    motif = ISNULL(motif_inobservable, '0_observable'),
    passages = COUNT(*)
FROM dbo.int_passage_theorique
WHERE line_id = '25' AND point_id = '0539'
GROUP BY point_id, trip_headsign, est_observable, motif_inobservable
ORDER BY trip_headsign;
GO


PRINT '=== E3 - Les inobservables sont-ils bien des terminus ? ===';
-- Controle de vraisemblance. Si la part de derniers arrets est
-- faible, la regle attrape autre chose que ce qu'on croit.
WITH rangs AS (
    SELECT
        racine = st.stop_id_racine,
        st.trip_id, st.feed_version, st.stop_sequence,
        rang_max = MAX(st.stop_sequence) OVER (PARTITION BY st.feed_version, st.trip_id)
    FROM dbo.stg_stop_times AS st
)
SELECT
    i.motif_inobservable,
    passages = COUNT(*),
    pct_dernier_arret = CAST(100.0 * SUM(CASE WHEN r.stop_sequence = r.rang_max
                                              THEN 1 ELSE 0 END)
                             / NULLIF(COUNT(*), 0) AS DECIMAL(5,1))
FROM dbo.int_passage_theorique AS i
JOIN rangs AS r
  ON r.feed_version = i.feed_version
 AND r.trip_id      = i.trip_id
 AND r.stop_sequence = i.stop_sequence
WHERE i.est_observable = 0
GROUP BY i.motif_inobservable;
GO


PRINT '=== E4 - Impact sur le denominateur, ligne 25 ===';
-- Non-regression : combien la 25 perd-elle de theoriques ?
-- La reponse chiffre de combien son taux d'appariement va monter.
SELECT
    theoriques_bruts     = COUNT(*),
    theoriques_mesurables = SUM(CAST(est_observable AS INT)),
    ecartes              = SUM(1 - CAST(est_observable AS INT))
FROM dbo.int_passage_theorique
WHERE line_id = '25';
GO


PRINT '=== E5 - Repartition par mode ===';
-- Un mode nettement plus touche signalerait un biais de la regle.
SELECT
    route_type,
    theoriques  = COUNT(*),
    inobservables = SUM(1 - CAST(est_observable AS INT)),
    pct = CAST(100.0 * SUM(1 - CAST(est_observable AS INT))
               / COUNT(*) AS DECIMAL(5,2))
FROM dbo.int_passage_theorique
GROUP BY route_type
ORDER BY route_type;
GO


SELECT point_id, trip_headsign, motif_inobservable, passages = COUNT(*)
FROM dbo.int_passage_theorique
WHERE line_id = '25' AND est_observable = 0
GROUP BY point_id, trip_headsign, motif_inobservable
ORDER BY passages DESC;