/*=============================================================================
  TFE STIB - 20_transform/44_ref_tolerance_ligne.sql
  ----------------------------------------------------------------------------
  OBJET : figer, ligne par ligne, la tolerance d'appariement T.

  POURQUOI T NE PEUT PAS ETRE UNE CONSTANTE
  ----------------------------------------------------------------------------
  T = 240 s convient a une ligne dont les passages sont espaces de 10 min :
  un candidat a 4 min ne peut etre que le bon vehicule, le suivant serait a
  10 min. Sur une ligne a 6 min d'intervalle, une tolerance de 4 min englobe
  le passage suivant : l'algorithme apparierait au mauvais horaire et
  produirait un resultat FAUX, pas absent. Un resultat faux ne se voit pas.

  D'ou la regle (§13.D) :  T = MIN(intervalle / 2, 300 s)

  POURQUOI LE P10 ET PAS LA MEDIANE
  ----------------------------------------------------------------------------
  La mediane decrit l'intervalle typique ; le P10 decrit les moments ou les
  passages sont les plus rapproches, donc ou le risque de confusion est
  maximal. Une tolerance se calibre sur le cas defavorable.

  POURQUOI UNE TABLE MATERIALISEE ET PAS UN CALCUL A LA VOLEE
  ----------------------------------------------------------------------------
  Meme raison que les cles de substitution : un calcul refait a chaque
  execution n'est pas reproductible. Si le GTFS change, T changerait
  SILENCIEUSEMENT et deux executions du meme script donneraient des
  resultats differents. Ici la valeur est figee, datee, et montrable.

  MESURE DU 27/08 (fenetre 09:15-13:45, 76 lignes) :
    aucune ligne sous 180 s. T s'etend de 180 a 300 s, facteur 1,7.
    En journee creuse meme le metro passe toutes les 7 min 30.

  COMPARABILITE ENTRE LIGNES
  ----------------------------------------------------------------------------
  T variable implique une censure de retard_sec variable selon la ligne :
  les medianes et les taux d'appariement BRUTS ne sont pas comparables
  entre lignes. Les comparaisons se font sur le taux de service conforme
  (fenetre -60/+180 s) rapporte au theorique observable. Comme toutes les
  lignes ont T >= 180 s, un retard de +180 s est mesurable partout.

  ENTREE : int_passage_theorique  (marquee par 41_est_observable.sql)
  SORTIE : dbo.ref_tolerance_ligne
  IDEMPOTENT : table reconstruite integralement.
=============================================================================*/

USE TFE_STIB;
GO

SET NOCOUNT ON;

DECLARE @plafond_sec INT = 300;   -- 5 minutes, limite haute (§13.D)
DECLARE @plancher_sec INT = 120;  -- garde-fou : jamais moins de 2 minutes

/*----------------------------------------------------------------------------
  1. L'intervalle theorique entre deux passages successifs
  ----------------------------------------------------------------------------
  LEAD() lit la ligne suivante dans l'ordre defini par le OVER. Le
  PARTITION BY definit ce qu'est "le passage suivant" : meme jour, meme
  ligne, meme arret, meme destination. Sans la destination, on melangerait
  les deux sens et les intervalles seraient divises par deux.

  Seuls les passages observables entrent : un terminus muet ne doit pas
  creer un faux intervalle long.
----------------------------------------------------------------------------*/

DROP TABLE IF EXISTS #ecarts;

SELECT
    line_id,
    route_type,
    intervalle_sec = DATEDIFF(SECOND, arrivee_theorique, suivant)
INTO #ecarts
FROM (
    SELECT
        line_id, route_type, arrivee_theorique,
        suivant = LEAD(arrivee_theorique) OVER (
            PARTITION BY date_service, line_id, point_id, trip_headsign
            ORDER BY arrivee_theorique)
    FROM dbo.int_passage_theorique
    WHERE est_observable = 1
) AS t
WHERE suivant IS NOT NULL
  AND DATEDIFF(SECOND, arrivee_theorique, suivant) > 0;
-- L'exclusion des intervalles nuls ecarte les doublons d'horaire
-- (deux courses au meme instant au meme arret), qui donneraient un
-- P10 de 0 et donc une tolerance absurde.

CREATE CLUSTERED INDEX ix_ec ON #ecarts (line_id);


/*----------------------------------------------------------------------------
  2. La table de reference
----------------------------------------------------------------------------*/

/*----------------------------------------------------------------------------
  2. La table de reference
  ----------------------------------------------------------------------------
  CREATE explicite et non SELECT INTO : SELECT INTO herite la nullabilite
  de la source, et line_id est nullable depuis stg_routes en cascade. Une
  cle primaire ne peut pas porter sur une colonne nullable.
----------------------------------------------------------------------------*/

DROP TABLE IF EXISTS dbo.ref_tolerance_ligne;

CREATE TABLE dbo.ref_tolerance_ligne (
    line_id            VARCHAR(50) NOT NULL,
    route_type         INT         NULL,
    nb_intervalles     INT         NOT NULL,
    intervalle_p10_sec INT         NOT NULL,
    intervalle_med_sec INT         NOT NULL,
    tolerance_sec      INT         NOT NULL,
    date_calcul        DATE        NOT NULL,
    CONSTRAINT pk_ref_tolerance_ligne PRIMARY KEY (line_id)
);

INSERT INTO dbo.ref_tolerance_ligne (
    line_id, route_type, nb_intervalles,
    intervalle_p10_sec, intervalle_med_sec, tolerance_sec, date_calcul)
SELECT
    line_id,
    route_type,
    COUNT(*),
    CAST(APPROX_PERCENTILE_CONT(0.10)
         WITHIN GROUP (ORDER BY intervalle_sec) AS INT),
    CAST(APPROX_PERCENTILE_CONT(0.50)
         WITHIN GROUP (ORDER BY intervalle_sec) AS INT),
    CAST(
        CASE
            WHEN APPROX_PERCENTILE_CONT(0.10)
                 WITHIN GROUP (ORDER BY intervalle_sec) / 2 > @plafond_sec
                 THEN @plafond_sec
            WHEN APPROX_PERCENTILE_CONT(0.10)
                 WITHIN GROUP (ORDER BY intervalle_sec) / 2 < @plancher_sec
                 THEN @plancher_sec
            ELSE APPROX_PERCENTILE_CONT(0.10)
                 WITHIN GROUP (ORDER BY intervalle_sec) / 2
        END AS INT),
    CAST(GETDATE() AS DATE)
FROM #ecarts
GROUP BY line_id, route_type;
GO

/*----------------------------------------------------------------------------
  2b. Lignes hors perimetre : aucun intervalle mesurable
  ----------------------------------------------------------------------------
  Une ligne dont aucun groupe (jour, arret, destination) ne contient deux
  passages ne produit aucun intervalle : LEAD() n'a rien a lire. C'est un
  service residuel, non exploite en journee creuse.

  Mesure du 27/08 : ligne 69, 72 passages, 3 courses, toutes vers 09:16.

  REGLE MESUREE, pas une liste de numeros de ligne : le critere est
  "nb_intervalles = 0", il attrapera tout cas futur sans intervention.

  MARQUEE, PAS SUPPRIMEE : la ligne reste dans la table de reference avec
  est_dans_perimetre = 0. Le perimetre devient une phrase chiffree au lieu
  d'un silence.
----------------------------------------------------------------------------*/

ALTER TABLE dbo.ref_tolerance_ligne ADD est_dans_perimetre BIT NOT NULL
    CONSTRAINT df_ref_tol_perim DEFAULT 1;
GO

INSERT INTO dbo.ref_tolerance_ligne (
    line_id, route_type, nb_intervalles, intervalle_p10_sec,
    intervalle_med_sec, tolerance_sec, date_calcul, est_dans_perimetre)
SELECT DISTINCT
    i.line_id, i.route_type, 0, -1, -1, 300,
    CAST(GETDATE() AS DATE), 0
FROM dbo.int_passage_theorique AS i
WHERE i.est_observable = 1
  AND NOT EXISTS (SELECT 1 FROM dbo.ref_tolerance_ligne AS r
                  WHERE r.line_id = i.line_id);


/*=============================================================================
  CONTROLES
=============================================================================*/

PRINT '=== F1 - Couverture : toutes les lignes du theorique sont-elles la ? ===';
-- Doit renvoyer 0 ligne. Une ligne absente ferait echouer la jointure du
-- script d'appariement, donc DISPARAITRE ses passages sans avertissement.
SELECT DISTINCT i.line_id, i.route_type
FROM dbo.int_passage_theorique AS i
WHERE i.est_observable = 1
  AND NOT EXISTS (SELECT 1 FROM dbo.ref_tolerance_ligne AS r
                  WHERE r.line_id = i.line_id);
GO


PRINT '=== F2 - Bornes ===';
SELECT line_id, intervalle_p10_sec, tolerance_sec
FROM dbo.ref_tolerance_ligne
WHERE tolerance_sec < 120 OR tolerance_sec > 300;

PRINT '=== F2b - Lignes sans intervalle mesurable ===';
-- Attendu : la ligne 69 seule. Toute autre ligne ici doit etre instruite
-- avant de poursuivre : un service residuel ne se devine pas.
SELECT line_id, route_type, tolerance_sec
FROM dbo.ref_tolerance_ligne
WHERE nb_intervalles = 0;


PRINT '=== F3 - Distribution des tolerances ===';
SELECT
    tolerance_sec,
    nb_lignes = COUNT(*),
    lignes    = STRING_AGG(line_id, ', ') WITHIN GROUP (ORDER BY line_id)
FROM dbo.ref_tolerance_ligne
GROUP BY tolerance_sec
ORDER BY tolerance_sec;
GO


PRINT '=== F4 - Non-regression ligne 25 ===';
-- Mesure du 27/08 : P10 = 600 s -> T plafonne a 300 s.
-- ATTENTION : l ancienne valeur etait 240 s. Le taux d appariement de la
-- ligne 25 va donc MONTER et tous ses chiffres valides vont bouger.
SELECT line_id, intervalle_p10_sec, intervalle_med_sec, tolerance_sec
FROM dbo.ref_tolerance_ligne
WHERE line_id = '25';
GO


PRINT '=== F5 - Lignes a surveiller : intervalle anormalement long ===';
-- La ligne 72 affichait une mediane d une heure au 27/08. Le plafond la
-- traite correctement, mais un intervalle pareil signale un service
-- atypique dont il faudra parler.
SELECT line_id, route_type, nb_intervalles, intervalle_p10_sec, intervalle_med_sec
FROM dbo.ref_tolerance_ligne
WHERE intervalle_med_sec > 1800
ORDER BY intervalle_med_sec DESC;
GO
